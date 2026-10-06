--- tests/unit/platform/remap/test_system_extension_observation.lua

--- ==============================================================================
--- MODULE: System Extension Observation Regression
--- DESCRIPTION:
--- Independent CLI grammar examples exercise the shared observation and the real
--- onboarding predicate. The modeled command performs no native operations and
--- says nothing about live driver readiness, signing, or version compatibility.
--- ==============================================================================

local helpers = require("tests.helpers")

-- These expectations are fixed before the parser exists. In particular, an older
-- legitimate shared installation remains approved independently of the owned pin.
local cases = {
	{ name = "official approved", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "older shared approved", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.7.0/1.7.0) Karabiner [activated enabled]\n", state = "approved", displayed_version = "1.7.0", displayed_build = "1.7.0" },
	{ name = "tabs and indentation", output = "\t*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice\t(1.8.0/1.8.0)\tKarabiner VirtualHIDDevice\t[activated enabled]\t\n", state = "approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "normal section header", output = "1 extension(s)\n--- com.apple.system_extension.driver_extension\nenabled active teamID bundleID (version) name [state]\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "unrelated extension before official", output = "* * FOREIGN123 org.example.Driver (2.0/2.0) Other [activated enabled]\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "CRLF output", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\r\n", state = "approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "no final newline", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]", state = "approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "waiting for user", output = "- - G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [waiting for user]\n", state = "not_approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "state words only in name", output = "- - G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) activated enabled [waiting for user]\n", state = "not_approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "active markers with waiting state", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [waiting for user]\n", state = "not_approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "disabled marker", output = "- * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "not_approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "inactive marker", output = "* - G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "not_approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "foreign bundle prefix", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.other (1.8.0/1.8.0) Other [activated enabled]\n", state = "unknown" },
	{ name = "foreign TeamID", output = "* * FOREIGN123 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Other [activated enabled]\n", state = "unknown" },
	{ name = "terminal status required", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled] unexpected\n", state = "unknown" },
	{ name = "unframed status", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner activated enabled\n", state = "unknown" },
	{ name = "missing version tuple", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "nonnumeric version tuple", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (banana/apple) Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "unknown bracket state", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [future state]\n", state = "unknown" },
	{ name = "duplicate approved rows", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "conflicting installed versions", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.7.0/1.7.0) Karabiner [terminated waiting to uninstall on reboot]\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "foreign and official same identifier", output = "* * FOREIGN123 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Other [activated enabled]\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "NUL output", output = "\0* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "bare CR output", output = "\r* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "oversized output", output = string.rep(" ", 65536) .. "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n", state = "unknown" },
	{ name = "no target extension", output = "0 extension(s)\n", state = "unknown" },
	{ name = "empty output", output = "", state = "unknown" },
	{ name = "nil output", state = "unknown" },
	{ name = "table output", output = {}, state = "unknown" },
	{ name = "whitespace-only display name", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)   [activated enabled]\n", state = "unknown" },
	{ name = "glued exact target identity", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice(1.8.0/1.8.0) Other [activated enabled]\n", state = "unknown" },
	{ name = "legitimate sibling identifier after official", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated enabled]\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.other (1.8.0/1.8.0) Other [activated enabled]\n", state = "approved", displayed_version = "1.8.0", displayed_build = "1.8.0" },
	{ name = "exact bracket-state spacing", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) Karabiner [activated    enabled]\n", state = "unknown" },
	{ name = "dense malformed whitespace", output = "* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0) " .. string.rep(" ", 60000), state = "unknown" },
}

--- Exercises the real predicate over one modeled, exact CLI invocation.
--- @param output any Modeled command output.
--- @param success any Modeled command success.
--- @return boolean approved Real onboarding result.
local function onboarding_observation(output, success)
	return helpers.with_stub_scope({
		"platform.remap.onboarding", "infra.logger", "infra.i18n", "infra.notifications",
		"infra.dialog_util", "infra.text_utils", "platform.remap.ke_paths",
		"adapters.task_lifecycle", "adapters.timer_scheduler", "remap.system_extension_observation",
	}, function()
		local onboarding = helpers.load_with_stubs("platform.remap.onboarding")
		local original = hs.execute
		local calls = 0
		hs.execute = function(command)
			helpers.assert_eq(command, "/usr/bin/systemextensionsctl list 2>&1")
			calls = calls + 1
			return output, success
		end
		local ok, approved = pcall(onboarding.is_sysext_activated)
		hs.execute = original
		if not ok then error(approved, 0) end
		helpers.assert_eq(calls, 1)
		return approved
	end)
end

helpers.describe("onboarding system extension approval regression", function()
	for _, case in ipairs(cases) do
		helpers.it(case.name, function()
			helpers.assert_eq(onboarding_observation(case.output, true), case.state == "approved")
		end)
	end
	for _, success in ipairs({ false, "true", 1 }) do
		helpers.it("rejects command success " .. tostring(success), function()
			helpers.assert_eq(onboarding_observation(cases[1].output, success), false)
		end)
	end
	helpers.it("rejects absent command success", function()
		helpers.assert_eq(onboarding_observation(cases[1].output, nil), false)
	end)
end)

helpers.describe("shared system extension observation grammar", function()
	for _, case in ipairs(cases) do
		helpers.it(case.name, function()
			local observation = require("remap.system_extension_observation").observe(case.output)
			helpers.assert_eq(observation, {
				state = case.state,
				approved = case.state == "approved",
				displayed_version = case.displayed_version,
				displayed_build = case.displayed_build,
			})
		end)
	end
end)
