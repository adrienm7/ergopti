--- tests/unit/platform/remap/test_watcher_operational_results.lua

--- ==============================================================================
--- MODULE: Remap watcher operational-result guards
--- DESCRIPTION:
--- Pins two false-success shapes at the user-triggered remap boundary: the input
--- layout fallback must call currentLayout only once under protection, and direct
--- previous-app switching must continue through every false launch/focus result.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================
-- ===========================================================
-- ======= 1/ Layout and Activation Result Guards =============
-- ===========================================================
-- ===========================================================

helpers.describe("remap watchers: operational return values are authoritative", function()
	helpers.it("never re-invokes currentLayout outside its protected read", function()
		local src, err = helpers.read_driver_unit("local function parse_layout_name")
		helpers.assert_true(src ~= nil, "watchers source must be reachable: " .. tostring(err))
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("pcall(function() return hs.keycodes.currentLayout() end) and hs.keycodes.currentLayout()", 1, true) == nil,
			"the second unprotected call can throw after the first protected call succeeded")
		local _, count = code:gsub("read_current_layout_safe%(%)", "")
		helpers.assert_true(count >= 2,
			"both initial seeding and the input-source callback must use the one-shot helper")
	end)

	helpers.it("checks every previous-app launch and activation result", function()
		local src, err = helpers.read_driver_unit("local function focus_previous_app_direct()")
		helpers.assert_true(src ~= nil, "watchers source must be reachable: " .. tostring(err))
		local at = src:find("local function focus_previous_app_direct()", 1, true)
		local body = src:sub(at, at + 1500):gsub("%-%-[^\n]*", "")
		helpers.assert_true(body:find("local ok, result = pcall", 1, true) ~= nil,
			"launch fallbacks must inspect both pcall status and the native result")
		helpers.assert_true(body:find("ok and result == true", 1, true) ~= nil,
			"a false launch result must fall through to the next strategy")
		helpers.assert_true(body:find("target:activate()", 1, true) ~= nil
			and body:find("activate_result == true", 1, true) ~= nil,
			"the final application-object fallback must also honour false")
	end)
end)
