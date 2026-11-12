--- tests/unit/ui/menu/about/test_start_at_login.lua

--- ==============================================================================
--- MODULE: Login Startup Menu Tests
--- DESCRIPTION:
--- Verifies native acknowledgements and queued user intent with inert workers.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fixture()
	package.loaded["ui.menu.start_at_login"] = nil
	local module = require("ui.menu.start_at_login")
	local calls = { commands = {}, callbacks = {}, errors = 0, changes = 0, dialogs = {}, logs = {} }
	local function log(level)
		return function(_, message) calls.logs[#calls.logs + 1] = level .. ": " .. message end
	end
	local deps = {
		resolver = { resolve = function() return "/fixture/ErgoptiPlus", nil, {} end },
		logger = { error = log("error"), warn = log("warn") },
		i18n = { get = function(key) return key end },
		dialog = { block_alert = function(_, text, _, _, style)
			calls.errors = calls.errors + 1
			calls.dialogs[#calls.dialogs + 1] = text .. " " .. style
		end },
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
	helpers.it("an approval answer tells the user the step left, not a failure (login-startup)", function()
		local module, deps, calls, changed = fixture()
		module.request("toggle", changed, deps)
		calls.callbacks[1](0, "approval\n")
		helpers.assert_eq(calls.dialogs, { "dialog.start_at_login.approval informational" })
		module.request("toggle", changed, deps)
		calls.callbacks[2](70, "")
		helpers.assert_eq(calls.dialogs[2], "dialog.start_at_login.failed critical")
	end)
	helpers.it("logs a failed status read once until a read succeeds (login-startup)", function()
		local module, deps, calls = fixture()
		local resolve = deps.resolver.resolve
		deps.resolver.resolve = function() return nil, "helper missing" end
		helpers.assert_eq(module.request("status", nil, deps), false)
		helpers.assert_eq(module.request("status", nil, deps), false)
		helpers.assert_eq(calls.logs, { "warn: Startup state could not be read: %s." })
		helpers.assert_eq(calls.errors, 0, "a status read never opens a dialog")
		deps.resolver.resolve = resolve
		module.request("status", nil, deps)
		calls.callbacks[1](0, "disabled\n")
		deps.resolver.resolve = function() return nil, "helper missing" end
		module.request("status", nil, deps)
		helpers.assert_eq(#calls.logs, 2)
	end)
	helpers.it("runs a queued click when refreshing the menu raises", function()
		local module, deps, calls = fixture()
		module.request("status", function() error("refresh failed") end, deps)
		module.request("toggle", nil, deps)
		calls.callbacks[1](0, "enabled\n")
		helpers.assert_eq(calls.commands, { "status", "toggle" })
		calls.callbacks[2](0, "disabled\n")
		helpers.assert_eq(module.enabled(), false)
	end)
	helpers.it("runs a queued click if the previous failure dialog cannot open", function()
		local module, deps, calls = fixture()
		deps.dialog.block_alert = function() error("dialog failed") end
		module.request("toggle", nil, deps)
		module.request("toggle", nil, deps)
		calls.callbacks[1](1, "")
		helpers.assert_eq(calls.commands, { "toggle", "toggle" })
		calls.callbacks[2](0, "enabled\n")
		helpers.assert_true(module.enabled())
	end)
	for _, boundary in ipairs({ "spawn", "start", "missing" }) do
		helpers.it("allows retry after native worker " .. boundary .. " failure", function()
			local module, deps, calls = fixture()
			local spawn = deps.shell.spawn
			deps.shell.spawn = function(...)
				if boundary == "spawn" then error("spawn failed") end
				if boundary == "start" then return { start = function() error("start failed") end } end
				return nil
			end
			helpers.assert_eq(module.request("toggle", nil, deps), false)
			helpers.assert_eq(calls.errors, 1)
			deps.shell.spawn = spawn
			helpers.assert_true(module.request("toggle", nil, deps))
			helpers.assert_eq(calls.commands, { "toggle" })
			calls.callbacks[1](0, "enabled\n")
			helpers.assert_true(module.enabled())
		end)
	end
	helpers.it("waits for a refused worker to settle before replaying a queued click", function()
		local module, deps, calls = fixture()
		local spawn = deps.shell.spawn
		local settle
		deps.shell.spawn = function()
			return {
				start = function() return false end,
				isSettled = function() return false end,
				onSettled = function(callback) settle = callback; return true end,
			}
		end
		helpers.assert_eq(module.request("toggle", nil, deps), false)
		deps.shell.spawn = spawn
		helpers.assert_true(module.request("toggle", nil, deps))
		helpers.assert_eq(#calls.commands, 0)
		settle()
		helpers.assert_eq(calls.commands, { "toggle" })
		calls.callbacks[1](0, "enabled\n")
		helpers.assert_true(module.enabled())
	end)
end)
