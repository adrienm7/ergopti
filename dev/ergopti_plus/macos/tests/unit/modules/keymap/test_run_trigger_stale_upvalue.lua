--- tests/unit/modules/keymap/test_run_trigger_stale_upvalue.lua

--- ==============================================================================
--- MODULE: keymap run_trigger_checks deferred-upvalue regression test (H-19)
--- DESCRIPTION:
--- Regression guard for the stale-upvalue bug in the ignored-window deferred path
--- of keymap/init.lua. When a keystroke arrives while the focused window is on the
--- ignore list, the handler schedules run_trigger_checks() via hs.timer.doAfter(0,…)
--- instead of calling it directly. The naive pre-H-19 implementation stored the
--- per-keystroke context in module-level variables (_tc_chars, _tc_char_len,
--- _tc_dt, _tc_complex_mult, _tc_is_ignored) and then captured those variables by
--- REFERENCE inside the deferred closure. A second rapid keystroke therefore
--- overwrote the module-level variables before the first deferred callback ran,
--- making BOTH closures see the second keystroke's context.
---
--- The fix (lines 801–811 of init.lua) captures each variable's VALUE into the
--- closure's parameter list at scheduling time:
---
---   hs.timer.doAfter(0, (function(chars, len, dt, mult, ign)
---     return function()
---       _tc_chars, _tc_char_len, … = chars, len, dt, mult, ign
---       run_trigger_checks()
---     end
---   end)(_tc_chars, _tc_char_len, _tc_dt, _tc_complex_mult, _tc_is_ignored))
---
--- FEATURES & RATIONALE:
--- 1. Self-contained: replicates the exact closure idiom without requiring the
---    full modules.keymap.init (which pulls in Hammerspoon runtime deps).
--- 2. Deterministic: "fires" deferred timers synchronously so the test never
---    depends on OS scheduling.
--- 3. Targets the root cause: asserts that the context seen by run_trigger_checks
---    at execution time matches the context present at SCHEDULING time, not at
---    execution time.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Closure idiom under test =======
-- ===========================================
-- ===========================================

--- Builds a minimal replica of the keymap ignored-window deferred path.
--- Returns a test harness that mimics the module and exposes:
---   simulate_keystroke(chars, len, dt, mult) -- schedules a deferred call
---   fire_pending()                            -- runs all pending deferred callbacks
---   captured_calls                            -- list of {chars, len, dt, mult, ign}
---                                               recorded by run_trigger_checks
--- @return table Harness with the three fields above.
local function make_harness()
	-- Module-level upvalues (mirrors _tc_* in init.lua)
	local _tc_chars        = ""
	local _tc_char_len     = 1
	local _tc_dt           = 0
	local _tc_complex_mult = 1
	local _tc_is_ignored   = false

	-- Deferred callback queue (mirrors hs.timer.doAfter in init.lua)
	local pending = {}

	-- Recorded invocations of the simulated run_trigger_checks
	local captured_calls = {}

	--- Simulated run_trigger_checks — reads the module-level upvalues, exactly
	--- as the real function does, and appends a snapshot to captured_calls.
	local function run_trigger_checks()
		captured_calls[#captured_calls + 1] = {
			chars        = _tc_chars,
			len          = _tc_char_len,
			dt           = _tc_dt,
			complex_mult = _tc_complex_mult,
			is_ignored   = _tc_is_ignored,
		}
	end

	--- Simulates one keystroke arriving while the window is ignored.
	--- Replicates the exact production code from init.lua (H-19 fix):
	--- all five upvalues are captured by value into the closure, then
	--- reassigned into the module-level variables just before the call.
	--- @param chars        string  Character(s) produced by the keystroke.
	--- @param len          number  Codepoint count of chars.
	--- @param dt           number  Elapsed seconds since previous keystroke.
	--- @param mult         number  Complex-keystroke delay multiplier.
	local function simulate_keystroke(chars, len, dt, mult)
		-- Populate module-level upvalues (mirrors the block in onKeyDownRaw)
		_tc_chars        = chars
		_tc_char_len     = len
		_tc_dt           = dt
		_tc_complex_mult = mult
		_tc_is_ignored   = true  -- always ignored in this harness

		-- The H-19 fix: capture each value NOW, before any later keystroke can
		-- overwrite the module-level variables. This is the exact outer-function
		-- / inner-closure idiom from init.lua lines 805-811.
		pending[#pending + 1] = (function(c, l, d, m, ign)
			return function()
				_tc_chars, _tc_char_len, _tc_dt, _tc_complex_mult, _tc_is_ignored
					= c, l, d, m, ign
				run_trigger_checks()
			end
		end)(_tc_chars, _tc_char_len, _tc_dt, _tc_complex_mult, _tc_is_ignored)
	end

	--- Fires every pending deferred callback in FIFO order, then clears the queue.
	local function fire_pending()
		for _, cb in ipairs(pending) do cb() end
		-- Clear the queue to allow re-use within a single test
		for i = #pending, 1, -1 do pending[i] = nil end
	end

	return {
		simulate_keystroke = simulate_keystroke,
		fire_pending       = fire_pending,
		captured_calls     = captured_calls,
	}
end


--- Builds a harness that uses the PRE-H-19 (buggy) capture approach.
--- Instead of capturing values into the closure parameters, the closure
--- captures the module-level upvalues by reference. A second keystroke
--- therefore overwrites them before the first callback runs.
--- @return table Harness with simulate_keystroke / fire_pending / captured_calls.
local function make_buggy_harness()
	local _tc_chars        = ""
	local _tc_char_len     = 1
	local _tc_dt           = 0
	local _tc_complex_mult = 1
	local _tc_is_ignored   = false

	local pending        = {}
	local captured_calls = {}

	local function run_trigger_checks()
		captured_calls[#captured_calls + 1] = {
			chars        = _tc_chars,
			len          = _tc_char_len,
			dt           = _tc_dt,
			complex_mult = _tc_complex_mult,
			is_ignored   = _tc_is_ignored,
		}
	end

	local function simulate_keystroke(chars, len, dt, mult)
		_tc_chars        = chars
		_tc_char_len     = len
		_tc_dt           = dt
		_tc_complex_mult = mult
		_tc_is_ignored   = true

		-- Buggy pre-H-19: the closure captures the upvalue REFERENCES,
		-- so overwriting them later affects what run_trigger_checks sees
		pending[#pending + 1] = function()
			run_trigger_checks()
		end
	end

	local function fire_pending()
		for _, cb in ipairs(pending) do cb() end
		for i = #pending, 1, -1 do pending[i] = nil end
	end

	return {
		simulate_keystroke = simulate_keystroke,
		fire_pending       = fire_pending,
		captured_calls     = captured_calls,
	}
end





-- ===============================================
-- ===============================================
-- ======= 2/ Core non-contamination tests =======
-- ===============================================
-- ===============================================

helpers.describe("H-19 fix: deferred run_trigger_checks receives its own keystroke context", function()

	helpers.it("first callback gets chars from keystroke 1, not keystroke 2", function()
		local h = make_harness()
		h.simulate_keystroke("a", 1, 0.05, 1)
		h.simulate_keystroke("b", 1, 0.04, 1)
		h.fire_pending()
		-- First deferred call must have seen "a", not "b"
		helpers.assert_eq(h.captured_calls[1].chars, "a",
			"first deferred call must carry 'a' (keystroke 1 chars)")
	end)

	helpers.it("second callback gets chars from keystroke 2", function()
		local h = make_harness()
		h.simulate_keystroke("a", 1, 0.05, 1)
		h.simulate_keystroke("b", 1, 0.04, 1)
		h.fire_pending()
		helpers.assert_eq(h.captured_calls[2].chars, "b",
			"second deferred call must carry 'b' (keystroke 2 chars)")
	end)

	helpers.it("each callback receives its own dt value", function()
		local h = make_harness()
		h.simulate_keystroke("x", 1, 0.10, 1)
		h.simulate_keystroke("y", 1, 0.20, 1)
		h.fire_pending()
		helpers.assert_eq(h.captured_calls[1].dt, 0.10,
			"first callback must carry dt from keystroke 1")
		helpers.assert_eq(h.captured_calls[2].dt, 0.20,
			"second callback must carry dt from keystroke 2")
	end)

	helpers.it("each callback receives its own complex_mult value", function()
		local h = make_harness()
		h.simulate_keystroke("A", 1, 0.05, 2)  -- shift-held: mult = 2
		h.simulate_keystroke("a", 1, 0.05, 1)  -- plain: mult = 1
		h.fire_pending()
		helpers.assert_eq(h.captured_calls[1].complex_mult, 2,
			"first callback must carry the shift-key multiplier")
		helpers.assert_eq(h.captured_calls[2].complex_mult, 1,
			"second callback must carry the non-shift multiplier")
	end)

	helpers.it("each callback receives its own codepoint length", function()
		local h = make_harness()
		-- Single ASCII char: len = 1
		h.simulate_keystroke("a", 1, 0.05, 1)
		-- Three-codepoint cluster: len = 3
		h.simulate_keystroke("abc", 3, 0.05, 1)
		h.fire_pending()
		helpers.assert_eq(h.captured_calls[1].len, 1,
			"first callback must carry len = 1")
		helpers.assert_eq(h.captured_calls[2].len, 3,
			"second callback must carry len = 3")
	end)

	helpers.it("is_ignored is true for every deferred call in an ignored window", function()
		local h = make_harness()
		h.simulate_keystroke("p", 1, 0.05, 1)
		h.simulate_keystroke("q", 1, 0.06, 1)
		h.fire_pending()
		helpers.assert_eq(h.captured_calls[1].is_ignored, true,
			"first deferred call must carry is_ignored = true")
		helpers.assert_eq(h.captured_calls[2].is_ignored, true,
			"second deferred call must carry is_ignored = true")
	end)

	helpers.it("exactly two deferred calls are scheduled for two keystrokes", function()
		local h = make_harness()
		h.simulate_keystroke("m", 1, 0.07, 1)
		h.simulate_keystroke("n", 1, 0.08, 1)
		h.fire_pending()
		helpers.assert_eq(#h.captured_calls, 2,
			"exactly two run_trigger_checks invocations expected")
	end)

	helpers.it("three rapid keystrokes produce three isolated contexts", function()
		local h = make_harness()
		h.simulate_keystroke("r", 1, 0.03, 1)
		h.simulate_keystroke("s", 1, 0.04, 1)
		h.simulate_keystroke("t", 1, 0.05, 1)
		h.fire_pending()
		helpers.assert_eq(#h.captured_calls, 3,
			"three keystrokes must yield three deferred calls")
		helpers.assert_eq(h.captured_calls[1].chars, "r", "call 1: chars = r")
		helpers.assert_eq(h.captured_calls[2].chars, "s", "call 2: chars = s")
		helpers.assert_eq(h.captured_calls[3].chars, "t", "call 3: chars = t")
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 3/ Buggy harness confirms what the fix prevents =======
-- ===============================================================
-- ===============================================================

helpers.describe("H-19 regression: pre-fix reference-capture causes contamination", function()

	helpers.it("buggy harness: both callbacks see the SECOND keystroke chars", function()
		-- This test documents the exact failure mode the fix prevents.
		-- The buggy closure captures upvalue references; the second simulate_keystroke
		-- call overwrites them before fire_pending runs.
		local h = make_buggy_harness()
		h.simulate_keystroke("a", 1, 0.05, 1)
		h.simulate_keystroke("b", 1, 0.04, 1)
		h.fire_pending()
		-- Both calls see "b" (stale upvalue bug)
		helpers.assert_eq(h.captured_calls[1].chars, "b",
			"buggy: first callback sees chars overwritten by keystroke 2")
		helpers.assert_eq(h.captured_calls[2].chars, "b",
			"buggy: second callback also sees the overwritten chars")
	end)

	helpers.it("buggy harness: both callbacks see the SECOND keystroke dt", function()
		local h = make_buggy_harness()
		h.simulate_keystroke("x", 1, 0.10, 1)
		h.simulate_keystroke("y", 1, 0.20, 1)
		h.fire_pending()
		helpers.assert_eq(h.captured_calls[1].dt, 0.20,
			"buggy: first callback dt is overwritten by keystroke 2")
	end)

end)





-- ========================================================================
-- ========================================================================
-- ======= 4/ Contract: fixed harness does NOT show buggy behaviour =======
-- ========================================================================
-- ========================================================================

helpers.describe("H-19 fix: fixed harness does not exhibit pre-fix contamination", function()

	helpers.it("first callback chars differ from second when keystrokes differ", function()
		local h = make_harness()
		h.simulate_keystroke("p", 1, 0.05, 1)
		h.simulate_keystroke("q", 1, 0.06, 1)
		h.fire_pending()
		-- The two chars must NOT be equal: the fix keeps them separate
		helpers.assert_true(
			h.captured_calls[1].chars ~= h.captured_calls[2].chars,
			"fix: each callback must see its own distinct chars value")
	end)

	helpers.it("first callback dt differs from second when dts differ", function()
		local h = make_harness()
		h.simulate_keystroke("a", 1, 0.10, 1)
		h.simulate_keystroke("b", 1, 0.99, 1)
		h.fire_pending()
		helpers.assert_true(
			h.captured_calls[1].dt ~= h.captured_calls[2].dt,
			"fix: each callback must see its own distinct dt value")
	end)

	helpers.it("first callback complex_mult differs from second when mults differ", function()
		local h = make_harness()
		h.simulate_keystroke("A", 1, 0.05, 2)
		h.simulate_keystroke("b", 1, 0.05, 1)
		h.fire_pending()
		helpers.assert_true(
			h.captured_calls[1].complex_mult ~= h.captured_calls[2].complex_mult,
			"fix: each callback must see its own distinct complex_mult value")
	end)

end)
