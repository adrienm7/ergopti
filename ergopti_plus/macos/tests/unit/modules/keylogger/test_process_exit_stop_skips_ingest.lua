--- tests/unit/modules/keylogger/test_process_exit_stop_skips_ingest.lua

--- ==============================================================================
--- MODULE: Keylogger Process-Exit Stop Skips the Final Ingest
--- DESCRIPTION:
--- Quit ran LogManager.stop(), whose final ingest_once() synced foreign data.sql
--- ledgers, rebuilt aggregates, read the JSONL tail and ran a SQLite transaction
--- (encrypting typing rows through a subprocess when at-rest encryption is on),
--- all on the Hammerspoon main thread while the app looked frozen
--- (hs-quit-never-blocks).
---
--- ROOT CAUSE ENCODED: the process-lifecycle stop and the Metrics OFF stop were
--- the same call. The process-exit stop must close the cache without ingesting;
--- today.log and the committed meta offset make the next boot ingest the tail.
--- The Metrics OFF stop keeps its final ingest.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =============================================
-- =============================================
-- ======= 1/ Real Log Manager Harness =========
-- =============================================
-- =============================================

--- Loads the REAL log_manager over doubles that count ingest work.
--- Harness shape copied from test_ingest_survives_stop_start.lua.
--- @return table log_manager, table sqlite_state, table spies
local function load_log_manager()
	local sqlite = { open = false, open_calls = 0 }
	local spies = { tail_reads = 0, foreign_syncs = 0 }

	package.loaded["modules.keylogger.rotation"] = {
		init = function() end, is_initialized = function() return true end,
		append_log = function() end,
		read_new_entries = function()
			spies.tail_reads = spies.tail_reads + 1
			return {}, 0, "eof"
		end,
		get_offset = function() return 0 end, set_offset = function() end,
		get_date = function() return "2099-07-01" end, rollover = function() end,
	}

	package.loaded["modules.keylogger.sqlite_writer"] = {
		init    = function() end,
		open_db = function()
			sqlite.open_calls = sqlite.open_calls + 1
			sqlite.open = true
			return true
		end,
		close_db = function() sqlite.open = false end,
		-- The real get_db() returns the live handle or nil — that distinction is the
		-- whole point here, so the double must honour it rather than return a constant.
		-- The handle carries the three methods log_manager calls on it (nrows/exec/
		-- errmsg); nrows yields nothing so the restore loops are empty no-ops.
		get_db                = function()
			if not sqlite.open then return nil end
			return {
				nrows  = function() return function() return nil end end,
				exec   = function() return 0 end,
				errmsg = function() return "" end,
			}
		end,
		build_inserts         = function() return {} end,
		get_next_event_id     = function() return 0 end,
		set_next_event_id     = function() end,
		persist_next_event_id = function() end,
	}

	-- Full Aggregator surface log_manager calls; a missing member raises inside
	-- init()'s replay path and masks the behaviour under test.
	package.loaded["modules.keylogger.aggregator"] = {
		init = function() end, walk_typing = function() end, walk_app_switch = function() end,
		walk_window_switch = function() end, walk_system_event = function() end,
		flush = function() end, get_ngram_ctx = function() return {} end,
		set_ngram_ctx = function() end, reset_ngram_ctx = function() end,
		set_device_id = function() end, reset_batch = function() end,
	}

	package.loaded["modules.keylogger.export"] = {
		init = function() end, get_native_app_category = function() return "other" end,
		get_device_short_id = function() return "abcd" end,
		get_sqlite_path = function() return "/tmp/test.sqlite" end,
		get_db_rev = function() return 0 end,
		sync_foreign_data_sql = function()
			spies.foreign_syncs = spies.foreign_syncs + 1
			return {}
		end,
		_last_complete_batch_offset = 0,
	}

	package.loaded["infra.i18n"]    = { t = function(key) return key end }
	package.loaded["infra.timings"] = { ms = function() return 1000 end, sec = function() return 1.0 end }
	local saved_file_system = package.loaded["adapters.file_system"]
package.loaded["adapters.file_system"] = {
	write = function() return true end,
	create_if_absent = function() return true, "created" end,
	read = function() return nil end,
}

	package.loaded["modules.keylogger.log_manager"] = nil
	local lm = helpers.load_with_stubs("modules.keylogger.log_manager", {
		fs      = { attributes = function() return nil end, dir = function() return function() return nil end end },
		execute = function() return "" end,
	})
	package.loaded["adapters.file_system"] = saved_file_system
	lm.init({
		LOG_DIR = "/tmp/test_process_exit_stop",
		buffer_events = {}, buffer_text = "", rich_chunks = {},
		session_mouse_clicks = 0, session_mouse_scrolls = 0, mouse_distance_px = 0,
		last_flush_time = 0, last_time = 0, pending_keyup = {},
		today_idx = {}, manifest = {},
	})
	return lm, sqlite, spies
end




-- ==============================================
-- ==============================================
-- ======= 2/ Process Exit Versus Metrics OFF ===
-- ==============================================
-- ==============================================

helpers.describe("keylogger process-exit stop never ingests (hs-quit-never-blocks)", function()
	helpers.it("(hs-quit-never-blocks) process-exit stop closes the cache without an ingest", function()
		local lm, sqlite, spies = load_log_manager()
		helpers.assert_true(sqlite.open, "fixture precondition: the cache is open")
		local reads_before, syncs_before = spies.tail_reads, spies.foreign_syncs

		helpers.assert_eq(lm.stop({ process_exit = true }), true)
		helpers.assert_eq(spies.tail_reads, reads_before,
			"Quit must not read the JSONL tail: the next boot ingests it")
		helpers.assert_eq(spies.foreign_syncs, syncs_before,
			"Quit must not sync foreign ledgers or rebuild aggregates")
		helpers.assert_eq(sqlite.open, false, "the cache must still be closed")
	end)

	helpers.it("(hs-quit-never-blocks) the Metrics OFF stop keeps its final ingest", function()
		local lm, sqlite, spies = load_log_manager()
		local reads_before = spies.tail_reads
		lm.stop()
		helpers.assert_true(spies.tail_reads > reads_before,
			"a feature-level stop inside a live session still drains the tail")
		helpers.assert_eq(sqlite.open, false)
	end)
end)
