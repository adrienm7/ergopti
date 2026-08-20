--- tests/unit/modules/keymap/test_apply_prediction_failure_propagation.lua

--- ==============================================================================
--- MODULE: apply_prediction replacement-failure propagation
--- DESCRIPTION:
--- A transaction builder may reject output by returning false without throwing.
--- The bridge must propagate that status before logging acceptance, arming the
--- chain, injecting F16, or consuming the user's validation key.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.apply_prediction_fixture")


helpers.describe("apply_prediction: rejected replacement is not accepted", function()
	helpers.it("propagates false and performs no success-only side effects", function()
		local result = fixture.run({
			text = "completion",
			buffer = "prefix ",
			expander_failure = true,
		})

		helpers.assert_true(result.call_ok,
			"a returned construction failure is data, not a Lua exception")
		helpers.assert_eq(result.applied, false,
			"apply_prediction must propagate perform_text_replacement(false)")
		helpers.assert_eq(result.consume, false,
			"without replacement output the user's validation key must not be swallowed")
		helpers.assert_nil(result.events,
			"a rejected transaction must return no Quartz replacement events")
		helpers.assert_eq(result.state.buffer, result.buffer_before,
			"the logical buffer must remain unchanged when no output was accepted")
		helpers.assert_eq(result.accepted_count, 0,
			"failed construction must not be persisted as an accepted prediction")
		helpers.assert_eq(result.arm_chain_count, 0,
			"there is no completed prediction from which to request a chain")
		helpers.assert_eq(result.timer_delta, 0,
			"failed construction must not queue the F16 loopback signal")
		helpers.assert_eq(result.synthetic.stats().active_transactions, 0,
			"failed construction must not leave an implicit loopback transaction")
		helpers.assert_eq(result.synthetic.stats().records, 0,
			"failed construction must not allocate provenance for phantom output")
	end)
end)
