--- tests/unit/modules/shortcuts/system_actions/test_capslock.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local with_fixture = fixture.with_fixture
local load_capslock_fixture = fixture.load_capslock_fixture

helpers.describe("shortcuts.actions.system: CapsLock HID toggle (system-capslock-hid)", function()
	helpers.it("uses hs.hid.capslock.toggle and logs the returned ON/OFF state (system-capslock-hid)", function()
		with_fixture(function()
			local hid_calls = 0
			local enabled = false
			local system, logs, raw_key_attempts = load_capslock_fixture(function()
				hid_calls = hid_calls + 1
				enabled = not enabled
				return enabled
			end)

			helpers.assert_eq(system.toggle_capslock(), true)
			helpers.assert_eq(system.toggle_capslock(), false,
				"false is a successful toggle-to-OFF result, not an API failure")
			helpers.assert_eq(hid_calls, 2)
			helpers.assert_eq(raw_key_attempts(), 0,
				"CapsLock is a flagsChanged HID state; a synthetic key pair silently no-ops on macOS")
			helpers.assert_eq(#logs.error, 0)
			helpers.assert_true(logs.debug[1] and logs.debug[1]:find("ON", 1, true) ~= nil)
			helpers.assert_true(logs.debug[2] and logs.debug[2]:find("OFF", 1, true) ~= nil)
		end)
	end)

	helpers.it("logs an adapter failure and never reports a false success (system-capslock-hid)", function()
		with_fixture(function()
			local system, logs, raw_key_attempts = load_capslock_fixture(function()
				return nil, "HID permission denied"
			end)

			local call_ok, result = pcall(system.toggle_capslock)
			helpers.assert_true(call_ok,
				"a user action must report the HID failure without escaping its callback")
			helpers.assert_nil(result)
			helpers.assert_eq(raw_key_attempts(), 0,
				"failure must not fall back to the known-silent newKeyEvent path")
			helpers.assert_eq(#logs.debug, 0,
				"the failure path must not emit the old unconditional success log")
			helpers.assert_eq(#logs.error, 1)
			helpers.assert_true(logs.error[1]:find("HID permission denied", 1, true) ~= nil)
		end)
	end)
end)
