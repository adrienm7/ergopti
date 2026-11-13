--- metrics/engine/reader/rebuild_snapshot.lua

--- Isolated SQLite rebuild snapshot and conditional atomic publication.
--- No path is reopened: the source is always the admitted writer handle.
local M = {}
local PAGE_STEP = 128
local TRANSFER_BUDGET_NS = 250000000
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
		return { db = stage, owner = owner, captured = captured, sqlite = sqlite, tables = tables,
			current = current, clock = clock, cleanup = close_on_failure, lease = lease }
	end)
	if not ok then close_on_failure(); return nil, "snapshot refused", terminal_owner_failure end
	return result
end

--- Publishes only one fully rebuilt partition, and its caller-supplied cursor SQL.
function M.publish(snapshot, device_sql, cursor_sql)
	local owner, stage, sqlite = snapshot.owner, snapshot.db, snapshot.sqlite
	local attached, backup, begun, leased, uncertain = false, nil, false, false, false
	local next_witness
	local function release_target()
		if not leased then return true end
		local called, released = pcall(snapshot.lease.release, owner)
		if not called or released ~= true then terminal_owner_failure = true; return false end
		leased = false
		return true
	end
	local ok = pcall(function()
		assert(snapshot.current() == owner and same(snapshot.captured, witness(owner)), "source changed")
		assert(owner:exec("ATTACH DATABASE '' AS ergopti_rebuild_stage;") == sqlite.OK, "attach refused")
		attached = true
		assert(snapshot.lease.acquire(owner), "cannot lease destination handle")
		leased = true
		backup = assert(sqlite.backup_init(owner, "ergopti_rebuild_stage", stage, "temp"), "copy refused")
		local start = snapshot.clock()
		while true do
			local rc = backup:step(PAGE_STEP)
			assert(snapshot.clock() - start <= TRANSFER_BUDGET_NS, "copy budget exceeded")
			if rc == sqlite.DONE then break end
			assert(rc == sqlite.OK, "copy step refused")
		end
		local completed = backup
		backup = nil -- Never retry a consumed backup owner.
		local called, rc = pcall(completed.finish, completed)
		if not called then
			uncertain, terminal_owner_failure = true, true
			terminal_backup_debt = { backup = completed, owner = owner, stage = stage }
			error("copy finish uncertain", 0)
		end
		assert(release_target(), "cannot release destination lease")
		assert(rc == sqlite.OK, "copy finish refused")
		assert(owner:exec("BEGIN IMMEDIATE;") == sqlite.OK, "publish transaction refused")
		begun = true
		assert(snapshot.current() == owner and same(snapshot.captured, witness(owner)), "source changed")
		for _, name in ipairs(snapshot.tables) do
			assert(owner:exec("DELETE FROM main." .. name .. " WHERE device_id=" .. device_sql .. ";") == sqlite.OK,
				"old partition could not be removed")
			assert(owner:exec("INSERT INTO main." .. name .. " SELECT * FROM ergopti_rebuild_stage." .. name
				.. " WHERE device_id=" .. device_sql .. ";") == sqlite.OK, "new partition could not be inserted")
		end
		if cursor_sql then assert(owner:exec(cursor_sql) == sqlite.OK, "cursor publication refused") end
		next_witness = assert(witness(owner), "published source witness unavailable")
		assert(owner:exec("COMMIT;") == sqlite.OK, "publish commit refused")
		begun = false
	end)
	if backup then
		local pending = backup; backup = nil
		local called = pcall(pending.finish, pending)
		if not called then
			uncertain, terminal_owner_failure = true, true
			terminal_backup_debt = { backup = pending, owner = owner, stage = stage }
		end
	end
	if not uncertain then release_target() end
	-- No SQLite API may touch the destination while backup ownership is uncertain.
	if uncertain then return false, nil, true end
	if begun then
		local called, rc = pcall(owner.exec, owner, "ROLLBACK;")
		if not called or rc ~= sqlite.OK then terminal_owner_failure = true end
	end
	local detached = true
	if attached then
		local called, rc = pcall(owner.exec, owner, "DETACH DATABASE ergopti_rebuild_stage;")
		detached = called and rc == sqlite.OK
		if not detached then terminal_owner_failure = true end
	end
	return ok and detached, ok and detached and next_witness or nil, terminal_owner_failure
end

function M.close(snapshot)
	return snapshot.cleanup()
end

return M
