--- tests/unit/adapters/test_window_info_frontmost_application.lua

--- ==============================================================================
--- MODULE: The frontmost application is read without the accessibility API
--- DESCRIPTION:
--- Runs WindowInfo.frontmost_application and application_bundle_id against an
--- hs double whose accessibility window reads fail, as they do for a hung
--- application or one with no window.
---
--- ROOT CAUSE ENCODED:
--- The confirmation of force_quit_frontmost read the focused window through
--- the accessibility API: nil for an application with no window, and a wait
--- then nil for one that does not answer, the main reason to force quit it.
--- The application must be read from NSWorkspace, which never asks it.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body over an hs double: windows unreadable, applications by pid.
--- @param apps table pid → bundle identifier of the running applications.
--- @param front number|nil The frontmost application's pid.
--- @param body function fn(WindowInfo, reads)
local function with_applications(apps, front, body)
	local saved_application, saved_window = hs.application, hs.window
	local reads = { window = 0 }
	local function app_for(pid)
		if apps[pid] == nil then return nil end
		return {
			pid = function() return pid end,
			bundleID = function() return apps[pid] ~= false and apps[pid] or nil end,
		}
	end
	hs.window = {
		focusedWindow = function()
			reads.window = reads.window + 1
			error("AX: the application does not answer")
		end,
	}
	hs.application = {
		frontmostApplication = function() return front and app_for(front) end,
		applicationForPID = function(pid) return app_for(pid) end,
	}
	local ok, err = pcall(helpers.with_fresh_modules, { "adapters.window_info", "infra.logger" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		body(require("adapters.window_info"), reads)
	end)
	hs.application, hs.window = saved_application, saved_window
	if not ok then error(err, 0) end
end

helpers.describe("WindowInfo reads the frontmost application from NSWorkspace", function()
	helpers.it("reads a hung or windowless application (force-quit-acted-from)", function()
		with_applications({ [4242] = "com.apple.Safari" }, 4242, function(WindowInfo, reads)
			helpers.assert_eq(WindowInfo.frontmost_application(), { pid = 4242, bundle_id = "com.apple.Safari" })
			helpers.assert_eq(reads.window, 0, "no accessibility window read")
		end)
	end)

	helpers.it("returns nil without a frontmost application or a bundle identifier", function()
		with_applications({ [77] = false }, nil, function(WindowInfo)
			helpers.assert_eq(WindowInfo.frontmost_application(), nil)
		end)
		with_applications({ [77] = false }, 77, function(WindowInfo)
			helpers.assert_eq(WindowInfo.frontmost_application(), nil, "an application with no bundle identifier")
		end)
	end)

	helpers.it("names the application a pid runs, or nil once it quit", function()
		with_applications({ [4242] = "com.apple.Safari" }, nil, function(WindowInfo)
			helpers.assert_eq(WindowInfo.application_bundle_id(4242), "com.apple.Safari")
			helpers.assert_eq(WindowInfo.application_bundle_id(4243), nil)
			helpers.assert_true(not pcall(WindowInfo.application_bundle_id, "4242"), "a pid is a number")
		end)
	end)
end)
