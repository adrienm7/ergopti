--- tests/unit/adapters/log_transport/test_session_diagnostics.lua

--- ==============================================================================
--- MODULE: Log Transport Session Diagnostic Ownership Tests
--- DESCRIPTION:
--- Keeps terminal callback errors and old native callbacks with their session.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")

--- Starts a successor on the same public adapter with a distinct failure handler.
--- @param context table Real transport fixture.
--- @param failures table Successor failure observations.
local function restart(context, failures)
	helpers.assert_eq(context.transport.stop(), true)
	context.options.session = "successor-diagnostic-session"
	context.options.on_failed = function(detail) failures[#failures + 1] = detail end
	helpers.assert_eq(context:start(), true)
end

helpers.describe("Log transport session diagnostics", function()
	helpers.it("(transport-session-diagnostics) archives an existing failure on ordinary restart", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			helpers.assert_eq(context.transport.drain(function() error("unreported drain marker") end, 1), true)
			context.state.pump()
			helpers.assert_contains(context.transport.status().last_error, "unreported drain marker")
			local successor = {}
			restart(context, successor)
			context.state.pump()
			local status = context.transport.status()
			helpers.assert_nil(status.last_error)
			helpers.assert_eq(#successor, 0)
			helpers.assert_not_nil(status.retired_failure)
			helpers.assert_contains(status.retired_failure.last_error, "unreported drain marker")
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	helpers.it("(transport-session-diagnostics) reports a retired drain failure only to its owner", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			local original, successor = {}, {}
			context.options.on_failed = function(detail) original[#original + 1] = detail end
			Fixture.configure(context)
			helpers.assert_eq(context.transport.drain(function()
				restart(context, successor)
				error("old drain marker")
			end, 1), true)
			context.state.pump()
			context.state.pump()
			local status = context.transport.status()
			helpers.assert_nil(status.last_error, "a predecessor exception must not become the successor failure")
			helpers.assert_eq(#successor, 0)
			helpers.assert_eq(#original, 1, "retirement must not silently discard the old failure")
			helpers.assert_contains(original[1], "old drain marker")
			helpers.assert_contains(status.retired_failure.last_error, "old drain marker")
			status.retired_failure.last_error = "caller mutation"
			helpers.assert_contains(context.transport.status().retired_failure.last_error, "old drain marker")
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	helpers.it("(transport-session-diagnostics) leaves successor work to its own pump", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			local old_pump = context.state.pump
			helpers.assert_eq(context.transport.drain(function()
				restart(context, {})
				helpers.assert_not_nil(context.transport.enqueue("successor work", "info"))
			end, 1), true)
			old_pump()
			helpers.assert_eq(#context.state.sends, 2, "the retired pump must stop after its continuation restarts")
			old_pump()
			helpers.assert_eq(#context.state.sends, 2, "late delivery of the retired timer must remain inert")
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 3)
			local batch = context:batch()
			helpers.assert_eq(batch.records[1].line, "successor work")
			context:ack(batch.records[1].sequence, { session = context.options.session })
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	helpers.it("(transport-session-diagnostics) retains a retired failure handler's own exception", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			local original, successor = {}, {}
			context.options.on_failed = function(detail)
				original[#original + 1] = detail
				restart(context, successor)
				error("old failure handler marker")
			end
			Fixture.configure(context)
			helpers.assert_eq(context.transport.drain(function() error("original drain marker") end, 1), true)
			context.state.pump()
			context.state.pump()
			context.state.pump()
			local status = context.transport.status()
			helpers.assert_nil(status.last_error)
			helpers.assert_nil(status.failure_callback_error)
			helpers.assert_eq(#successor, 0)
			helpers.assert_eq(#original, 1)
			helpers.assert_contains(original[1], "original drain marker")
			helpers.assert_contains(status.retired_failure.failure_callback_error, "old failure handler marker")
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	helpers.it("(transport-session-diagnostics) does not recursively report a failing failure handler", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			local calls = 0
			context.options.on_failed = function()
				calls = calls + 1
				error("failure handler marker")
			end
			Fixture.configure(context)
			helpers.assert_eq(context.transport.drain(function() error("drain marker") end, 1), true)
			for _ = 1, 5 do context.state.pump() end
			helpers.assert_eq(calls, 1, "a diagnostic sink error must not create a self-amplifying failure stream")
			helpers.assert_contains(context.transport.status().last_error, "drain marker")
			helpers.assert_contains(context.transport.status().failure_callback_error, "failure handler marker")
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	helpers.it("(transport-session-diagnostics) ignores a retired socket even with successor ACK bytes", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			Fixture.configure(context)
			local old_receiver = context.state.receive_callback
			restart(context, {})
			helpers.assert_not_nil(context.transport.enqueue("successor record", "info"))
			context.state.pump()
			local sequence = context.transport.status().inflight_sequence
			local payload = context.hs.json.encode({
				v = 1, kind = "ack", token = Fixture.TOKEN,
				session = context.options.session, ack = sequence,
			})
			old_receiver(payload, Fixture.LOOPBACK)
			helpers.assert_eq(context.transport.status().queued, 1, "a retired native receiver cannot retire successor records")
			helpers.assert_eq(#context.state.delivered, 0)
			context:raw_ack(payload)
			helpers.assert_eq(#context.state.delivered, 1)
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)
end)
