--- tests/unit/adapters/synthetic_input/test_ordinary_publication.lua

--- ==============================================================================
--- MODULE: Ordinary Synthetic Publication Admission
--- DESCRIPTION:
--- Retains the real FIFO and Quartz callback handoffs after publication revocation.
--- Full checks belong outside event taps; the final handoff uses RAM-only guards.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")

--- Runs one isolated broker with independently revocable full and cached guards.
--- @param scenario function Receives native fixture, real adapter and authority.
local function with_broker(scenario)
	helpers.with_stub_scope({ "adapters.synthetic_input", "adapters.event_provenance",
		"adapters.storage", "adapters.timer_scheduler", "infra.logger" }, function()
		local fixture = Fixture.make({ deliver_trigger = false })
		local synthetic = fixture.load()
		local state = { full = true, cached = true, full_calls = 0, cached_calls = 0 }
		state.publication = {
			current = function()
				state.full_calls = state.full_calls + 1
				helpers.assert_true(not fixture.callback_active, "full publication checks must stay outside native callbacks")
				return state.full
			end,
			cached = function() state.cached_calls = state.cached_calls + 1; return state.cached end,
		}
		scenario(fixture, synthetic, state)
	end)
end

--- Queues a real ordinary command pair with the existing optional publication API.
--- @return table transaction
local function enqueue(synthetic, state, key)
	local tx = synthetic.begin("unit.ordinary-publication", "action", state.publication)
	local batch = synthetic.begin_batch(tx)
	synthetic.keyStroke(batch, { "cmd" }, key or "v")
	helpers.assert_true(synthetic.dispatch(batch))
	helpers.assert_true(synthetic.seal(tx))
	return tx
end

--- Proves terminal refusal releases payload provenance without an action handoff.
local function assert_refused(synthetic, tx, before)
	helpers.assert_eq(tx.completion_status, "failed")
	helpers.assert_eq(synthetic.stats().records, 0)
	helpers.assert_eq(synthetic.stats().pending, 0)
	helpers.assert_true(synthetic.current_action_epoch() == before)
end

helpers.describe("ordinary synthetic batches retain publication authority", function()
	helpers.it("delivers a live publication through the real FIFO and pump (ordinary-publication-positive)", function()
		with_broker(function(fixture, synthetic, state)
			enqueue(synthetic, state)
			fixture.fire_next_timer()
			fixture.callback_active = true
			local consume, events = fixture.deliver_posted_trigger()
			fixture.callback_active = false
			helpers.assert_true(consume)
			helpers.assert_eq(#events, 2)
			helpers.assert_eq(events[1].key, "v")
			helpers.assert_eq(fixture.key_posts, 0, "ordinary payloads must be callback-returned")
		end)
	end)

	helpers.it("refuses publication revoked before the broker turn (ordinary-publication-before-broker)", function()
		with_broker(function(fixture, synthetic, state)
			local before = synthetic.current_action_epoch()
			local tx = enqueue(synthetic, state)
			state.full = false
			fixture.fire_next_timer()
			if fixture.last_trigger then fixture.deliver_posted_trigger() end
			local delivery = fixture.pump_deliveries[#fixture.pump_deliveries]
			helpers.assert_nil(delivery and delivery.events, "a revoked command must never reach Quartz")
			assert_refused(synthetic, tx, before)
			helpers.assert_nil(fixture.last_trigger, "refusal before the pump must not post a control event")
		end)
	end)

	helpers.it("rechecks cached publication after posting the native trigger (ordinary-publication-trigger)", function()
		with_broker(function(fixture, synthetic, state)
			local before = synthetic.current_action_epoch()
			local tx = enqueue(synthetic, state)
			fixture.fire_next_timer()
			helpers.assert_not_nil(fixture.last_trigger)
			local trigger = fixture.last_trigger
			local watchdog
			for _, handle in ipairs(fixture.delayed_handles) do
				if handle.entry and handle.entry.delay == synthetic.PUMP_DELIVERY_TIMEOUT_SEC then watchdog = handle end
			end
			helpers.assert_not_nil(watchdog, "real broker must retain a watchdog before trigger delivery")
			helpers.assert_true(watchdog.running)
			state.cached = false
			fixture.callback_active = true
			local consume, events = fixture.deliver_posted_trigger()
			fixture.callback_active = false
			helpers.assert_true(consume, "the private broker trigger remains consumed")
			helpers.assert_nil(events, "cached revocation must prevent command handoff")
			assert_refused(synthetic, tx, before)
			helpers.assert_true(not watchdog.running, "refused trigger must stop its watchdog")
			fixture.callback_active = true
			consume, events = fixture.deliver_posted_trigger(trigger)
			fixture.callback_active = false
			helpers.assert_true(consume, "a retired private trigger must remain a consumed tombstone")
			helpers.assert_nil(events)
			assert_refused(synthetic, tx, before)
		end)
	end)

	helpers.it("drops revoked output at the physical-input fence (ordinary-publication-physical)", function()
		with_broker(function(fixture, synthetic, state)
			local before = synthetic.current_action_epoch()
			local tx = enqueue(synthetic, state)
			state.cached = false
			fixture.callback_active = true
			local fence = synthetic.claim_physical_fence(fixture.external_event(0, 1122))
			fixture.callback_active = false
			helpers.assert_nil(fence and fence.events, "physical input must not flush a revoked command")
			helpers.assert_true(fence == nil or fence.consume_original ~= true)
			assert_refused(synthetic, tx, before)
		end)
	end)

	helpers.it("continues the FIFO after a revoked ordinary head (ordinary-publication-fifo-sibling)", function()
		with_broker(function(fixture, synthetic, state)
			local refused = enqueue(synthetic, state)
			local live = enqueue(synthetic, { publication = nil }, "z")
			state.full = false
			fixture.fire_next_timer()
			helpers.assert_eq(refused.completion_status, "failed")
			fixture.fire_next_timer()
			fixture.callback_active = true
			local consume, events = fixture.deliver_posted_trigger()
			fixture.callback_active = false
			helpers.assert_true(consume)
			helpers.assert_eq(#events, 2)
			helpers.assert_eq(events[1].key, "z")
			helpers.assert_true(live.failed ~= true)
			helpers.assert_eq(synthetic.stats().pending, 0)
		end)
	end)

	helpers.it("preserves a live callback sibling when older output is revoked (ordinary-publication-adoption)", function()
		with_broker(function(fixture, synthetic, state)
			enqueue(synthetic, state)
			state.cached = false
			fixture.callback_active = true
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.live-sibling", "action")
			synthetic.with_transaction(tx, function() synthetic.emit_key_stroke({}, "z", 0) end)
			synthetic.seal(tx)
			local consume, events = synthetic.leave_callback(true)
			fixture.callback_active = false
			helpers.assert_true(consume)
			helpers.assert_eq(#events, 2, "revoked output must not prepend to its live sibling")
			helpers.assert_eq(events[1].key, "z")
			helpers.assert_eq(synthetic.stats().pending, 0)
		end)
	end)

	helpers.it("revokes a directly collected callback batch without consuming physical input (ordinary-publication-direct)", function()
		with_broker(function(fixture, synthetic, state)
			local before = synthetic.current_action_epoch()
			fixture.callback_active = true
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.guarded-callback", "action", state.publication)
			synthetic.with_transaction(tx, function() synthetic.emit_key_stroke({ "cmd" }, "v", 0) end)
			synthetic.seal(tx)
			state.cached = false
			local consume, events = synthetic.leave_callback()
			fixture.callback_active = false
			helpers.assert_true(not consume)
			helpers.assert_nil(events)
			assert_refused(synthetic, tx, before)
		end)
	end)

	helpers.it("defers full authority checks when an input callback cancels a reservation (ordinary-publication-cancel-reservation)", function()
		with_broker(function(fixture, synthetic, state)
			local predecessor = synthetic.begin("unit.reserved-predecessor", "replacement")
			synthetic.retain(predecessor)
			synthetic.seal(predecessor)
			local reserved = synthetic.prepare_reserved_successor(predecessor,
				function() synthetic.emit_key_stroke({}, "return", 0) end)
			helpers.assert_not_nil(reserved)
			helpers.assert_true(synthetic.authorize_reserved_successor(reserved))
			helpers.assert_true(synthetic.commit_reserved_successor(reserved))
			local live = enqueue(synthetic, state)
			fixture.callback_active = true
			helpers.assert_true(synthetic.cancel_reserved_successor(reserved))
			fixture.callback_active = false
			helpers.assert_eq(state.full_calls, 0, "cancellation in an event tap must defer the full destination probe")
			helpers.assert_nil(fixture.last_trigger)
			fixture.fire_timer_matching(0)
			helpers.assert_not_nil(fixture.last_trigger)
			fixture.callback_active = true
			local consume, events = fixture.deliver_posted_trigger()
			fixture.callback_active = false
			helpers.assert_true(consume)
			helpers.assert_eq(#events, 2)
			helpers.assert_eq(events[1].key, "v")
			helpers.assert_true(live.failed ~= true)
		end)
	end)

	helpers.it("refuses full authority revoked before a watchdog retry (ordinary-publication-watchdog)", function()
		with_broker(function(fixture, synthetic, state)
			local before = synthetic.current_action_epoch()
			local tx = enqueue(synthetic, state)
			fixture.fire_next_timer()
			helpers.assert_eq(fixture.trigger_posts, 1)
			state.full = false
			helpers.assert_not_nil(fixture.fire_timer_matching(synthetic.PUMP_DELIVERY_TIMEOUT_SEC))
			helpers.assert_eq(fixture.trigger_posts, 1, "watchdog retries must not renew a revoked publication")
			assert_refused(synthetic, tx, before)
		end)
	end)
end)
