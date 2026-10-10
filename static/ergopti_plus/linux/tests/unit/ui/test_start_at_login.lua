--- tests/unit/ui/test_start_at_login.lua

--- ==============================================================================
--- MODULE: Login Startup Menu Tests
--- DESCRIPTION:
--- Exercises state queries and explicit changes without altering real startup.
--- ==============================================================================

local helpers = require("tests.helpers")
local Startup = require("ui.menu.start_at_login")

helpers.describe("login startup", function()
	helpers.it("queries without changing startup and verifies both toggle directions (login-startup)", function()
		local enabled = false
		local changes = 0
		local function run(command)
			if command:match(" status$") then return true, enabled and "enabled\n" or "disabled\n" end
			changes = changes + 1
			enabled = command:match(" enable$") ~= nil
			return true, ""
		end
		helpers.assert_eq(Startup.enabled(run), false)
		helpers.assert_eq(changes, 0)
		helpers.assert_true(Startup.toggle(run))
		helpers.assert_true(enabled)
		helpers.assert_true(Startup.toggle(run))
		helpers.assert_eq(enabled, false)
		helpers.assert_eq(changes, 2)
	end)
	helpers.it("refuses failed queries, failed mutations and unconfirmed changes (login-startup)", function()
		helpers.assert_eq(Startup.toggle(function() return false, "" end), false)
		helpers.assert_eq(Startup.toggle(function(command)
			return command:match(" status$") ~= nil, "disabled\n"
		end), false)
		helpers.assert_eq(Startup.toggle(function() return true, "disabled\n" end), false)
	end)
	helpers.it("another startup command disables mutation without a false owned state (login-startup)", function()
		local commands = {}
		local function run(command)
			commands[#commands + 1] = command
			return true, "other\n"
		end
		helpers.assert_eq(Startup.command_available(run), false)
		helpers.assert_eq(Startup.enabled(run), nil)
		helpers.assert_eq(Startup.toggle(run), false)
		helpers.assert_eq(#commands, 3)
		for _, command in ipairs(commands) do
			helpers.assert_true(command:match(" status$") ~= nil, "no mutation crosses the existing helper")
		end
		helpers.assert_eq(Startup.command_available(function() return false, "" end), nil)
		helpers.assert_eq(Startup.command_available(function() return true, "enabled\n" end), true)
		helpers.assert_eq(Startup.command_available(function() return true, "disabled\n" end), true)
	end)
end)
