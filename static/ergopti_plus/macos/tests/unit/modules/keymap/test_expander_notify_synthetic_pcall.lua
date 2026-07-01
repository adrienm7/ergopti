--- tests/unit/modules/keymap/test_expander_notify_synthetic_pcall.lua

--- ==============================================================================
--- MODULE: Regression — expander guards notify_synthetic against raising (F-HIGH-16)
--- DESCRIPTION:
--- perform_text_replacement — the synthetic-injection choke point used by every
--- hotstring/LLM-paste path — called keylogger.notify_synthetic(...) WITHOUT a
--- pcall, unlike the neighboring buffer_action call a few lines below (which is
--- explicitly pcall-wrapped, with a comment acknowledging exactly this desync
--- risk). notify_synthetic's own utf8.codes loop can raise on malformed UTF-8
--- (e.g. a truncated LLM completion cut mid-codepoint), which used to abort the
--- expansion mid-flight and leave the synthetic-injection trackers desynced.
---
--- This test drives the REAL perform_text_replacement with an injected
--- modules.keylogger stub whose notify_synthetic always raises, and asserts the
--- expansion still completes (buffer_action runs, no propagated error).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

--- Builds a minimal CoreState object that satisfies the expander's contract.
--- @return table
local function make_state(buffer)
	local s = {
		buffer                     = buffer or "",
		expected_synthetic_chars   = "",
		expected_synthetic_deletes = 0,
		magic_key                  = "★",
		repeat_enabled             = true,
	}
	function s.is_repeat_feature_enabled() return s.repeat_enabled end
	function s.suppress_rescan(_) end
	return s
end

local function make_registry(terminator_set, consumed_set)
	local R = {}
	function R.is_terminator(c) return (terminator_set or {})[c] == true end
	function R.terminator_is_consumed(c) return (consumed_set or {})[c] == true end
	return R
end

local function make_llm()
	local L = { previews = {}, timer_starts = 0, llm_on = false }
	function L.update_preview(buf) table.insert(L.previews, buf) end
	function L.get_llm_enabled() return L.llm_on end
	function L.start_timer() L.timer_starts = L.timer_starts + 1 end
	return L
end




-- ==================================================================================
-- ==================================================================================
-- ======= 1/ perform_text_replacement survives a raising notify_synthetic ========
-- ==================================================================================
-- ==================================================================================

helpers.describe("keymap.expander: perform_text_replacement survives notify_synthetic raising (F-HIGH-16)", function()

	helpers.it("completes the expansion (buffer_action still runs) when notify_synthetic throws", function()
		-- Inject a keylogger stub whose notify_synthetic always raises, mimicking
		-- notify_synthetic's own utf8.codes crash on malformed UTF-8 input BEFORE
		-- the keylogger-side fix guards it — pins that the CALL SITE in expander.lua
		-- must not let this propagate regardless of what notify_synthetic does.
		package.loaded["modules.keylogger"] = {
			notify_synthetic = function() error("simulated malformed-UTF-8 crash") end,
			set_buffer       = function() end,
		}
		local E = helpers.load_with_stubs("modules.keymap.expander")

		local s = make_state("hello")
		E.init(s, make_registry({}, {}), make_llm())

		local buf_called = false
		local ok = pcall(E.perform_text_replacement,
			3,
			function() return 4, "wrld" end,
			function() buf_called = true; s.buffer = "hewrld" end,
			false, false, "test"
		)

		-- Must run before any assertion could fail-and-return-early below:
		-- this test is the only one that ever assigns a raising stub into
		-- package.loaded["modules.keylogger"]. Without clearing it here, the
		-- poisoned stub leaks into every later test file that requires
		-- modules.keylogger in this same Lua process — it doesn't crash them
		-- (the real notify_synthetic pcall guard swallows it), but for a
		-- module like test_expander.lua that reads notify_synthetic's return
		-- value or side effects, the always-raising stub silently changes
		-- behaviour and fails unrelated tests with this file's own error
		-- message, which is exactly what happened in CI on 2026-07-01.
		package.loaded["modules.keylogger"] = nil

		helpers.assert_true(ok, "perform_text_replacement must not propagate a notify_synthetic error")
		helpers.assert_true(buf_called, "buffer_action must still run after notify_synthetic throws")
		helpers.assert_eq(s.buffer, "hewrld")
	end)
end)
