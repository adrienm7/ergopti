--- tests/unit/adapters/log_transport/test_stall_budget.lua

--- ==============================================================================
--- MODULE: Log Transport Stall Budget Tests
--- DESCRIPTION:
--- A user saw "ErgoptiPlus could not start. Step native_logger. Cause: native
--- logger did not ACK retained sequence 181557 after 4 sends": the transport
--- declared the native worker dead at its fourth send, about 1.5 s after the
--- first, and the driver exited. A slow volume, a sync tool or App Nap can hold
--- the worker that long without anything being wrong.
---
--- FEATURES & RATIONALE:
--- 1. Only a whole stall budget without an exact ACK is a failure, reported once.
--- 2. Resends back off to a bounded interval and stay byte-identical.
--- 3. While stalled, DEBUG/TRACE/DONE records beyond a small backlog are shed
---    and counted instead of filling the queue; nothing else is ever shed.
--- 4. A pump tick that follows a frozen run loop defers its verdict, so an ACK
---    already waiting in the socket is read before the transport is declared dead.
---    It defers once per batch: a run loop that stays throttled still gets one.
--- 5. The budget counts running pump time: a parked run loop (a modal dialog, a
---    busy main thread) counts at most one longest resend interval. A user who
---    read a blocking dialog for thirty seconds saw the driver exit with "did
---    not ACK retained sequence 128 within the 30000 ms stall budget (3 sends)"
---    (transport-parked-run-loop).
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")
local Timings = require("infra.timings")

-- The pump runs every 10 ms in production; 50 ms keeps these loops short while
-- remaining far below every retry interval under test.
local PUMP_STEP_SEC = 0.05

-- App Nap or a saturated main thread can space every pump tick further apart
-- than the first resend, which is what the transport reads as a frozen run loop.
local THROTTLED_PUMP_STEP_SEC = Timings.sec("logger", "ack_retry_ms") + 0.1

--- Advances the fixture clock tick by tick, running the pump on each tick. Each
--- tick is computed from the start rather than accumulated, so a retry that is
--- due exactly on a tick is not pushed to the next one by rounding drift.
--- @param context table Transport fixture.
--- @param target number Clock value to reach.
--- @param step number|nil Seconds between two pump ticks.
local function pump_until(context, target, step)
	step = step or PUMP_STEP_SEC
	local start = context.state.clock
	local ticks = math.ceil((target - start) / step - 1e-9)
	for tick = 1, ticks do
		context.state.clock = start + tick * step
		context.state.pump()
	end
end

--- Returns the runtime sends of one sequence, excluding the boot configure.
--- @param context table Transport fixture.
--- @param sequence integer Batch sequence (the UDP tag).
--- @return table sends
local function sends_of(context, sequence)
	local found = {}
	for _, sent in ipairs(context.state.sends) do
		if sent.bootstrap ~= true and sent.tag == sequence then found[#found + 1] = sent end
	end
	return found
end

helpers.describe("Log transport stall budget", function()
	helpers.it("(transport-stall-budget) a 1.6 s native stall followed by its ACK is not fatal", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			context.transport.enqueue("survives-a-slow-worker", "error")
			context.state.pump()
			local first_send_at = context.state.clock

			pump_until(context, first_send_at + 1.6)
			helpers.assert_eq(#context.state.failures, 0,
				"a worker that answers after 1.6 s is slow, not dead")
			helpers.assert_eq(context.transport.status().stalled, true,
				"a batch past its first ACK deadline marks the transport stalled")

			context:ack(1)
			context.state.pump()
			helpers.assert_eq(#context.state.failures, 0)
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.delivered, 1)
			helpers.assert_eq(context.transport.status().stalled, false)
			helpers.assert_eq(#context.state.recoveries, 1,
				"the recovery is reported once, from the pump")
			helpers.assert_eq(context.state.recoveries[1].stalled_ms, 1600)
			helpers.assert_eq(context.state.recoveries[1].shed, 0)
		end)
	end)

	helpers.it("(transport-stall-budget) no ACK for the whole budget reports exactly one failure", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			context.transport.enqueue("never-acknowledged", "error")
			context.state.pump()
			local first_send_at = context.state.clock
			local budget = context.transport.status().stall_budget_sec
			helpers.assert_true(type(budget) == "number" and budget >= 10,
				"the stall budget must outlast ordinary disk and scheduling pauses")

			pump_until(context, first_send_at + budget - 0.1)
			helpers.assert_eq(#context.state.failures, 0,
				"the transport must not fail before its stall budget elapses")

			pump_until(context, first_send_at + budget + 30)
			helpers.assert_eq(#context.state.failures, 1,
				"an exhausted budget is one failure, not one per later resend")
			helpers.assert_contains(context.state.failures[1], "did not ACK retained sequence 1")
			helpers.assert_contains(context.state.failures[1],
				string.format("%d ms", math.floor(budget * 1000 + 0.5)))
			helpers.assert_eq(context.transport.status().queued, 1,
				"a failure verdict is not evidence of delivery")
		end)
	end)

	helpers.it("(transport-stall-budget) resends back off to a bounded interval with identical bytes", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			context.transport.enqueue("backoff-me", "error")
			context.state.pump()
			local sent_at = { context.state.clock }
			local observed = 1
			local target = context.state.clock + context.transport.status().stall_budget_sec
			while context.state.clock < target do
				context.state.clock = context.state.clock + PUMP_STEP_SEC
				context.state.pump()
				local sends = sends_of(context, 1)
				if #sends > observed then
					observed = #sends
					sent_at[#sent_at + 1] = context.state.clock
				end
			end

			local sends = sends_of(context, 1)
			helpers.assert_true(#sends >= 5, "the budget must allow several resends, got " .. #sends)
			helpers.assert_true(#sends <= 16,
				"a stalled worker must not be made to decode a resend every half second, got " .. #sends)
			for index = 2, #sends do
				helpers.assert_eq(sends[index].data, sends[1].data,
					"resend " .. index .. " must be byte-identical for worker deduplication")
			end
			local previous_interval = 0
			local cap_reached = false
			for index = 2, #sent_at do
				local interval = sent_at[index] - sent_at[index - 1]
				helpers.assert_true(interval + 1e-6 >= previous_interval,
					"the resend interval must never shrink while the stall lasts")
				helpers.assert_true(interval <= 4 + PUMP_STEP_SEC + 1e-6,
					"the resend interval must stay bounded, got " .. interval)
				if interval >= 4 - 1e-6 then cap_reached = true end
				previous_interval = interval
			end
			helpers.assert_true(sent_at[2] - sent_at[1] <= 0.5 + PUMP_STEP_SEC + 1e-6,
				"the first resend keeps the short retry for a merely lost datagram")
			helpers.assert_true(cap_reached, "a long stall must reach the backoff cap")
		end)
	end)

	helpers.it("(transport-stall-budget) sheds only DEBUG, TRACE and DONE while stalled and counts them", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			helpers.assert_not_nil(context.transport.enqueue("head-of-line", "info"))
			context.state.pump()
			helpers.assert_eq(context.transport.enqueue("before-stall", "debug") ~= nil, true)
			pump_until(context, context.state.clock + 0.6)
			local status = context.transport.status()
			helpers.assert_eq(status.stalled, true)
			local limit = status.stalled_sheddable_limit
			helpers.assert_true(type(limit) == "number" and limit > 0 and limit < 7168,
				"shedding must start below the non-critical admission ceiling")

			local admitted = 0
			for index = 1, limit + 50 do
				local record = context.transport.enqueue("stalled-debug-" .. index, "debug")
				if type(record) == "table" then admitted = admitted + 1 end
			end
			helpers.assert_true(admitted > 0 and admitted <= limit,
				"a short backlog of low-importance lines stays lossless")
			for _, variant in ipairs({ "trace", "done" }) do
				local record, detail = context.transport.enqueue("stalled-" .. variant, variant)
				helpers.assert_eq(record, false, variant .. " past the stalled backlog must be shed")
				helpers.assert_contains(detail, "shed")
			end
			for _, variant in ipairs({ "info", "start", "success", "warn", "error" }) do
				helpers.assert_eq(type(context.transport.enqueue("kept-" .. variant, variant)), "table",
					variant .. " is never shed")
			end
			status = context.transport.status()
			local shed = limit + 50 - admitted + 2
			helpers.assert_eq(status.stall_shed, shed)
			helpers.assert_eq(status.last_error, nil, "shedding is a policy, not a transport failure")
			helpers.assert_eq(status.dropped_total, 0, "shed lines are not capacity drops")

			context.state.pump()
			helpers.assert_eq(#context.state.failures, 0)
			context:ack(1)
			context.state.pump()
			helpers.assert_eq(#context.state.recoveries, 1)
			helpers.assert_eq(context.state.recoveries[1].shed, shed,
				"the recovery report names every shed record")
			helpers.assert_eq(context.transport.status().stall_shed, 0,
				"the next stall starts a fresh count")
			helpers.assert_eq(type(context.transport.enqueue("after-recovery", "debug")), "table",
				"low-importance lines are admitted again once the worker answers")
		end)
	end)

	helpers.it("(transport-stall-budget) a tick after a frozen run loop reads the waiting ACK first", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			context.transport.enqueue("acknowledged-during-a-freeze", "error")
			context.state.pump()
			local budget = context.transport.status().stall_budget_sec

			context.state.clock = context.state.clock + budget + 1
			context.state.pump()
			helpers.assert_eq(#context.state.failures, 0,
				"the first tick after a frozen run loop cannot tell a dead worker from an unread ACK")
			context:ack(1)
			context.state.clock = context.state.clock + 0.01
			context.state.pump()
			helpers.assert_eq(#context.state.failures, 0)
			helpers.assert_eq(context.transport.status().queued, 0)

			context.transport.enqueue("still-unacknowledged", "error")
			context.state.pump()
			context.state.clock = context.state.clock + budget + 1
			context.state.pump()
			helpers.assert_eq(#context.state.failures, 0)
			local resumed_at = context.state.clock
			pump_until(context, resumed_at + budget + 5)
			helpers.assert_eq(#context.state.failures, 1,
				"a live pump after the freeze still enforces the budget")
		end)
	end)

	helpers.it("(transport-parked-run-loop) a dialog read for longer than the budget is not fatal", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			context.transport.enqueue("logged-just-before-a-dialog", "error")
			context.state.pump()
			local first_send_at = context.state.clock
			local budget = context.transport.status().stall_budget_sec

			-- Two resends go out, then a blocking dialog parks the run loop, the
			-- pump and the ACK callback together until the user closes it.
			pump_until(context, first_send_at + 1.6)
			helpers.assert_eq(#sends_of(context, 1), 3, "the pump resent twice before the dialog")
			context.state.clock = first_send_at + budget - 1
			pump_until(context, first_send_at + budget + 3)
			helpers.assert_eq(#context.state.failures, 0,
				"the time the dialog held the run loop proves nothing about the worker")

			context:ack(1)
			context.state.clock = context.state.clock + 0.01
			context.state.pump()
			helpers.assert_eq(#context.state.failures, 0)
			helpers.assert_eq(context.transport.status().queued, 0, "the answered batch is retired")
		end)
	end)

	helpers.it("(transport-parked-run-loop) a dead worker is reported after the budget of running pump time", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			context.transport.enqueue("never-acknowledged-around-a-dialog", "error")
			context.state.pump()
			local budget = context.transport.status().stall_budget_sec
			local longest_resend = Timings.sec("logger", "ack_retry_cap_ms")

			context.state.clock = context.state.clock + 10 * budget
			context.state.pump()
			local resumed_at = context.state.clock
			pump_until(context, resumed_at + budget - longest_resend - 0.1)
			helpers.assert_eq(#context.state.failures, 0,
				"a parked run loop counts at most one longest resend interval")
			pump_until(context, resumed_at + budget + 5)
			helpers.assert_eq(#context.state.failures, 1,
				"a worker silent through the whole budget of running pump time is dead")
			helpers.assert_contains(context.state.failures[1], "did not ACK retained sequence 1")
		end)
	end)

	helpers.it("(transport-stall-budget) a run loop that stays throttled still reaches the verdict", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			context.transport.enqueue("never-acknowledged-while-throttled", "error")
			context.state.pump()
			local first_send_at = context.state.clock
			local budget = context.transport.status().stall_budget_sec

			pump_until(context, first_send_at + budget - THROTTLED_PUMP_STEP_SEC, THROTTLED_PUMP_STEP_SEC)
			helpers.assert_eq(#context.state.failures, 0,
				"throttled ticks must not shorten the stall budget")
			pump_until(context, first_send_at + budget + 5, THROTTLED_PUMP_STEP_SEC)
			helpers.assert_eq(#context.state.failures, 1,
				"every tick is late, so the verdict may wait one tick but never forever")
			helpers.assert_contains(context.state.failures[1], "did not ACK retained sequence 1")
		end)
	end)
end)
