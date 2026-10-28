--- tests/unit/modules/hotstrings/injector/test_injection_diagnostic_output_owner.lua

--- ==============================================================================
--- MODULE: Injection Diagnostics Retain Their Original Output Owner
--- DESCRIPTION:
--- A logger callback can replace a native writer session before planning. The
--- already requested edit must refuse that successor before erasing its trigger.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modifier_broker_fixture")

--- Executes the actual injector, writer, broker and transaction on byte ports.
--- @param mode string Ordinary, one-field or multiple-field entry point.
--- @param change string Native writer replacement or broker replacement.
local function scenario(mode, change)
	local names = { "modules.hotstrings.device_finder", "adapters.evdev_reader", "adapters.uinput_writer",
		"adapters.keyboard_hook", "adapters.xkb_capture", "adapters.keyboard_layout", "modules.hotstrings.injector", "logger.shim" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local injector, successor, writer
	local called, failure = pcall(function()
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_level("debug")
		package.loaded["logger.shim"] = logger
		Fixture.with_session(nil, function(session)
			writer = session.writer
			local Broker = require("adapters.modifier_broker")
			local original = assert(Broker.for_channel(writer))
			local saved_xkb = package.loaded["adapters.xkb_capture"]
			package.loaded["adapters.xkb_capture"] = { caps_locked = function() return false end }
			local layout = helpers.load_module("adapters.keyboard_layout")
			layout._set_table_for_test({ x = { keycode = 45, level = 1, mods = {} } })
			injector = helpers.load_module("modules.hotstrings.injector")
			package.loaded["adapters.xkb_capture"] = saved_xkb
			injector._set_uinput(writer)
			injector._set_nanosleep_for_test(function() end)
			local notified, crossed = 0, false
			assert(injector.set_output_observer(function() notified = notified + 1 end))
			logger.set_sink(function(line)
				if crossed or not line:find("inject", 1, true) or not line:find("bc=", 1, true) then return end
				crossed = true
				if change == "writer" then
					assert(writer.close_owned(session.cap)); assert(writer.open())
					successor = assert(writer.capture_output())
					Broker.detach(writer); assert(Broker.attach(writer))
				elseif change == "broker" then Broker.detach(writer); assert(Broker.attach(writer)) end
			end)
			local function inject()
				if mode == "ordinary" then return injector.inject(3, "x", true) end
				return injector.inject_fields(3, mode == "single" and { "x" } or { "x", "x" }, true)
			end
			local ok, reason = pcall(function()
				local count = #session.rows
				local result = inject()
				helpers.assert_eq(crossed, true, "the actual logger sink must cross the preflight boundary")
				helpers.assert_eq(result.ok, change == "none")
				helpers.assert_eq(result.cleanup_ok, true)
				if change == "none" then
					helpers.assert_true(#session.rows > count)
					helpers.assert_eq(notified, 1)
				else
					helpers.assert_eq(#session.rows, count, "the old request cannot erase or type through a successor session")
					helpers.assert_eq(notified, 0, "a refused source cannot publish completed output")
					helpers.assert_true(Broker.for_channel(writer) ~= original)
					logger.set_sink(nil)
					helpers.assert_eq(inject().ok, true, "a fresh request can use the acknowledged successor")
					helpers.assert_eq(notified, 1)
				end
			end)
			logger.set_sink(nil)
			if successor then assert(writer.close_owned(successor)); successor = nil end
			if not ok then error(reason, 0) end
		end)
	end)
	if successor and writer then pcall(writer.close_owned, successor) end
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not called then error(failure, 0) end
end

helpers.describe("injection diagnostics keep original output (linux-injection-diagnostic-owner)", function()
	for _, mode in ipairs({ "ordinary", "single", "multiple" }) do
		for _, change in ipairs({ "writer", "broker", "none" }) do
			helpers.it("retains " .. mode .. " output across " .. change .. " diagnostics", function() scenario(mode, change) end)
		end
	end
end)
