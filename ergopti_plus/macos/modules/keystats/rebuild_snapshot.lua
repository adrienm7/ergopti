--- modules/keystats/rebuild_snapshot.lua

--- Isolated SQLite rebuild snapshot and conditional day-by-day publication.
--- No path is reopened: the source is always the admitted writer handle.
local Literal = require("core.fs.engine.sqlite.literal")

local M = {}
local PAGE_STEP = 128
-- Hammerspoon consumes the native SQLite pointer even on a failed close.
local terminal_close_failure = false
local terminal_owner_failure = false
local terminal_backup_debt = nil

local function scalar(db, sql, field)
	local value, count
	count = 0
	for row in db:nrows(sql) do value, count = row[field], count + 1 end
	if count ~= 1 or math.type(value) ~= "integer" or value < 0 then return nil end
	return value
end

--- The refusal text of a caught error, without the chunk position Lua adds,
--- so a field log names the step instead of a source line.
--- @param err any Caught error value.
--- @return string cause
local function cause(err)
	return (tostring(err):gsub("^[^\n]-:%d+: ", "", 1))
end

local function witness(db)
	local version = scalar(db, "PRAGMA data_version;", "data_version")
	local changes = scalar(db, "SELECT total_changes() AS n;", "n")
	if not version or not changes then return nil end
	return { version = version, changes = changes }
end

local function same(a, b)
	return a and b and a.version == b.version and a.changes == b.changes
end

M.witness = witness
M.same = same

--- @param owner userdata Exact canonical writer handle.
--- @param sqlite table Native Hammerspoon SQLite binding.
--- @param tables table Exhaustive derived tables.
--- @param current function Returns the currently owned writer handle.
--- @param pace function Cooperative pause for source snapshot only.
--- @param clock function Monotone nanosecond clock.
--- @return table|nil snapshot
function M.open(owner, sqlite, tables, current, pace, clock, register_cleanup, lease)
	if terminal_close_failure or terminal_owner_failure or type(sqlite.backup_init) ~= "function" or type(current) ~= "function" or current() ~= owner then
		return nil, "snapshot capabilities unavailable"
	end
	local stage = sqlite.open("")
	if not stage then return nil, "cannot open private snapshot" end
	local backup, closed, leased = nil, false, false
	local function release_lease()
		if not leased then return true end
		local ok, released = pcall(lease.release, owner)
		if not ok or released ~= true then terminal_owner_failure = true; return false end
		leased = false
		return true
	end
	local function close_on_failure()
		if terminal_backup_debt and terminal_backup_debt.stage == stage then return false end
		if closed then return not terminal_close_failure and not terminal_owner_failure end
		closed = true
		if backup then
			local pending = backup; backup = nil
			local called = pcall(pending.finish, pending)
			-- An exception gives no receipt that the backup owner was consumed.
			if not called then
				terminal_backup_debt = { backup = pending, stage = stage, owner = owner }
				terminal_close_failure = true
				return false
			end
		end
		local released = release_lease()
		local called, rc = pcall(stage.close, stage)
		if not called or rc ~= sqlite.OK then terminal_close_failure = true end
		return released and not terminal_close_failure and not terminal_owner_failure
	end
	if register_cleanup then register_cleanup(close_on_failure) end
	local ok, result = pcall(function()
		local captured = assert(witness(owner), "cannot observe source revision")
		assert(type(lease) == "table" and lease.acquire(owner), "cannot lease source handle")
		leased = true
		backup = assert(sqlite.backup_init(stage, "main", owner, "main"), "cannot start source snapshot")
		while true do
			local rc = backup:step(PAGE_STEP)
			if rc == sqlite.DONE then break end
			assert(rc == sqlite.OK, "source snapshot step refused")
			if pace then pace() end
			assert(current() == owner and same(captured, witness(owner)), "source changed during snapshot")
		end
		local completed = backup
		backup = nil -- finish consumes the native object even when it reports failure.
		local called, finish_rc = pcall(completed.finish, completed)
		if not called then
			terminal_backup_debt = { backup = completed, stage = stage, owner = owner }
			terminal_close_failure = true
			error("source snapshot finish uncertain", 0)
		end
		assert(release_lease(), "cannot release source lease")
		assert(finish_rc == sqlite.OK, "source snapshot finish refused")
		assert(current() == owner and same(captured, witness(owner)), "source changed after snapshot")
		-- TEMP derived tables intentionally have no copied parent tables. Keep
		-- foreign-key enforcement on the canonical publisher untouched.
		assert(stage:exec("PRAGMA foreign_keys=OFF;") == sqlite.OK, "cannot configure staging constraints")
		assert(scalar(stage, "PRAGMA foreign_keys;", "foreign_keys") == 0, "staging constraints remain enabled")
		for _, name in ipairs(tables) do
			assert(name:match("^[%w_]+$"), "invalid derived table")
			local definition
			for row in stage:nrows("SELECT sql FROM main.sqlite_master WHERE type='table' AND name='" .. name .. "';") do
				definition = row.sql
			end
			assert(type(definition) == "string", "missing derived table")
			local ddl, replaced = definition:gsub("^CREATE TABLE ", "CREATE TEMP TABLE ", 1)
			assert(replaced == 1 and stage:exec(ddl) == sqlite.OK, "cannot create isolated derived table")
		end
		local columns = {}
		for _, name in ipairs(tables) do
			local list, has_device, has_date = {}, false, false
			for row in stage:nrows("PRAGMA temp.table_info(" .. name .. ");") do
				assert(type(row.name) == "string" and row.name:match("^[%w_]+$"), "invalid derived column")
				list[#list + 1] = row.name
				has_device = has_device or row.name == "device_id"
				has_date = has_date or row.name == "date"
			end
			-- Publication replaces one day at a time; a table without both keys
			-- could not be replaced by day and would publish a mixed partition.
			assert(has_device and has_date, "derived table " .. name .. " has no device_id and date columns")
			columns[name] = list
		end
		return { db = stage, owner = owner, captured = captured, sqlite = sqlite, tables = tables,
			columns = columns, current = current, pace = pace, clock = clock, cleanup = close_on_failure }
	end)
	if not ok then close_on_failure(); return nil, "snapshot refused: " .. cause(result), terminal_owner_failure end
	return result
end

--- Renders one stored value as an SQL literal of the same type.
--- @param value any Value read from the staging connection.
--- @return string literal
local function sql_value(value)
	if value == nil then return "NULL" end
	if math.type(value) == "integer" then return tostring(value) end
	if math.type(value) == "float" then
		assert(value == value and value ~= math.huge and value ~= -math.huge, "non-finite derived value")
		return string.format("%.17g", value)
	end
	assert(type(value) == "string", "unsupported derived value type " .. type(value))
	return "'" .. Literal.escape(value) .. "'"
end

--- The first day after `after` that the partition holds in either database.
--- Each per-table probe walks the (device_id, date) primary-key prefix, so one
--- statement per connection finds a day in a few index seeks instead of a scan
--- of millions of rows.
local function next_day(snapshot, device_sql, after)
	local condition = " WHERE device_id=" .. device_sql .. (after and (" AND date>" .. sql_value(after)) or "")
	local found = nil
	for _, source in ipairs({ { snapshot.db, "temp." }, { snapshot.owner, "main." } }) do
		local probes = {}
		for _, name in ipairs(snapshot.tables) do
			probes[#probes + 1] = "SELECT MIN(date) AS day FROM " .. source[2] .. name .. condition
		end
		for row in source[1]:nrows("SELECT MIN(day) AS day FROM (" .. table.concat(probes, " UNION ALL ") .. ");") do
			local day = row.day
			if day ~= nil then
				assert(type(day) == "string", "derived date is not text")
				if found == nil or day < found then found = day end
			end
		end
	end
	return found
end

--- Replaces one fully rebuilt partition, one day per transaction, then runs the
--- caller's cursor SQL in its own transaction.
---
--- Each day replaces every derived table's rows of that day at once, so a reader
--- never sees a day half old and half new. The pace runs between two days, when
--- no transaction is open: a partition of millions of n-gram rows never holds the
--- main thread in one block, and a lock-free reader still sees committed files.
--- Every day re-proves that nothing else wrote to the canonical handle since the
--- snapshot or this publication's previous commit.
--- @param snapshot table Snapshot returned by M.open.
--- @param device_sql string SQL literal of the device whose partition is published.
--- @param cursor_sql string|nil SQL committed once every day is in.
--- @return boolean published
--- @return table|nil next_witness Witness after the last commit.
--- @return boolean poisoned True when the canonical handle needs quarantine.
--- @return string|table detail Refusal cause, or { days, longest_ns } on success.
function M.publish(snapshot, device_sql, cursor_sql)
	local owner, stage, sqlite = snapshot.owner, snapshot.db, snapshot.sqlite
	local begun, step = false, "start"
	local days, longest_ns, day = 0, 0, nil
	local function transaction(label, body)
		step = label
		assert(snapshot.current() == owner, "the canonical writer handle changed")
		assert(owner:exec("BEGIN IMMEDIATE;") == sqlite.OK, "publish transaction refused: " .. tostring(owner:errmsg()))
		begun = true
		local started = snapshot.clock()
		assert(same(snapshot.captured, witness(owner)), "source changed")
		body()
		local next_witness = assert(witness(owner), "published source witness unavailable")
		assert(owner:exec("COMMIT;") == sqlite.OK, "publish commit refused: " .. tostring(owner:errmsg()))
		begun = false
		snapshot.captured = next_witness
		longest_ns = math.max(longest_ns, snapshot.clock() - started)
	end
	local ok, failure = pcall(function()
		while true do
			step = "find the next day"
			day = next_day(snapshot, device_sql, day)
			if day == nil then break end
			local day_sql = sql_value(day)
			transaction("publish day " .. day, function()
				for _, name in ipairs(snapshot.tables) do
					assert(owner:exec("DELETE FROM main." .. name .. " WHERE device_id=" .. device_sql
						.. " AND date=" .. day_sql .. ";") == sqlite.OK, "old rows of " .. name .. " could not be removed")
					local columns, values = snapshot.columns[name], {}
					for row in stage:nrows("SELECT * FROM temp." .. name .. " WHERE device_id=" .. device_sql
						.. " AND date=" .. day_sql .. ";") do
						local literals = {}
						for index, column in ipairs(columns) do literals[index] = sql_value(row[column]) end
						values[#values + 1] = "(" .. table.concat(literals, ",") .. ")"
					end
					if #values > 0 then
						assert(owner:exec("INSERT INTO main." .. name .. "(" .. table.concat(columns, ",") .. ") VALUES "
							.. table.concat(values, ",") .. ";") == sqlite.OK,
							"new rows of " .. name .. " could not be inserted: " .. tostring(owner:errmsg()))
					end
				end
			end)
			days = days + 1
			if snapshot.pace then snapshot.pace() end
		end
		if cursor_sql then
			transaction("publish the cursor", function()
				assert(owner:exec(cursor_sql) == sqlite.OK, "cursor publication refused: " .. tostring(owner:errmsg()))
			end)
		end
	end)
	if begun then
		local called, rc = pcall(owner.exec, owner, "ROLLBACK;")
		if not called or rc ~= sqlite.OK then terminal_owner_failure = true end
	end
	if not ok then
		return false, nil, terminal_owner_failure, string.format("%s after %d published day(s) (%s)",
			cause(failure), days, step)
	end
	return true, snapshot.captured, terminal_owner_failure, { days = days, longest_ns = longest_ns }
end

function M.close(snapshot)
	return snapshot.cleanup()
end

return M
