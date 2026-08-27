--- tests/unit/modules/updater/test_updater_packaged_identity.lua

--- ==============================================================================
--- MODULE: Packaged updater identity regression
--- DESCRIPTION:
--- Proves the updater reads the launcher version while running inside the exact
--- nested Hammerspoon bundle produced by the macOS packaging script.
--- ==============================================================================

local helpers = require("tests.helpers")

local OUTER_BUNDLE_ID = "com.ergoptiplus.app"
local INNER_BUNDLE_ID = "com.ergoptiplus.app.hammerspoon"
local OUTER_VERSION = "0.0.0-dev.117"

helpers.describe("updater: packaged launcher identity", function()
	helpers.it("recognises the nested runtime and uses the outer launcher version", function()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "ERGOPTI_LAUNCHER_BUNDLE_ID" then return OUTER_BUNDLE_ID end
			if name == "ERGOPTI_LAUNCHER_VERSION" then return OUTER_VERSION end
			return real_getenv(name)
		end

		local ok, failure = xpcall(function()
			package.loaded["modules.updater"] = nil
			local updater = helpers.load_with_stubs("modules.updater", {
				processInfo = { bundleID = INNER_BUNDLE_ID, version = "1.1.1" },
			})
			helpers.assert_true(not updater.is_local_source(),
				"the packaged nested Hammerspoon process must enable updater controls")
			helpers.assert_eq(updater.current_version(), OUTER_VERSION,
				"release comparison must use the outer ErgoptiPlus version")
			helpers.assert_eq(updater.default_channel(), "dev",
				"a packaged prerelease must select the prerelease feed")
		end, debug.traceback)

		os.getenv = real_getenv
		if not ok then error(failure, 0) end
	end)

	helpers.it("keeps stable launcher versions on the stable channel", function()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "ERGOPTI_LAUNCHER_VERSION" then return "1.2.3" end
			return real_getenv(name)
		end

		local ok, failure = xpcall(function()
			package.loaded["modules.updater"] = nil
			local updater = helpers.load_with_stubs("modules.updater", {
				processInfo = { bundleID = INNER_BUNDLE_ID, version = "1.1.1" },
			})
			helpers.assert_eq(updater.default_channel(), "main")
		end, debug.traceback)

		os.getenv = real_getenv
		if not ok then error(failure, 0) end
	end)
end)
