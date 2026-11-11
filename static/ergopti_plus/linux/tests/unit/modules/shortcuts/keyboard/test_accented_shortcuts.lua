--- tests/unit/modules/shortcuts/keyboard/test_accented_shortcuts.lua

--- ==============================================================================
--- MODULE: Accented-Letter Shortcuts (Linux)
--- DESCRIPTION:
--- Windows remaps Ctrl, Alt and Win (+ Shift) on a key that types è, ê, é or
--- à directly to the chord on a chosen letter, so Ctrl+é acts as Ctrl+C on
--- AZERTY or an installed Ergopti layout. Linux had no equivalent; these tests
--- pin the same contract: layout-driven, AltGr left alone, digit-row keys left
--- as digits while the row types digits first, and the setting read from
--- config.toml at the press.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox

-- AZERTY's plain presses on four keys: KEY_2 types é, KEY_7 è, KEY_0 à, KEY_Q a.
local BASE = { [3] = { text = "é" }, [8] = { text = "è" }, [11] = { text = "à" }, [16] = { text = "a" },
	[26] = { text = "^", dead = true } }

local ENABLED = {
	e_grave = { enabled = true, letter = "z" }, e_circ = { enabled = true, letter = "x" },
	e_acute = { enabled = true, letter = "c" }, a_grave = { enabled = true, letter = "v" },
}

local function ports(row_mode, settings)
	return {
		base_symbol = function(code) return BASE[code] end,
		number_row_mode = function() return row_mode or "native" end,
		settings = function() return settings or ENABLED end,
	}
end

local function fresh()
	package.loaded["modules.shortcuts.accented_shortcuts"] = nil
	return require("modules.shortcuts.accented_shortcuts")
end

helpers.describe("linux accented-letter shortcuts (linux-accented-shortcuts)", function()
	helpers.it("accented-shortcut: Ctrl, Alt and Super on a direct accented key become the letter's chord", function()
		local Accented = fresh()
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { ctrl = true } }, ports()), "ctrl+c")
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { ctrl = true, shift = true } }, ports()), "ctrl+shift+c")
		helpers.assert_eq(Accented.combo_for({ code = 8, value = 1, mods = { alt = true } }, ports()), "alt+z")
		helpers.assert_eq(Accented.combo_for({ code = 11, value = 1, mods = { meta = true } }, ports()), "super+v")
	end)

	helpers.it("accented-shortcut: AltGr, a bare key, a plain letter and a dead key stay the application's", function()
		local Accented = fresh()
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { altgr = true } }, ports()), nil)
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { ctrl = true, altgr = true } }, ports()), nil)
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { shift = true } }, ports()), nil)
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = {} }, ports()), nil)
		helpers.assert_eq(Accented.combo_for({ code = 16, value = 1, mods = { ctrl = true } }, ports()), nil)
		helpers.assert_eq(Accented.combo_for({ code = 26, value = 1, mods = { ctrl = true } }, ports()), nil)
	end)

	helpers.it("accented-shortcut: a digit-row key stays a digit while the row types digits first", function()
		local Accented = fresh()
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { ctrl = true } }, ports("digits")), nil)
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { ctrl = true } }, ports("symbols")), "ctrl+c")
	end)

	helpers.it("accented-shortcut: a letter switched off is left to the application", function()
		local Accented = fresh()
		local settings = { e_grave = ENABLED.e_grave, e_circ = ENABLED.e_circ, a_grave = ENABLED.a_grave,
			e_acute = { enabled = false, letter = "c" } }
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { ctrl = true } }, ports(nil, settings)), nil)
		local unreadable = ports()
		unreadable.settings = function() return nil end
		helpers.assert_eq(Accented.combo_for({ code = 3, value = 1, mods = { ctrl = true } }, unreadable), nil,
			"an unreadable configuration consumes nothing")
	end)

	helpers.it("accented-shortcut: the press is consumed and the chord pressed on the next tick", function()
		local Accented = fresh()
		local queued, pressed, active = {}, {}, true
		local options = {
			active = function() return active end,
			defer = function(fn) queued[#queued + 1] = fn return true end,
			press = function(combo) pressed[#pressed + 1] = combo return true end,
		}
		for key, port in pairs(ports()) do options[key] = port end
		helpers.assert_eq(Accented.on_key({ code = 3, value = 1, mods = { ctrl = true } }, options), true)
		helpers.assert_eq(#pressed, 0, "nothing is pressed inside the consumption callback")
		queued[1]()
		helpers.assert_eq(pressed, { "ctrl+c" })
		active = false
		helpers.assert_eq(Accented.on_key({ code = 3, value = 1, mods = { ctrl = true } }, options), false,
			"paused, or the Shortcuts master off: the key goes to the application")
	end)

	-- AHK's ^SCxxx hotkeys fire on every auto-repeat: holding Ctrl+è undoes
	-- repeatedly on Windows. Linux consumed the press with no repeat owner, so
	-- the hook swallowed every repeat and the chord fired once (SCL-001,
	-- accented-shortcut-repeat).
	helpers.it("accented-shortcut: each auto-repeat presses the chord again (accented-shortcut-repeat)", function()
		local Accented = fresh()
		local queued, pressed, active = {}, {}, true
		local options = {
			active = function() return active end,
			defer = function(fn) queued[#queued + 1] = fn return true end,
			press = function(combo) pressed[#pressed + 1] = combo return true end,
		}
		for key, port in pairs(ports()) do options[key] = port end
		local consumed, repeat_callback = Accented.on_key({ code = 8, value = 1, mods = { ctrl = true } }, options)
		helpers.assert_eq(consumed, true)
		helpers.assert_type(repeat_callback, "function", "the held chord owns its repeats")
		helpers.assert_eq(repeat_callback({ code = 8, value = 2, mods = { ctrl = true } }), true)
		helpers.assert_eq(repeat_callback({ code = 8, value = 2, mods = { ctrl = true, shift = true } }), true)
		for _, fn in ipairs(queued) do fn() end
		helpers.assert_eq(pressed, { "ctrl+z", "ctrl+z", "ctrl+shift+z" }, "one press per repeat, held modifiers read live")
		helpers.assert_eq(repeat_callback({ code = 3, value = 2, mods = { ctrl = true } }), false,
			"another key's repeat is not its own")
		active = false
		helpers.assert_eq(repeat_callback({ code = 8, value = 2, mods = { ctrl = true } }), false,
			"paused mid-hold: the repeats go to the application")
	end)

	helpers.it("accented-shortcut: the settings are config.toml's, over the manifest defaults", function()
		local path = os.tmpname()
		local saved = package.loaded["infra.config_paths"]
		package.loaded["infra.config_paths"] = { config = function() return path end }
		local ok, err = pcall(function()
			Sandbox.write_bytes(path, "")
			local Accented = fresh()
			local defaults = Accented.settings()
			helpers.assert_eq(defaults.e_acute, { enabled = false, letter = "c" }, "the manifest default is off")
			helpers.assert_eq(Accented.set("e_acute", "q"), true)
			helpers.assert_eq(Accented.settings().e_acute, { enabled = true, letter = "q" })
			helpers.assert_eq(Accented.set("e_acute", nil), true)
			helpers.assert_eq(Accented.settings().e_acute, { enabled = false, letter = "q" }, "off keeps the letter")
			helpers.assert_eq(Accented.set("e_acute", "Q"), false, "a letter outside a-z is refused")
			local marked = {}
			Accented.mark_config_reads({ shortcuts = { e_acute = { enabled = true, letter = "Q" } } },
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(marked, { "shortcuts.e_acute.enabled" }, "an outdated letter is left for the cleanup")
		end)
		package.loaded["infra.config_paths"] = saved
		os.remove(path)
		if not ok then error(err, 0) end
	end)
end)
