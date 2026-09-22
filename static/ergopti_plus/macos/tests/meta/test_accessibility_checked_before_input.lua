--- tests/meta/test_accessibility_checked_before_input.lua

--- ==============================================================================
--- MODULE: Accessibility is checked before the first eventtap
--- DESCRIPTION:
--- v0.0.0-dev.128 on a Mac whose onboarding was skipped (config.toml already
--- present) reached the input pre-start transaction without Accessibility trust
--- for the packaged runtime. The script-control eventtap never enabled, the
--- transaction refused, and boot died with a generic cause. Root boot cannot be
--- loaded headlessly, so this guard reads init.lua (accessibility-before-eventtaps).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("root boot: Accessibility before input owners (accessibility-before-eventtaps)", function()
	helpers.it("checks trust, prompts and names the stage before arming any eventtap", function()
		local source = helpers.read_driver_unit("local function finish_boot_after_onboarding()")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"root init.lua must remain discoverable by its post-onboarding boot function")
		local boot_at = source:find("local function finish_boot_after_onboarding()", 1, true)
		local query_at = source:find("AccessibilityPermission.is_trusted()", boot_at, true)
		local prompt_at = source:find("AccessibilityPermission.request_prompt()", boot_at, true)
		local refusal_at = source:find('emergency_exit_after_runtime_failure("accessibility",', boot_at, true)
		local key_at = source:find('"startup.accessibility_required")', boot_at, true)
		local input_at = source:find("StartupTransaction.run({", boot_at, true)
		helpers.assert_true(query_at ~= nil and prompt_at ~= nil and refusal_at ~= nil
			and key_at ~= nil and input_at ~= nil,
			"trust query, prompt, named refusal, localized message and input start must exist")
		helpers.assert_true(query_at < prompt_at and prompt_at < refusal_at
			and refusal_at < key_at and key_at < input_at,
			"Accessibility must be settled before the first input owner is armed")
		local refusal_block = source:sub(refusal_at, input_at)
		helpers.assert_true(refusal_block:find("\n\treturn\nend", 1, true) ~= nil,
			"an untrusted boot must stop instead of falling through to the eventtaps")
	end)
end)
