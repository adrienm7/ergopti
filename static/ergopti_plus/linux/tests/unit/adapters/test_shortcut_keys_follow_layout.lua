--- tests/unit/adapters/test_shortcut_keys_follow_layout.lua

--- ==============================================================================
--- MODULE: Shortcut Chords Press The Key The Layout Puts The Letter On
--- DESCRIPTION:
--- Applications match Ctrl+V by the symbol a key produces. The clipboard
--- fallback pressed KEY_V (evdev 47) and the gesture emitter KEY_W (evdev 17)
--- whatever the layout: on Ergopti evdev 47 types a comma, so the clipboard
--- fallback pressed Ctrl+comma and reported the expansion delivered; on AZERTY
--- evdev 17 types z, so "close the tab" was Ctrl+Z, undo.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Two layouts, as the injection table models them: letter → unmodified key.
local AZERTY = { w = { keycode = 44, level = 1, mods = {} }, v = { keycode = 47, level = 1, mods = {} } }
local ERGOPTI = { v = { keycode = 22, level = 1, mods = {} }, [","] = { keycode = 47, level = 1, mods = {} } }

--- Loads keyboard_layout with a given table.
local function with_layout(built)
	local Layout = helpers.load_module("adapters.keyboard_layout")
	Layout._set_table_for_test(built)
	return Layout
end

helpers.describe("shortcut keys: the live layout decides the key", function()

	helpers.it("resolves ctrl+w to AZERTY's w key, not KEY_W (which is z there)", function()
		with_layout(AZERTY)
		local Emitter = helpers.load_module("modules.gestures.combo_emitter")
		local parsed = Emitter.parse("ctrl+w")
		helpers.assert_eq(parsed.keys, { 44 }, "Ctrl+KEY_W is Ctrl+Z (undo) on AZERTY")
		helpers.assert_eq(parsed.mods, { 29 })
	end)

	helpers.it("pastes with the key that types v on Ergopti", function()
		with_layout(ERGOPTI)
		local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		package.loaded["adapters.shell_runner"] = {
			has_command = function() return true end,
			exec = function() return "before" end,
			exec_checked = function() return true, "before", nil end,
			with_exact_stdin = function(command) return command end,
			run = function() return true end,
		}
		package.loaded["infra.display_server"] = {
			UNKNOWN = "unknown",
			is_wayland = function() return false end,
			is_x11 = function() return true end,
			kind = function() return "x11" end,
		}
		package.loaded["adapters.clipboard"] = nil
		local emitted = {}
		local channel = { emit = function(code, value)
			emitted[#emitted + 1] = { code = code, value = value }
			return true
		end }
		local ok, err = pcall(function()
			require("adapters.clipboard").paste_text("é", channel, function() end)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(emitted[2], { code = 22, value = 1 },
			"on Ergopti evdev 47 types a comma: Ctrl+47 pastes nothing")
	end)

	helpers.it("presses the key and level that type a period on AZERTY, not KEY_DOT (shortcut-level)", function()
		-- On AZERTY "." is Shift+KEY_COMMA and KEY_DOT types ":": Ctrl+KEY_DOT
		-- was Ctrl+colon to every application.
		local Layout = with_layout({
			["."] = { keycode = 51, level = 2, mods = { "shift" } },
			[","] = { keycode = 50, level = 1, mods = {} },
			["1"] = { keycode = 2, level = 2, mods = { "shift" } },
			[";"] = { keycode = 40, level = 3, mods = { "altgr" } },
		})
		local code, level_mods = Layout.shortcut_keycode(".", 52)
		helpers.assert_eq({ code, level_mods }, { 51, { 42 } }, "Shift+KEY_COMMA types the period")
		code, level_mods = Layout.shortcut_keycode(";", 39)
		helpers.assert_eq({ code, level_mods }, { 40, { 100 } }, "AltGr selects level 3 on the virtual keyboard")
		code, level_mods = Layout.shortcut_keycode("1", 2)
		helpers.assert_eq({ code, level_mods }, { 2, {} },
			"a digit on its own US key stays that key: toolkits read Ctrl+KEY_1 as Ctrl+1")
		local Emitter = helpers.load_module("modules.gestures.combo_emitter")
		helpers.assert_eq(Emitter.parse("ctrl+period"), { mods = { 29, 42 }, keys = { 51 } })
		helpers.assert_eq(Emitter.parse("ctrl+shift+period"), { mods = { 29, 42 }, keys = { 51 } },
			"a Shift the chord already holds is not pressed twice")
		helpers.assert_eq(Emitter.parse("ctrl+comma"), { mods = { 29 }, keys = { 50 } })
	end)

	helpers.it("keeps the US key for a letter the layout has no plain key for", function()
		-- GTK and Qt fall back to the US position for shortcuts on a non-Latin
		-- layout, so that is the right key when the layout has no plain "c".
		local Layout = with_layout({ ["с"] = { keycode = 46, level = 1, mods = {} } })
		helpers.assert_eq(Layout.shortcut_keycode("c", 46), 46)
		local shifted = with_layout({ v = { keycode = 30, level = 2, mods = { "shift" } } })
		helpers.assert_eq(shifted.shortcut_keycode("v", 47), 47,
			"a letter reachable only with Shift is not what Ctrl+letter presses")
	end)

end)
