--- tests/unit/modules/keystats/storage/test_fresh_cache_recovery.lua

--- ============================================================================
--- MODULE: Regression — fresh SQLite cache reconstruction
--- DESCRIPTION:
--- A normal macOS TMPDIR purge removes db.sqlite while data.sql and today.log
--- remain durable. The recovery cursor must resume after the last complete
--- ledger batch, otherwise the next ingest replays already-persisted JSONL and
--- duplicates every metric. A day rollover without a later batch starts the
--- new today.log at offset zero.
--- ============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["infra.i18n"] = { t = function(key) return key end }
package.loaded["infra.timings"] = {
	ms = function() return 1000 end,
	sec = function() return 1 end,
}
package.loaded["modules.keystats.timestamp"] = { now_ts = function() return "2026-07-18 12:00:00.000" end }
package.loaded["modules.keystats.rotation"] = {
	init = function() end, is_initialized = function() return true end,
	append_log = function() end, read_new_entries = function() return {}, 0 end,
	get_offset = function() return 0 end, get_date = function() return "2026-07-18" end,
	set_offset = function() end, rollover = function() end,
}
package.loaded["modules.keystats.sqlite_writer"] = {
	init = function() end, open_db = function() return true end, close_db = function() end,
	get_db = function() return nil end, build_inserts = function() return {} end,
	get_next_event_id = function() return 1 end, set_next_event_id = function() end,
	persist_next_event_id = function() end,
}
package.loaded["modules.keystats.aggregator"] = {
	init = function() end, set_device_id = function() end, get_device_id = function() return nil end,
	reset_batch = function() end, reset_ngram_ctx = function() end, get_ngram_ctx = function() return {} end,
	set_ngram_ctx = function() end, walk_typing = function() end, walk_app_switch = function() end,
	walk_window_switch = function() end, walk_system_event = function() end, flush = function() end,
}
package.loaded["modules.keystats.export"] = {
	init = function() end, sync_foreign_data_sql = function() end,
	get_native_app_category = function() return "other" end, get_device_short_id = function() return "test" end,
	get_sqlite_path = function() return nil end, get_db_rev = function() return 0 end,
}

local LM = helpers.load_with_stubs("modules.keystats.log_manager", {
	fs = { attributes = function() return nil end, dir = function() return function() return nil end end },
	execute = function() return "" end,
})

helpers.describe("keystats/log_manager: fresh cache recovery cursor", function()
	helpers.it("uses the last complete batch offset and ignores a torn suffix", function()
		local ledger = [[-- header
-- === ingest batch 2026-07-18 09:00:00.000 (offset 0 -> 120, 2 entry(ies)) ===
BEGIN TRANSACTION;
INSERT OR IGNORE INTO events_typing VALUES ('device', 1);
COMMIT;
-- === ingest batch 2026-07-18 09:01:00.000 (offset 120 -> 240, 1 entry(ies)) ===
BEGIN TRANSACTION;
INSERT OR IGNORE INTO events_typing VALUES ('device', 2);
]]
		local complete = ledger:find("COMMIT;", 1, true) + #"COMMIT;" - 1
		local cursor = LM._local_ledger_replay_cursor(ledger, complete)
		helpers.assert_eq(cursor.offset, 120, "unfinished batch must not advance the today.log cursor")
		helpers.assert_eq(cursor.date, "2026-07-18")
	end)

	helpers.it("resets the cursor after a rollover with no new durable batch", function()
		local ledger = [[-- === ingest batch 2026-07-17 23:59:00.000 (offset 0 -> 99, 1 entry(ies)) ===
BEGIN TRANSACTION;
INSERT OR IGNORE INTO events_typing VALUES ('device', 1);
COMMIT;
-- === day rollover 2026-07-17 -> 2026-07-18 ===
]]
		local complete = ledger:find("COMMIT;", 1, true) + #"COMMIT;" - 1
		local cursor = LM._local_ledger_replay_cursor(ledger, complete)
		helpers.assert_eq(cursor.offset, 0, "new day must not inherit the prior file offset")
		helpers.assert_eq(cursor.date, "2026-07-18")
	end)

	helpers.it("ignores a rollover marker after a torn batch", function()
		local ledger = [[-- === ingest batch 2026-07-17 23:59:00.000 (offset 0 -> 99, 1 entry(ies)) ===
BEGIN TRANSACTION;
INSERT OR IGNORE INTO events_typing VALUES ('device', 1);
COMMIT;
-- === ingest batch 2026-07-18 00:00:00.000 (offset 99 -> 160, 1 entry(ies)) ===
BEGIN TRANSACTION;
INSERT OR IGNORE INTO events_typing VALUES ('device', 2);
-- === day rollover 2026-07-17 -> 2026-07-18 ===
]]
		local complete = ledger:find("COMMIT;", 1, true) + #"COMMIT;" - 1
		local cursor = LM._local_ledger_replay_cursor(ledger, complete)
		helpers.assert_eq(cursor.offset, 99, "unsafe rollover metadata must not reset a durable cursor")
		helpers.assert_eq(cursor.date, "2026-07-17")
	end)
end)

helpers.describe("keystats/log_manager: fresh cache id ownership", function()
	-- Boot-path ordering is reachable only through the source (init needs a live
	-- cache). A failed derived rebuild must not leave next_event_id at its seed:
	-- that recreated the legacy id restart which refuses every later rebuild.
	helpers.it("publishes the replayed id counter before the derived rebuild (issue104-fresh-cache-ids)", function()
		local src = assert(helpers.read_driver_unit("local function _ensure_ledger_header"))
		local body = src:sub((assert(src:find("local function _init(core_state)", 1, true))))
		local replay = assert(body:find("_replay_local_data_sql(db)", 1, true))
		local persist = body:find("_persist_recovery_state(db, cursor)", 1, true)
		local rebuild = assert(body:find("_start_aggregate_recovery(db)", 1, true))
		helpers.assert_true(persist ~= nil and replay < persist and persist < rebuild,
			"the replay cursor and id counter must be published before the aggregate rebuild can fail")
		local recovery = src:match("local function _recover_aggregate_cache%(db%)(.-)\nend\n")
		helpers.assert_true(recovery ~= nil and not recovery:find("_persist_recovery_state", 1, true),
			"a successful rebuild must not be the only owner of the replay cursor")
	end)
end)
