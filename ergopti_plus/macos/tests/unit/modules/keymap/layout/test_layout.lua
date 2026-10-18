--- tests/unit/modules/keymap/layout/test_layout.lua

--- ==============================================================================
--- MODULE: layout Unit Tests
--- DESCRIPTION:
--- Verifies the keyboard layout resolver: char → physical QWERTY name and back,
--- with explicit checks for the QWERTY default fallback when hs.keycodes.map
--- is unavailable, and the Ergopti-style remap (physical "O" → "c") path.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ key_code_for_char =========
-- =====================================
-- =====================================

helpers.describe("layout.key_code_for_char", function()
	helpers.it("falls back to char itself when hs.keycodes.map is missing", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		_G.hs.keycodes.map = nil
		helpers.assert_eq(Layout.key_code_for_char("a"), "a")
	end)

	helpers.it("resolves the QWERTY name from a Carbon keycode", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		-- Direct lookup: map["a"] returns the keycode (0 for the QWERTY "A" position)
		_G.hs.keycodes.map = { ["a"] = 0 }
		helpers.assert_eq(Layout.key_code_for_char("a"), "a")
	end)

	helpers.it("resolves Ergopti-style remap (physical O = 31 produces 'c')", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		_G.hs.keycodes.map = { ["c"] = 31 }   -- Physical "o" → "c" on Ergopti
		helpers.assert_eq(Layout.key_code_for_char("c"), "o")
	end)

	helpers.it("falls back to char when keycode lookup fails", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		_G.hs.keycodes.map = {}  -- Empty map: no resolution possible
		helpers.assert_eq(Layout.key_code_for_char("z"), "z")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ char_for_key_code =========
-- =====================================
-- =====================================

helpers.describe("layout.char_for_key_code", function()
	helpers.it("falls back to qwerty_name when map missing", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		_G.hs.keycodes.map = nil
		helpers.assert_eq(Layout.char_for_key_code("a"), "a")
	end)

	helpers.it("returns char from current layout for a known QWERTY name", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		-- Numeric key 31 ("o" position on QWERTY) produces "c" on Ergopti
		_G.hs.keycodes.map = { [31] = "c" }
		helpers.assert_eq(Layout.char_for_key_code("o"), "c")
	end)

	helpers.it("falls back to qwerty_name when keycode unknown to layout", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		_G.hs.keycodes.map = {}
		helpers.assert_eq(Layout.char_for_key_code("o"), "o")
	end)

	helpers.it("falls back to qwerty_name when name is not in QWERTY table", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		_G.hs.keycodes.map = {}
		helpers.assert_eq(Layout.char_for_key_code("nonexistent_key"), "nonexistent_key")
	end)
end)

helpers.describe("layout declared keyboard convention (iso-typing-convention)", function()
	helpers.it("resolves the active installed registry declaration and refuses incomplete known entries", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		helpers.assert_eq(Layout.keyboard_form({ active = "ergopti", installed = {}, index = {
			layouts = { { id = "ergopti", keycode_convention = "iso" } },
		} }), "iso")
		helpers.assert_eq(Layout.keyboard_form({ active = "ergol", installed = {}, index = {
			layouts = { { id = "ergol", keycode_convention = "ansi" } },
		} }), "ansi")
		helpers.assert_eq(Layout.keyboard_form({ active = "ergopti_ansi", installed = {}, index = {
			layouts = { { id = "ergopti_ansi", keycode_convention = "iso" } },
		} }), "iso", "an ANSI variant name does not replace the layout's declared numbering")
		helpers.assert_eq(Layout.keyboard_form({ active = "", installed = {}, index = nil }), "ansi",
			"an unregistered source retains the existing ANSI virtual-keyboard policy")
		for _, entry in ipairs({ { id = "ergopti" }, { id = "ergopti", keycode_convention = "jis" } }) do
			helpers.assert_throws(function()
				Layout.keyboard_form({ active = "ergopti", installed = {}, index = { layouts = { entry } } })
			end, "a known layout must not silently acquire ANSI key identities")
		end
		helpers.assert_throws(function() Layout.keyboard_form({ active = "ergopti", installed = {}, index = nil }) end)
		helpers.assert_eq(Layout.keyboard_form({ active = "ergopti", installed = {
			ergopti = { id = "ergopti", keycode_convention = "iso" },
		}, index = { layouts = { { id = "ergopti", keycode_convention = "ansi" } } } }), "iso",
			"the installed layout's own metadata wins over a different catalogue revision")
	end)

	helpers.it("translates both ISO positions through ISO virtual output while leaving ANSI and ordinary keys intact", function()
		local Layout = helpers.load_with_stubs("modules.keymap.layout")
		_G.hs.keycodes.map = { ["ê"] = 50, ["$"] = 10, [50] = "ê", [10] = "$", ["c"] = 31, [31] = "c" }
		helpers.assert_eq(Layout.key_code_for_char("ê", "iso"), "non_us_backslash")
		helpers.assert_eq(Layout.key_code_for_char("$", "iso"), "grave_accent_and_tilde")
		helpers.assert_eq(Layout.char_for_key_code("non_us_backslash", "iso"), "ê")
		helpers.assert_eq(Layout.char_for_key_code("grave_accent_and_tilde", "iso"), "$")
		helpers.assert_eq(Layout.key_code_for_char("ê", "ansi"), "grave_accent_and_tilde")
		helpers.assert_eq(Layout.key_code_for_char("$", "ansi"), "non_us_backslash")
		helpers.assert_eq(Layout.char_for_key_code("non_us_backslash", "ansi"), "$")
		helpers.assert_eq(Layout.char_for_key_code("grave_accent_and_tilde", "ansi"), "ê")
		for _, form in ipairs({ "ansi", "iso" }) do
			helpers.assert_eq(Layout.key_code_for_char("c", form), "o")
			helpers.assert_eq(Layout.char_for_key_code("o", form), "c")
		end
		_G.hs.keycodes.map = { [50] = "ê", [10] = "$" }
		helpers.assert_eq(Layout.key_code_for_char("ê", "iso"), "non_us_backslash",
			"numeric-only layout maps use the same declared convention")
	end)
end)

helpers.describe("one form owns one action generation (iso-typing-convention)", function()
	helpers.it("captures the registry declaration once before resolving every logical character", function()
		helpers.with_stub_scope({ "modules.keymap.layout_registry", "modules.keymap.layout", "platform.remap.config" }, function()
			local reads = 0
			package.loaded["modules.keymap.layout_registry"] = { snapshot = function()
				reads = reads + 1
				return { active = "fixture", installed = {}, index = { layouts = {
					{ id = "fixture", keycode_convention = reads == 1 and "iso" or "ansi" },
				} } }
			end }
			_G.hs.keycodes.map = { ["ê"] = 50, ["$"] = 10 }
			local Config = require("platform.remap.config")
			local actions = { { id = "extra", logical_char = "ê" }, { id = "top", logical_char = "$" } }
			local count, form = Config.resolve_layout_actions(actions)
			helpers.assert_eq(count, 2)
			helpers.assert_eq(form, "iso")
			helpers.assert_eq(reads, 1, "one metadata snapshot must own the complete action list")
			helpers.assert_eq(actions[1].karabiner_to, { { key_code = "non_us_backslash" } })
			helpers.assert_eq(actions[2].karabiner_to, { { key_code = "grave_accent_and_tilde" } })
		end)
	end)
end)
