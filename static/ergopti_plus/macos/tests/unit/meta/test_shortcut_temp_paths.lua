--- tests/unit/meta/test_shortcut_temp_paths.lua

--- ==============================================================================
--- MODULE: Shortcut Temporary-Path Ratchet
--- DESCRIPTION:
--- Predictable process-wide /tmp names let another process pre-create a symlink
--- before a shortcut writes or captures. The behavioral owner tests prove the
--- argv boundaries; this ratchet prevents a fixed /tmp/_hs_* literal from being
--- reintroduced at a sibling shortcut site.
--- ==============================================================================

local helpers = require("tests.helpers")


local function contains_predictable_hs_tmp(source)
	return type(source) == "string" and source:find("/tmp/_hs_", 1, true) ~= nil
end


helpers.describe("shortcut subprocesses never use predictable /tmp names", function()
	helpers.it("rejects the legacy literal across mouse and pixel actions", function()
		local mouse_source = helpers.read_driver_source("toggle_display_mirror")
		local pixel_source = helpers.read_driver_source("pixel_hex_at")
		helpers.assert_type(mouse_source, "string")
		helpers.assert_type(pixel_source, "string")
		helpers.assert_true(contains_predictable_hs_tmp("local p = '/tmp/_hs_probe'"),
			"the ratchet must detect the original fixed-name class")
		helpers.assert_eq(contains_predictable_hs_tmp(mouse_source), false)
		helpers.assert_eq(contains_predictable_hs_tmp(pixel_source), false)
	end)
end)
