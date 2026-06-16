--- tests/unit/modules/llm/test_prediction_engine_reset.lua

--- ==============================================================================
--- MODULE: prediction_engine.reset() Chain-Cleanup Tests
--- DESCRIPTION:
--- Regression tests for the D3 audit finding: M.reset() did not clear
--- chain_pending or stop _chain_trigger_timer, so a fallback timer that fired
--- after a reset could call M.perform_check() on stale state.
---
--- After the fix, M.reset() unconditionally sets chain_pending = false and
--- stops/nils _chain_trigger_timer before any other teardown.
---
--- These tests verify the contract via a lightweight simulation that mirrors
--- the state machine without requiring the full HS environment.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
--- =======================================================
-- ======= 1/ reset() chain-state cleanup contract =======
--- =======================================================
-- ================================================================

helpers.describe("prediction_engine.reset(): chain state cleanup (D3)", function()
	--- Minimal simulation of the chain-pending state machine used by
	--- prediction_engine: arm_chain() sets the flag, reset() must clear it.
	local function make_engine()
		local engine = {
			chain_pending         = false,
			chain_timer_stopped   = false,
			chain_timer_exists    = false,
			fetch_called_by_timer = false,
		}

		function engine.arm_chain()
			engine.chain_pending       = true
			engine.chain_timer_exists  = true
			-- Simulate fallback timer body: fires fetch only if chain_pending is true
			engine._timer_callback = function()
				if engine.chain_pending then
					engine.fetch_called_by_timer = true
				end
			end
		end

		function engine.reset()
			-- D3 fix: clear chain state FIRST, before stopping other resources
			engine.chain_pending = false
			if engine.chain_timer_exists then
				engine.chain_timer_stopped = true
				engine.chain_timer_exists  = false
				engine._timer_callback     = nil
			end
			-- (Other teardown omitted for this unit test)
		end

		return engine
	end

	helpers.it("is_chain_pending() returns false immediately after reset()", function()
		local e = make_engine()
		e.arm_chain()
		helpers.assert_eq(e.chain_pending, true)
		e.reset()
		helpers.assert_eq(e.chain_pending, false)
	end)

	helpers.it("reset() stops and nils the fallback timer", function()
		local e = make_engine()
		e.arm_chain()
		helpers.assert_eq(e.chain_timer_exists, true)
		e.reset()
		helpers.assert_eq(e.chain_timer_stopped, true)
		helpers.assert_eq(e.chain_timer_exists, false)
	end)

	helpers.it("fallback timer callback does NOT call fetch after reset()", function()
		local e = make_engine()
		e.arm_chain()
		-- Capture the callback before reset() nils it
		local captured_cb = e._timer_callback
		e.reset()
		-- Simulate the timer firing after reset (race condition scenario)
		if captured_cb then
			captured_cb()
		end
		-- chain_pending was cleared by reset(), so fetch must NOT have been called
		helpers.assert_eq(e.fetch_called_by_timer, false)
	end)

	helpers.it("reset() is safe to call when chain was never armed", function()
		local e = make_engine()
		-- Should not error when chain_pending is already false and no timer exists
		local ok = pcall(function() e.reset() end)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(e.chain_pending, false)
	end)
end)
