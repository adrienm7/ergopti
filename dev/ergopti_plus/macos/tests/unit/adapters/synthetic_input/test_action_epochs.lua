--- tests/unit/adapters/synthetic_input/test_action_epochs.lua

--- ==============================================================================
--- MODULE: Synthetic Input action epochs Tests
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
	helpers.it("advances one opaque epoch only at the first successful action handoff", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.epoch", "action")
		local first = synthetic.begin_callback(tx)
		synthetic.keyStroke(first, {}, "a")
		helpers.assert_true(synthetic.current_action_epoch() == initial,
			"build remains abortable and must not publish")
		synthetic.finish_callback(first, true)
		local handed_off = synthetic.current_action_epoch()
		helpers.assert_true(handed_off ~= initial)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		local token = synthetic.retain(tx)
		synthetic.seal(tx)
		local second = synthetic.begin_callback(tx, token)
		synthetic.keyStroke(second, {}, "b")
		synthetic.finish_callback(second, true)
		helpers.assert_true(synthetic.current_action_epoch() == handed_off,
			"a retained sibling batch is still the same logical action")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)
		synthetic.release(tx, token)
	end)

	helpers.it("notifies stable listeners asynchronously without vetoing handed-off output", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local calls, transient_calls = 0, 0
		local seen_token, seen_time
		synthetic.register_action_listener("broken", function()
			transient_calls = transient_calls + 1
			if transient_calls == 1 then error("listener boom") end
		end)
		synthetic.register_action_listener("keymap", function(token, handoff_time_ms)
			calls = calls + 1
			seen_token = token
			seen_time = handoff_time_ms
		end)

		local tx = synthetic.begin("unit.listener", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "a")
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(#events, 2,
			"listener failure cannot veto output after irrevocable handoff")
		helpers.assert_eq(calls, 0,
			"listeners must never run inside the originating eventtap callback")
		local epoch, handoff_time = synthetic.current_action_epoch()
		helpers.assert_true(epoch ~= nil)
		helpers.assert_eq(type(handoff_time), "number")
		collectgarbage("collect")
		fixture.fire_next_timer()
		helpers.assert_eq(calls, 1,
			"listener reconciles even when no synthetic echo or later human key arrives")
		helpers.assert_true(seen_token == epoch)
		helpers.assert_eq(seen_time, handoff_time)
		while #fixture.timers > 0 and transient_calls < 2 do fixture.fire_next_timer() end
		helpers.assert_eq(transient_calls, 2,
			"a transient listener failure must be retried without another user event")
	end)

	helpers.it("reconciles an action handed off while a consumer was unregistered", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local last_safe_epoch = synthetic.current_action_epoch()

		local tx = synthetic.begin("unit.stopped-consumer", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(#events, 2)
		synthetic.seal(tx)
		local live_epoch = synthetic.current_action_epoch()
		helpers.assert_true(live_epoch ~= last_safe_epoch)

		local calls, observed = 0, nil
		synthetic.register_action_listener("restarted", function(epoch)
			calls = calls + 1
			observed = epoch
		end, last_safe_epoch)
		local fired = 0
		while calls == 0 and #fixture.timers > 0 and fired < 10 do
			fixture.fire_next_timer()
			fired = fired + 1
		end

		helpers.assert_eq(calls, 1,
			"registration with an older safe token must schedule reconciliation")
		helpers.assert_true(observed == live_epoch)
	end)

	helpers.it("bounds retries for a permanently failing listener", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local attempts = 0
		synthetic.register_action_listener("permanent", function()
			attempts = attempts + 1
			error("deterministic listener failure")
		end)

		local tx = synthetic.begin("unit.listener-quarantine", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.finish_callback(batch, true)
		synthetic.seal(tx)

		local fired = 0
		while #fixture.timers > 0 and fired < 100 do
			fixture.fire_next_timer()
			fired = fired + 1
		end
		helpers.assert_eq(attempts, synthetic.ACTION_LISTENER_MAX_ATTEMPTS,
			"a deterministic consumer error must be quarantined for this epoch")
		helpers.assert_true(fired < 100,
			"the listener dispatcher must not spin forever at a fixed cadence")
		helpers.assert_eq(#fixture.timers, 0)
	end)

	helpers.it("bounds retries for a persistent dispatcher-internal failure", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.register_action_listener("keymap", function() end)
		local tx = synthetic.begin("unit.dispatcher-internal-failure", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.finish_callback(batch, true)
		synthetic.seal(tx)

		local original_sort = table.sort
		table.sort = function() error("dispatcher bookkeeping unavailable") end
		local ok, err = xpcall(function()
			local fired = 0
			while #fixture.timers > 0 and fired < 100 do
				fixture.fire_next_timer()
				fired = fired + 1
			end
			helpers.assert_true(fired < 100,
				"an adapter-internal error must not create an immortal retry timer")
			helpers.assert_eq(#fixture.timers, 0)
		end, debug.traceback)
		table.sort = original_sort
		if not ok then error(err, 0) end
	end)

	helpers.it("retries a one-shot listener timer failure from confirmation without a later key", function()
		local fixture = make_fixture({ do_after_failures = 1 })
		local synthetic = fixture.load()
		local calls = 0
		synthetic.register_action_listener("keymap", function() calls = calls + 1 end)
		local tx = synthetic.begin("unit.listener-retry", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(#events, 2)
		helpers.assert_eq(calls, 0)
		fixture.fire_next_timer() -- independent confirmation timer performs retry
		helpers.assert_eq(calls, 1,
			"one timer allocation failure must not leave the tooltip stale forever")
	end)

	helpers.it("does not advance epoch for aborted, cancelled, failed, empty, or replacement output", function()
		local fixture = make_fixture({ tap_should_enable = false })
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()

		synthetic.enter_callback()
		local aborted = synthetic.begin("unit.abort", "action")
		synthetic.with_transaction(aborted, function()
			synthetic.emit_key_stroke({}, "a", 0)
		end)
		synthetic.abort_callback()
		helpers.assert_true(synthetic.current_action_epoch() == initial)

		local cancelled = synthetic.begin("unit.cancel", "action")
		local cancelled_batch = synthetic.begin_callback(cancelled)
		synthetic.keyStroke(cancelled_batch, {}, "b")
		synthetic.cancel(cancelled)
		helpers.assert_true(synthetic.current_action_epoch() == initial)

		local failed = synthetic.begin("unit.failed", "action")
		local failed_batch = synthetic.begin_batch(failed)
		synthetic.keyStroke(failed_batch, {}, "c")
		synthetic.dispatch(failed_batch)
		synthetic.seal(failed)
		fixture.fire_next_timer()
		helpers.assert_true(synthetic.current_action_epoch() == initial,
			"pump creation failure is not an output handoff")

		local empty = synthetic.begin("unit.empty", "action")
		local empty_batch = synthetic.begin_callback(empty)
		local _, empty_events = synthetic.finish_callback(empty_batch, false)
		helpers.assert_nil(empty_events)
		helpers.assert_true(synthetic.current_action_epoch() == initial)

		local replacement = synthetic.begin("unit.replacement", "replacement")
		local replacement_batch = synthetic.begin_callback(replacement)
		synthetic.keyStroke(replacement_batch, {}, "d")
		synthetic.finish_callback(replacement_batch, true)
		helpers.assert_true(synthetic.current_action_epoch() == initial)
	end)

	helpers.it("rolls observable-action metadata back with malformed UTF-8", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.malformed-action", "action")
		local batch = synthetic.begin_callback(tx)
		local ok = synthetic.keyStrokes(batch, "a\255")
		helpers.assert_true(not ok)
		helpers.assert_eq(#batch.events, 0)
		local consume, events = synthetic.finish_callback(batch, false)
		helpers.assert_true(not consume)
		helpers.assert_nil(events)
		helpers.assert_true(synthetic.current_action_epoch() == initial,
			"a rolled-back prefix must not leave an observable-action marker")
	end)

	helpers.it("cancels explicit siblings atomically when any high-level emitter fails", function()
		local cases = {
			{
				name = "single-key argument error",
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_key_stroke({}, "y", 1, tx)
				end,
			},
			{
				name = "single-key constructor error",
				options = { new_key_event_throw_at = 3 },
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_key_stroke({}, "y", 0, tx)
				end,
			},
			{
				name = "text argument error",
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_key_strokes({}, tx)
				end,
			},
			{
				name = "malformed UTF-8 text",
				invoke = function(synthetic, tx)
					return synthetic.emit_key_strokes("a\255", tx)
				end,
			},
			{
				name = "loopback transaction effect error",
				effect = "replacement",
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_loopback_key_stroke({}, "f16", 0, tx)
				end,
			},
			{
				name = "loopback constructor error",
				options = { new_key_event_throw_at = 3 },
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_loopback_key_stroke({}, "f16", 0, tx)
				end,
			},
			{
				name = "loopback timer allocation failure",
				options = { fail_on_do_after_call = 2 },
				invoke = function(synthetic, tx)
					return synthetic.emit_loopback_key_stroke({}, "f16", 0, tx)
				end,
			},
		}

		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local tx = synthetic.begin("unit.atomic-emitter-" .. case.name,
				case.effect or "action")
			local sibling = synthetic.begin_batch(tx)
			synthetic.keyStroke(sibling, {}, "x")
			local completion
			synthetic.on_complete(tx, function(_, status) completion = status end)
			helpers.assert_true(synthetic.dispatch(sibling))

			local ok, result = pcall(case.invoke, synthetic, tx)
			if case.throws then
				helpers.assert_true(not ok, case.name .. " must propagate its root error")
			else
				helpers.assert_true(ok, case.name .. " must report failure without throwing")
				helpers.assert_eq(result, false)
			end
			helpers.assert_true(tx.cancelled, case.name .. " must cancel the explicit transaction")
			helpers.assert_true(tx.completed, case.name .. " must leave no live transaction")
			helpers.assert_eq(tx.completion_status, "cancelled")
			helpers.assert_eq(sibling.status, "cancelled",
				case.name .. " must cancel an older queued sibling")
			helpers.assert_eq(synthetic.stats().pending, 0)
			helpers.assert_eq(synthetic.stats().records, 0)
			helpers.assert_eq(synthetic.stats().active_transactions, 0)

			while #fixture.timers > 0 do fixture.fire_next_timer() end
			helpers.assert_eq(completion, "cancelled")
			helpers.assert_eq(fixture.trigger_posts, 0)
			helpers.assert_eq(fixture.key_posts, 0)
		end
	end)

	helpers.it("advances once for an action larger than the enrichment ledger", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local initial = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.large-action", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "a")
		local evicted = batch.events[1]
		for _ = 2, 2050 do synthetic.keyStroke(batch, {}, "a") end
		synthetic.finish_callback(batch, true)
		helpers.assert_true(synthetic.current_action_epoch() ~= initial)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)
		local stale = provenance.classify(evicted, "unregistered-consumer")
		helpers.assert_true(stale.owned)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1,
			"current-session ledger eviction must not republish one action per old phase")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)
	end)

	helpers.it("validates direct and ambient handoff atomically before epoch publication", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()

		local direct_tx = synthetic.begin("unit.invalid-direct", "action")
		local direct_batch = synthetic.begin_callback(direct_tx)
		synthetic.keyStroke(direct_batch, {}, "a")
		helpers.assert_throws(function()
			synthetic.finish_callback(direct_batch, "not-a-boolean")
		end)
		helpers.assert_eq(direct_batch.status, "building")
		helpers.assert_true(synthetic.current_action_epoch() == initial)
		synthetic.cancel(direct_tx)

		local collector = synthetic.enter_callback()
		local first_tx = synthetic.begin("unit.atomic-first", "action")
		synthetic.with_transaction(first_tx, function()
			synthetic.emit_key_stroke({}, "b", 0)
		end)
		local second_tx = synthetic.begin("unit.atomic-second", "action")
		synthetic.with_transaction(second_tx, function()
			synthetic.emit_key_stroke({}, "c", 0)
		end)
		collector.batches[2].status = "queued" -- invalid for a callback collector
		helpers.assert_throws(function() synthetic.leave_callback(true) end)
		helpers.assert_eq(collector.batches[1].status, "building",
			"validation of a later batch must not hand off an earlier prefix")
		helpers.assert_true(synthetic.current_action_epoch() == initial)
		helpers.assert_true(synthetic.abort_callback(),
			"failed validation must leave the collector available for rollback")
		helpers.assert_eq(synthetic.stats().records, 0)
	end)

	helpers.it("hands off ambient output when the diagnostic clock throws", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.clock-failure", "action")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "x", 0)
		end)
		fixture.absolute_time_throws = true
		local ok, consume, events = pcall(synthetic.leave_callback, true)
		helpers.assert_true(ok,
			"diagnostic timestamp failure must not strand a popped collector")
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 2)
		local epoch, handoff_time = synthetic.current_action_epoch()
		helpers.assert_true(epoch ~= initial)
		helpers.assert_nil(handoff_time)
	end)

	helpers.it("returns direct and ambient events when confirmation scheduling fails", function()
		local direct_fixture = make_fixture({ do_after_failures = 1 })
		local direct = direct_fixture.load()
		local direct_tx = direct.begin("unit.direct-confirm-fail", "action")
		local direct_batch = direct.begin_callback(direct_tx)
		direct.keyStroke(direct_batch, {}, "x")
		local consume, events = direct.finish_callback(direct_batch, true)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 2)
		direct.seal(direct_tx)
		helpers.assert_eq(direct_tx.completion_status, "failed")

		local ambient_fixture = make_fixture({ do_after_failures = 1 })
		local ambient = ambient_fixture.load()
		ambient.enter_callback()
		ambient.emit_key_stroke({}, "y", 0)
		local left_ok, ambient_consume, ambient_events = pcall(ambient.leave_callback, true)
		helpers.assert_true(left_ok)
		helpers.assert_true(ambient_consume)
		helpers.assert_eq(#ambient_events, 2)
		helpers.assert_true(not ambient.abort_callback(),
			"successful leave must remove the collector even on timer failure")
	end)

	helpers.it("keeps adopted output and defers terminal lifecycle on confirmation failure", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.adopt-confirm-fail", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local completion
		synthetic.on_complete(tx, function(_, status) completion = status end)
		helpers.assert_true(synthetic.dispatch(batch))
		synthetic.seal(tx)

		fixture.fail_next_do_after = true
		local fence = synthetic.claim_physical_fence()
		helpers.assert_not_nil(fence)
		helpers.assert_eq(#fence.events, 2,
			"irrevocably queued output must still be returned before physical input")
		helpers.assert_nil(completion,
			"failure lifecycle must not run inside the physical event callback")
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(completion, "failed")
	end)

	helpers.it("preserves ambient scope, timer retain, delay compatibility, and cancellation", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.ambient", "action")
		synthetic.with_transaction(tx, function()
			helpers.assert_true(synthetic.current_transaction() == tx)
			synthetic.emit_key_stroke({}, "x", 0.02)
			synthetic.emit_key_strokes("y")
		end)
		helpers.assert_nil(synthetic.current_transaction())
		synthetic.seal(tx)
		local consume, events = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(fixture.post_count, 0)
		fixture.fire_next_timer()

		local retained = synthetic.begin("unit.retained", "action")
		local token = synthetic.retain(retained)
		synthetic.seal(retained)
		synthetic.with_transaction(retained, function()
			synthetic.emit_key_stroke({}, "z", 0)
		end)
		helpers.assert_true(synthetic.release(retained, token))
		helpers.assert_true(not synthetic.release(retained, token),
			"release must be idempotent")
		fixture.fire_next_timer()
		fixture.fire_next_timer()

		synthetic.enter_callback()
		local cancelled = synthetic.begin("unit.cancelled", "action")
		synthetic.with_transaction(cancelled, function()
			synthetic.emit_key_stroke({}, "q", 0)
		end)
		synthetic.cancel(cancelled)
		local _, cancelled_events = synthetic.leave_callback(false)
		helpers.assert_nil(cancelled_events,
			"cancelled ambient events must not survive into the callback return")

		local timers_before = #fixture.timers
		helpers.assert_true(synthetic.emit_key_strokes(""))
		helpers.assert_eq(#fixture.timers, timers_before,
			"empty ambient/deferred emissions are true no-ops")
		helpers.assert_throws(function()
			synthetic.emit_key_stroke({}, "x", 1)
		end, "delay >= 1 microsecond must fail fast")
	end)
end)
