--- tests/unit/platform/input/test_key_names.lua

--- ==============================================================================
--- MODULE: Shared Key Name Contract
--- DESCRIPTION:
--- Replays the shared key name table over the real French and English
--- catalogues: every spelling of a key reads as its human name, the platform
--- picks the usual name, and an unknown id or a missing translation raises
--- instead of showing the id.
--- ==============================================================================

local helpers = require("tests.helpers")
local KeyNames = require("platform.input.keycodes.key_names")
local check = require("tests.lua.menu.row_text")

local SHARED_ROOT = "../_shared"

--- A translate function over one real catalogue; a miss returns the key, as
--- the drivers' accessors do.
--- @param locale string Locale code.
--- @return function
local function translator(locale)
	local catalogue = check.catalogue(SHARED_ROOT, locale, require("core.text.engine.json").decode)
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
		local registry = require("core.text.engine.json").decode(assert(io.open(SHARED_ROOT .. "/layouts/data/keycodes/physical_keys.json")):read("*a"))
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

	helpers.it("key names: a shortcut group heading names its modifiers in the user's language", function()
		local fr = translator("fr")
		-- 2026-11-03: the French headings read « Ctrl+Shift » and the macOS
		-- Option group « ⎇ Alt »; each is now its template filled from the table.
		helpers.assert_eq(KeyNames.modifiers_label({ "ctrl", "shift" }, "linux", fr), "Ctrl + Maj")
		helpers.assert_eq(KeyNames.modifiers_heading({ "ctrl", "shift" }, "linux", fr), "Ctrl + Maj")
		helpers.assert_eq(KeyNames.modifiers_heading({ "option" }, "macos", fr), "⌥ Option")
		helpers.assert_eq(KeyNames.modifiers_heading({ "cmd", "shift" }, "macos", fr), "⌘⇧ Cmd + Maj")
		helpers.assert_eq(KeyNames.fill("menu.shortcuts.ctrl_shift_group", "Ctrl + Maj", fr), "Raccourcis Ctrl + Maj")
		helpers.assert_eq(KeyNames.fill("menu.shortcuts.super_add", "Super", fr), "[+ Ajouter un raccourci Super + …]")
		helpers.assert_eq(KeyNames.fill("absent.key", "Ctrl", fr), "absent.key", "a miss reads as its dotted key")
		helpers.assert_eq((pcall(KeyNames.fill, "key_name.ctrl", "Ctrl", fr)), false, "a template without {1}")
		local Keyboard = require("modules.shortcuts.keyboard_shortcuts")
		local i18n = require("core.i18n.engine.i18n")
		local saved = i18n.get
		i18n.get = fr
		local ok, err = pcall(function()
			local seen = 0
			for _, group in ipairs(Keyboard.SLOT_GROUPS) do
				local label = Keyboard.get_group_label(group)
				helpers.assert_true(not label:find("{1}", 1, true) and not label:find("Ctrl+Shift", 1, true)
					and not label:find("❖", 1, true), "a heading reads as text: " .. label)
				if group.prefix == "primary_shift_" then
					helpers.assert_eq(label, "Raccourcis Ctrl + Maj")
					seen = seen + 1
				elseif group.prefix == "meta_" then
					helpers.assert_eq(label, "Raccourcis Super")
					seen = seen + 1
				end
			end
			helpers.assert_eq(seen, 2, "the Ctrl + Shift and Super groups are offered")
		end)
		i18n.get = saved
		if not ok then error(err, 0) end
	end)

	helpers.it("key names: a modifier chord names its keys, a legend prints as written", function()
		-- 2026-11-03: the chord rows read « Cmd + Option + Shift + Enter » in every locale.
		local fr = translator("fr")
		local enter = { id = "enter", key_name = "enter", label = "Enter" }
		helpers.assert_eq(KeyNames.chord_label({ "cmd", "option", "shift" }, enter, "macos", fr),
			"Cmd + Option + Maj + Entrée")
		helpers.assert_eq(KeyNames.chord_label({ "ctrl", "super" }, { id = "space", key_name = "space", label = "Space" },
			"linux", fr), "Ctrl + Super + Espace")
		helpers.assert_eq(KeyNames.chord_label({ "win" }, { id = "period", label = "." }, "windows", fr), "Win + .")
		helpers.assert_eq((pcall(KeyNames.chord_label, { "ctrl" }, { id = "x" }, "linux", fr)), false,
			"a key with neither key_name nor label")
		helpers.assert_eq((pcall(KeyNames.chord_label, {}, enter, "linux", fr)), false, "no modifier")
	end)

	helpers.it("key names: a sticky label names its modifiers on each platform", function()
		-- 2026-11-03: « 📌 Cmd+Shift rémanents » in every locale, swapped to Win on Windows.
		local StickyLabel = require("shortcuts.engine.actions.sticky_label")
		local fr, en = translator("fr"), translator("en")
		helpers.assert_eq(StickyLabel.label("sticky_cmd_shift", "sg_actions.sticky_cmd_shift", "macos", fr),
			"📌 Cmd + Maj rémanents")
		helpers.assert_eq(StickyLabel.label("sticky_cmd_shift", "sg_actions.sticky_cmd_shift", "windows", fr),
			"📌 Win + Maj rémanents")
		helpers.assert_eq(StickyLabel.label("sticky_option", "sg_actions.sticky_option", "macos", en), "📌 Sticky Option")
		helpers.assert_eq(StickyLabel.label("sticky_option", "sg_actions.sticky_option", "windows", en), "📌 Sticky Alt")
		helpers.assert_eq(StickyLabel.label("sticky_shift", "sg_actions.sticky_shift", "macos", fr), "📌 Maj rémanente")
		helpers.assert_eq(StickyLabel.label("sticky_hyper", "sg_actions.sticky_hyper", "macos", fr), "📌 Hyper rémanent")
		helpers.assert_eq((pcall(StickyLabel.modifiers, "sticky_fn")), false, "an unknown modifier")
		helpers.assert_eq((pcall(StickyLabel.modifiers, "copy")), false, "not a sticky action")
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
