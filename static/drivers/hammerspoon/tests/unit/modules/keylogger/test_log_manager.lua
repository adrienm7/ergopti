--- tests/unit/modules/keylogger/test_log_manager.lua

--- ==============================================================================
--- MODULE: keylogger.log_manager Unit Tests
--- DESCRIPTION:
--- Verifies the pure-logic surface of the log_manager orchestrator. Because
--- log_manager delegates all I/O to sub-modules, the tests focus on the parts
--- that contain in-process logic: the init guard, the delegate entry points
--- (log_app_switch, log_shortcut, etc.), and the flush_buffer WPM formula.
--- All hs.*, SqliteWriter, Aggregator, Rotation, and Export calls are stubbed.
---
--- FEATURES & RATIONALE:
--- 1. Guard Enforcement: Every public function must be a safe no-op before init.
--- 2. Stub Isolation: hs.json, hs.fs, hs.sqlite3, hs.timer, and all sub-module
---    requires are replaced with in-memory stubs so no disk or OS call occurs.
--- 3. WPM Formula: flush_buffer computes words-per-minute from per-event delays;
---    we feed a known synthetic buffer and verify the formula produces the
---    expected result.
--- 4. Idempotent Init: calling M.init() twice must be harmless.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Stub Setup ==============
-- =====================================
-- =====================================

-- Must be registered BEFORE load_with_stubs so downstream requires resolve them.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

package.loaded["lib.i18n"] = {
	t = function(key) return key end,
}

-- Sub-module stubs so log_manager never tries to open real files.
local _appended_entries = {}
package.loaded["modules.keylogger.rotation"] = {
	init           = function() end,
	append_log     = function(entry) table.insert(_appended_entries, entry) end,
	read_new_entries = function() return {}, 0 end,
	get_offset     = function() return 0 end,
	get_date       = function() return os.date("%Y-%m-%d") end,
	set_offset     = function() end,
	rollover       = function() end,
}

package.loaded["modules.keylogger.sqlite_writer"] = {
	init              = function() end,
	open_db           = function() return true end,
	close_db          = function() end,
	get_db            = function() return nil end,
	build_inserts     = function() return {} end,
	persist_next_event_id = function() end,
}

package.loaded["modules.keylogger.aggregator"] = {
	init           = function() end,
	walk_typing    = function() end,
	walk_app_switch = function() end,
	walk_window_switch = function() end,
	walk_system_event  = function() end,
	flush          = function() end,
	get_ngram_ctx  = function() return {} end,
	set_ngram_ctx  = function() end,
	reset_ngram_ctx = function() end,
}

package.loaded["modules.keylogger.export"] = {
	init                    = function() end,
	get_native_app_category = function() return "other" end,
	get_device_short_id     = function() return "abcd" end,
	get_sqlite_path         = function() return "/tmp/test.sqlite" end,
	get_db_rev              = function() return 0 end,
	sync_foreign_data_sql   = function() end,
}

-- Provide hs overrides that avoid real I/O.
local hs_overrides = {
	fs = {
		attributes = function() return nil end,
		dir        = function() return function() return nil end end,
	},
	execute = function() return "" end,
}

local LM = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)




-- ======================================================
-- ======================================================
-- ======= 2/ Module Surface Invariants =================
-- ======================================================
-- ======================================================

helpers.describe("log_manager — public surface", function()
	helpers.it("exposes init, stop, flush_buffer, and log_* delegates", function()
		helpers.assert_eq(type(LM.init),             "function")
		helpers.assert_eq(type(LM.stop),             "function")
		helpers.assert_eq(type(LM.flush_buffer),     "function")
		helpers.assert_eq(type(LM.append_log),       "function")
		helpers.assert_eq(type(LM.log_app_switch),   "function")
		helpers.assert_eq(type(LM.log_shortcut),     "function")
		helpers.assert_eq(type(LM.log_system_event), "function")
		helpers.assert_eq(type(LM.log_modifier_press),   "function")
		helpers.assert_eq(type(LM.log_modifier_hold),    "function")
		helpers.assert_eq(type(LM.log_passive_period),   "function")
		helpers.assert_eq(type(LM.log_focus_first_key),  "function")
		helpers.assert_eq(type(LM.increment_manifest_stat), "function")
	end)

	helpers.it("exposes export delegate accessors", function()
		helpers.assert_eq(type(LM.get_native_app_category), "function")
		helpers.assert_eq(type(LM.get_device_short_id),     "function")
		helpers.assert_eq(type(LM.get_sqlite_path),         "function")
		helpers.assert_eq(type(LM.get_db_rev),              "function")
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 3/ Pre-init Guard Enforcement ========
-- ==============================================
-- ==============================================

helpers.describe("log_manager — pre-init guards", function()
	-- Fresh module so _state is nil.
	local fresh = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)

	helpers.it("flush_buffer is a safe no-op before init", function()
		local ok = pcall(function() fresh.flush_buffer() end)
		helpers.assert_true(ok)
	end)

	helpers.it("log_app_switch is a safe no-op before init", function()
		local ok = pcall(function() fresh.log_app_switch("A", "B", 1000) end)
		helpers.assert_true(ok)
	end)

	helpers.it("log_shortcut is a safe no-op before init", function()
		local ok = pcall(function() fresh.log_shortcut("cmd+c", "Finder") end)
		helpers.assert_true(ok)
	end)

	helpers.it("log_system_event is a safe no-op before init", function()
		local ok = pcall(function() fresh.log_system_event("wifi_change", {}) end)
		helpers.assert_true(ok)
	end)

	helpers.it("log_passive_period is a safe no-op before init", function()
		local ok = pcall(function() fresh.log_passive_period("idle", 60000) end)
		helpers.assert_true(ok)
	end)

	helpers.it("day_rollover is a safe no-op before init", function()
		local ok = pcall(function() fresh.day_rollover() end)
		helpers.assert_true(ok)
	end)
end)




-- ================================================
-- ================================================
-- ======= 4/ M.init() Validation ================
-- ================================================
-- ================================================

helpers.describe("log_manager — M.init()", function()
	helpers.it("rejects nil core_state", function()
		local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
		lm.init(nil)
		-- Guard must prevent any delegate from running.
		local ok = pcall(function() lm.flush_buffer() end)
		helpers.assert_true(ok)
	end)

	helpers.it("rejects core_state without LOG_DIR string", function()
		local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
		lm.init({ some = "table", LOG_DIR = 42 })
		local ok = pcall(function() lm.flush_buffer() end)
		helpers.assert_true(ok)
	end)

	helpers.it("accepts valid core_state and does not throw", function()
		local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
		local ok = pcall(function()
			lm.init({
				LOG_DIR              = "/tmp/test_ergopti_metrics",
				buffer_events        = {},
				buffer_text          = "",
				rich_chunks          = {},
				session_mouse_clicks  = 0,
				session_mouse_scrolls = 0,
				mouse_distance_px     = 0,
				last_flush_time       = 0,
				last_time             = 0,
				pending_keyup         = {},
				today_idx             = {},
				manifest              = {},
			})
		end)
		helpers.assert_true(ok)
	end)

	helpers.it("ignores duplicate init calls", function()
		local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
		local state = {
			LOG_DIR = "/tmp/test2",
			buffer_events = {}, buffer_text = "", rich_chunks = {},
			session_mouse_clicks = 0, session_mouse_scrolls = 0,
			mouse_distance_px = 0, last_flush_time = 0,
			last_time = 0, pending_keyup = {},
			today_idx = {}, manifest = {},
		}
		lm.init(state)
		local ok = pcall(function() lm.init(state) end)
		helpers.assert_true(ok)
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 5/ flush_buffer — WPM formula ==============
-- =====================================================
-- =====================================================

helpers.describe("log_manager — flush_buffer WPM formula", function()
	--- Build a minimal but initialised log_manager with a given buffer.
	--- Returns the lm instance. The Rotation.append_log stub captures the entry.
	local function make_lm_with_buffer(events, extra_state)
		_appended_entries = {}
		local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
		local state = {
			LOG_DIR = "/tmp/wpm_test",
			buffer_events        = events or {},
			buffer_text          = "hello",
			rich_chunks          = {},
			session_mouse_clicks  = 0,
			session_mouse_scrolls = 0,
			mouse_distance_px     = 0,
			last_flush_time       = 0,
			last_time             = 0,
			pending_keyup         = {},
			today_idx             = {},
			manifest              = {},
			session_app_name     = "TestApp",
			session_win_title    = "",
			session_url          = "",
			session_field_role   = "",
			session_layout       = "AZERTY",
			session_document_path = "",
			is_fullscreen        = false,
			in_meeting           = false,
			current_session_pause = 0,
			current_battery_level = 100,
			current_audio_volume  = 50,
		}
		if extra_state then
			for k, v in pairs(extra_state) do state[k] = v end
		end
		lm.init(state)
		return lm
	end

	helpers.it("empty buffer produces no appended entry", function()
		local lm = make_lm_with_buffer({})
		lm.flush_buffer()
		helpers.assert_eq(#_appended_entries, 0)
	end)

	helpers.it("non-empty buffer produces exactly one typing entry", function()
		-- 5 chars, 1000 ms apart → 5/5 chars = 1 word, in 5s → 12 WPM
		local events = {
			{ "h", 1000, {} },
			{ "e", 1000, {} },
			{ "l", 1000, {} },
			{ "l", 1000, {} },
			{ "o", 1000, {} },
		}
		local lm = make_lm_with_buffer(events)
		lm.flush_buffer()
		helpers.assert_eq(#_appended_entries, 1)
		helpers.assert_eq(_appended_entries[1].type, "typing")
	end)

	helpers.it("wpm is proportional to char count and total time", function()
		-- 10 chars with 600 ms each = 6000 ms = 0.1 min; 10/5 = 2 words → 20 WPM
		local events = {}
		for i = 1, 10 do events[i] = { string.char(96 + i), 600, {} } end
		local lm = make_lm_with_buffer(events)
		lm.flush_buffer()
		helpers.assert_true(#_appended_entries == 1)
		local wpm = _appended_entries[1].wpm
		helpers.assert_true(type(wpm) == "number", "wpm must be a number")
		-- Expect ~20 WPM with a tolerance of ±1 for floating-point rounding.
		helpers.assert_true(wpm >= 19 and wpm <= 21,
			"expected ~20 WPM, got " .. tostring(wpm))
	end)

	helpers.it("synthetic events (meta.s=true) are excluded from WPM calculation", function()
		-- Only 2 real chars + 3 synthetic; WPM must reflect real chars only.
		local events = {
			{ "a", 600, {} },
			{ "b", 600, {} },
			{ "c", 600, { s = true } },  -- synthetic — excluded from time total
			{ "d", 600, { s = true } },
			{ "e", 600, { s = true } },
		}
		local lm = make_lm_with_buffer(events)
		lm.flush_buffer()
		helpers.assert_true(#_appended_entries == 1)
		local wpm = _appended_entries[1].wpm
		-- With 2 real chars at 600 ms each: 1200 ms, 2/5=0.4 words → 20 WPM
		helpers.assert_true(type(wpm) == "number")
		helpers.assert_true(wpm >= 19 and wpm <= 21,
			"expected ~20 WPM (synthetic excluded), got " .. tostring(wpm))
	end)

	helpers.it("zero total time yields 0 WPM (no division by zero)", function()
		-- All synthetic events contribute 0 total_time_ms.
		local events = {
			{ "x", 0, { s = true } },
			{ "y", 0, { s = true } },
		}
		local lm = make_lm_with_buffer(events)
		lm.flush_buffer()
		helpers.assert_true(#_appended_entries == 1)
		helpers.assert_eq(_appended_entries[1].wpm, 0)
	end)

	helpers.it("delays beyond WPM_MAX_EVENT_DELAY_MS are capped at 5000 ms", function()
		-- One char with a 60-second pause — must be capped so WPM is sane.
		local events = { { "a", 60000, {} } }
		local lm = make_lm_with_buffer(events)
		lm.flush_buffer()
		helpers.assert_true(#_appended_entries == 1)
		-- Capped at 5000 ms: 1 char / 5 = 0.2 words in 5000 ms = 2.4 WPM
		local wpm = _appended_entries[1].wpm
		helpers.assert_true(type(wpm) == "number")
		helpers.assert_true(wpm > 0, "WPM must be positive even with capped delay")
		-- The cap prevents inflating the denominator beyond 5 s for one char.
		helpers.assert_true(wpm >= 2 and wpm <= 3,
			"expected ~2.4 WPM after cap, got " .. tostring(wpm))
	end)

	helpers.it("buffer is cleared after flush", function()
		local events = { { "a", 300, {} } }
		local state_ref = {
			LOG_DIR = "/tmp/clear_test",
			buffer_events = events, buffer_text = "a", rich_chunks = {},
			session_mouse_clicks = 0, session_mouse_scrolls = 0,
			mouse_distance_px = 0, last_flush_time = 0, last_time = 0,
			pending_keyup = {}, today_idx = {}, manifest = {},
			session_app_name = "App",
		}
		local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
		lm.init(state_ref)
		lm.flush_buffer()
		-- After flush the buffer is reset to empty.
		helpers.assert_eq(#state_ref.buffer_events, 0)
		helpers.assert_eq(state_ref.buffer_text, "")
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 6/ Log delegate entry points ==============
-- =====================================================
-- =====================================================

helpers.describe("log_manager — log delegate entry points", function()
	local function make_initialized_lm()
		_appended_entries = {}
		local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
		lm.init({
			LOG_DIR = "/tmp/delegate_test",
			buffer_events = {}, buffer_text = "", rich_chunks = {},
			session_mouse_clicks = 0, session_mouse_scrolls = 0,
			mouse_distance_px = 0, last_flush_time = 0,
			last_time = 0, pending_keyup = {},
			today_idx = {}, manifest = {},
		})
		return lm
	end

	helpers.it("log_app_switch appends an app_switch entry", function()
		local lm = make_initialized_lm()
		lm.log_app_switch("Finder", "Terminal", 2000)
		helpers.assert_true(#_appended_entries >= 1)
		local entry = _appended_entries[#_appended_entries]
		helpers.assert_eq(entry.type, "app_switch")
		helpers.assert_eq(entry.prev_app, "Finder")
		helpers.assert_eq(entry.next_app, "Terminal")
	end)

	helpers.it("log_shortcut appends a shortcut entry", function()
		local lm = make_initialized_lm()
		lm.log_shortcut("cmd+c", "Xcode")
		local entry = _appended_entries[#_appended_entries]
		helpers.assert_eq(entry.type, "shortcut")
		helpers.assert_eq(entry.key,  "cmd+c")
		helpers.assert_eq(entry.app,  "Xcode")
	end)

	helpers.it("log_shortcut silently drops empty key strings", function()
		local lm = make_initialized_lm()
		local before = #_appended_entries
		lm.log_shortcut("", "Finder")
		helpers.assert_eq(#_appended_entries, before)
	end)

	helpers.it("log_system_event appends a system_event entry", function()
		local lm = make_initialized_lm()
		lm.log_system_event("wifi_change", { ssid = "home" })
		local entry = _appended_entries[#_appended_entries]
		helpers.assert_eq(entry.type,   "system_event")
		helpers.assert_eq(entry.action, "wifi_change")
		helpers.assert_eq(entry.ssid,   "home")
	end)

	helpers.it("log_modifier_press appends a modifier_press entry", function()
		local lm = make_initialized_lm()
		lm.log_modifier_press(56, "Emacs")
		local entry = _appended_entries[#_appended_entries]
		helpers.assert_eq(entry.type,   "system_event")
		helpers.assert_eq(entry.action, "modifier_press")
		helpers.assert_eq(entry.keycode, 56)
	end)

	helpers.it("log_passive_period appends a passive_period entry", function()
		local lm = make_initialized_lm()
		lm.log_passive_period("idle", 120000)
		local entry = _appended_entries[#_appended_entries]
		helpers.assert_eq(entry.type,        "system_event")
		helpers.assert_eq(entry.action,      "passive_period")
		helpers.assert_eq(entry.duration_ms, 120000)
	end)
end)
