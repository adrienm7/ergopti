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
