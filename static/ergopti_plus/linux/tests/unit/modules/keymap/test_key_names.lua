--- tests/unit/modules/keymap/test_key_names.lua

--- ==============================================================================
--- MODULE: Shared Key Name Contract
--- DESCRIPTION:
--- Replays the shared key name table over the real French and English
--- catalogues: every spelling of a key reads as its human name, the platform
--- picks the usual name, and an unknown id or a missing translation raises
--- instead of showing the id.
--- ==============================================================================

local helpers = require("tests.helpers")
local KeyNames = require("keycodes.key_names")
local check = require("test.menu_row_text")

local SHARED_ROOT = "../_shared"

--- A translate function over one real catalogue; a miss returns the key, as
--- the drivers' accessors do.
--- @param locale string Locale code.
--- @return function
local function translator(locale)
	local catalogue = check.catalogue(SHARED_ROOT, locale, require("json").decode)
	return function(key)
		local text = catalogue[key]
		return (text == nil or text == "") and key or text
	end
end

helpers.describe("the shared key names", function()
	helpers.it("key names: every spelling of a key by its human name", function()
		local fr = translator("fr")
		helpers.assert_eq(KeyNames.label("left_ctrl", "windows", fr), "Ctrl gauche")
		helpers.assert_eq(KeyNames.label("LCtrl", "windows", fr), "Ctrl gauche")
		helpers.assert_eq(KeyNames.label("left_control", "macos", fr), "Ctrl gauche")
		helpers.assert_eq(KeyNames.label("right_shift", "linux", fr), "Maj droite")
		helpers.assert_eq(KeyNames.label("lalt", "windows", fr), "Alt gauche")
		helpers.assert_eq(KeyNames.label("caps_lock", "linux", fr), "Verr. Maj")
		helpers.assert_eq(KeyNames.label("RShift", "windows", translator("en")), "Right Shift")
	end)

	helpers.it("key names: each platform's usual name", function()
		local en = translator("en")
		helpers.assert_eq(KeyNames.label("alt", "macos", en), "Option")
		helpers.assert_eq(KeyNames.label("alt", "windows", en), "Alt")
		helpers.assert_eq(KeyNames.label("win", "linux", en), "Super")
		helpers.assert_eq(KeyNames.label("win", "windows", en), "Win")
	end)

	helpers.it("key names: a combination in the order written", function()
		helpers.assert_eq(KeyNames.combo_label("ctrl+shift", "linux", translator("fr")), "Ctrl + Maj")
		helpers.assert_eq(KeyNames.combo_label("lctrl + alt_gr", "windows", translator("en")), "Left Ctrl + AltGr")
	end)

	helpers.it("key names: one macOS glyph per modifier, a caret never", function()
		helpers.assert_eq(KeyNames.macos_symbol("ctrl"), "⌃")
		helpers.assert_eq(KeyNames.macos_symbol("alt"), "⌥")
		helpers.assert_eq(KeyNames.macos_symbol("option"), "⌥")
		helpers.assert_eq(KeyNames.macos_symbol("command"), "⌘")
		helpers.assert_eq(KeyNames.macos_symbol("shift"), "⇧")
		helpers.assert_eq((pcall(KeyNames.macos_symbol, "tab")), false, "a key that is no modifier")
	end)

	helpers.it("key names: a physical position by its name, never its W3C code", function()
		local fr = translator("fr")
		helpers.assert_eq(KeyNames.physical_label("KeyA", "macos", fr), "A")
		helpers.assert_eq(KeyNames.physical_label("Digit7", "linux", fr), "7")
		helpers.assert_eq(KeyNames.physical_label("F12", "linux", fr), "F12")
		helpers.assert_eq(KeyNames.physical_label("Minus", "macos", fr), "-")
		helpers.assert_eq(KeyNames.physical_label("PageUp", "linux", fr), "Page préc.")
		helpers.assert_eq(KeyNames.physical_label("Escape", "macos", fr), "Échap")
		helpers.assert_eq(KeyNames.physical_label("Numpad7", "linux", fr), "Pavé num. 7")
		helpers.assert_eq(KeyNames.physical_label("NumpadEnter", "linux", fr), "Pavé num. Entrée")
		-- Every key position a physical slot can hold reads as text in both locales.
		local registry = require("json").decode(assert(io.open(SHARED_ROOT .. "/data/keycodes/physical_keys.json")):read("*a"))
		local modifiers = { ShiftLeft = true, ShiftRight = true, ControlLeft = true, ControlRight = true,
			AltLeft = true, AltRight = true, MetaLeft = true, MetaRight = true, CapsLock = true }
		for _, locale in ipairs({ "fr", "en" }) do
			local translate = translator(locale)
			for code, record in pairs(registry.keys) do
				if record.kind == "key" and not modifiers[code] then
					local label = KeyNames.physical_label(code, "linux", translate)
					-- English names some keys as W3C does (Space, Home, F5): that is the name.
					helpers.assert_true(label ~= code or KeyNames.canonical(code) ~= nil or code:match("^F%d") ~= nil,
						code .. " reads as its code in " .. locale)
					helpers.assert_true(not label:find("key_name.", 1, true), code .. " has no " .. locale .. " text")
				end
			end
		end
	end)

	helpers.it("key names: refuse an unknown key, platform or empty text", function()
		local en = translator("en")
		helpers.assert_eq((pcall(KeyNames.label, "not_a_key", "linux", en)), false, "an unknown key")
		helpers.assert_eq((pcall(KeyNames.label, "ctrl", "amiga", en)), false, "an unknown platform")
		helpers.assert_eq((pcall(KeyNames.label, "ctrl", "linux", function() return "" end)), false,
			"an empty text")
		-- A miss reads as the dotted key, which the row walks refuse; never the id.
		helpers.assert_eq(KeyNames.label("lctrl", "linux", function(key) return key end), "key_name.left_ctrl")
		helpers.assert_eq((pcall(KeyNames.combo_label, "+", "linux", en)), false, "an empty combination")
		helpers.assert_eq(KeyNames.canonical("not_a_key"), nil)
	end)
end)
