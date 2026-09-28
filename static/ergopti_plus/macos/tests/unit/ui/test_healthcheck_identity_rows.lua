--- tests/unit/ui/test_healthcheck_identity_rows.lua

--- ==============================================================================
--- MODULE: Healthcheck identity rows (macOS)
--- DESCRIPTION:
--- The packaged app's diagnostics showed the nested Hammerspoon's own version
--- (1.1.1) as the ErgoptiPlus version, and called the bundle directory
--- "Script dir". The version now comes from the About menu's owner, the
--- runtime is named as Hammerspoon's, and the bundle directory is the app dir.
--- ==============================================================================

local helpers = require("tests.helpers")

local LAUNCHER_VERSION = "0.0.0-dev.131"
local BUNDLE = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos"

--- Runs body with the real collectors over a packaged app's runtime.
--- @param body function Receives (H).
local function with_collectors(body)
	helpers.with_stub_scope({
		"infra.logger", "ui.healthcheck.helpers", "modules.updater", "adapters.system_info",
	}, function()
		helpers.load_with_stubs("infra.logger", { configdir = BUNDLE })
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.updater"] = {
			current_version = function() return LAUNCHER_VERSION end,
			installed_channel = function() return "main" end,
		}
		package.loaded["adapters.system_info"] = {
			runtime_version = function() return "1.1.1" end,
		}
		package.loaded["ui.healthcheck.helpers"] = nil
		body(require("ui.healthcheck.helpers"))
	end)
end

helpers.describe("healthcheck: macOS identity rows", function()
	helpers.it("reports the ErgoptiPlus version, and Hammerspoon's only as the runtime", function()
		with_collectors(function(H)
			local versions = H.collect_versions()
			helpers.assert_eq(versions.ergopti_version, LAUNCHER_VERSION)
			helpers.assert_eq(versions.runtime, "Hammerspoon 1.1.1")
			helpers.assert_eq(versions.channel, "main")
		end)
	end)

	helpers.it("reports the bundle directory as the app dir", function()
		with_collectors(function(H)
			helpers.assert_eq(H.collect_paths("diagnostics").app_dir, BUNDLE)
		end)
	end)
end)
