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
		-- Use the checked-in fixture directory so the test is self-contained and
		-- does not depend on a real macOS build artefact being present on disk.
		local bundles_dir = helpers.fixtures_dir() .. "bundles/"
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

	helpers.it("renders the legacy com.apple.keyboardlayout.ergopti.* form via the pretty formatter", function()
		-- Ergopti entries flow through format_ergopti_display rather than
		-- plain prefix-stripping, so the user sees a friendly name in the menu
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keyboardlayout.ergopti.v2_2_0"),
			"Ergopti v2.2.0")
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





-- ====================================================
--- =====================================================
--- ======= 5/ format_ergopti_display + legacy id =======
--- =====================================================
-- ====================================================

helpers.describe("menu_keyboard_layout._format_ergopti_display", function()
	helpers.it("renders the legacy bundle id with version", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.v2_2_0"),
			"Ergopti v2.2.0")
	end)

	helpers.it("renders the plus variant", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.v2_2_0.plus"),
			"Ergopti+ v2.2.0")
	end)

	helpers.it("renders the plus_plus ANSI variant", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.v2_2_1.plus_plus.ansi"),
			"Ergopti++ ANSI v2.2.1")
	end)

	helpers.it("renders the new stable id without version suffix", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.plus"),
			"Ergopti+")
	end)

	helpers.it("returns nil for non-Ergopti identifiers", function()
		helpers.assert_nil(kbd._format_ergopti_display("com.apple.keylayout.French"))
	end)
end)

helpers.describe("menu_keyboard_layout._clean_layout_name (Ergopti pretty form)", function()
	helpers.it("uses the pretty formatter for Ergopti entries", function()
		helpers.assert_eq(
			kbd._clean_layout_name("com.apple.keyboardlayout.ergopti.v2_2_0.plus"),
			"Ergopti+ v2.2.0")
	end)

	helpers.it("falls back to plain prefix-stripping for non-Ergopti entries", function()
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keylayout.French"), "French")
	end)
end)

helpers.describe("menu_keyboard_layout._is_legacy_ergopti_id", function()
	helpers.it("matches a versioned id under the third-party namespace", function()
		helpers.assert_true(kbd._is_legacy_ergopti_id("com.apple.keyboardlayout.ergopti.v2_2_0"))
	end)

	helpers.it("matches an embedded version even without a known prefix", function()
		helpers.assert_true(kbd._is_legacy_ergopti_id("ergopti.v2_2_0"))
	end)

	helpers.it("matches the reserved-namespace form (mistakenly used in v2.2.2 betas)", function()
		helpers.assert_true(kbd._is_legacy_ergopti_id("com.apple.keylayout.ergopti"))
		helpers.assert_true(kbd._is_legacy_ergopti_id("com.apple.keylayout.ergopti.plus"))
	end)

	helpers.it("rejects the new stable third-party id", function()
		helpers.assert_true(not kbd._is_legacy_ergopti_id("com.apple.keyboardlayout.ergopti"))
		helpers.assert_true(not kbd._is_legacy_ergopti_id("com.apple.keyboardlayout.ergopti.plus"))
	end)

	helpers.it("rejects unrelated layout ids", function()
		helpers.assert_true(not kbd._is_legacy_ergopti_id("com.apple.keylayout.French"))
	end)
end)

helpers.describe("menu_keyboard_layout._migrate_legacy_id", function()
	helpers.it("strips the version segment under the third-party namespace", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.v2_2_0"),
			"com.apple.keyboardlayout.ergopti")
	end)

	helpers.it("preserves the variant suffix after the version is stripped", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.v2_2_0.plus"),
			"com.apple.keyboardlayout.ergopti.plus")
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.v2_2_1.plus_plus.ansi"),
			"com.apple.keyboardlayout.ergopti.plus_plus.ansi")
	end)

	helpers.it("lifts the reserved short namespace to the third-party one", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keylayout.ergopti.plus"),
			"com.apple.keyboardlayout.ergopti.plus")
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keylayout.ergopti"),
			"com.apple.keyboardlayout.ergopti")
	end)

	helpers.it("is a no-op on already-stable third-party ids", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.plus"),
			"com.apple.keyboardlayout.ergopti.plus")
	end)
end)
