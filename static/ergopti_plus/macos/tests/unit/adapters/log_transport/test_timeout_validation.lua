--- tests/unit/adapters/log_transport/test_timeout_validation.lua

--- ==============================================================================
--- MODULE: Log Transport Timeout Validation Tests
--- DESCRIPTION:
--- Rejects invalid deadlines before native waits or drain ownership are published.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")

local invalid_timeouts = {
	{ name = "NaN", value = 0 / 0 },
	{ name = "positive infinity", value = math.huge },
	{ name = "negative infinity", value = -math.huge },
	{ name = "zero", value = 0 },
	{ name = "negative", value = -1 },
	{ name = "above both maxima", value = 3 },
	{ name = "nonnumeric string", value = "invalid" },
	{ name = "numeric string", value = "0.1" },
	{ name = "false", value = false },
	{ name = "table", value = {} },
	{ name = "function", value = function() return 0.1 end },
}

helpers.describe("Log transport timeout validation", function()
	for _, case in ipairs(invalid_timeouts) do
		helpers.it("(transport-timeout-validation) refuses bootstrap " .. case.name, function()
			Fixture.with_fixture(function()
				local context = Fixture.new_context()
				context.options.bootstrap_timeout_sec = case.value
				local started, detail = context:start()
				helpers.assert_eq(started, false)
				helpers.assert_contains(detail, "timeout must be positive and bounded")
				helpers.assert_eq(#context.state.preflight_timeouts, 0)
				helpers.assert_eq(#context.state.preflight_payloads, 0)
				helpers.assert_eq(context.state.bootstrap_close_calls, 1)
				helpers.assert_eq(context.state.new_calls, 0)
				helpers.assert_eq(context.transport.status().active, false)
				context.options.bootstrap_timeout_sec = 0.125
				helpers.assert_eq(context:start(), true, "refusal must not leave unusable bootstrap debt")
				helpers.assert_eq(context.transport.stop(), true)
			end)
		end)

		helpers.it("(transport-timeout-validation) refuses drain " .. case.name, function()
			Fixture.with_fixture(function()
				local context = Fixture.new_context()
				Fixture.configure(context)
				local callbacks = 0
				local accepted, detail = context.transport.drain(function() callbacks = callbacks + 1 end, case.value)
				helpers.assert_eq(accepted, false)
				helpers.assert_contains(detail, "timeout must be positive and bounded")
				helpers.assert_eq(context.transport.status().draining, false)
				context.state.pump()
				helpers.assert_eq(callbacks, 0, "a refused deadline must not publish its callback")
				helpers.assert_eq(context.transport.drain(function(drained)
					helpers.assert_eq(drained, true)
					callbacks = callbacks + 1
				end, 1), true)
				context.state.pump()
				helpers.assert_eq(callbacks, 1, "a valid drain must remain possible after refusal")
				helpers.assert_eq(context.transport.stop(), true)
			end)
		end)
	end

	for _, case in ipairs({
		{ name = "omitted", bootstrap = nil, drain = nil, deadline = 2, native = 0.25 },
		{ name = "positive fraction", bootstrap = 0.125, drain = 0.5, deadline = 0.5, native = 0.125 },
		{ name = "maximum", bootstrap = 0.25, drain = 2, deadline = 2, native = 0.25 },
	}) do
		helpers.it("(transport-timeout-validation) preserves " .. case.name .. " deadlines", function()
			Fixture.with_fixture(function()
				local context = Fixture.new_context()
				context.options.bootstrap_timeout_sec = case.bootstrap
				Fixture.configure(context)
				helpers.assert_eq(context.state.preflight_timeouts[1], case.native)
				helpers.assert_not_nil(context.transport.enqueue("retained timeout record", "info"))
				local callbacks, outcome = 0, nil
				helpers.assert_eq(context.transport.drain(function(drained)
					callbacks = callbacks + 1
					outcome = drained
				end, case.drain), true)
				context.state.clock = context.state.clock + case.deadline / 2
				context.state.pump()
				helpers.assert_eq(callbacks, 0)
				context.state.clock = context.state.clock + case.deadline / 2
				context.state.pump()
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(outcome, false, "retained records must expire at the requested deadline")
				helpers.assert_eq(context.transport.status().draining, false)
				local batch = context:batch()
				context:ack(batch.records[1].sequence)
				helpers.assert_eq(context.transport.stop(), true)
			end)
		end)
	end
end)
