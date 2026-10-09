--- tests/unit/adapters/synthetic_input/test_idle_admission.lua

--- ==============================================================================
--- MODULE: Synthetic Input idle admission Tests
--- DESCRIPTION:
--- Preserves the native behavioral scenarios from the original provenance suite.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")
local make_fixture = Fixture.make
local USER_DATA = Fixture.USER_DATA
local SOURCE_PID = Fixture.SOURCE_PID
local MOUSE_BUTTON = Fixture.MOUSE_BUTTON
local KEY_DOWN = Fixture.KEY_DOWN
local KEY_UP = Fixture.KEY_UP
local FLAGS_CHANGED = Fixture.FLAGS_CHANGED
local LEFT_MOUSE_DOWN = Fixture.LEFT_MOUSE_DOWN
local LEFT_MOUSE_UP = Fixture.LEFT_MOUSE_UP
local RIGHT_MOUSE_DOWN = Fixture.RIGHT_MOUSE_DOWN
local RIGHT_MOUSE_UP = Fixture.RIGHT_MOUSE_UP
local MOUSE_MOVED = Fixture.MOUSE_MOVED
local LEFT_MOUSE_DRAGGED = Fixture.LEFT_MOUSE_DRAGGED
local OTHER_MOUSE_UP = Fixture.OTHER_MOUSE_UP
local RIGHT_MOUSE_DRAGGED = Fixture.RIGHT_MOUSE_DRAGGED
local OTHER_MOUSE_DRAGGED = Fixture.OTHER_MOUSE_DRAGGED
local CURRENT_PID = Fixture.CURRENT_PID

helpers.describe("synthetic input: ambient transactions and loopback", function()
	helpers.it("revalidates idle state when the deferred callback actually executes", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local idle_calls = 0
		local active_seen
		local tx1 = synthetic.begin("unit.idle-first", "action")
		local batch1 = synthetic.begin_callback(tx1)
		synthetic.keyStroke(batch1, {}, "x")
		synthetic.when_idle(function()
			idle_calls = idle_calls + 1
			active_seen = synthetic.stats().active_transactions
		end)
		synthetic.finish_callback(batch1, true)
		synthetic.seal(tx1)

		fixture.fire_next_timer() -- confirms tx1 and queues the idle lifecycle call
		local tx2 = synthetic.begin("unit.idle-racer", "replacement")
		fixture.fire_next_timer() -- stale idle observation executes while tx2 is active
		helpers.assert_eq(idle_calls, 0,
			"an idle callback must not fire after a newer transaction has started")
		helpers.assert_eq(synthetic.stats().active_transactions, 1)

		synthetic.seal(tx2)
		fixture.fire_next_timer()
		helpers.assert_eq(idle_calls, 1)
		helpers.assert_eq(active_seen, 0,
			"the callback must observe the execution-time idle state")

		local immediate_calls = 0
		synthetic.when_idle(function() immediate_calls = immediate_calls + 1 end)
		local tx3 = synthetic.begin("unit.idle-immediate-racer", "replacement")
		fixture.fire_next_timer()
		helpers.assert_eq(immediate_calls, 0,
			"the already-idle fast path needs the same execution-time fence")
		synthetic.seal(tx3)
		fixture.fire_next_timer()
		helpers.assert_eq(immediate_calls, 1)
	end)

	helpers.it("gives an accepted active idle waiter an autonomous wake", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.autonomous-idle-waiter", "replacement")
		local token = synthetic.retain(tx)
		helpers.assert_true(synthetic.seal(tx))
		local calls = 0
		helpers.assert_true(synthetic.when_idle(function() calls = calls + 1 end),
			"acceptance must mean an independently owned terminal path exists")

		fixture.options.delayed_start_failures = 2
		fixture.fail_next_do_after = true
		helpers.assert_true(synthetic.release(tx, token))
		helpers.assert_eq(calls, 0,
			"the caller stack may not become a lifecycle dispatcher")
		local guard = 0
		while calls == 0 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 20, "owned idle waiter did not settle")
		end
		helpers.assert_eq(calls, 1,
			"all one-shot dispatch refusals must not strand an accepted drain")
	end)

	helpers.it("keeps an accepted stale idle callback owned across false nil and throw rearm traps", function()
		for _, case in ipairs({ "false", "nil", "throw" }) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			local calls = 0
			helpers.assert_true(synthetic.when_idle(function() calls = calls + 1 end))
			helpers.assert_eq(fixture.timer_new_calls, 1,
				"initial acceptance must acquire exactly one autonomous periodic owner")

			-- Production now owns the autonomous waiter before accepting. The old
			-- implementation first accepted only a lifecycle entry, then attempted a
			-- fresh periodic acquisition from its stale recheck and discarded false.
			local refused_call = fixture.timer_new_calls + 1
			if case == "false" then
				fixture.options.false_on_timer_new_call = refused_call
			elseif case == "nil" then
				fixture.options.fail_on_timer_new_call = refused_call
			else
				fixture.options.throw_on_timer_new_call = refused_call
			end
			local racer = synthetic.begin("unit.idle-recheck-" .. case, "replacement")
			fixture.fire_timer_matching(0)
			helpers.assert_eq(calls, 0,
				"the accepted callback must revalidate rather than cross an active tx")
			helpers.assert_true(synthetic.seal(racer))
			local guard = 0
			while calls == 0 and #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20, case .. " stranded an accepted idle owner")
			end
			helpers.assert_eq(calls, 1,
				case .. " may not lose a callback whose initial acceptance was true")
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case .. " stale recheck must reuse its initial owner, never hit a rearm trap")
		end
	end)

	helpers.it("removes a refused idle FIFO entry before any unrelated enqueue", function()
		for _, case in ipairs({ "false", "nil", "throw" }) do
			local options = { delayed_start_failures = 2 }
			options[case == "false" and "false_on_timer_new_call"
				or (case == "nil" and "fail_on_timer_new_call"
					or "throw_on_timer_new_call")] = 1
			local fixture = make_fixture(options)
			fixture.fail_next_do_after = true
			local synthetic = fixture.load()
			local stale_calls = 0
			helpers.assert_true(synthetic.when_idle(function()
				stale_calls = stale_calls + 1
			end) ~= true, case .. " acquisition refusal must reject the idle request")
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case .. " must exercise exactly one initial periodic acquisition")

			fixture.options.delayed_start_failures = 0
			fixture.options.false_on_timer_new_call = nil
			fixture.options.fail_on_timer_new_call = nil
			fixture.options.throw_on_timer_new_call = nil
			fixture.fail_next_do_after = false
			local unrelated_calls = 0
			helpers.assert_true(synthetic.defer_after_callback("unit unrelated enqueue", function()
				unrelated_calls = unrelated_calls + 1
			end))
			local guard = 0
			while #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case .. " unrelated lifecycle enqueue did not settle")
			end
			helpers.assert_eq(unrelated_calls, 1)
			helpers.assert_eq(stale_calls, 0,
				case .. " refused idle request must never revive from a later FIFO start")
		end
	end)

	helpers.it("keeps accepted post-eventtap work inside idle recheck and admission", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local idle_calls = 0
		local deferred_tx = nil
		local deferred_token = nil

		-- Queue the idle observation first, then accept user work behind it. The
		-- lifecycle FIFO will execute the stale idle recheck before that work, so
		-- only the accepted post-callback debt can prevent a false drain.
		helpers.assert_true(synthetic.when_idle(function() idle_calls = idle_calls + 1 end))
		helpers.assert_true(synthetic.defer_after_callback("unit accepted producer", function()
			deferred_tx = synthetic.begin("unit.accepted-post-callback", "replacement")
			deferred_token = synthetic.retain(deferred_tx)
			synthetic.seal(deferred_tx)
		end))
		helpers.assert_nil(synthetic.acquire_admission_fence("pause"),
			"accepted user work must close the same idle-to-PAUSED admission boundary")

		helpers.assert_not_nil(fixture.fire_timer_matching(0),
			"the accepted post-eventtap producer must run at its zero-delay deadline")
		helpers.assert_eq(idle_calls, 0,
			"a stale idle callback must requeue behind accepted post-eventtap work")
		helpers.assert_not_nil(deferred_tx)
		helpers.assert_eq(synthetic.stats().active_transactions, 1)
		helpers.assert_true(synthetic.release(deferred_tx, deferred_token))
		local guard = 0
		while idle_calls == 0 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 20, "accepted post-eventtap debt stranded idle")
		end
		helpers.assert_eq(idle_calls, 1)
	end)

	helpers.it("accepts idle ownership only after transactional construction and start", function()
		local cases = {
			{ name = "constructor false", options = { false_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor nil", options = { fail_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor throw", options = { throw_on_timer_new_call = 1 }, starts = 0 },
			{ name = "start false", options = { timer_start_mode = "false" }, starts = 1 },
			{ name = "start nil", options = { timer_start_mode = "nil" }, starts = 1 },
			{ name = "start throw", options = { timer_start_mode = "throw" }, starts = 1 },
			{ name = "start state mismatch", options = { timer_start_mode = "stopped" }, starts = 1 },
			{ name = "start callback reentry", options = { timer_start_inline = true }, starts = 1 },
			{
				name = "start callback rollback debt",
				options = {
					timer_start_inline = true,
					timer_stop_failures_by_call = { [1] = 1 },
				},
				starts = 1,
				cleanup = 1,
			},
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local tx = synthetic.begin("unit.idle-constructor-" .. case.name, "replacement")
			local token = synthetic.retain(tx)
			synthetic.seal(tx)
			local callback_calls = 0
			local call_ok, accepted = pcall(synthetic.when_idle, function()
				callback_calls = callback_calls + 1
			end)
			helpers.assert_true(call_ok,
				case.name .. " is a native refusal, not a Lua error boundary")
			helpers.assert_true(accepted ~= true,
				case.name .. " cannot authorize a drain with no autonomous owner")
			helpers.assert_eq(callback_calls, 0)
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " must construct at most one exact native candidate")
			helpers.assert_eq(fixture.timer_start_calls, case.starts,
				case.name .. " must not hide a successor start")
			helpers.assert_eq(fixture.raw_do_every_calls, 0,
				case.name .. " must stay behind TimerScheduler")
			local expected_cleanup = case.cleanup or 0
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, expected_cleanup,
				case.name .. " must publish exact rollback debt before refusing admission")
			if expected_cleanup > 0 then
				local periodic = fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC)
				helpers.assert_not_nil(periodic)
				helpers.assert_eq(periodic.stop_calls, 2,
					"queued reentry must retry the exact uncommitted candidate")
				helpers.assert_true(periodic.stopped)
				helpers.assert_eq(fixture.timer_new_calls, 1)
				helpers.assert_eq(callback_calls, 0)
				helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 0)
			end
			synthetic.release(tx, token)
		end
	end)

	helpers.it("settles an idle waiter only after its exact periodic handle stops", function()
		local cases = {
			{
				name = "false",
				options = { timer_stop_failures_by_call = { [1] = 1 } },
			},
			{
				name = "nil",
				options = { timer_stop_nils_by_call = { [1] = 1 } },
			},
			{
				name = "throw",
				options = { timer_stop_throws_by_call = { [1] = 1 } },
			},
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local tx = synthetic.begin("unit.idle-stop-debt-" .. case.name, "replacement")
			local token = synthetic.retain(tx)
			synthetic.seal(tx)
			local idle_calls = 0
			helpers.assert_true(synthetic.when_idle(function()
				idle_calls = idle_calls + 1
			end))
			helpers.assert_eq(fixture.timer_new_calls, 1)
			helpers.assert_eq(fixture.timer_start_calls, 1)
			helpers.assert_true(synthetic.release(tx, token))

			local periodic = fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC)
			helpers.assert_not_nil(periodic)
			helpers.assert_not_nil(periodic.handle)
			helpers.assert_eq(periodic.stop_calls, 1)
			helpers.assert_eq(idle_calls, 0,
				case.name .. " stop refusal must keep when_idle behind native cleanup")
			helpers.assert_true(not periodic.stopped,
				case.name .. " stop refusal must retain the recurring handle")
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 1,
				case.name .. " stop refusal must remain observable lifecycle debt")
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " cancel refusal must retain rather than reacquire")

			local retried = fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC)
			helpers.assert_true(retried == periodic,
				case.name .. " cleanup must retry the exact same native timer entry")
			helpers.assert_true(retried.handle == periodic.handle,
				case.name .. " cleanup must not substitute a new native handle")
			helpers.assert_eq(periodic.stop_calls, 2,
				case.name .. " retained handle must retry autonomously on its next tick")
			helpers.assert_true(periodic.stopped)
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " callback reentry must settle the original construction")
			helpers.assert_eq(fixture.timer_start_calls, 1)
			helpers.assert_eq(fixture.raw_do_every_calls, 0)
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 0)
			helpers.assert_eq(idle_calls, 1,
				case.name .. " accepted drain must settle once after exact stop")

			local guard = 0
			while #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case.name .. " stop settlement left a recurring wake")
			end
			helpers.assert_eq(idle_calls, 1,
				case.name .. " stale lifecycle wakes must not redeliver when_idle")
		end
	end)

	helpers.it("atomically fences new admission only at an exact idle boundary", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local active = synthetic.begin("unit.admission-active", "replacement")
		helpers.assert_nil(synthetic.acquire_admission_fence("pause"),
			"a fence may not falsely acknowledge idle while output is active")
		helpers.assert_true(synthetic.seal(active))

		local fence = synthetic.acquire_admission_fence("pause")
		helpers.assert_not_nil(fence)
		helpers.assert_true(not synthetic.admission_open())
		local admitted = pcall(synthetic.begin, "unit.admission-racer", "replacement")
		helpers.assert_true(not admitted,
			"no producer may enter between the idle observation and PAUSED acknowledgement")
		helpers.assert_true(not synthetic.release_admission_fence({}),
			"only the exact lifecycle owner can reopen admission")
		helpers.assert_true(synthetic.release_admission_fence(fence))
		helpers.assert_true(synthetic.admission_open())
		local resumed = synthetic.begin("unit.admission-resumed", "replacement")
		helpers.assert_true(synthetic.seal(resumed))
	end)
end)
