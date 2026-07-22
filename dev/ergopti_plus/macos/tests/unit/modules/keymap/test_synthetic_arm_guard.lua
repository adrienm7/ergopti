--- tests/unit/modules/keymap/test_synthetic_arm_guard.lua

--- ==============================================================================
--- MODULE: keymap synthetic arm-guard Unit Tests
--- DESCRIPTION:
--- Regression tests for the A6 audit finding: the 0.5 s stuck-counter reset in
--- onKeyDownRaw must not wipe expected_synthetic_deletes / expected_synthetic_chars
--- when the counters were armed within the last second (last_synthetic_arm_time).
--- Previously the reset fired unconditionally on dt > 0.5, which could destroy
--- counters that were just set by perform_text_replacement if the runloop lagged.
---
--- These tests exercise the state.new() factory (verifying the new field exists)
--- and the arm_synthetic logic in isolation via a lightweight simulation.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local State = helpers.load_with_stubs("modules.keymap.state")

local function make_defaults()
	return { trigger_char = "★", expansion_delay = 0.4 }
end





-- ====================================================
-- ==================================================
-- ======= 1/ CoreState carries the new field =======
-- ==================================================
-- ====================================================

helpers.describe("CoreState: last_synthetic_arm_time field", function()
	helpers.it("is present and initialised to 0 in a fresh state", function()
		local s = State.new(make_defaults(), {})
		helpers.assert_eq(type(s.last_synthetic_arm_time), "number")
		helpers.assert_eq(s.last_synthetic_arm_time, 0)
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 2/ Synthetic counter reset respects arm timestamp =======
-- =================================================================
-- =================================================================

helpers.describe("onKeyDownRaw: synthetic counter reset guard (A6)", function()
	--- Simulates the reset logic from onKeyDownRaw with the A6 guard applied.
	--- @param dt number Inter-key delay in seconds.
	--- @param now number Current epoch timestamp.
	--- @param last_arm number Epoch timestamp of the last arm_synthetic() call.
	--- @param deletes number Current expected_synthetic_deletes value.
	--- @param chars string Current expected_synthetic_chars value.
	--- @return number, string Post-reset deletes and chars values.
	local function simulate_reset_guard(dt, now, last_arm, deletes, chars)
		-- Replicate the guard from onKeyDownRaw exactly:
		-- if dt > 0.5 and (now - last_arm) > 1.0 then reset end
		if dt > 0.5 and (now - last_arm) > 1.0 then
			deletes = 0
			chars   = ""
		end
		return deletes, chars
	end

	helpers.it("resets counters when dt > 0.5 and arm is old (> 1 s ago)", function()
		-- Arm happened 2 seconds ago — safe to reset
		local deletes, chars = simulate_reset_guard(0.6, 100.0, 98.0, 3, "abc")
		helpers.assert_eq(deletes, 0)
		helpers.assert_eq(chars, "")
	end)

	helpers.it("preserves counters when dt > 0.5 but arm is recent (< 1 s ago)", function()
		-- Arm happened 0.4 s ago — in-flight expansion, must NOT reset
		local deletes, chars = simulate_reset_guard(0.6, 100.0, 99.6, 3, "abc")
		helpers.assert_eq(deletes, 3)
		helpers.assert_eq(chars, "abc")
	end)

	helpers.it("preserves counters when dt <= 0.5 regardless of arm time", function()
		-- Short gap — normal typing rhythm, never resets
		local deletes, chars = simulate_reset_guard(0.3, 100.0, 50.0, 2, "xy")
		helpers.assert_eq(deletes, 2)
		helpers.assert_eq(chars, "xy")
	end)

	helpers.it("preserves counters when arm_time == now (just armed)", function()
		-- Arm happened this instant (now - arm = 0) — must NOT reset
		local deletes, chars = simulate_reset_guard(0.6, 100.0, 100.0, 1, "z")
		helpers.assert_eq(deletes, 1)
		helpers.assert_eq(chars, "z")
	end)
end)
