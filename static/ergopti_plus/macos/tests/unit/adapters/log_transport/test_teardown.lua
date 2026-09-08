--- tests/unit/adapters/log_transport/test_teardown.lua

--- ==============================================================================
--- MODULE: LogTransport teardown ownership Tests
--- DESCRIPTION:
--- Exercises real transport behavior inside an isolated native and module scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")
local new_context, configure = Fixture.new_context, Fixture.configure
local TOKEN, SESSION, LOOPBACK = Fixture.TOKEN, Fixture.SESSION, Fixture.LOOPBACK

helpers.describe("LogTransport teardown ownership", function()
	helpers.it("contains a throwing drain callback and keeps cleanup retryable", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			helpers.assert_eq(context.transport.drain(function()
				error("synthetic drain owner failure")
			end, 0.25), true)
			local pump_ok, pump_err = pcall(context.state.pump)
			if not pump_ok then
				error("timer boundary must contain a drain-owner exception: " .. tostring(pump_err), 0)
			end
			helpers.assert_contains(context.transport.status().last_error, "drain callback failed")
			helpers.assert_eq(context.transport.status().accepting, false)
			helpers.assert_eq(context.transport.stop(), true,
				"contained callback failure must not orphan timer/socket ownership")
		end)
	end)

	helpers.it("drains queued records before releasing timer and socket ownership", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("shutdown-tail", "info")
			local completions = {}

			local committed = context.transport.drain(function(settled, detail)
				completions[#completions + 1] = { settled = settled, detail = detail }
			end, 0.25)
			helpers.assert_eq(committed, true,
				"controlled teardown must acquire an exact drain deadline")
			helpers.assert_eq(#completions, 0, "an unacknowledged tail cannot complete shutdown")
			helpers.assert_eq(context.state.cancel_calls, 0,
				"the pump must remain owned while queued shutdown diagnostics drain")
			helpers.assert_eq(context.state.close_calls, 0)
			helpers.assert_eq(context.transport.status().active, true)
			helpers.assert_eq(context.transport.status().queued, 1)
			local late_record = context.transport.enqueue("reload-upgraded-to-quit", "info")
			helpers.assert_not_nil(late_record,
				"a pending reload drain must still accept a quit-upgrade diagnostic")

			context.state.pump()
			helpers.assert_eq(context.transport.status().inflight_sequence, 1)
			context:ack(1)
			helpers.assert_eq(#completions, 0,
				"the drain cannot settle while the quit-upgrade tail remains queued")
			context.state.pump()
			helpers.assert_eq(context.transport.status().inflight_sequence, 2)
			context:ack(2)
			helpers.assert_eq(#completions, 0,
				"socket ACK handling must not run the timer-owned drain continuation")
			context.state.pump()
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1].settled, true)
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_nil(context.transport.enqueue("after-drain-boundary", "info"),
				"the pump must fence producers atomically at the observed empty boundary")
			helpers.assert_eq(context.transport.status().active, true,
				"the drain callback hands terminal ownership to its shutdown coordinator")
			helpers.assert_eq(context.transport.stop(), true)
			helpers.assert_eq(context.transport.status().active, false)
			helpers.assert_eq(context.state.cancel_calls, 1)
			helpers.assert_eq(context.state.close_calls, 1)
			context:ack(1)
			helpers.assert_eq(#completions, 1,
				"a duplicate late ACK must not deliver shutdown completion twice")
		end)
	end)

	helpers.it("reports a final ACK delivery failure before the drain continuation", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.state.delivered_mode = "false"
			context.transport.enqueue("final-delivery-hook", "info")
			local failure_count_at_completion = nil
			local completion = nil
			helpers.assert_eq(context.transport.drain(function(settled, detail)
				failure_count_at_completion = #context.state.failures
				completion = { settled = settled, detail = detail }
			end, 0.25), true)

			context.state.pump()
			context:ack(1)
			helpers.assert_eq(#context.state.failures, 0,
				"the socket callback must not invoke secondary fail-safe code re-entrantly")
			helpers.assert_nil(failure_count_at_completion,
				"the final ACK alone must not bypass deferred failure delivery")
			context.state.pump()
			helpers.assert_eq(#context.state.failures, 1)
			helpers.assert_contains(context.state.failures[1], "delivery callback failed")
			helpers.assert_eq(failure_count_at_completion, 1,
				"the fail-safe must observe the post-ACK failure before finalization")
			helpers.assert_eq(completion.settled, false,
				"a failed final delivery hook cannot certify a clean native drain")
			helpers.assert_contains(completion.detail, "synthetic delivery refusal")
			helpers.assert_eq(context.transport.status().accepting, true,
				"a failed drain must resume producers instead of publishing a terminal fence")
		end)
	end)

	helpers.it("reports a drain deadline without discarding recoverable ownership", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("still-pending", "error")
			local completions = {}
			local committed = context.transport.drain(function(settled, detail)
				completions[#completions + 1] = { settled = settled, detail = detail }
			end, 0.25)
			helpers.assert_eq(committed, true)
			context.state.clock = context.state.clock + 0.26
			context.state.pump()

			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1].settled, false)
			helpers.assert_type(completions[1].detail, "string")
			helpers.assert_eq(context.transport.status().active, true,
				"deadline expiry is not proof that the UDP socket stopped")
			helpers.assert_eq(context.transport.status().queued, 1,
				"deadline expiry is not proof that the queued record was durable")
			helpers.assert_eq(context.state.close_calls, 0)
			helpers.assert_not_nil(context.transport.enqueue("accepted-after-timeout", "info"),
				"a failed drain must resume producers so normal runtime can recover")
		end)
	end)

	helpers.it("refuses stop while records remain without releasing their pump", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("owned-tail", "warn")
			helpers.assert_eq(context.transport.stop(), false)
			helpers.assert_eq(context.state.cancel_calls, 0)
			helpers.assert_eq(context.state.close_calls, 0)
			helpers.assert_eq(context.transport.status().active, true)
			helpers.assert_eq(context.transport.status().queued, 1)
			context.state.pump()
			context:ack(1)
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	helpers.it("fences producers when socket close fails after pump cancellation", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.state.close_mode = "false"

			local stopped = context.transport.stop()
			helpers.assert_eq(stopped, false)
			helpers.assert_eq(context.state.cancel_calls, 1)
			helpers.assert_eq(context.state.close_calls, 1)
			helpers.assert_eq(context.transport.status().accepting, false,
				"once the only pump is gone, accepting a record would strand it forever")
			helpers.assert_nil(context.transport.enqueue("cannot-be-pumped", "error"),
				"cleanup debt must be callback-inert and producer-fenced")

			context.state.close_mode = "success"
			stopped = context.transport.stop()
			helpers.assert_eq(stopped, true)
			helpers.assert_eq(context.state.cancel_calls, 1,
				"the already released timer must not be cancelled twice")
			helpers.assert_eq(context.state.close_calls, 2,
				"retry must close the exact retained socket")
			helpers.assert_eq(context.transport.status().active, false)
		end)
	end)

	helpers.it("retains the exact timer and socket when cancellation refuses", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.state.cancel_mode = "false"

			local stopped = context.transport.stop()
			helpers.assert_eq(stopped, false)
			helpers.assert_eq(context.state.cancel_calls, 1)
			helpers.assert_eq(context.state.cancel_handles[1], context.state.timer_handle)
			helpers.assert_eq(context.state.close_calls, 0,
				"socket ownership must remain while the pump may still fire")
			helpers.assert_eq(context.transport.status().active, true)
			helpers.assert_eq(context.transport.status().queued, 0)

			context.state.cancel_mode = "success"
			stopped = context.transport.stop()
			helpers.assert_eq(stopped, true)
			helpers.assert_eq(context.state.cancel_calls, 2)
			helpers.assert_eq(context.state.cancel_handles[2], context.state.timer_handle,
				"retry must target the same retained timer handle")
			helpers.assert_eq(context.state.close_calls, 1)
			helpers.assert_eq(context.transport.status().active, false)
			helpers.assert_eq(context.transport.status().queued, 0)
		end)
	end)
end)
