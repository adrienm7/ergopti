--- static/ergopti_plus/macos/tests/unit/core/process/test_app_launcher_bundle_id.lua
--- Verifies the distinct Hammerspoon name and bundle-ID launch APIs.
local helpers = require("tests.helpers")

helpers.describe("application bundle launch", function()
	helpers.it("does not relaunch by bundle after a successful name launch", function()
		local bundle_calls = 0
		local launcher = helpers.load_with_stubs("adapters.app_launcher", {
			application = {
				launchOrFocus = function() return true end,
				launchOrFocusByBundleID = function() bundle_calls = bundle_calls + 1; return true end,
			},
		})
		helpers.assert_eq(launcher.launch("Safari"), true)
		helpers.assert_eq(bundle_calls, 0)
	end)

	helpers.it("falls back to the native bundle lookup after name refusal", function()
		local names, bundles = {}, {}
		local launcher = helpers.load_with_stubs("adapters.app_launcher", {
			application = {
				launchOrFocus = function(name) names[#names + 1] = name; return false end,
				launchOrFocusByBundleID = function(id) bundles[#bundles + 1] = id; return id == "com.example.app" end,
			},
		})
		helpers.assert_eq(launcher.launch("com.example.app"), true)
		helpers.assert_eq(names, { "com.example.app" })
		helpers.assert_eq(bundles, { "com.example.app" })
	end)
end)
