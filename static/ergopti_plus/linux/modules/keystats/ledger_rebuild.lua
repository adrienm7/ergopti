--- modules/keystats/ledger_rebuild.lua

--- ==============================================================================
--- MODULE: Foreign Device Aggregate Rebuild (Linux)
--- DESCRIPTION:
--- Rebuilds the derived rows of one imported device from its raw rows, as
--- macOS does after a foreign ledger import (log_manager
--- _rebuild_aggregates_from_raw): every Linux dashboard reads aggregates only,
--- so a raw import alone would show nothing.
---
--- FEATURES & RATIONALE:
--- 1. Same walk, same rows. Typing rows go through the shared walker
---    (aggregate_walker), app and window switches through its switch walks and
---    system rows through the macOS system-day rules, then every row is
---    rendered by the writer's own derived formatters: the rebuilt partition is
---    what a local flush of the same events would have written.
--- 2. One partition, one script. The returned SQL deletes every derived row of
---    the device and inserts the rebuilt ones; the caller runs it inside the
---    transaction that clears the import's pending mark, so a dashboard never
---    sees a half-rebuilt device.
--- 3. A row is bucketed by the hour of its own timestamp (shared
---    walker.timestamp_slot), as the macOS replay does: a replayed row carries
---    no per-keystroke clock.
--- 4. Refusals are loud. A typing row whose events cannot be read (another
---    machine's encrypted text, a malformed array) refuses the whole rebuild,
---    as on macOS: certifying a partial walk would show wrong totals forever.
--- ==============================================================================

local M = {}

local Json = require("json")
local SharedWalker = require("keystats.walker")
local AggregateWalker = require("modules.keystats.aggregate_walker")
local SqliteCommand = require("modules.keystats.sqlite_command")

local Helpers = require("keystats.aggregator_helpers")

local SEPARATOR = "\1"

--- System-day stat names a manifest_increment row may bump (macOS events.lua).
local MANIFEST_STAT_FIELDS = { hs_suggested = true, llm_suggested = true }

--- The daily families the walker fills, and the writer formatter of each.
local DAILY_FORMATTERS = {
	chars_class = "chars_class", errors = "errors", hourly = "hourly", hourly_min5 = "hourly_min5",
	app_buckets = "app_bucket", bursts = "burst", sessions = "session", ergo = "ergo", layouts = "layout",
}





-- ================================
-- ================================
-- ======= 1/ Raw Row Reads =======
-- ================================
-- ================================

local function unhex(text)
	if #text % 2 ~= 0 or text:find("[^%x]") then return nil end
	return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

--- Reads one family's rows, every column hex-encoded so a newline or a NUL in
--- a value cannot break the line framing.
--- @param store table { query_rows }
--- @param table_name string Raw table.
--- @param columns table Column names.
--- @param device_id string Device partition.
--- @return table rows Array of { column = value }.
local function read_rows(store, table_name, columns, device_id)
	local parts = {}
	for index, column in ipairs(columns) do parts[index] = "hex(coalesce(" .. column .. ",''))" end
	local lines = store.query_rows(string.format("SELECT %s FROM %s WHERE device_id='%s' ORDER BY ts, id;",
		table.concat(parts, " || ' ' || "), table_name, SqliteCommand.escape_literal(device_id)))
	if lines == nil then error("cannot read " .. table_name .. " of the imported device", 0) end
	local rows = {}
	for _, line in ipairs(lines) do
		local row, index = {}, 0
		for field in (line .. " "):gmatch("(%x*) ") do
			index = index + 1
			local value = unhex(field)
			if value == nil or columns[index] == nil then error("malformed " .. table_name .. " row", 0) end
			row[columns[index]] = value
		end
		if index ~= #columns then error("malformed " .. table_name .. " row", 0) end
		rows[#rows + 1] = row
	end
	return rows
end

--- Decodes one typing row's events, refusing every shape macOS refuses.
--- @param plaintext string Decrypted events_json.
--- @return table events
local function typing_events(plaintext)
	if plaintext:match("^%s*{%s*}%s*$") then return {} end
	if not plaintext:match("^%s*%[") then error("typing event shape refused", 0) end
	local ok, events = pcall(Json.decode, plaintext)
	if not ok or type(events) ~= "table" then error("typing event decoding failed", 0) end
	local count = 0
	for key, event in pairs(events) do
		count = count + 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or type(event) ~= "table"
			or type(event[1]) ~= "string" then error("typing event shape refused", 0) end
	end
	for index = 1, count do
		if events[index] == nil then error("typing event shape refused", 0) end
	end
	return events
end





-- ===============================
-- ===============================
-- ======= 2/ Walks ===============
-- ===============================
-- ===============================

--- Applies one system row to the batch with the macOS system-day rules.
--- @param batch table Walker batch.
--- @param date string Row date.
--- @param action string Row action.
--- @param meta table Decoded metadata.
--- @param timestamp string Row timestamp, local on the drivers that wake-count from it.
local function walk_system(batch, date, action, meta, timestamp)
	if action == "manifest_increment" and MANIFEST_STAT_FIELDS[meta.stat] then
		local app = type(meta.app) == "string" and meta.app or "Unknown"
		local key = date .. SEPARATOR .. app
		batch.app_day[key] = batch.app_day[key] or { date = date, app = app }
		local row = batch.app_day[key]
		row[meta.stat] = (row[meta.stat] or 0) + (tonumber(meta.amount) or 1)
	end
	local day = batch.system_day[date]
	if not day then
		day = { date = date, wifi_changes = 0, space_switches = 0, audio_muted_ms = 0, locked_ms = 0,
			sleep_ms = 0, awake_ms = 0, passive_count = 0, night_wake_count = 0 }
		batch.system_day[date] = day
	end
	local duration = tonumber(meta.duration_ms) or 0
	if action == "wifi_change" then day.wifi_changes = day.wifi_changes + 1
	elseif action == "space_change" then day.space_switches = day.space_switches + 1
	elseif action == "passive_period" then
		day.passive_count = day.passive_count + 1
		if meta.kind == "sleep" then day.sleep_ms = day.sleep_ms + duration
		elseif meta.kind == "lock" then day.locked_ms = day.locked_ms + duration
		elseif meta.kind == "awake" then day.awake_ms = day.awake_ms + duration end
	elseif action == "unlock" then day.locked_ms = day.locked_ms + duration
	elseif action == "wake" then
		day.sleep_ms = day.sleep_ms + duration
		if Helpers.is_night_wake(timestamp, require("infra.timings").ms("keystats", "night_wake_end_ms")) then day.night_wake_count = day.night_wake_count + 1 end
	end
end

--- Walks every raw row of one device into a fresh walker batch.
--- @param opts table { store, device_id, decrypt fun(value):string }
--- @return table batch
function M.walk_device(opts)
	local store, device_id, decrypt = opts.store, opts.device_id, opts.decrypt
	local batch = require("keystats.aggregator_helpers").new_batch()
	local contexts = {}
	for _, row in ipairs(read_rows(store, "events_typing", { "ts", "date", "app", "layout", "events_json" }, device_id)) do
		local plaintext = decrypt(row.events_json)
		if type(plaintext) ~= "string" or (plaintext == "" and row.events_json ~= "") then
			error("typing event decryption failed", 0)
		end
		local events = typing_events(plaintext)
		if #events > 0 then
			local date = row.date:match("^%d%d%d%d%-%d%d%-%d%d$") and row.date or row.ts:sub(1, 10)
			contexts[row.app] = contexts[row.app] or {}
			AggregateWalker.walk(events, date, row.app, batch, {
				layout = row.layout ~= "" and row.layout or nil, physical_layout = row.layout,
				foreign = true, slot = SharedWalker.timestamp_slot(row.ts),
			}, contexts[row.app])
		end
	end
	for _, context in pairs(contexts) do AggregateWalker.settle(context, nil, batch, true) end

	-- The switch walks read no timing and no finger; the walker still requires both.
	local Timings = require("infra.timings")
	local timings = {}
	for _, name in ipairs({ "max_keystroke_delay_ms", "think_pause_ms", "burst_gap_ms", "session_gap_ms",
		"auto_repeat_max_delay_ms" }) do timings[name] = Timings.ms("keystats", name) end
	local Walker = SharedWalker.new({ timings = timings, finger_of = function() return nil end })
	for _, row in ipairs(read_rows(store, "events_app_switch", { "ts", "prev_app", "next_app", "duration_ms" }, device_id)) do
		Walker.walk_app_switch(batch, { timestamp = row.ts, prev_app = row.prev_app ~= "" and row.prev_app or nil,
			next_app = row.next_app ~= "" and row.next_app or nil, duration_ms = tonumber(row.duration_ms) or 0 })
	end
	for _, row in ipairs(read_rows(store, "events_window_switch", { "ts", "app", "prev_title", "duration_ms" }, device_id)) do
		Walker.walk_window_switch(batch, { timestamp = row.ts, app = row.app ~= "" and row.app or nil,
			prev_title = row.prev_title, duration_ms = tonumber(row.duration_ms) or 0 })
	end
	for _, row in ipairs(read_rows(store, "events_system", { "ts", "date", "action", "metadata_json" }, device_id)) do
		local ok, meta = pcall(Json.decode, row.metadata_json ~= "" and row.metadata_json or "{}")
		if not ok or type(meta) ~= "table" then meta = {} end
		walk_system(batch, row.ts:sub(1, 10), row.action, meta, row.ts)
	end
	return batch
end





-- ================================
-- ================================
-- ======= 3/ Partition SQL =======
-- ================================
-- ================================

--- The derived tables of the shared schema: every agg_* and ngram_* table.
--- @param schema string Text of _shared/data/db/schema.sql.
--- @return table names
function M.derived_tables(schema)
	local names = {}
	for name in schema:gmatch("CREATE TABLE IF NOT EXISTS ([%w_]+)") do
		if name:match("^agg_") or name:match("^ngram_") then names[#names + 1] = name end
	end
	assert(#names > 0, "the shared schema names no derived table")
	return names
end

--- Renders the partition rebuild: every derived row of the device deleted,
--- then the rows of a fresh walk.
--- @param opts table { store, device_id, decrypt, schema, statement fun(kind, device_id, ...):string|nil }
--- @return string sql Statements without BEGIN/COMMIT.
function M.render(opts)
	local batch = M.walk_device(opts)
	local device_id, statement = opts.device_id, opts.statement
	local out = {}
	local quoted = SqliteCommand.escape_literal(device_id)
	for _, name in ipairs(M.derived_tables(opts.schema)) do
		out[#out + 1] = string.format("DELETE FROM %s WHERE device_id='%s';", name, quoted)
	end
	local function add(sql) if type(sql) == "string" and sql ~= "" then out[#out + 1] = sql end end
	for _, group in ipairs(AggregateWalker.batches_for_writer(batch)) do
		add(statement("ngrams", device_id, group.date, group.app, group.ngrams, group.table_name))
	end
	for family, rows in pairs(AggregateWalker.daily_rows(batch)) do
		for _, row in ipairs(rows) do add(statement(assert(DAILY_FORMATTERS[family]), device_id, row)) end
	end
	local app_days = {}
	for key, row in pairs(batch.app_day) do app_days[key] = row end
	for key, row in pairs(batch.app_time) do
		app_days[key] = app_days[key] or { date = row.date, app = row.app }
		app_days[key].app_time_ms = (app_days[key].app_time_ms or 0) + row.ms
	end
	for _, row in pairs(app_days) do add(statement("app_day", device_id, row.date, row.app, row)) end
	for _, row in pairs(batch.titles) do add(statement("title", device_id, row)) end
	for _, row in pairs(batch.switches_to or {}) do add(statement("switch_to", device_id, row)) end
	for _, row in pairs(batch.system_day) do add(statement("system_day", device_id, row)) end
	return table.concat(out, "\n")
end

return M
