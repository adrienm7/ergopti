-- tests/unit/modules/keylogger/test_root_recurring_owner_transaction.lua
-- Causal lifecycle tests for the keylogger root's recurring native owners.

local helpers = require("tests.helpers")
local fixture = require("tests.unit.modules.keylogger.test_activation_callback_fail_closed")
local load_keylogger = fixture.load_keylogger

helpers.describe("keylogger root recurring-owner transaction", function()
	helpers.it("rejects a chainable start whose running probe stays false (keylogger-root-owner-transaction)", function()
		local ctx = load_keylogger({
			timer_lifecycle = true,
			timer_start_stays_stopped_at = 1,
		})

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(false, ctx.state.is_enabled,
			"a truthy timer object is not activation without running() == true")
		helpers.assert_eq(1, ctx.timer_handles[1].stop_calls,
			"the exact uncommitted candidate must still enter rollback")
		helpers.assert_eq(1, ctx.caffeinate_stop_calls,
			"a later timer refusal must roll back the earlier watcher sibling")
	end)

	helpers.it("rolls back activate-then-throw and fences its stale delivery (keylogger-root-owner-transaction)", function()
		local ctx = load_keylogger({
			timer_lifecycle = true,
			timer_start_throws_after_active_at = 2,
		})
		local idle_candidate = ctx.timer_handles[2]

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_true(idle_candidate ~= nil and idle_candidate.stop_calls == 1,
			"a candidate activated before throwing must retain exact rollback ownership")
		idle_candidate.callback()
		helpers.assert_eq(0, ctx.idle_calls,
			"a queued callback from the rolled-back generation must be inert")
	end)

	helpers.it("rolls back every earlier timer when a later sibling is unavailable (keylogger-root-owner-transaction)", function()
		local ctx = load_keylogger({
			timer_lifecycle = true,
			timer_new_fail_at = 3,
		})

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(1, ctx.timer_handles[1].stop_calls)
		helpers.assert_eq(1, ctx.timer_handles[2].stop_calls,
			"maintenance construction failure must release the committed idle sibling")
		helpers.assert_eq(1, ctx.caffeinate_stop_calls)
	end)

	helpers.it("retains a timer whose chainable stop leaves it running (keylogger-root-owner-transaction)", function()
		local ctx = load_keylogger({
			timer_lifecycle = true,
			timer_stop_stays_running_at = 2,
			timer_stop_refusals = 1,
		})
		local idle_candidate = ctx.timer_handles[2]

		helpers.assert_eq(true, ctx.start_result)
		helpers.assert_eq(false, ctx.keylogger.stop(),
			"stop returning the timer object cannot clear a still-running candidate")
		helpers.assert_eq(true, idle_candidate:running())
		helpers.assert_eq(true, ctx.keylogger.stop(),
			"a later stop must retry the retained exact candidate")
		helpers.assert_eq(2, idle_candidate.stop_calls)
		helpers.assert_eq(false, idle_candidate:running())
	end)

	helpers.it("delivers foreground bootstrap once and retries its exact stop debt (keylogger-root-owner-transaction)", function()
		local ctx = load_keylogger({
			timer_lifecycle = true,
			timer_stop_stays_running_at = 4,
			timer_stop_refusals = 1,
		})
		local bootstrap = ctx.timer_handles[4]

		helpers.assert_eq(true, ctx.start_result)
		bootstrap.callback()
		helpers.assert_eq(1, ctx.foreground_capture_calls)
		helpers.assert_eq(true, bootstrap:running(),
			"a refused callback-time stop must retain the live bootstrap capability")
		bootstrap.callback()
		helpers.assert_eq(1, ctx.foreground_capture_calls,
			"duplicate native delivery must never repeat foreground publication")
		helpers.assert_eq(2, bootstrap.stop_calls,
			"duplicate delivery may retry only the exact retained cleanup debt")
		helpers.assert_eq(false, bootstrap:running())
	end)

	helpers.it("requires foreground bootstrap activation before publishing enabled (keylogger-root-owner-transaction)", function()
		local ctx = load_keylogger({
			timer_lifecycle = true,
			timer_start_stays_stopped_at = 4,
		})

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(false, ctx.state.is_enabled)
		helpers.assert_eq(1, ctx.timer_handles[1].stop_calls)
		helpers.assert_eq(1, ctx.timer_handles[2].stop_calls)
		helpers.assert_eq(1, ctx.timer_handles[3].stop_calls)
	end)

	helpers.it("keeps the KC drain alive on feature OFF and stops it only at shutdown (keylogger-root-owner-transaction)", function()
		local ctx = load_keylogger({
			timer_lifecycle = true,
			kc_stop_results = { false, true },
		})

		helpers.assert_eq(true, ctx.start_result)
		helpers.assert_eq(true, ctx.keylogger.stop())
		helpers.assert_eq(0, ctx.kc_stop_calls,
			"feature OFF must preserve the always-on physical-key ledger drain")
		helpers.assert_eq(false, ctx.keylogger.shutdown(),
			"terminal bridge stop refusal must remain visible and retryable")
		helpers.assert_eq(true, ctx.keylogger.shutdown())
		helpers.assert_eq(2, ctx.kc_stop_calls)
	end)
end)
