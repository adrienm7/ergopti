--- tests/unit/lib/test_layout.lua

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
		local Layout = helpers.load_with_stubs("lib.layout")
		_G.hs.keycodes.map = nil
		helpers.assert_eq(Layout.key_code_for_char("a"), "a")
	end)

	helpers.it("resolves the QWERTY name from a Carbon keycode", function()
		local Layout = helpers.load_with_stubs("lib.layout")
		-- Direct lookup: map["a"] returns the keycode (0 for the QWERTY "A" position)
		_G.hs.keycodes.map = { ["a"] = 0 }
		helpers.assert_eq(Layout.key_code_for_char("a"), "a")
	end)

	helpers.it("resolves Ergopti-style remap (physical O = 31 produces 'c')", function()
		local Layout = helpers.load_with_stubs("lib.layout")
		_G.hs.keycodes.map = { ["c"] = 31 }   -- Physical "o" → "c" on Ergopti
		helpers.assert_eq(Layout.key_code_for_char("c"), "o")
	end)

	helpers.it("falls back to char when keycode lookup fails", function()
		local Layout = helpers.load_with_stubs("lib.layout")
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
		local Layout = helpers.load_with_stubs("lib.layout")
		_G.hs.keycodes.map = nil
		helpers.assert_eq(Layout.char_for_key_code("a"), "a")
	end)

	helpers.it("returns char from current layout for a known QWERTY name", function()
		local Layout = helpers.load_with_stubs("lib.layout")
		-- Numeric key 31 ("o" position on QWERTY) produces "c" on Ergopti
		_G.hs.keycodes.map = { [31] = "c" }
		helpers.assert_eq(Layout.char_for_key_code("o"), "c")
	end)

	helpers.it("falls back to qwerty_name when keycode unknown to layout", function()
		local Layout = helpers.load_with_stubs("lib.layout")
		_G.hs.keycodes.map = {}
		helpers.assert_eq(Layout.char_for_key_code("o"), "o")
	end)

	helpers.it("falls back to qwerty_name when name is not in QWERTY table", function()
		local Layout = helpers.load_with_stubs("lib.layout")
		_G.hs.keycodes.map = {}
		helpers.assert_eq(Layout.char_for_key_code("nonexistent_key"), "nonexistent_key")
	end)
end)
