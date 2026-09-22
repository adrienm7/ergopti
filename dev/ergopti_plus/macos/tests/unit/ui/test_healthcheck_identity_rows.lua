--- tests/unit/ui/test_healthcheck_identity_rows.lua

--- ==============================================================================
--- MODULE: Healthcheck identity rows (macOS)
--- DESCRIPTION:
--- The packaged app's System diagnostics showed the nested Hammerspoon's own
--- version (1.1.1) as the ErgoptiPlus version, a "?" DPI in front of the known
--- Retina scale, and called the bundle directory "Script dir". The version now
--- comes from the About menu's owner, an unknown DPI leaves the scale alone,
--- and the bundle directory is the "App dir".
--- ==============================================================================

local helpers = require("tests.helpers")

local LAUNCHER_VERSION = "0.0.0-dev.131"

--- Runs body with the real healthcheck core over a stubbed collector set.
--- @param sys table What sys_info returns.
--- @param body function Receives (core).
local function with_healthcheck(sys, body)
	local saved, prior_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, err = xpcall(function()
		helpers.load_with_stubs("infra.logger")
		local logger = helpers.make_logger_stub()
		logger.ring_buffer_snapshot = function() return {} end
		package.loaded["infra.logger"] = logger
		package.loaded["modules.updater"] = { current_version = function() return LAUNCHER_VERSION end }
		package.loaded["ui.healthcheck.core"] = nil
		package.loaded["ui.healthcheck.helpers"] = nil
		local H = require("ui.healthcheck.helpers")
		for name, value in pairs(H) do
			if type(value) == "function" and name ~= "format_uptime" then
				H[name] = function() return {} end
			end
		end
		H.sys_info = function() return sys end
		hs.processInfo = { version = "1.1.1", bundleID = "com.ergoptiplus.app.hammerspoon" }
		body(require("ui.healthcheck.core"))
	end, debug.traceback)
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("healthcheck: macOS identity rows", function()
	helpers.it("reports the ErgoptiPlus version, not Hammerspoon's", function()
		with_healthcheck({ hs_version = "1.1.1" }, function(core)
			local snapshot = core.run()
			helpers.assert_eq(snapshot.version, LAUNCHER_VERSION)
			local text = core.format_plain(snapshot)
			helpers.assert_true(text:find("Version          : " .. LAUNCHER_VERSION, 1, true) ~= nil, text)
		end)
	end)

	helpers.it("shows the Retina scale alone when the DPI is unknown", function()
		with_healthcheck({ retina_scale = "2.0×" }, function(core)
			local text = core.format_plain(core.run())
			helpers.assert_true(text:find("DPI              : 2.0× Retina", 1, true) ~= nil, text)
			helpers.assert_nil(text:find("DPI              : ?", 1, true), "an unknown DPI must not print '?'")
		end)
	end)

	helpers.it("names the bundle directory App dir", function()
		with_healthcheck({ script_dir = "/Applications/ErgoptiPlus.app/Contents/Resources" }, function(core)
			local text = core.format_plain(core.run())
			helpers.assert_true(text:find("App dir          : /Applications/ErgoptiPlus.app", 1, true) ~= nil, text)
			helpers.assert_nil(text:find("Script dir", 1, true), "the packaged app has no script dir")
		end)
	end)
end)
