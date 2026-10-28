--- _shared/lua/keystats/media_store.lua

--- Shared SQL planning and projection for the closed semantic media namespace.
--- Native ports own transactions and truthful write/read acknowledgement. This
--- module enables no observation and never places media on a numeric heatmap.
local M = {}
local Identity = require("keystats.media_identity")
local Release = require("keystats.physical_release")
local MAX_COUNTER = 2 ^ 53 - 1
local IDS = {
	["media.play_pause"] = true, ["media.next_track"] = true,
	["media.previous_track"] = true, ["media.brightness_up"] = true,
	["media.brightness_down"] = true,
}

local function integer(value, minimum, maximum)
	return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

--- Checks the independently closed persistence identity set.
---@param id any Candidate semantic identity.
---@return boolean known
function M.is_known(id) return type(id) == "string" and IDS[id] == true end

--- Keeps additive schema admission atomic without reserving an unnecessary writer.
--- Existing tables need only a read transaction; SQLite acquires write ownership
--- when a genuine upgrade executes DDL and still requires COMMIT acknowledgement.
---@param schema string Admitted packaged additive schema.
---@return string sql Deferred native transaction.
function M.schema_transaction(schema)
	assert(type(schema) == "string" and schema:find("%S"), "Media schema source is unavailable")
	return "BEGIN;\n" .. schema .. "\nCOMMIT;"
end

local function identity(row)
	assert(type(row) == "table" and M.is_known(row.media_id), "Unsupported stored media identity")
	assert(row.keycode == nil and row.scancode == nil, "Stored media cannot fabricate a keyboard position")
	assert(type(row.date) == "string" and row.date:match("^%d%d%d%d%-%d%d%-%d%d$"), "Invalid media date")
	assert(type(row.app) == "string" and row.app ~= "", "Invalid media application")
end

local function press(row)
	identity(row)
	assert(integer(row.count, 1, MAX_COUNTER), "Invalid media press counter")
end

local function hold(row)
	identity(row)
	assert(integer(row.count, 1, MAX_COUNTER) and integer(row.sum_ms, 0, MAX_COUNTER)
		and integer(row.max_ms, 0, Release.MAX_HOLD_MS), "Invalid media hold counters")
	assert(integer(row.tap_count, 0, MAX_COUNTER) and integer(row.hold_count, 0, MAX_COUNTER)
		and row.tap_count + row.hold_count == row.count and row.sum_ms >= row.max_ms, "Inconsistent media hold counters")
end

--- Quotes arbitrary text as a hex blob cast to TEXT, including NUL/newlines.
local function text(value)
	assert(type(value) == "string" and value ~= "", "Media SQL requires nonempty text")
	return "CAST(X'" .. value:gsub(".", function(byte) return string.format("%02x", byte:byte()) end) .. "' AS TEXT)"
end

--- Plans one additive media press UPSERT; execution is the native caller's job.
---@param device_id string Persisted collector/device partition, not a raw HID ID.
---@param row table Validated media press aggregate.
---@return string sql
function M.press_sql(device_id, row)
	press(row)
	return string.format("INSERT INTO ngram_media_keys (device_id,date,app,media_id,c) VALUES (%s,%s,%s,%s,%.0f) "
		.. "ON CONFLICT(device_id,date,app,media_id) DO UPDATE SET c=c+excluded.c;",
		text(device_id), text(row.date), text(row.app), text(row.media_id), row.count)
end

--- Plans one hold UPSERT, retaining MAX duration and additive sums/counters.
---@param device_id string Persisted collector/device partition.
---@param row table Validated media hold aggregate.
---@return string sql
function M.hold_sql(device_id, row)
	hold(row)
	return string.format("INSERT INTO agg_app_day_media_hold (device_id,date,app,media_id,sum_ms,count,max_ms,tap_count,hold_count) "
		.. "VALUES (%s,%s,%s,%s,%.0f,%.0f,%.0f,%.0f,%.0f) ON CONFLICT(device_id,date,app,media_id) DO UPDATE SET "
		.. "sum_ms=sum_ms+excluded.sum_ms,count=count+excluded.count,max_ms=MAX(max_ms,excluded.max_ms),"
		.. "tap_count=tap_count+excluded.tap_count,hold_count=hold_count+excluded.hold_count;",
		text(device_id), text(row.date), text(row.app), text(row.media_id), row.sum_ms, row.count,
		row.max_ms, row.tap_count, row.hold_count)
end

--- Removes only deltas exactly acknowledged by the actual native executor.
--- This port inherits its caller's enclosing transaction/rollback ownership.
---@param batch table Shared accumulator with separate media_ngram/media_hold buckets.
---@param device_id string Persisted collector partition.
---@param exec function Native SQL executor returning exactly true on acceptance.
---@return boolean drained
function M.flush(batch, device_id, exec)
	assert(type(batch) == "table" and type(exec) == "function", "Media flush requires batch and native executor")
	local drained = true
	for _, item in ipairs({ { batch.media_ngram, M.press_sql }, { batch.media_hold, M.hold_sql } }) do
		assert(type(item[1]) == "table", "Media flush requires separate media buckets")
		for key, row in pairs(item[1]) do
			if exec(item[2](device_id, row)) == true then item[1][key] = nil else drained = false end
		end
	end
	return drained
end

--- Projects a native press row using canonical dashboard field names.
---@param row table Native grouped row with date/app/media_id/c.
---@return integer count
function M.project_press(row)
	local candidate = { date = row.date, app = row.app, media_id = row.media_id, count = row.c }
	press(candidate)
	return candidate.count
end

--- Projects native hold columns without returning SQL-only aliases.
---@param row table Native grouped row with date/app/media_id/sum_ms/count/max_ms/tap_count/hold_count.
---@return table record Canonical s/n/m/tap/hold vocabulary.
function M.project_hold(row)
	hold(row)
	return { s = row.sum_ms, n = row.count, m = row.max_ms, tap = row.tap_count, hold = row.hold_count }
end

--- Creates the raw replay policy from the reviewed catalogue; persistence remains
--- closed even if a structurally valid foreign catalogue attempts extra identities.
---@param catalogue table Source-admitted shared catalogue.
---@return table policy
function M.policy(catalogue)
	local policy = Identity.new(catalogue)
	local count = 0
	for _, row in ipairs(catalogue.keys) do
		assert(M.is_known(row.id), "Unsupported catalogue media persistence identity")
		count = count + 1
	end
	assert(count == 5, "Media persistence requires the complete five-key catalogue")
	return policy
end

--- Plans one canonical raw event after the caller validates admitted identity.
---@param device_id string Persisted collector partition.
---@param event_id integer Durably reserved raw-event identifier.
---@param entry table Structurally validated physical_media_press/release event.
---@param encode function Shared/native JSON codec.
---@return string sql Raw insertion only; enclosing transaction is required.
function M.raw_sql(device_id, event_id, entry, encode)
	assert(integer(event_id, 1, MAX_COUNTER), "Invalid media raw event identifier")
	assert(entry.action == "physical_media_press" or entry.action == "physical_media_release", "Invalid media raw action")
	assert(M.is_known(entry.media_id), "Unsupported raw media identity")
	local metadata = { capture = entry.capture, device = entry.device, app = entry.app, media_id = entry.media_id }
	if entry.action == "physical_media_release" then metadata.hold_ms = entry.hold_ms end
	local encoded = assert(encode(metadata), "Media raw metadata encoding failed")
	return string.format("INSERT INTO events_system (device_id,id,ts,date,action,metadata_json) VALUES (%s,%.0f,%s,%s,%s,%s);",
		text(device_id), event_id, text(entry.timestamp), text(entry.timestamp:sub(1, 10)), text(entry.action), text(encoded))
end

--- Replays only known raw media actions into separate buckets, without typing.
---@param policy table Reviewed source catalogue policy.
---@param batch table Shared accumulator.
---@param entries table Ordered already admitted raw events.
---@param threshold_ms integer Shared inclusive tap boundary.
function M.replay(policy, batch, entries, threshold_ms)
	assert(type(entries) == "table", "Media replay requires an event array")
	assert(integer(threshold_ms, 0, Release.MAX_HOLD_MS), "Invalid media replay tap threshold")
	for key in pairs(entries) do
		assert(integer(key, 1, #entries), "Media replay requires a dense event array")
	end
	for index = 1, #entries do
		assert(type(entries[index]) == "table", "Media replay event is missing")
	end
	for _, entry in ipairs(entries) do
		assert(M.is_known(entry.media_id), "Unsupported replay media identity")
		assert(entry.scancode == nil, "Media replay cannot fabricate a scan code")
		if entry.action == "physical_media_press" then policy.aggregate_press(batch.media_ngram, entry)
		elseif entry.action == "physical_media_release" then policy.aggregate_hold(batch.media_hold, entry, threshold_ms)
		else error("Unsupported replay media action") end
	end
end

--- Plans one transaction-owned rebuild directly from canonical raw SQLite rows.
--- Native SQL reads and replacement share a write lock, so a concurrent writer
--- cannot insert between a snapshot and the deletion of its derived partition.
--- The admission table forces malformed/unknown raw media rows to fail the whole
--- transaction instead of silently dropping them; numeric rows are never touched.
---@param device_id string Exact collector partition to rebuild.
---@param threshold_ms integer Shared inclusive tap boundary.
---@return string sql Must execute inside BEGIN IMMEDIATE/COMMIT.
function M.rebuild_sql(device_id, threshold_ms)
	assert(integer(threshold_ms, 0, Release.MAX_HOLD_MS), "Invalid media rebuild tap threshold")
	local partition = text(device_id)
	local where = " WHERE device_id=" .. partition .. " AND action IN ('physical_media_press','physical_media_release')"
	local id = "json_extract(metadata_json,'$.media_id')"
	local app = "json_extract(metadata_json,'$.app')"
	local duration = "json_extract(metadata_json,'$.hold_ms')"
	local known = "'media.play_pause','media.next_track','media.previous_track','media.brightness_up','media.brightness_down'"
	return "CREATE TEMP TABLE media_rebuild_admission (valid INTEGER NOT NULL CHECK(valid=1));\n"
		.. "INSERT INTO media_rebuild_admission SELECT CASE WHEN json_valid(metadata_json) AND json_type(metadata_json)='object' "
		.. "AND " .. id .. " IN (" .. known .. ") AND json_type(metadata_json,'$.app')='text' AND length(CAST(" .. app .. " AS BLOB))>0 "
		.. "AND json_type(metadata_json,'$.capture')='text' AND length(CAST(json_extract(metadata_json,'$.capture') AS BLOB))>0 "
		.. "AND json_type(metadata_json,'$.device')='text' AND instr(json_extract(metadata_json,'$.device'),char(0))=0 AND json_extract(metadata_json,'$.device') NOT GLOB '*[^0-9]*' "
		.. "AND substr(json_extract(metadata_json,'$.device'),1,1) BETWEEN '1' AND '9' "
		.. "AND (length(json_extract(metadata_json,'$.device'))<20 OR (length(json_extract(metadata_json,'$.device'))=20 "
		.. "AND json_extract(metadata_json,'$.device')<='18446744073709551615')) "
		.. "AND json_type(metadata_json,'$.keycode') IS NULL AND json_type(metadata_json,'$.scancode') IS NULL "
		.. "AND substr(ts,1,11) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ' AND date=substr(ts,1,10) "
		.. "AND (action='physical_media_press' OR (json_type(metadata_json,'$.hold_ms')='integer' AND "
		.. duration .. " BETWEEN 0 AND 9223372036854)) THEN 1 ELSE 0 END FROM events_system" .. where .. ";\n"
		.. "DELETE FROM ngram_media_keys WHERE device_id=" .. partition .. ";\n"
		.. "DELETE FROM agg_app_day_media_hold WHERE device_id=" .. partition .. ";\n"
		.. "INSERT INTO ngram_media_keys (device_id,date,app,media_id,c) SELECT device_id,date," .. app .. "," .. id
		.. ",COUNT(*) FROM events_system" .. where .. " AND action='physical_media_press' GROUP BY device_id,date," .. app .. "," .. id .. ";\n"
		.. "INSERT INTO agg_app_day_media_hold (device_id,date,app,media_id,sum_ms,count,max_ms,tap_count,hold_count) "
		.. "SELECT device_id,date," .. app .. "," .. id .. ",SUM(" .. duration .. "),COUNT(*),MAX(" .. duration .. "),"
		.. "SUM(CASE WHEN " .. duration .. "<=" .. string.format("%.0f", threshold_ms) .. " THEN 1 ELSE 0 END),"
		.. "SUM(CASE WHEN " .. duration .. ">" .. string.format("%.0f", threshold_ms) .. " THEN 1 ELSE 0 END) FROM events_system"
		.. where .. " AND action='physical_media_release' GROUP BY device_id,date," .. app .. "," .. id .. ";\n"
		.. "DROP TABLE media_rebuild_admission;"
end

return M
