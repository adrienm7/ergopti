--- tests/unit/adapters/atspi/test_atspi_inserted_span.lua

--- ==============================================================================
--- MODULE: Private Inserted Span Observation
--- DESCRIPTION:
--- Checks the cold worker's numeric-only span protocol and strict remaining
--- deadline contract. Payload bytes stay in private bounded stdout.
--- ==============================================================================
local helpers = require("tests.helpers")
local Json = require("json")
require("adapters.atspi_focus")

local function with_capture(options, body)
	local names = { "adapters.atspi_focus", "adapters.owned_process", "luv" }
	local previous, state = {}, { calls = 0 }
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	package.loaded["luv"] = { exepath = function() return "/native/luajit" end, os_getpid = function() return 1234 end }
	package.loaded["adapters.owned_process"] = { start = function(executable, argv, ports, callback)
		state.calls, state.argv, state.ports, state.callback = state.calls + 1, argv, ports, callback
		return { on_settled = function() return true end }
	end }
	package.loaded["adapters.atspi_focus"] = nil
	local ok, detail = pcall(function()
		local field = { bus = ":1.7", path = "/original/field", role = 61 }
		state.field = field
		options.owner, options.authorized = "original-owner", function() return true end
		state.operation = require("adapters.atspi_focus").start_selection_capture(field, options, function(snapshot) state.snapshot = snapshot end)
		function state.deliver(first, last, text)
			state.ports.on_output("SELECTION:" .. Json.encode({ field = field,
				selection = { bus = field.bus, path = field.path, role = field.role, first = first, last = last, text = text } }), "stdout")
			state.callback({ ok = true })
		end
		body(state)
	end)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("private inserted span protocol", function()
	helpers.it("floors the remaining wall deadline to the native integer contract without extending it", function()
		with_capture({ timeout_ms = 432.7, span = { first = 5, last = 8 } }, function(state)
			helpers.assert_eq(state.ports.timeout_ms, 432)
		end)
	end)
	helpers.it("passes only immutable numeric codepoint offsets and privately captures the span", function()
		with_capture({ timeout_ms = 650, span = { first = 5, last = 8 } }, function(state)
			helpers.assert_eq(state.argv[7], "span")
			helpers.assert_eq(state.argv[8], "5")
			helpers.assert_eq(state.argv[9], "8")
			helpers.assert_eq(#state.argv, 9)
			helpers.assert_eq(state.ports.capture_output, false)
			helpers.assert_eq(state.ports.capture_tail, false)
			for _, arg in ipairs(state.argv) do helpers.assert_eq(arg:find("PRIVATE", 1, true), nil) end
			state.deliver(5, 8, "PRIVATE")
			helpers.assert_eq(state.snapshot.text, "PRIVATE")
		end)
	end)
	for _, offsets in ipairs({ { 6, 8 }, { 5, 9 }, { 0, 3 } }) do
		helpers.it("cannot adopt a different span " .. offsets[1] .. ":" .. offsets[2], function()
			with_capture({ span = { first = 5, last = 8 } }, function(state)
				state.deliver(offsets[1], offsets[2], "replacement")
				helpers.assert_eq(state.snapshot, nil)
			end)
		end)
	end
	for _, timeout in ipairs({ -1, 0, .9, 1001 }) do
		helpers.it("refuses an expired or enlarged remaining deadline " .. timeout, function()
			with_capture({ timeout_ms = timeout, span = { first = 5, last = 8 } }, function(state)
				helpers.assert_eq(state.calls, 0)
				helpers.assert_eq(state.operation, nil)
			end)
		end)
	end
end)
