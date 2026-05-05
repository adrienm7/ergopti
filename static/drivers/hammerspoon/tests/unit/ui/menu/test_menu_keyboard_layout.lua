--- tests/unit/ui/menu/test_menu_keyboard_layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Menu Unit Tests
--- DESCRIPTION:
--- Validates the pure-Lua bundle version picker exposed by
--- ui.menu.menu_keyboard_layout. The real submenu builder is macOS-only
--- (depends on hs.execute / hs.osascript), so we only exercise the helpers
--- safe to run cross-platform.
--- ==============================================================================

local helpers = require("tests.helpers")
local kbd     = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")

helpers.describe("menu_keyboard_layout._parse_version", function()
	helpers.it("parses a standard 'Ergopti_v2.2.1.bundle' name", function()
		local v = kbd._parse_version("Ergopti_v2.2.1.bundle")
		helpers.assert_true(type(v) == "table" and #v == 3)
		helpers.assert_eq(v[1], 2) ; helpers.assert_eq(v[2], 2) ; helpers.assert_eq(v[3], 1)
	end)

	helpers.it("returns nil on names without the expected suffix", function()
		helpers.assert_nil(kbd._parse_version("Ergopti.bundle"))
		helpers.assert_nil(kbd._parse_version("random.txt"))
	end)
end)

helpers.describe("menu_keyboard_layout._version_gt", function()
	helpers.it("orders 2.2.1 above 2.2.0", function()
		helpers.assert_true(kbd._version_gt({2,2,1}, {2,2,0}))
		helpers.assert_true(not kbd._version_gt({2,2,0}, {2,2,1}))
	end)

	helpers.it("treats missing components as zero", function()
		helpers.assert_true(kbd._version_gt({3}, {2,9,9}))
		helpers.assert_true(not kbd._version_gt({1,0}, {1,0,0}))
	end)
end)

helpers.describe("menu_keyboard_layout.pick_latest_bundle", function()
	helpers.it("returns the highest version present in the bundles directory", function()
		-- The repository ships with at least 2.2.0 and 2.2.1 — verify the picker
		-- selects the highest one. We resolve the directory relative to the
		-- driver root so the test is location-independent.
		local driver_root = helpers.driver_root()
		local bundles_dir = driver_root .. "../macos/bundles/"
		local latest = kbd.pick_latest_bundle(bundles_dir)
		helpers.assert_true(type(latest) == "string" and latest:match("^Ergopti_v[%d%.]+%.bundle$") ~= nil,
			"expected a bundle name, got " .. tostring(latest))
		-- Whatever the exact version on disk, it must be >= 2.2.1
		local v = kbd._parse_version(latest)
		helpers.assert_true(kbd._version_gt(v, {2,2,0}) or (v[1]==2 and v[2]==2 and v[3]==1))
	end)

	helpers.it("returns nil when the directory has no Ergopti bundles", function()
		helpers.assert_nil(kbd.pick_latest_bundle("/no/such/dir/here/"))
	end)
end)




-- ====================================================
-- ====================================================
-- ======= 4/ Display & version-extraction helpers ====
-- ====================================================
-- ====================================================

helpers.describe("menu_keyboard_layout._clean_layout_name", function()
	helpers.it("strips the standard com.apple.keylayout. prefix", function()
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keylayout.French"), "French")
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keylayout.US"), "US")
	end)

	helpers.it("strips the legacy com.apple.keyboardlayout. prefix", function()
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keyboardlayout.ergopti.v2_2_0"),
			"ergopti.v2_2_0")
	end)

	helpers.it("strips com.apple.inputmethod. and inputsource. prefixes", function()
		helpers.assert_eq(kbd._clean_layout_name("com.apple.inputmethod.SCIM.ITABC"), "SCIM.ITABC")
		helpers.assert_eq(kbd._clean_layout_name("com.apple.inputsource.foo"), "foo")
	end)

	helpers.it("returns the input verbatim when no Apple prefix is present", function()
		helpers.assert_eq(kbd._clean_layout_name("Ergopti"), "Ergopti")
	end)

	helpers.it("coerces non-string input safely", function()
		helpers.assert_eq(kbd._clean_layout_name(nil), "nil")
		helpers.assert_eq(kbd._clean_layout_name(42), "42")
	end)
end)

helpers.describe("menu_keyboard_layout._extract_ergopti_version", function()
	helpers.it("extracts v2_2_0 from the legacy underscore form", function()
		local v = kbd._extract_ergopti_version("com.apple.keyboardlayout.ergopti.v2_2_0")
		helpers.assert_eq(v[1], 2) ; helpers.assert_eq(v[2], 2) ; helpers.assert_eq(v[3], 0)
	end)

	helpers.it("extracts v2.2.1 from the dotted form", function()
		local v = kbd._extract_ergopti_version("com.apple.keylayout.ergopti.v2.2.1")
		helpers.assert_eq(v[1], 2) ; helpers.assert_eq(v[2], 2) ; helpers.assert_eq(v[3], 1)
	end)

	helpers.it("zero-fills missing minor / patch components", function()
		local v1 = kbd._extract_ergopti_version("ergopti_v2.2")
		helpers.assert_eq(v1[3], 0)
		local v2 = kbd._extract_ergopti_version("ergopti.v3")
		helpers.assert_eq(v2[1], 3) ; helpers.assert_eq(v2[2], 0) ; helpers.assert_eq(v2[3], 0)
	end)

	helpers.it("returns a zeroed tuple for unversioned ergopti ids", function()
		local v = kbd._extract_ergopti_version("com.apple.keylayout.ergopti")
		helpers.assert_eq(v[1], 0) ; helpers.assert_eq(v[2], 0) ; helpers.assert_eq(v[3], 0)
	end)

	helpers.it("returns nil when the name is unrelated to Ergopti", function()
		helpers.assert_nil(kbd._extract_ergopti_version("com.apple.keylayout.French"))
	end)
end)

helpers.describe("menu_keyboard_layout._version_str", function()
	helpers.it("renders {2,2,1} as '2.2.1'", function()
		helpers.assert_eq(kbd._version_str({2,2,1}), "2.2.1")
	end)
	helpers.it("preserves single-component input", function()
		helpers.assert_eq(kbd._version_str({3}), "3")
	end)
end)
