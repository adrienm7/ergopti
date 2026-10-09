--- tests/meta/test_accessibility_checked_before_input.lua

--- ==============================================================================
--- MODULE: Accessibility is checked before the first eventtap
--- DESCRIPTION:
--- v0.0.0-dev.128 on a Mac whose onboarding was skipped (config.toml already
--- present) reached the input pre-start transaction without Accessibility trust
--- for the packaged runtime. The script-control eventtap never enabled, the
--- transaction refused, and boot died with a generic cause. Root boot cannot be
--- loaded headlessly, so this guard reads init.lua (accessibility-before-eventtaps).
---
--- Exiting with instructions then left users stuck: each ad hoc signed build
--- invalidates the grant while System Settings still shows it checked. Boot
--- now waits for the grant and runs itself again (accessibility-wait-resumes).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("root boot: Accessibility before input owners (accessibility-before-eventtaps)", function()
	local source = helpers.read_driver_unit("local function finish_boot_after_onboarding()")

	--- Returns the post-onboarding boot body and the offsets inside it.
	local function boot_body()
		helpers.assert_true(type(source) == "string" and source ~= "",
			"root init.lua must remain discoverable by its post-onboarding boot function")
		local boot_at = source:find("local function finish_boot_after_onboarding()", 1, true)
		local input_at = source:find("StartupTransaction.run({", boot_at, true)
		helpers.assert_true(boot_at ~= nil and input_at ~= nil, "boot body and first input owner must exist")
		return source:sub(boot_at, input_at), boot_at, input_at
	end

	helpers.it("settles trust before arming any eventtap and stops while untrusted", function()
		local body = boot_body()
		local query_at = body:find("AccessibilityPermission.is_trusted()", 1, true)
		local wait_at = body:find("AccessibilityWait.start({", 1, true)
		helpers.assert_true(query_at ~= nil and wait_at ~= nil and query_at < wait_at,
			"the trust query must precede the wait")
		helpers.assert_true(body:sub(wait_at):find("\n\treturn\nend", 1, true) ~= nil,
			"an untrusted boot must stop instead of falling through to the eventtaps")
		helpers.assert_true(body:find('"startup.accessibility_required")', 1, true) ~= nil,
			"a failed query or an expired wait must name the permission to the user")
	end)

	helpers.it("resumes the whole boot once trusted instead of exiting (accessibility-wait-resumes)", function()
		local body = boot_body()
		local trusted_at = body:find("on_trusted = function()", 1, true)
		helpers.assert_true(trusted_at ~= nil
			and body:find("xpcall(finish_boot_after_onboarding, debug.traceback)", trusted_at, true) ~= nil
			and body:find('emergency_exit_after_runtime_failure("boot", resumed_error)', trusted_at, true) ~= nil,
			"a granted permission must run the post-onboarding boot again under the boot guard")
		helpers.assert_true(body:find("permission = AccessibilityPermission", 1, true) ~= nil,
			"the wait must use the real permission adapter")
	end)
end)
