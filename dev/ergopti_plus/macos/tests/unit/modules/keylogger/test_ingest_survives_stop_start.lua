--- tests/unit/modules/keylogger/test_ingest_survives_stop_start.lua

--- ==============================================================================
--- MODULE: Regression — ingest must survive a Metrics OFF/ON toggle
--- DESCRIPTION:
--- Toggling Metrics off and back on permanently killed SQLite ingest and midnight
--- rotation for the rest of the session.
---
--- ROOT CAUSE ENCODED — an asymmetric teardown/re-arm pair:
---   M.stop()                 stops the ingest timer AND calls SqliteWriter.close_db()
---   M.ensure_ingest_running() re-armed ONLY the timer
--- So after OFF/ON the tick was running again but every ingest_once() call found a
--- closed database and did nothing. Nothing logged an error, because ingest_once()
--- treats a nil handle as "nothing to do" — the feature reported healthy while
--- silently persisting zero keystrokes until the next Hammerspoon reload.
---
--- The re-arm is the only place the cache can be reacquired on that path:
--- keylogger.start() latches on its own _state and never calls log_manager.init()
--- a second time.
---
--- The test drives the REAL log_manager through a stop -> ensure_ingest_running
--- cycle with a SqliteWriter double that models the real handle lifecycle, and
--- asserts the database is open again afterwards — the state ingest actually needs,
--- not merely that a timer object exists.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =============================================
-- =============================================
-- ======= 1/ Real Log Manager Harness =========
-- =============================================
-- =============================================

--- Loads the REAL log_manager over doubles, with a SqliteWriter that models the
--- open/close lifecycle so the test can observe whether the cache is live.
--- Harness shape copied from test_day_rollover_drain.lua's load_real_day_rollover.
--- @return table log_manager, table sqlite_state
local function load_log_manager()
	local sqlite = { open = false, open_calls = 0 }

	package.loaded["modules.keylogger.rotation"] = {
		init = function() end, is_initialized = function() return true end,
		append_log = function() end,
		read_new_entries = function() return {}, 0 end,
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
		get_db_rev = function() return 0 end, sync_foreign_data_sql = function() end,
		_last_complete_batch_offset = 0,
	}

	package.loaded["lib.i18n"]    = { t = function(key) return key end }
	package.loaded["lib.timings"] = { ms = function() return 1000 end, sec = function() return 1.0 end }

	package.loaded["modules.keylogger.log_manager"] = nil
	local lm = helpers.load_with_stubs("modules.keylogger.log_manager", {
		fs      = { attributes = function() return nil end, dir = function() return function() return nil end end },
		execute = function() return "" end,
	})
	lm.init({
		LOG_DIR = "/tmp/test_ingest_stop_start",
		buffer_events = {}, buffer_text = "", rich_chunks = {},
		session_mouse_clicks = 0, session_mouse_scrolls = 0, mouse_distance_px = 0,
		last_flush_time = 0, last_time = 0, pending_keyup = {},
		today_idx = {}, manifest = {},
	})
	return lm, sqlite
end




-- ==============================================
-- ==============================================
-- ======= 2/ The Cache Comes Back On ===========
-- ==============================================
-- ==============================================

helpers.describe("ingest survives a Metrics OFF/ON toggle", function()
	helpers.it("re-opens the SQLite cache that M.stop() closed", function()
		local lm, sqlite = load_log_manager()

		-- The state M.stop() leaves behind: it calls SqliteWriter.close_db(), so the
		-- cache is shut while _state survives. Set directly rather than calling stop(),
		-- whose ingest_once() pass would need the whole export/aggregator surface
		-- stubbed for a precondition this test does not measure.
		sqlite.open = false

		lm.ensure_ingest_running()

		helpers.assert_true(sqlite.open == true,
			"ensure_ingest_running() must re-open the cache M.stop() closed. Re-arming only the "
			.. "timer leaves every ingest tick running against a closed database — ingest and "
			.. "midnight rotation stay dead for the rest of the session, silently")
	end)

	helpers.it("does not re-open a cache that is already open", function()
		-- The re-arm is called unconditionally from keylogger.start(), so it must be
		-- safe to re-enter: reopening a live handle would leak the previous one.
		local lm, sqlite = load_log_manager()
		sqlite.open = true
		local before = sqlite.open_calls

		lm.ensure_ingest_running()

		helpers.assert_eq(sqlite.open_calls, before,
			"an already-open cache must not be re-opened — ensure_ingest_running() is called "
			.. "unconditionally on every start and must be idempotent")
	end)
end)
