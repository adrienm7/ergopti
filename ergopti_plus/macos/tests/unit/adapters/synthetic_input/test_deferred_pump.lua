--- tests/unit/adapters/synthetic_input/test_deferred_pump.lua

--- ==============================================================================
--- MODULE: Synthetic Input deferred pump Tests
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

helpers.describe("synthetic input: callback and deferred dispatch", function()
	helpers.it("starts the pump lazily and hands one unposted payload batch back", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local epoch_before = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.deferred", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, { "cmd" }, "v")
		local completed = false
		synthetic.on_complete(tx, function(_, status) completed = status == "complete" end)
		helpers.assert_true(synthetic.dispatch(batch))
		synthetic.seal(tx)
		helpers.assert_eq(#fixture.taps, 0)
		helpers.assert_eq(fixture.post_count, 0)
		helpers.assert_eq(#fixture.timers, 1,
			"dispatch itself may only enqueue timer-zero work")

		helpers.assert_eq(fixture.fire_next_timer(), 0)
		helpers.assert_eq(#fixture.taps, 1)
		helpers.assert_eq(fixture.taps[1].types[1], OTHER_MOUSE_UP)
		helpers.assert_eq(fixture.trigger_posts, 1)
		helpers.assert_eq(fixture.last_trigger.position.x, 321)
		helpers.assert_eq(fixture.last_trigger.position.y, 654)
		helpers.assert_eq(fixture.last_trigger:getProperty(MOUSE_BUTTON),
			synthetic.PUMP_MOUSE_BUTTON)
		helpers.assert_true(fixture.last_trigger:getProperty(USER_DATA) ~= 0)
		helpers.assert_eq(fixture.key_posts, 0,
			"payload events must be callback-returned, never individually posted")
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2)
		helpers.assert_true(synthetic.current_action_epoch() ~= epoch_before)
		local echo = provenance.classify(fixture.pump_deliveries[1].events[1], "keymap")
		helpers.assert_true(echo.owned)
		helpers.assert_true(not completed)
		fixture.fire_next_timer() -- post-return confirmation
		helpers.assert_true(not completed)
		fixture.fire_next_timer() -- retained lifecycle dispatcher
		helpers.assert_true(completed)
	end)

	helpers.it("recreates a pump disabled between two batches", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local function send_one(owner)
			local tx = synthetic.begin(owner, "action")
			local batch = synthetic.begin_batch(tx)
			synthetic.keyStroke(batch, {}, "x")
			synthetic.dispatch(batch)
			synthetic.seal(tx)
			fixture.fire_next_timer()
			fixture.fire_next_timer()
		end
		send_one("unit.first")
		helpers.assert_eq(#fixture.taps, 1)
		local old_tap = fixture.active_tap
		old_tap.enabled = false
		send_one("unit.second")
		helpers.assert_eq(#fixture.taps, 2)
		helpers.assert_true(old_tap.stop_count > 0)
	end)

	helpers.it("settles an activated start failure before publishing a successor pump", function()
		local fixture = make_fixture({
			tap_start_modes_by_call = { [1] = "throw" },
			tap_stop_throws_by_call = { [1] = 2 },
		})
		local synthetic = fixture.load()

		local function send_one(owner)
			local tx = synthetic.begin(owner, "action")
			local batch = synthetic.begin_batch(tx)
			synthetic.keyStroke(batch, {}, "x")
			local status = nil
			synthetic.on_complete(tx, function(_, value) status = value end)
			synthetic.dispatch(batch)
			synthetic.seal(tx)
			local guard = 0
			while status == nil and #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20, "synthetic batch did not settle")
			end
			return status
		end

		helpers.assert_eq(send_one("unit.start-throw"), "failed")
		local failed_candidate = fixture.taps[1]
		helpers.assert_true(failed_candidate.enabled,
			"the fixture must model a start that activated before cleanup was refused")
		helpers.assert_eq(send_one("unit.start-retry"), "complete")
		helpers.assert_true(not failed_candidate.enabled,
			"the exact failed candidate must settle before a successor is published")
		local enabled_count = 0
		for _, tap in ipairs(fixture.taps) do
			if tap.enabled then enabled_count = enabled_count + 1 end
		end
		helpers.assert_eq(enabled_count, 1,
			"a retry must never leave two native pump taps active")
	end)

	helpers.it("delivers with the runtime-faithful event-type surface", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		helpers.assert_nil(fixture.eventtap.event.types.tapDisabledByTimeout,
			"the pump fixture must not manufacture a native-only callback event")
		helpers.assert_nil(fixture.eventtap.event.types.tapDisabledByUserInput)

		local tx = synthetic.begin("unit.native-contract", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()

		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2,
			"ordinary tagged payload delivery must not depend on an unreachable disable branch")
	end)

	helpers.it("serializes deferred batches through one FIFO timer under reverse scheduling", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local function enqueue(owner, key)
			local tx = synthetic.begin(owner, "action")
			local batch = synthetic.begin_batch(tx)
			synthetic.keyStroke(batch, {}, key)
			synthetic.dispatch(batch)
			synthetic.seal(tx)
		end
		enqueue("unit.fifo-a", "a")
		enqueue("unit.fifo-b", "b")
		helpers.assert_eq(#fixture.timers, 1,
			"N queued batches must have only one broker timer in flight")

		-- A scheduler that chooses the newest equal-deadline timer cannot reverse
		-- output because the broker never exposes two trigger timers at once.
		fixture.fire_last_timer()
		helpers.assert_eq(fixture.pump_deliveries[1].events[1].key, "a")
		helpers.assert_eq(#fixture.timers, 1,
			"only A's post-return confirmation may exist before B is eligible")
		fixture.fire_last_timer() -- confirms A and schedules B's sole broker timer
		helpers.assert_eq(#fixture.timers, 1)
		fixture.fire_last_timer()
		helpers.assert_eq(fixture.pump_deliveries[2].events[1].key, "b")
	end)

	helpers.it("prepends older deferred output to a later callback handoff", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()

		local older_tx = synthetic.begin("unit.mixed-a", "action")
		local older_batch = synthetic.begin_batch(older_tx)
		synthetic.keyStroke(older_batch, {}, "a")
		synthetic.dispatch(older_batch)
		synthetic.seal(older_tx)
		helpers.assert_eq(#fixture.timers, 1,
			"the older deferred action is waiting for its broker turn")

		synthetic.enter_callback()
		local newer_tx = synthetic.begin("unit.mixed-b", "action")
		synthetic.with_transaction(newer_tx, function()
			synthetic.emit_key_stroke({}, "b", 0)
		end)
		synthetic.seal(newer_tx)
		local consume, events = synthetic.leave_callback(true)

		helpers.assert_true(consume)
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(events[1].key, "a",
			"an earlier deferred action must not be overtaken by callback output")
		helpers.assert_eq(events[3].key, "b")
		helpers.assert_eq(synthetic.stats().pending, 0)
		helpers.assert_eq(#fixture.pump_deliveries, 0,
			"adoption must return one ordered batch, not also pump the older payload")
	end)

	helpers.it("hands older deferred output off before an ordinary physical event", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local initial_epoch = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.physical-fence", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "a")
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		local fence = synthetic.claim_physical_fence()
		helpers.assert_not_nil(fence)
		helpers.assert_eq(#fence.events, 2)
		helpers.assert_eq(fence.events[1].key, "a",
			"Hammerspoon posts the returned table before propagating the original event")
		helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch,
			"the first tap must reconcile consumers before mutating the physical event")
		helpers.assert_eq(synthetic.stats().pending, 0)
		helpers.assert_nil(synthetic.claim_physical_fence(),
			"a downstream tap must not claim the same deferred action twice")
	end)

	helpers.it("keeps action and physical state ordered in both head-insert tap orders", function()
		local function exercise(order_names)
			local fixture = make_fixture({ deliver_trigger = false })
			local synthetic, provenance = fixture.load()
			local initial_epoch = synthetic.current_action_epoch()
			local tx = synthetic.begin("unit.tap-chain", "action")
			local batch = synthetic.begin_batch(tx)
			synthetic.keyStroke(batch, {}, "a")
			synthetic.dispatch(batch)
			synthetic.seal(tx)

			local state = {
				keymap = { epoch = initial_epoch, buffer = { "pre" } },
				keylogger = { epoch = initial_epoch, buffer = { "pre" }, snapshots = {} },
			}
			local function reconcile(name)
				local epoch = synthetic.current_action_epoch()
				local consumer = state[name]
				if epoch == consumer.epoch then return end
				if name == "keylogger" then
					consumer.snapshots[#consumer.snapshots + 1] = table.concat(consumer.buffer)
				end
				consumer.buffer = {}
				consumer.epoch = epoch
			end
			local callbacks = {}
			for _, name in ipairs({ "keymap", "keylogger" }) do
				callbacks[name] = function(event)
					local owned = provenance.classify(event, name)
					local fence = nil
					if not owned then fence = synthetic.claim_physical_fence() end
					reconcile(name)
					if not owned and event.isDown then
						state[name].buffer[#state[name].buffer + 1] = event.key
					end
					return false, fence and fence.events or nil
				end
			end

			local app_keys = {}
			local function deliver(index, event)
				if index > #order_names then
					if event.isDown then app_keys[#app_keys + 1] = event.key end
					return
				end
				local consume, returned = callbacks[order_names[index]](event)
				-- Mirrors libeventtap.m: returned events enter only downstream taps
				-- before the physical original continues through that same proxy.
				for _, returned_event in ipairs(returned or {}) do
					deliver(index + 1, returned_event)
				end
				if not consume then deliver(index + 1, event) end
			end

			deliver(1, fixture.external_event(nil, CURRENT_PID))
			helpers.assert_eq(table.concat(app_keys, ","), "a,x")
			helpers.assert_eq(state.keylogger.snapshots[1], "pre",
				"the overtaking physical key belongs to the post-action run")
			helpers.assert_eq(table.concat(state.keylogger.buffer), "x")
			helpers.assert_eq(table.concat(state.keymap.buffer), "x")
			helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch)
			helpers.assert_eq(synthetic.stats().pending, 0)
		end

		exercise({ "keylogger", "keymap" })
		exercise({ "keymap", "keylogger" })
	end)

	helpers.it("strongly retains broker, listener, and confirmation timers across GC", function()
		local fixture = make_fixture({ gc_cancels_unretained_timers = true })
		local synthetic = fixture.load()
		local listener_calls, status = 0, nil
		synthetic.register_action_listener("unit", function()
			listener_calls = listener_calls + 1
		end)
		local tx = synthetic.begin("unit.gc", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		collectgarbage("collect")
		fixture.fire_next_timer() -- retained broker hands off payload
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		collectgarbage("collect")
		fixture.fire_next_timer() -- retained async listener
		helpers.assert_eq(listener_calls, 1)
		collectgarbage("collect")
		fixture.fire_next_timer() -- retained post-return confirmation
		helpers.assert_nil(status,
			"completion callbacks are isolated from the confirmation timer")
		fixture.fire_next_timer() -- retained lifecycle dispatcher
		helpers.assert_eq(status, "complete")
	end)

	helpers.it("returns pump payload even when its confirmation timer cannot allocate", function()
		local fixture = make_fixture({ fail_on_do_after_call = 2 })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.pump-confirm-fail", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2,
			"confirmation diagnostics cannot erase an irrevocably handed-off payload")
		helpers.assert_nil(status)
		while #fixture.timers > 0 and status == nil do fixture.fire_next_timer() end
		helpers.assert_eq(status, "failed")
	end)

	helpers.it("uses the retained backup dispatcher without running feature work inline", function()
		local fixture = make_fixture({ delayed_start_failures = 1 })
		local synthetic = fixture.load()
		local calls = 0
		helpers.assert_true(synthetic.defer_after_callback(
			"unit backup dispatcher", function() calls = calls + 1 end))
		helpers.assert_eq(calls, 0,
			"post-eventtap feature work must never run on the caller's stack")
		helpers.assert_eq(fixture.delayed_start_calls, 2,
			"one failed primary start must fall through to the pre-created backup")
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1)
		fixture.fire_next_timer()
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0)
	end)

	helpers.it("fails a feature action closed when every dispatcher start fails", function()
		local fixture = make_fixture({ delayed_start_failures = 2 })
		local synthetic = fixture.load()
		local calls = 0
		fixture.fail_next_do_after = true -- independent retained doAfter fallback
		helpers.assert_true(not synthetic.defer_after_callback(
			"unit unavailable dispatcher", function() calls = calls + 1 end))
		helpers.assert_eq(calls, 0)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
			"a rejected feature action must be removed instead of firing later")
		helpers.assert_eq(synthetic.stats().pending_lifecycle_callbacks, 0)
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(calls, 0,
			"a caller that passed its physical event through must not get a duplicate action")
	end)

	helpers.it("keeps an already-idle drain owned when every fast dispatcher start fails", function()
		local fixture = make_fixture({ delayed_start_failures = 2 })
		local synthetic = fixture.load()
		local calls = 0
		fixture.fail_next_do_after = true -- independent retained doAfter fallback
		helpers.assert_true(synthetic.when_idle(function() calls = calls + 1 end),
			"the pre-acquired periodic owner must survive every fast-dispatch refusal")
		helpers.assert_eq(calls, 0,
			"an unavailable dispatcher must not run lifecycle work inline")
		helpers.assert_not_nil(fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC),
			"an accepted drain must retain an autonomous wake")
		helpers.assert_eq(calls, 1,
			"the periodic owner must deliver the accepted drain exactly once")
	end)

	helpers.it("fails terminally when CGEventTapCreate returns a disabled tap", function()
		local fixture = make_fixture({ tap_should_enable = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.disabled", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_nil(status)
		fixture.fire_next_timer()
		helpers.assert_eq(status, "failed")
		helpers.assert_eq(synthetic.stats().pending, 0)
		helpers.assert_eq(fixture.trigger_posts, 0)
	end)

	helpers.it("watchdog retries without dropping output and sinks the late old trigger", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local initial_epoch = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.timeout", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_eq(fixture.trigger_posts, 1)
		helpers.assert_eq(synthetic.stats().pending, 1)
		helpers.assert_eq(fixture.fire_next_timer(), synthetic.PUMP_DELIVERY_TIMEOUT_SEC)
		helpers.assert_nil(status,
			"an overdue run loop must not convert queued user output into failure")
		helpers.assert_eq(fixture.trigger_posts, 2)
		helpers.assert_eq(synthetic.stats().pending, 1)
		helpers.assert_true(fixture.active_tap.enabled,
			"an enabled pump remains the sink for late tombstoned triggers")
		local consume, events = fixture.deliver_posted_trigger(fixture.triggers[2])
		helpers.assert_true(consume,
			"the retry trigger must hand off the original payload")
		helpers.assert_eq(#events, 2)
		helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch)
		local old_consume, old_events = fixture.deliver_posted_trigger(fixture.triggers[1])
		helpers.assert_true(old_consume,
			"the late first trigger must be consumed as a tombstone")
		helpers.assert_nil(old_events)
		while #fixture.timers > 0 and status == nil do fixture.fire_next_timer() end
		helpers.assert_eq(status, "complete")
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("terminates a permanently undelivered pump trigger after a bounded retry budget", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.timeout-budget", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer() -- FIFO broker posts attempt one
		for _ = 1, synthetic.PUMP_WATCHDOG_MAX_FAILURES do
			helpers.assert_eq(fixture.fire_next_timer(),
				synthetic.PUMP_DELIVERY_TIMEOUT_SEC)
		end
		helpers.assert_eq(fixture.trigger_posts, synthetic.PUMP_WATCHDOG_MAX_FAILURES,
			"the normal timeout path must consume the same bounded budget as callback errors")
		helpers.assert_eq(synthetic.stats().pending, 0,
			"persistent run-loop loss must not leave an immortal queued transaction")
		helpers.assert_true(tx.completed)
		helpers.assert_eq(tx.completion_status, "failed")

		local consume, events = fixture.deliver_posted_trigger(fixture.triggers[#fixture.triggers])
		helpers.assert_true(consume,
			"the replacement pump must sink a trigger delivered after terminal timeout")
		helpers.assert_nil(events)
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(status, "failed")
		helpers.assert_eq(#fixture.timers, 0,
			"terminal timeout must not leave a self-rearming watchdog")
	end)

	helpers.it("arms the retained watchdog before posting a deferred trigger", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.watchdog-prearm", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer()
		helpers.assert_true(fixture.watchdog_armed_at_post,
			"watchdog startup must succeed before user intent is handed to Quartz")
		helpers.assert_nil(status)
		helpers.assert_true(fixture.active_tap.enabled,
			"a posted trigger still needs an enabled payload/tombstone sink")
		local consume, events = fixture.deliver_posted_trigger()
		helpers.assert_true(consume,
			"the reserved button-31 trigger must not reach the front application")
		helpers.assert_eq(#events, 2,
			"watchdog bookkeeping must never revoke already-posted user intent")
		while #fixture.timers > 0 and status == nil do fixture.fire_next_timer() end
		helpers.assert_eq(status, "complete")
	end)

	helpers.it("rejects a watchdog start that returns no retained handle", function()
		local fixture = make_fixture({
			deliver_trigger = false,
			watchdog_start_returns_nil = true,
		})
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.watchdog-start-nil", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer()
		helpers.assert_nil(status)
		fixture.fire_next_timer()
		helpers.assert_eq(status, "failed",
			"a watchdog with no live timer cannot authorize an unmonitored post")
		helpers.assert_eq(fixture.trigger_posts, 0,
			"the broker trigger must not post after watchdog startup failed")
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("contains watchdog callback errors without stranding output", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local original_warn = fixture.logger.warn
		local warn_calls = 0
		fixture.logger.warn = function(...)
			warn_calls = warn_calls + 1
			if warn_calls == 1 then error("watchdog logger unavailable") end
			return original_warn(...)
		end
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.watchdog-callback-error", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer() -- FIFO broker and first trigger post
		-- Let any escaped watchdog exception fail the test directly. The state
		-- assertions below prove that containment also preserves forward progress.
		fixture.fire_next_timer()
		fixture.deliver_trigger = true
		local fired = 0
		while #fixture.timers > 0 and status == nil and fired < 20 do
			fixture.fire_next_timer()
			fired = fired + 1
		end
		helpers.assert_eq(status, "complete",
			"a diagnostic failure cannot strand or revoke queued user output")
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("sinks a delayed trigger after cancellation", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.cancel-trigger", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_true(synthetic.cancel(tx))
		local consume, events = fixture.deliver_posted_trigger()
		helpers.assert_true(consume,
			"a cancelled broker trigger must never leak as a phantom mouse-up")
		helpers.assert_nil(events)
	end)

	helpers.it("rolls back trigger and payload records when trigger tagging throws", function()
		local fixture = make_fixture({ trigger_set_property_fail = true })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.trigger-fail", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_eq(synthetic.stats().records, 0)
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("contains pump callback failure and consumes its exact trigger", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local decode_tag = synthetic.decode_tag
		local fail_once = true
		synthetic.decode_tag = function(...)
			if fail_once then
				fail_once = false
				error("callback processing exploded")
			end
			return decode_tag(...)
		end
		local tx = synthetic.begin("unit.callback-failure", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer()
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume,
			"a proven broker trigger must never leak when callback processing throws")
		helpers.assert_nil(fixture.pump_deliveries[1].events)
		helpers.assert_eq(synthetic.stats().pending, 0,
			"the matched batch must fail terminally instead of retrying forever")
		helpers.assert_eq(synthetic.stats().records, 0)
	end)

	helpers.it("does not depend on a second mouse-button property read", function()
		local fixture = make_fixture({ throw_on_mouse_button_read = true })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.mouse-property", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2,
			"the unique reserved tag is sufficient broker authority")
	end)
end)
