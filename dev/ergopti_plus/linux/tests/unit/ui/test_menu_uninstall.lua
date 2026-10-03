--- tests/unit/ui/test_menu_uninstall.lua

--- ==============================================================================
--- MODULE: Menu Uninstall Handoff Tests
--- DESCRIPTION:
--- Exercises cancellation, ownership refusal and the independent removal worker
--- without stopping a real daemon or deleting an installed application.
--- ==============================================================================

local helpers = require("tests.helpers")
local Uninstall = require("ui.menu.uninstall")

--- Builds inert dependencies and a record of every external operation.
--- @return table opts, table log
local function fixture()
	local log = { commands = {}, quit = 0, failures = 0 }
	local fields = { "S" }
	for _ = 2, 19 do fields[#fields + 1] = "0" end
	fields[20] = "987654"
	return {
		root = "/home/user's files/prefix/lib/ergopti/linux",
		title = "Uninstall", confirmation = "Confirm", failure = "Failed",
		run = function(command) log.commands[#log.commands + 1] = command; return true end,
		read = function(path)
			helpers.assert_eq(path, "/proc/self/stat")
			return "123 (a process with ) parentheses) " .. table.concat(fields, " ")
		end,
		getenv = function(key) if key == "DISPLAY" then return ":7" end end,
		confirm = function() return true end,
		fail = function() log.failures = log.failures + 1 end,
		quit = function() log.quit = log.quit + 1 end,
	}, log
end

helpers.describe("Linux menu uninstall", function()
	-- The About row is greyed on a source run; a click that still reaches the
	-- action does nothing: no command, and no « could not be uninstalled ».
	helpers.it("does nothing for a local version run from source (menu-uninstall)", function()
		local opts, log = fixture()
		opts.root = "/checkout/static/ergopti_plus/linux"
		opts.version_source = "local"
		helpers.assert_eq(Uninstall.run(opts), false)
		helpers.assert_eq(#log.commands, 0)
		helpers.assert_eq(log.quit, 0)
		helpers.assert_eq(log.failures, 0, "no failure dialog for a removal that was never possible")
	end)
	helpers.it("refuses a stamped build outside every install layout (menu-uninstall)", function()
		local opts, log = fixture()
		opts.root = "/tmp/ergopti-release/linux"
		opts.version_source = "build"
		helpers.assert_eq(Uninstall.run(opts), false)
		helpers.assert_eq(#log.commands, 0)
		helpers.assert_eq(log.quit, 0)
		helpers.assert_eq(log.failures, 1)
	end)
	helpers.it("cancellation retains the running application (menu-uninstall)", function()
		local opts, log = fixture()
		opts.confirm = function() return false end
		helpers.assert_eq(Uninstall.run(opts), false)
		helpers.assert_eq(#log.commands, 1)
		helpers.assert_true(log.commands[1]:find(" --check", 1, true) ~= nil)
		helpers.assert_eq(log.quit, 0)
	end)
	helpers.it("moves removal outside the daemon service and waits for its exact identity (menu-uninstall)", function()
		local opts, log = fixture()
		helpers.assert_true(Uninstall.run(opts))
		local command = log.commands[3]
		helpers.assert_true(command:find("systemd-run --user --collect", 1, true) ~= nil)
		helpers.assert_true(command:find(" --wait-owner '123:987654'", 1, true) ~= nil)
		helpers.assert_true(command:find(" --gui 'ErgoptiPlus — Uninstall' 'Failed'", 1, true) ~= nil,
			"the independent worker receives composed chrome and unchanged failure body")
		helpers.assert_true(command:find(" --setenv='DISPLAY=:7'", 1, true) ~= nil)
		helpers.assert_true(command:find("/home/user'\\''s files/prefix'", 1, true) ~= nil)
		helpers.assert_eq(log.quit, 1)
		helpers.assert_eq(log.failures, 0)
	end)
	helpers.it("does not close the application when worker launch fails (menu-uninstall)", function()
		local opts, log = fixture()
		opts.run = function(command)
			log.commands[#log.commands + 1] = command
			return not command:find("systemd-run", 1, true)
		end
		helpers.assert_eq(Uninstall.run(opts), false)
		helpers.assert_eq(log.quit, 0)
		helpers.assert_eq(log.failures, 1)
	end)
	helpers.it("refuses an unreadable process identity (menu-uninstall)", function()
		local opts, log = fixture()
		opts.read = function() return nil end
		helpers.assert_eq(Uninstall.run(opts), false)
		helpers.assert_eq(log.quit, 0)
		helpers.assert_eq(#log.commands, 1)
	end)
	helpers.it("keeps the daemon running without a detached worker command (menu-uninstall)", function()
		local opts, log = fixture()
		opts.run = function(command)
			log.commands[#log.commands + 1] = command
			return command:find(" --check", 1, true) ~= nil
		end
		helpers.assert_eq(Uninstall.run(opts), false)
		helpers.assert_eq(log.quit, 0)
		helpers.assert_eq(log.failures, 1)
		helpers.assert_eq(log.commands[3], "command -v setsid >/dev/null 2>&1")
	end)
end)
