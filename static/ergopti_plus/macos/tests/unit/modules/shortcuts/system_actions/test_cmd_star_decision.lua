--- tests/unit/modules/shortcuts/system_actions/test_cmd_star_decision.lua

--- ==============================================================================
--- MODULE: Modifiers + Magic Key Save (macOS)
--- DESCRIPTION:
--- The shortcuts.keys.cmd_star tap sends the modifiers of a shortcut chord on
--- the layout's own magic key with S, by the three drivers' shared rule
--- (_shared/shortcuts/engine/magic_key_save_core.lua). It used to fire on Cmd
--- only, on any key typing ★, * or ✱, whatever the magic key or its source, and
--- left Ctrl+★ to the application. These cases pin the shared rule on the tap:
--- Ctrl, Cmd and their extra modifiers saved, Option (the macOS AltGr level)
--- and ★ alone left to the layout, only the layout's own magic key, a chosen
--- physical source and an owned chord kept, and each auto-repeat saving again.
--- ==============================================================================

local helpers = require("tests.helpers")
local CmdStarPorts = require("tests.support.cmd_star_ports")
local fixture = require("tests.support.system_actions_fixture")
local with_fixture = fixture.with_fixture
local physical_key_down = fixture.physical_key_down

require("tests.lua.keyboard.magic_key_save_contract")(helpers, require("core.text.engine.json"), helpers.shared(""))

--- The modifiers one decision sends, in a stable order, or false.
local function decide(flags, keycode, overrides)
	local result
	with_fixture(function()
		local system = fixture.load_h01_system().system
		local ports = CmdStarPorts.build(overrides)
		local mods = system.cmd_star_decision(flags, keycode or CmdStarPorts.MAGIC_KEYCODE, ports)
		if mods == nil then result = false return end
		table.sort(mods)
		result = table.concat(mods, "+")
	end)
	return result
end

helpers.describe("macOS modifiers + magic key save (cmd-star-decision)", function()
	helpers.it("cmd-star: Cmd and Ctrl chords keep their modifiers with S", function()
		helpers.assert_eq(decide({ cmd = true }), "cmd")
		helpers.assert_eq(decide({ cmd = true, shift = true }), "cmd+shift")
		helpers.assert_eq(decide({ ctrl = true }), "ctrl")
		helpers.assert_eq(decide({ ctrl = true, shift = true }), "ctrl+shift")
		helpers.assert_eq(decide({ cmd = true, alt = true }), "alt+cmd")
	end)

	helpers.it("cmd-star: ★ alone, Shift and Option keep the layout's level", function()
		helpers.assert_eq(decide({}), false)
		helpers.assert_eq(decide({ shift = true }), false)
		helpers.assert_eq(decide({ alt = true }), false, "Option is the AltGr layer: its character stays")
		helpers.assert_eq(decide({ alt = true, shift = true }), false)
	end)

	helpers.it("cmd-star: only the layout's own magic key saves", function()
		helpers.assert_eq(decide({ cmd = true }, 1), false, "Cmd on another key keeps its own chord")
		helpers.assert_eq(decide({ cmd = true }, nil, { plain = { [28] = "*" } }), false,
			"a * that is not the magic key no longer saves")
		helpers.assert_eq(decide({ cmd = true }, nil, { magic_key = "*", plain = { [28] = "*" } }), "cmd",
			"the magic key in effect, whatever it is")
	end)

	helpers.it("cmd-star: the magic key not replaced, a chosen source or an owned chord leave the chord", function()
		helpers.assert_eq(decide({ cmd = true }, nil, { replace_on = false }), false)
		helpers.assert_eq(decide({ cmd = true }, nil, { chosen_source = true }), false)
		helpers.assert_eq(decide({ ctrl = true }, nil, { owned = true }), false,
			"the magic editor's Ctrl+★ keeps its shortcut")
	end)

	helpers.it("cmd-star: a plain press reads no port", function()
		with_fixture(function()
			local system = fixture.load_h01_system().system
			local reads = 0
			local function count() reads = reads + 1 end
			local ports = { replace_on = count, chosen_source = count, magic_key = count, plain_text = count,
				shortcut_owns = count }
			helpers.assert_nil(system.cmd_star_decision({ shift = true }, 28, ports))
			helpers.assert_nil(system.cmd_star_decision({ alt = true }, 28, ports))
			helpers.assert_eq(reads, 0)
		end)
	end)

	helpers.it("cmd-star: the tap consumes Ctrl+Shift+★ and each auto-repeat", function()
		with_fixture(function()
			local h01 = fixture.load_h01_system()
			helpers.assert_not_nil(h01.system.bind_cmd_star(nil, nil, CmdStarPorts.build()))
			local tap = h01.hs.eventtap.__taps[#h01.hs.eventtap.__taps]
			helpers.assert_true(tap.fn(physical_key_down(h01, 28, "★", { ctrl = true, shift = true })))
			helpers.assert_true(tap.fn(physical_key_down(h01, 28, "★", { ctrl = true, shift = true })),
				"an auto-repeat keyDown saves again")
			helpers.assert_true(not tap.fn(physical_key_down(h01, 28, "★", { alt = true })),
				"Option+★ reaches the layout")
			helpers.assert_true(not tap.fn(physical_key_down(h01, 28, "★", {})), "★ alone stays the magic key")
		end)
	end)

	helpers.it("cmd-star: a caller without the ports is refused", function()
		with_fixture(function()
			local system = fixture.load_h01_system().system
			helpers.assert_throws(function() system.bind_cmd_star(nil, nil, nil) end)
		end)
	end)
end)
