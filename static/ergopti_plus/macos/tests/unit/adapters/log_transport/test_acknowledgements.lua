--- tests/unit/adapters/log_transport/test_acknowledgements.lua

--- ==============================================================================
--- MODULE: LogTransport authenticated ACK handling Tests
--- DESCRIPTION:
--- Exercises real transport behavior inside an isolated native and module scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")
local new_context, configure = Fixture.new_context, Fixture.configure
local TOKEN, SESSION, LOOPBACK = Fixture.TOKEN, Fixture.SESSION, Fixture.LOOPBACK

helpers.describe("LogTransport authenticated ACK handling", function()
	helpers.it("keeps ACK retry bounded when the wall-clock fallback steps backward", function()
		Fixture.with_fixture(function()
			local context = new_context()
			context.options.clock = nil
			local wall_clock = 100
			context.hs.timer.absoluteTime = nil
			context.hs.timer.secondsSinceEpoch = function() return wall_clock end
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local timer_scheduler = helpers.load_with_stubs("adapters.timer_scheduler", {
				timer = context.hs.timer,
			})
			context.scheduler.now_ns = timer_scheduler.now_ns
			configure(context)
			context.transport.enqueue("retry-after-wall-clock-regression", "error")
			context.state.pump()
			local sends_before_retry = #context.state.sends
			local retry_tick = nil

			for tick = 1, 60 do
				wall_clock = 99 + (tick / 100)
				context.state.pump()
				if #context.state.sends > sends_before_retry then
					retry_tick = tick
					break
				end
			end

			helpers.assert_not_nil(retry_tick,
				"a backward wall-clock step must not stall the monotonic ACK retry contract")
			helpers.assert_true(retry_tick <= 60,
				"the fallback clock must recover within the bounded pump window")
		end)
	end)

	helpers.it("uses elapsed scheduler time when the process CPU clock is frozen", function()
		Fixture.with_fixture(function()
			local context = new_context()
			context.options.clock = nil
			local original_clock = os.clock
			os.clock = function() return 7 end
			local call_ok, call_err = xpcall(function()
				configure(context)
				context.transport.enqueue("retry-on-monotonic-time", "error")
				context.state.pump()
				local sends_before_retry = #context.state.sends
				context.state.clock = context.state.clock + 0.51
				context.state.pump()
				helpers.assert_eq(#context.state.sends, sends_before_retry + 1,
					"ACK retry must advance from scheduler elapsed time, not CPU consumption")

				local completions = {}
				helpers.assert_eq(context.transport.drain(function(settled)
					completions[#completions + 1] = settled
				end, 0.25), true)
				context.state.clock = context.state.clock + 0.26
				context.state.pump()
				helpers.assert_eq(completions[1], false,
					"a retained record must hit its real elapsed-time drain deadline")
			end, debug.traceback)
			os.clock = original_clock
			if not call_ok then error(call_err, 0) end
		end)
	end)

	helpers.it("contains timer-owned routing failures and reports them off the HID path", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("route-me", "info")
			context.state.route_mode = "throw"
			local pump_ok, pump_err = pcall(context.state.pump)
			helpers.assert_true(pump_ok, "timer callback must contain routing exceptions: " .. tostring(pump_err))
			helpers.assert_eq(#context.state.sends, 1,
				"a record with no valid route payload cannot cross the socket boundary")
			helpers.assert_eq(context.transport.status().queued, 1)
			helpers.assert_eq(#context.state.failures, 1,
				"the async failure must reach the injected off-hotpath reporter")
			helpers.assert_contains(context.state.failures[1], "routing failure")

			context.state.route_mode = nil
			context.state.clock = context.state.clock + 0.51
			context.state.pump()
			helpers.assert_eq(context:payload().sequence, 1)
			context:ack(1)
			helpers.assert_eq(context.transport.status().queued, 0)
		end)
	end)

	helpers.it("contains delivery-hook exceptions after exact dequeue", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.state.delivered_mode = "throw"
			context.transport.enqueue("deliver-once", "done")
			context.state.pump()
			local callback_ok, callback_err = pcall(context.ack, context, 1)
			if not callback_ok then
				error("the native socket callback must contain delivery-hook exceptions: "
					.. tostring(callback_err), 0)
			end
			helpers.assert_eq(context.transport.status().queued, 0,
				"an exact durable ACK owns dequeue even when a secondary hook fails")
			helpers.assert_eq(#context.state.delivered, 1)
			helpers.assert_contains(context.transport.status().last_error, "delivery callback failed")
			helpers.assert_eq(#context.state.failures, 0,
				"receive callback containment must not invoke secondary user code re-entrantly")
			context.state.pump()
			helpers.assert_eq(#context.state.failures, 1)
			helpers.assert_contains(context.state.failures[1], "delivery callback failed")
		end)
	end)

	helpers.it("rejects malformed, stale, unauthenticated, and non-loopback ACKs", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("one", "INFO")
			context.transport.enqueue("two", "INFO")
			context.state.pump()

			local invalid = {
				function() context:raw_ack("{") end,
				function() context:raw_ack(context.hs.json.encode({
					kind = "ack", token = TOKEN, session = SESSION, ack = 1,
				})) end,
				function() context:raw_ack(context.hs.json.encode({
					v = 1, token = TOKEN, session = SESSION, ack = 1,
				})) end,
				function() context:raw_ack(context.hs.json.encode({
					v = 1, kind = "ack", session = SESSION, ack = 1,
				})) end,
				function() context:raw_ack(context.hs.json.encode({
					v = 1, kind = "ack", token = TOKEN, ack = 1,
				})) end,
				function() context:ack(1, nil, { host = "192.0.2.9" }) end,
				function() context:ack(1, nil, { host = "127.0.0.1", port = 49322 }) end,
				function() context:ack(1, { v = 2 }) end,
				function() context:ack(1, { kind = "nack" }) end,
				function() context:ack(1, { token = string.rep("wrong-token-", 4) }) end,
				function() context:ack(1, { session = "previous-runtime" }) end,
				function() context:ack(0) end,
				function() context:ack(1.5) end,
				function() context:raw_ack("[]") end,
			}
			for index, deliver in ipairs(invalid) do
				deliver()
				local status = context.transport.status()
				helpers.assert_eq(status.queued, 2,
					"invalid ACK case " .. tostring(index) .. " must retain the queue head")
				helpers.assert_eq(status.inflight_sequence, 1,
					"invalid ACK case " .. tostring(index) .. " must retain exact ownership")
				helpers.assert_eq(#context.state.delivered, 0)
			end

			context:ack(1)
			helpers.assert_eq(context.transport.status().queued, 1)
			helpers.assert_eq(#context.state.delivered, 1)
			context.state.pump()
			helpers.assert_eq(context.transport.status().inflight_sequence, 2)

			context:ack(1)
			helpers.assert_eq(context.transport.status().queued, 1,
				"a duplicate old ACK must not dequeue the new in-flight head")
			helpers.assert_eq(#context.state.delivered, 1)
			context:ack(2)
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.delivered, 2)
		end)
	end)

	helpers.it("treats a native NACK as a visible refusal, never as delivery", function()
		Fixture.with_fixture(function()
			local context = new_context()
			local started, start_err = context:start()
			helpers.assert_eq(started, true, tostring(start_err))
			context.transport.enqueue("must-stay-queued", "error")
			context.state.pump()
			context:raw_ack(context.hs.json.encode({
				v = 1,
				kind = "nack",
				token = TOKEN,
				session = SESSION,
				reason = "configure_failed",
			}))

			local status = context.transport.status()
			helpers.assert_eq(status.configured, true)
			helpers.assert_eq(status.inflight_sequence, 1,
				"a native refusal must retain the exact record in-flight owner")
			helpers.assert_eq(status.queued, 1,
				"a native refusal is not evidence that a queued record was delivered")
			helpers.assert_contains(status.last_error, "configure_failed",
				"the boot readiness gate needs the native refusal reason")
			helpers.assert_eq(#context.state.delivered, 0)
		end)
	end)

	helpers.it("retains and retries the identical queue head after ACK timeout", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("retry-me", "ERROR")
			context.state.pump()
			local first_send = context.state.sends[#context.state.sends]
			helpers.assert_eq(first_send.tag, 1)

			context.state.clock = context.state.clock + 0.49
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 2,
				"the pump must not duplicate a record before its retry deadline")
			context.state.clock = context.state.clock + 0.02
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 3)
			local retry_send = context.state.sends[#context.state.sends]
			helpers.assert_eq(retry_send.tag, 1)
			helpers.assert_eq(retry_send.data, first_send.data,
				"retry must reuse byte-identical authenticated payload for worker deduplication")
			helpers.assert_eq(context.transport.status().queued, 1,
				"timeout is not evidence of delivery and must not dequeue the head")

			context:ack(1)
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.delivered, 1)
		end)
	end)

	helpers.it("replays a complete multi-record batch byte-identically until its final ACK", function()
		Fixture.with_fixture(function()
			local context = new_context({ batch_records = 4 })
			configure(context)
			for index = 1, 4 do
				context.transport.enqueue("batch-retry-" .. tostring(index), "info")
			end
			context.state.pump()
			local first_send = context.state.sends[#context.state.sends]
			local first_batch = context:batch()
			helpers.assert_eq(first_batch.kind, "batch")
			helpers.assert_eq(#first_batch.records, 4)
			helpers.assert_eq(first_send.tag, 4,
				"the UDP tag and ACK authority belong to the final batch sequence")

			context:ack(1)
			helpers.assert_eq(context.transport.status().queued, 4,
				"an inner record ACK cannot retire any producer in the batch")
			helpers.assert_eq(#context.state.delivered, 0)
			context.state.clock = context.state.clock + 0.51
			context.state.pump()
			local retry_send = context.state.sends[#context.state.sends]
			helpers.assert_eq(retry_send.tag, 4)
			helpers.assert_eq(retry_send.data, first_send.data,
				"a lost final ACK must replay the byte-identical whole batch")
			context:ack(4)
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.delivered, 4)
			for index, delivered in ipairs(context.state.delivered) do
				helpers.assert_eq(delivered.sequence, index)
				helpers.assert_eq(delivered.line, "batch-retry-" .. tostring(index))
			end
		end)
	end)

	helpers.it("backs off a refused send without dropping the queue head", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("send-refusal", "error")
			context.state.send_mode = "false"
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 2)
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 2,
				"one native send refusal must not create a 100 Hz retry spin")
			helpers.assert_eq(context.transport.status().queued, 1)

			context.state.clock = context.state.clock + 0.51
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 3,
				"the exact retained payload must retry after bounded backoff")
			helpers.assert_eq(context.transport.status().inflight_sequence, 1)
		end)
	end)
end)
