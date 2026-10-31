--- tests/unit/adapters/synthetic_input/test_keyboard_source_fixture.lua

--- ==============================================================================
--- MODULE: Keyboard-Only Fixture Sources For The Kernel Harnesses
--- DESCRIPTION:
--- The real-kernel harnesses (modifier custody, input owner, simultaneous
--- configuration) build their "physical keyboards" from a copy of the
--- production writer. When the writer gained relative axes for the navigation
--- layer's wheel, every such source advertised EV_REL, the hook refused to grab
--- it and "The whole daemon, live" failed at "Hook owns both real virtual source
--- grabs" with nothing logged. These cases replay the writer's device setup
--- through a recorder and judge the event mask with the hook's own grab policy.
--- ==============================================================================

package.loaded["tests.support.adapters.synthetic_input.uinput_writer_fixture"] = nil
local Fixture = require("tests.support.adapters.synthetic_input.uinput_writer_fixture")
local helpers, recorder = Fixture.helpers, Fixture.recorder
local Finder = require("modules.hotstrings.device_finder")
local KeyboardSource = require("tests.hardware.keyboard_source_writer")

local WRITER_PATH = helpers.driver_root() .. "/adapters/uinput_writer.lua"
local HARNESSES = { "run_modifier_custody.lua", "run_input_owner_real.lua", "run_simultaneous_configuration_real.lua" }

--- Opens a writer copy on a recorder and returns the EV_* mask it registered.
--- @param writer table A writer module instance.
--- @return integer mask
local function registered_mask(writer)
	local rec = recorder()
	writer._set_backend(rec.backend)
	helpers.assert_true(writer.open(), "the recorded device opens")
	local mask, seen = 0, {}
	for _, call in ipairs(rec.ioctls) do
		if call.request == writer.UI_SET_EVBIT and not seen[call.arg] then
			seen[call.arg] = true
			mask = mask + 2 ^ call.arg
		end
	end
	writer.close()
	return mask
end

helpers.describe("keyboard-only fixture sources", function()

	helpers.it("(keyboard-source-fixture) the production writer is refused as a grabbed source", function()
		local production = assert(loadfile(WRITER_PATH))()
		local allowed = Finder.is_interceptable_event_mask(registered_mask(production))
		helpers.assert_true(not allowed, "the production device advertises the wheel's relative axes")
	end)

	helpers.it("(keyboard-source-fixture) the fixture writer is a source the hook grabs", function()
		local source = KeyboardSource.load("Ergopti Fixture Source", WRITER_PATH)
		local allowed, reason = Finder.is_interceptable_event_mask(registered_mask(source))
		helpers.assert_true(allowed == true, "a fixture keyboard must be interceptable: " .. tostring(reason))
	end)

	helpers.it("(keyboard-source-fixture) the fixture differs from the writer by that registration only", function()
		local file = assert(io.open(WRITER_PATH, "rb"))
		local production = file:read("*a")
		file:close()
		local fixture = KeyboardSource.keyboard_source(WRITER_PATH)
		helpers.assert_eq(#production - #fixture, #KeyboardSource.RELATIVE_REGISTRATION)
		local at = production:find(KeyboardSource.RELATIVE_REGISTRATION, 1, true)
		helpers.assert_eq(production:sub(1, at - 1) .. production:sub(at + #KeyboardSource.RELATIVE_REGISTRATION), fixture)
	end)

	helpers.it("(keyboard-source-fixture) every kernel harness builds its sources through the fixture", function()
		for _, name in ipairs(HARNESSES) do
			local file = assert(io.open(helpers.driver_root() .. "/tests/hardware/" .. name, "rb"))
			local text = file:read("*a")
			file:close()
			helpers.assert_true(text:find('require("tests.hardware.keyboard_source_writer").load(', 1, true) ~= nil,
				name .. " must create keyboard-only sources")
			helpers.assert_true(text:find('loadfile("adapters/uinput_writer.lua")', 1, true) == nil,
				name .. " still loads the pointer-capable production writer as a source")
		end
	end)
end)
