--- tests/unit/adapters/synthetic_input/test_paced_cadence.lua

--- ==============================================================================
--- MODULE: Synthetic Input paced cadence Tests
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
	helpers.it("serializes terminal deletion pairs after callback return with timed render turns", function()
		local fixture = make_fixture({ gc_cancels_unretained_timers = true })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local observed_tags = {}
		fixture.key_observer = function(event)
			local property = fixture.eventtap.event.properties.eventSourceUserData
			local metadata = synthetic.lookup_tag(event:getProperty(property))
			observed_tags[#observed_tags + 1] = string.format("%d:%s",
				metadata.ordinal, metadata.phase)
		end
		fixture.callback_active = true
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)

		local owner = synthetic.prepare_collected_paced(tx, 2, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_eq(fixture.key_posts, 0,
			"paced delivery must not post from the active eventtap callback")
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned,
			"target-posted events must not be returned to Quartz a second time")
		helpers.assert_eq(fixture.key_posts, 0)
		fixture.callback_active = false
		local paced_delays = 0
		local guard = 0
		while fixture.key_posts < 6 and #fixture.timers > 0 do
			collectgarbage("collect")
			local delay = fixture.fire_next_timer()
			if delay == 0.012 then paced_delays = paced_delays + 1 end
			guard = guard + 1
			helpers.assert_true(guard < 40, "paced serializer must terminate")
		end
		helpers.assert_eq(fixture.key_posts, 6)
		helpers.assert_eq(table.concat(observed_tags, ","),
			"1:down,1:up,2:down,2:up,3:down,3:up",
			"paced output must preserve the exact immutable tag order")
		helpers.assert_eq(paced_delays, 3,
			"both Backspace pairs and the contiguous replacement suffix need their own paced turn")
		helpers.assert_eq(#fixture.paced_sleeps, 0,
			"paced delivery must never block with hs.timer.usleep")
		for _, app in ipairs(fixture.posted_targets) do helpers.assert_true(app == target) end
	end)

	helpers.it("has one paced wake authority in both zero-before-periodic orders", function()
		for _, zero_first in ipairs({ true, false }) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			synthetic.enter_callback()
			local tx = synthetic.begin(
				zero_first and "unit.cadence.zero-first" or "unit.cadence.periodic-first",
				"replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local owner = synthetic.prepare_collected_paced(tx, 2, 20000,
				{ id = "terminal-app" })
			helpers.assert_not_nil(owner)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(owner))
			helpers.assert_true(synthetic.commit_collected_paced(owner))
			synthetic.leave_callback(true)

			local zero = nil
			local periodic = nil
			if zero_first then
				zero = fixture.fire_timer_matching(0)
				helpers.assert_eq(fixture.key_posts, 0,
					"a late zero wake must not post a pair before the cadence owner")
				periodic = fixture.fire_timer_matching(0.02)
			else
				periodic = fixture.fire_timer_matching(0.02)
				helpers.assert_eq(fixture.key_posts, 2,
					"one periodic turn posts exactly one delete pair")
				zero = fixture.fire_timer_matching(0)
				helpers.assert_eq(fixture.key_posts, 2,
					"a queued zero wake after a long callback may not collapse the next pair")
			end
			helpers.assert_not_nil(periodic,
				"the prepared 20 ms periodic cadence must be the sole output authority")
			helpers.assert_nil(zero,
				"paced preparation must not own a competing zero-delay wake")
			if zero_first then helpers.assert_eq(fixture.key_posts, 2) end
		end
	end)

	helpers.it("never lends a deferred tail broker turn to a paced FIFO head", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local paced_tx = synthetic.begin("unit.foreign-broker-paced", "replacement")
		synthetic.with_transaction(paced_tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local paced_owner = synthetic.prepare_collected_paced(paced_tx, 2, 20000,
			{ id = "terminal-app" })
		helpers.assert_not_nil(paced_owner)
		helpers.assert_true(synthetic.seal(paced_tx))
		helpers.assert_true(synthetic.authorize_collected_paced(paced_owner))
		helpers.assert_true(synthetic.commit_collected_paced(paced_owner))
		synthetic.leave_callback(true)

		local deferred_tx = synthetic.begin("unit.foreign-broker-tail", "replacement")
		local deferred_batch = synthetic.begin_batch(deferred_tx)
		synthetic.keyStroke(deferred_batch, {}, "q")
		helpers.assert_true(synthetic.dispatch(deferred_batch))
		helpers.assert_true(synthetic.seal(deferred_tx))

		helpers.assert_not_nil(fixture.fire_timer_matching(0),
			"the ordinary deferred tail must exercise its generic zero-delay broker")
		helpers.assert_eq(fixture.key_posts, 0,
			"a foreign broker turn must not post the paced head before its 20 ms owner")
		helpers.assert_not_nil(fixture.fire_timer_matching(0.02))
		helpers.assert_eq(fixture.key_posts, 2,
			"the paced owner must post exactly one complete delete pair on its own turn")
	end)

	helpers.it("fails an exact predecessor sibling when its broker timer is refused behind a reservation", function()
		local cases = {
			{ name = "false", option = "false_on_do_after_call" },
			{ name = "nil", option = "fail_on_do_after_call" },
			{ name = "throw", option = "throw_on_do_after_call" },
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			local predecessor = synthetic.begin(
				"unit.reserved-broker-refusal-" .. case.name, "replacement")
			local retain = synthetic.retain(predecessor)
			helpers.assert_true(synthetic.seal(predecessor))

			local reserved = synthetic.prepare_reserved_successor(predecessor, function()
				return synthetic.emit_key_stroke({}, "return", 0)
			end)
			helpers.assert_not_nil(reserved)
			helpers.assert_true(synthetic.authorize_reserved_successor(reserved))
			helpers.assert_true(synthetic.commit_reserved_successor(reserved))
			helpers.assert_true(reserved.ready ~= true,
				"the reserved FIFO head must remain a non-ready barrier")

			local sibling = synthetic.begin_batch(predecessor, retain)
			synthetic.keyStroke(sibling, {}, "x")
			local dispatched_status = nil
			synthetic.on_dispatched(predecessor, function(_, observed, status)
				if observed == sibling then dispatched_status = status end
			end)
			fixture.options[case.option] = fixture.do_after_calls + 1
			local call_ok, scheduled = pcall(synthetic.dispatch, sibling)
			helpers.assert_true(call_ok,
				case.name .. " broker refusal must be a reported result, not a throw")
			helpers.assert_eq(scheduled, false,
				case.name .. " broker refusal must reject the exact sibling dispatch")
			helpers.assert_eq(sibling.status, "failed",
				case.name .. " must terminally remove the refused predecessor sibling")
			helpers.assert_eq(synthetic.stats().pending_deferred, 1,
				case.name .. " must leave only the separately-owned reservation pending")
			helpers.assert_eq(fixture.trigger_posts, 0)
			helpers.assert_eq(fixture.key_posts, 0)

			helpers.assert_true(synthetic.cancel_reserved_successor(reserved))
			helpers.assert_true(synthetic.release(predecessor, retain))
			local guard = 0
			while #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case.name .. " broker refusal left immortal timer debt")
			end
			helpers.assert_eq(dispatched_status, "failed")
			helpers.assert_eq(synthetic.stats().pending, 0)
			helpers.assert_eq(synthetic.stats().active_transactions, 0)
			helpers.assert_eq(fixture.trigger_posts, 0,
				case.name .. " refused sibling must never revive from a later wake")
			helpers.assert_eq(fixture.key_posts, 0)
		end
	end)

	helpers.it("never lends a 5ms physical or reserved wake to a 20ms paced head", function()
		for _, kind in ipairs({ "physical", "reserved" }) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.cross-owner-" .. kind, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local paced = synthetic.prepare_collected_paced(tx, 1, 20000,
				{ id = "terminal-app" })
			helpers.assert_not_nil(paced)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(paced))
			helpers.assert_true(synthetic.commit_collected_paced(paced))
			synthetic.leave_callback(true)

			if kind == "physical" then
				local fence = synthetic.claim_physical_fence(fixture.external_event(nil, 42))
				helpers.assert_not_nil(fence)
				helpers.assert_true(fence.consume_original)
			else
				local reserved = synthetic.prepare_reserved_successor(tx, function()
					return synthetic.emit_key_stroke({}, "return", 0)
				end)
				helpers.assert_not_nil(reserved)
				helpers.assert_true(synthetic.authorize_reserved_successor(reserved))
				helpers.assert_true(synthetic.commit_reserved_successor(reserved))
				helpers.assert_true(synthetic.activate_reserved_successor(reserved))
			end

			helpers.assert_not_nil(
				fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC))
			helpers.assert_eq(fixture.key_posts, 0,
				kind .. " wake must not start the foreign paced ordinal 15ms early")
			helpers.assert_not_nil(fixture.fire_timer_matching(0.02))
			helpers.assert_eq(fixture.key_posts, 2,
				"the paced head begins only from its own 20ms authority")
		end
	end)

	helpers.it("retains paced timer cleanup debt until the exact stop retry succeeds", function()
		local cases = {
			{ name = "false", option = "timer_stop_failures_by_call" },
			{ name = "nil", option = "timer_stop_nils_by_call" },
			{ name = "throw", option = "timer_stop_throws_by_call" },
		}
		for _, case in ipairs(cases) do
			local options = { [case.option] = { [1] = 1 } }
			local fixture = make_fixture(options)
			local synthetic = fixture.load()
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.paced-stop-debt-" .. case.name, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local owner = synthetic.prepare_collected_paced(tx, 1, 20000,
				{ id = "terminal-app" })
			helpers.assert_not_nil(owner)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(owner))
			helpers.assert_true(synthetic.commit_collected_paced(owner))
			synthetic.leave_callback(true)
			local drained = 0
			helpers.assert_true(synthetic.when_idle(function() drained = drained + 1 end))
			local timer_new_before = fixture.timer_new_calls

			local periodic = fixture.fire_timer_matching(0.02)
			helpers.assert_eq(fixture.key_posts, 2)
			fixture.fire_timer_matching(0.02)
			helpers.assert_eq(fixture.key_posts, 4)
			fixture.fire_timer_matching(0.02)
			helpers.assert_eq(periodic.stop_calls, 1)
			helpers.assert_true(not periodic.stopped)
			helpers.assert_eq(drained, 0,
				case.name .. " completion may not hide an unstopped periodic handle")
			helpers.assert_eq(fixture.timer_new_calls, timer_new_before,
				case.name .. " cancel refusal must retain the exact construction")

			local retried = fixture.fire_timer_matching(0.02)
			helpers.assert_true(retried == periodic,
				case.name .. " callback reentry must target the retained native timer")
			helpers.assert_true(retried.handle == periodic.handle)
			helpers.assert_eq(periodic.stop_calls, 2)
			helpers.assert_true(periodic.stopped)
			helpers.assert_eq(fixture.timer_new_calls, timer_new_before)
			helpers.assert_eq(fixture.raw_do_every_calls, 0)
			local guard = 0
			while drained == 0 and #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case.name .. " paced cleanup debt stranded global idle")
			end
			helpers.assert_eq(drained, 1)
		end
	end)

	helpers.it("retries the exact terminal ordinal after a refused paced post", function()
		local fixture = make_fixture({ key_post_throw_at = 3 })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local completion
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.retry", "replacement")
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 2, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		fixture.fire_next_timer() -- timer-zero wake: first pair succeeds
		helpers.assert_eq(#fixture.key_attempts, 2)
		fixture.fire_next_timer() -- next paced turn: ordinal three is refused
		helpers.assert_eq(#fixture.key_attempts, 3,
			"a refused post must end the current render turn without bursting its retry")
		fixture.fire_next_timer() -- a later paced turn retries the exact event
		helpers.assert_eq(#fixture.key_attempts, 5,
			"the retry may finish only its original delete pair on the next turn")
		local guard = 0
		while (#fixture.timers > 0 or completion == nil) and guard < 60 do
			if #fixture.timers > 0 then fixture.fire_next_timer() end
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 6,
			"all six unique events must eventually post exactly once")
		helpers.assert_eq(#fixture.key_attempts, 7,
			"one refused ordinal must add exactly one retry attempt")
		helpers.assert_true(fixture.key_attempts[3] == fixture.key_attempts[4],
			"retry must retain the exact event object and ordinal")
		helpers.assert_eq(completion, "complete")
	end)
end)
