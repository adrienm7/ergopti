--- tests/unit/adapters/test_input_source_broker.lua

--- ==============================================================================
--- MODULE: Input Source Broker Regression Tests
--- DESCRIPTION:
--- Proves that Ergopti owns Hammerspoon's setter-only input-source callback once
--- and multiplexes every subsystem through that single native owner.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh broker with a setter-only native callback stub.
--- @return table context Test controls and observations.
local function load_broker()
	local context = {
		callback = nil,
		setter_calls = 0,
		fail_setter = false,
		fail_after_assignment = false,
		errors = {},
	}
	local logger = helpers.make_logger_stub()
	logger.error = function(_module, format_string, ...)
		context.errors[#context.errors + 1] = string.format(format_string, ...)
	end
	package.loaded["infra.logger"] = logger
	local function native_setter(callback)
		context.setter_calls = context.setter_calls + 1
		if context.fail_setter then error("native setter exploded") end
		context.callback = callback
		if context.fail_after_assignment then
			error("native setter exploded after replacement")
		end
	end
	local keycodes = { inputSourceChanged = native_setter }
	local broker = helpers.load_with_stubs("adapters.input_source_broker", {
		keycodes = keycodes,
	})
	context.keycodes = keycodes
	context.native_setter = native_setter
	context.broker = broker
	context.fire = function()
		if context.callback then context.callback() end
	end
	return context
end

helpers.describe("InputSourceBroker single native ownership", function()
	helpers.it("multiplexes siblings without replacing the native callback", function()
		local context = load_broker()
		local calls = {}
		helpers.assert_eq(true, context.broker.subscribe("karabiner", function()
			calls[#calls + 1] = "karabiner"
		end))
		helpers.assert_eq(true, context.broker.subscribe("keylogger", function()
			calls[#calls + 1] = "keylogger"
		end))
		helpers.assert_eq(1, context.setter_calls,
			"two subscribers must install exactly one native callback")
		context.fire()
		helpers.assert_eq("karabiner,keylogger", table.concat(calls, ","))
	end)

	helpers.it("isolates a throwing subscriber and keeps its healthy sibling", function()
		local context = load_broker()
		local healthy_calls = 0
		context.broker.subscribe("a_throwing", function() error("subscriber exploded") end)
		context.broker.subscribe("b_healthy", function() healthy_calls = healthy_calls + 1 end)
		local ok = pcall(context.fire)
		helpers.assert_eq(true, ok)
		helpers.assert_eq(1, healthy_calls)
		helpers.assert_eq(1, #context.errors)
	end)

	helpers.it("removes only the named sibling and unsets after the last one", function()
		local context = load_broker()
		local first_calls, second_calls = 0, 0
		context.broker.subscribe("first", function() first_calls = first_calls + 1 end)
		context.broker.subscribe("second", function() second_calls = second_calls + 1 end)
		helpers.assert_eq(true, context.broker.unsubscribe("first"))
		helpers.assert_eq(1, context.setter_calls,
			"removing one sibling must not touch the global slot")
		context.fire()
		helpers.assert_eq(0, first_calls)
		helpers.assert_eq(1, second_calls)
		helpers.assert_eq(true, context.broker.unsubscribe("second"))
		helpers.assert_eq(2, context.setter_calls)
		helpers.assert_eq(nil, context.callback)
	end)

	helpers.it("retains an inert removal debt and retries the native unset", function()
		local context = load_broker()
		local calls = 0
		context.broker.subscribe("owner", function() calls = calls + 1 end)
		context.fail_setter = true
		helpers.assert_eq(false, context.broker.unsubscribe("owner"))
		context.fire()
		helpers.assert_eq(0, calls,
			"failed native removal must not resurrect the removed callback")
		context.fail_setter = false
		helpers.assert_eq(true, context.broker.unsubscribe("owner"))
		helpers.assert_eq(nil, context.callback)
	end)

	helpers.it("reinstalls after an unset throws after removing the native callback", function()
		local context = load_broker()
		local replacement_calls = 0
		context.broker.subscribe("owner", function() end)
		context.fail_after_assignment = true
		helpers.assert_eq(false, context.broker.unsubscribe("owner"))
		helpers.assert_eq(nil, context.callback,
			"the fixture must model a native throw after predecessor removal")
		context.fail_after_assignment = false
		helpers.assert_eq(true, context.broker.subscribe("replacement", function()
			replacement_calls = replacement_calls + 1
		end))
		context.fire()
		helpers.assert_eq(1, replacement_calls,
			"uncertain native state must force dispatcher reinstallation")
	end)

	helpers.it("retains installation debt when the setter throws after replacement", function()
		local context = load_broker()
		context.fail_after_assignment = true
		helpers.assert_eq(false, context.broker.subscribe("owner", function() end))
		helpers.assert_true(type(context.callback) == "function",
			"the fixture must prove the failed setter already published the dispatcher")
		helpers.assert_eq(1, context.setter_calls)

		context.fail_after_assignment = false
		helpers.assert_eq(true, context.broker.unsubscribe("owner"),
			"an explicit cleanup retry must settle the uncertain native slot")
		helpers.assert_eq(2, context.setter_calls,
			"cleanup must issue the exact native unset after partial installation")
		helpers.assert_eq(nil, context.callback)
	end)

	helpers.it("contains a missing teardown API and retries the retained slot", function()
		local context = load_broker()
		context.broker.subscribe("owner", function() end)
		context.keycodes.inputSourceChanged = nil
		local call_ok, removed = pcall(context.broker.unsubscribe, "owner")
		helpers.assert_eq(true, call_ok,
			"native API loss during teardown must not escape the lifecycle callback")
		helpers.assert_eq(false, removed)

		context.keycodes.inputSourceChanged = context.native_setter
		helpers.assert_eq(true, context.broker.unsubscribe("owner"),
			"a later teardown must retry the retained native slot")
		helpers.assert_eq(nil, context.callback)
	end)
end)
