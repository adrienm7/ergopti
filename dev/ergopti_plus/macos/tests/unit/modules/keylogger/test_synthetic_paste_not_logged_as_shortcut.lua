--- tests/unit/modules/keylogger/test_synthetic_paste_not_logged_as_shortcut.lua

--- ==============================================================================
--- MODULE: Regression — synthetic paste Cmd+V is not logged as a user shortcut (F-HIGH-17)
--- DESCRIPTION:
--- Any hotstring/personal-info/LLM expansion whose replacement exceeds the
--- 50-codepoint paste threshold synthesizes a Cmd+V (keymap.utils.emit_text /
--- emit_tokens). The keylogger's shortcut-classification branch
--- (is_shortcut_candidate → LogManager.log_shortcut) was never wired to the
--- keymap module's synthetic-paste tracker (CoreState.expected_synthetic_pastes)
--- — it only gated the plain-character branch further down via synth_queue. Net
--- effect: every long paste-worthy expansion inflated the user's logged Cmd+V
--- shortcut count, corrupting metrics data integrity.
---
--- Fix: keymap/init.lua exposes M.is_pending_synthetic_paste(flags, key_code), a
--- read-only peek built on the new pure predicate
--- keymap.utils.is_synthetic_paste_keystroke(flags, is_v_key, pending_pastes)
--- (is_v_key is resolved via the keycode registry rather than a fresh keycode-map
--- lookup, so the peek adds no new OS-API call site). keylogger/init.lua's
--- handle_key now gates LogManager.log_shortcut on
--- `not _keymap_mod.is_pending_synthetic_paste(flags, keycode)`.
---
--- This test exercises the real predicate and the real LogManager.log_shortcut
--- delegate together, mirroring the exact gating branch handle_key now runs
--- (keylogger/init.lua cannot be driven end-to-end in a headless unit test: its
--- M.start() needs hs.caffeinate and real filesystem I/O unavailable under the
--- stub), and separately pins the gate at the source level.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local KU = helpers.load_with_stubs("modules.keymap.utils")

--- Builds a fully-initialized LogManager instance with an inspectable
--- _appended_entries array, mirroring test_log_manager.lua's make_initialized_lm.
--- @return table LogManager module instance, table appended-entries array.
local function make_log_manager()
	package.loaded["modules.keylogger.rotation"] = {
		init = function() end, is_initialized = function() return true end,
		append_log = function(entry) end,
		read_new_entries = function() return {}, 0 end,
		get_offset = function() return 0 end, get_date = function() return os.date("%Y-%m-%d") end,
		set_offset = function() end, rollover = function() end,
	}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		init = function() end, open_db = function() return true end, close_db = function() end,
		get_db = function() return nil end, build_inserts = function() return {} end,
		persist_next_event_id = function() end,
	}
	package.loaded["modules.keylogger.aggregator"] = {
		init = function() end, walk_typing = function() end, walk_app_switch = function() end,
		walk_window_switch = function() end, walk_system_event = function() end, flush = function() end,
		get_ngram_ctx = function() return {} end, set_ngram_ctx = function() end, reset_ngram_ctx = function() end,
	}
	package.loaded["modules.keylogger.export"] = {
		init = function() end, get_native_app_category = function() return "other" end,
		get_device_short_id = function() return "abcd" end, get_sqlite_path = function() return "/tmp/test.sqlite" end,
		get_db_rev = function() return 0 end, sync_foreign_data_sql = function() end,
	}
	package.loaded["lib.timings"] = {
		ms  = function(_section, _key) return 1000 end,
		sec = function(_section, _key) return 1.0 end,
	}

	local appended_entries = {}
	-- Capture append_log directly rather than relying on rotation's own storage,
	-- so the test observes exactly what log_manager hands off per call.
	local hs_overrides = {
		fs = { attributes = function() return nil end, dir = function() return function() return nil end end },
		execute = function() return "" end,
	}
	local LM = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
	local orig_rotation = package.loaded["modules.keylogger.rotation"]
	orig_rotation.append_log = function(entry) table.insert(appended_entries, entry) end

	LM.init({
		LOG_DIR = "/tmp/synth_paste_shortcut_test",
		buffer_events = {}, buffer_text = "", rich_chunks = {},
		session_mouse_clicks = 0, session_mouse_scrolls = 0,
		mouse_distance_px = 0, last_flush_time = 0,
		last_time = 0, pending_keyup = {},
		today_idx = {}, manifest = {},
	})
	return LM, appended_entries
end

--- Mirrors handle_key's shortcut-classification gate verbatim: logs a shortcut
--- via the REAL LogManager.log_shortcut unless the keystroke is a pending
--- synthetic paste echo per the REAL keymap.utils predicate.
--- @param LM table A real, initialized LogManager instance.
--- @param flags table The modifier flags from the key event.
--- @param is_v_key boolean Whether the keystroke's keycode resolves to "v".
--- @param pending_pastes number CoreState.expected_synthetic_pastes at this instant.
local function simulate_shortcut_branch(LM, flags, is_v_key, pending_pastes)
	local is_synth_paste = KU.is_synthetic_paste_keystroke(flags, is_v_key, pending_pastes)
	if not is_synth_paste then
		LM.log_shortcut("cmd+v", "TestApp")
	end
end





-- ===============================================================================
-- ===============================================================================
-- ======= 1/ Synthetic paste echo is NOT logged as a shortcut (F-HIGH-17) =======
-- ===============================================================================
-- ===============================================================================

helpers.describe("keylogger: synthetic paste Cmd+V is not logged as a shortcut (F-HIGH-17)", function()

	helpers.it("LogManager.log_shortcut is NOT called when a synthetic paste is pending", function()
		local LM, entries = make_log_manager()

		-- Prime a pending paste exactly as expander.lua does: emit_tokens/emit_text
		-- increments the paste-ops counter, which flows into
		-- CoreState.expected_synthetic_pastes in the real keymap module.
		KU.take_paste_ops()  -- drain any leakage from a previous test
		KU.emit_text(("a"):rep(60))  -- 60 chars exceeds the 50-char paste threshold
		local pending_pastes = KU.take_paste_ops()
		helpers.assert_eq(pending_pastes, 1, "emit_text must have queued exactly one paste op")

		simulate_shortcut_branch(LM, { cmd = true }, true, pending_pastes)

		helpers.assert_eq(#entries, 0, "log_shortcut must NOT append an entry for a synthetic paste echo")
	end)

	helpers.it("LogManager.log_shortcut IS called for a genuine user Cmd+V (no pending paste)", function()
		local LM, entries = make_log_manager()

		simulate_shortcut_branch(LM, { cmd = true }, true, 0)

		helpers.assert_eq(#entries, 1, "a genuine Cmd+V with no pending synthetic paste must be logged")
		helpers.assert_eq(entries[1].type, "shortcut")
		helpers.assert_eq(entries[1].key, "cmd+v")
	end)

	helpers.it("LogManager.log_shortcut IS called for a different Cmd+key combo even with a pending paste", function()
		local LM, entries = make_log_manager()
		-- Cmd+C: cmd is held but the key is NOT "v" — the pending-paste peek must
		-- only suppress the exact Cmd+V echo, never other genuine shortcuts.
		local is_synth_paste = KU.is_synthetic_paste_keystroke({ cmd = true }, false, 1)
		helpers.assert_eq(is_synth_paste, false, "a non-V key must never match the synthetic-paste predicate")
		if not is_synth_paste then LM.log_shortcut("cmd+c", "TestApp") end
		helpers.assert_eq(#entries, 1)
	end)
end)





-- ====================================================================================
-- ====================================================================================
-- ======= 2/ Source pin: handle_key gates log_shortcut on the peek (F-HIGH-17) =======
-- ====================================================================================
-- ====================================================================================

helpers.describe("keylogger: handle_key source gates log_shortcut on is_pending_synthetic_paste (F-HIGH-17)", function()

	helpers.it("the shortcut branch checks is_pending_synthetic_paste before calling log_shortcut", function()
		local path = helpers.driver_root() .. "modules/keylogger/init.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open keylogger/init.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()

		local branch_start = src:find("is_shortcut_candidate(flags, keycode) then", 1, true)
		helpers.assert_true(branch_start ~= nil, "the shortcut-classification branch must still exist")

		local branch_end = src:find("\n\t\t-- Drop synthetic OS%-signal keys", branch_start)
		local branch = src:sub(branch_start, branch_end or (branch_start + 600))

		local peek_pos = branch:find("is_pending_synthetic_paste(flags, keycode)", 1, true)
		local log_pos  = branch:find("log_shortcut(", 1, true)
		helpers.assert_true(peek_pos ~= nil, "handle_key must call is_pending_synthetic_paste inside the shortcut branch")
		helpers.assert_true(log_pos ~= nil, "handle_key must still call log_shortcut for genuine shortcuts")
		helpers.assert_true(peek_pos < log_pos, "the synthetic-paste peek must be evaluated before log_shortcut runs")
	end)
end)
