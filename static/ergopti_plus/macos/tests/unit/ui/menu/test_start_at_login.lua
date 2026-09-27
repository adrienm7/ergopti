--- tests/unit/ui/menu/test_start_at_login.lua

--- ==============================================================================
--- MODULE: Login Startup Menu Tests
--- DESCRIPTION:
--- Verifies native acknowledgements and queued user intent with inert workers.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fixture()
	package.loaded["ui.menu.start_at_login"] = nil
	local module = require("ui.menu.start_at_login")
	local calls = { commands = {}, callbacks = {}, errors = 0, changes = 0 }
	local deps = {
		resolver = { resolve = function() return "/fixture/ErgoptiPlus", nil, {} end },
		logger = { error = function() end },
		i18n = { get = function(key) return key end },
		dialog = { block_alert = function() calls.errors = calls.errors + 1 end },
		shell = { spawn = function(_, args, done)
			calls.commands[#calls.commands + 1] = args[2]
			calls.callbacks[#calls.callbacks + 1] = done
			return { start = function() return true end }
		end },
	}
	return module, deps, calls, function() calls.changes = calls.changes + 1 end
end

helpers.describe("login startup menu", function()
	helpers.it("a query never changes startup and a click waits for native confirmation (login-startup)", function()
		local module, deps, calls, changed = fixture()
		helpers.assert_true(module.request("status", changed, deps))
		helpers.assert_eq(module.enabled(), false)
		calls.callbacks[1](0, "disabled\n")
		helpers.assert_true(module.request("toggle", changed, deps))
		helpers.assert_eq(module.enabled(), false)
		calls.callbacks[2](0, "enabled\n")
		helpers.assert_eq(module.enabled(), true)
		helpers.assert_eq(calls.changes, 1)
		helpers.assert_eq(calls.commands, { "status", "toggle" })
	end)
	helpers.it("retains one explicit click while the initial query is pending (login-startup)", function()
		local module, deps, calls, changed = fixture()
		module.request("status", changed, deps)
		helpers.assert_true(module.request("toggle", changed, deps))
		helpers.assert_eq(#calls.commands, 1)
		calls.callbacks[1](0, "disabled\n")
		helpers.assert_eq(calls.commands, { "status", "toggle" })
		calls.callbacks[2](0, "enabled\n")
		helpers.assert_true(module.enabled())
	end)
	helpers.it("approval and worker failure cannot publish a false checkmark (login-startup)", function()
		local module, deps, calls, changed = fixture()
		module.request("toggle", changed, deps)
		calls.callbacks[1](0, "approval\n")
		helpers.assert_eq(module.enabled(), false)
		helpers.assert_eq(calls.errors, 1)
		module.request("toggle", changed, deps)
		calls.callbacks[2](70, "enabled\n")
		helpers.assert_eq(module.enabled(), false)
		helpers.assert_eq(calls.errors, 2)
	end)
end)
