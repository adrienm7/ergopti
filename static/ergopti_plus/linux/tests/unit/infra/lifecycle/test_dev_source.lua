--- tests/unit/infra/lifecycle/test_dev_source.lua

--- ==============================================================================
--- MODULE: Developer Source Mode Tests (Linux)
--- DESCRIPTION:
--- A developer run starts from tools/dev/run-linux-dev.sh, which names the
--- clone root. These tests pin that only an exact root is accepted, and that a
--- Reload of such a run relays the developer launcher: a checkout has no
--- install-layout wrapper, so the restart was refused there before.
--- ==============================================================================

local helpers = require("tests.helpers")
local DevSource = helpers.load_module("infra.dev_source")
local Restarter = helpers.load_module("modules.updater.restarter")

local ROOT = "/home/dev/ergopti"
local DRIVER = ROOT .. "/static/ergopti_plus/linux"
local SESSION_CGROUP = "0::/user.slice/user-1000.slice/session-2.scope\n"

--- An environment reader answering one value for the developer variable.
--- @param value string|nil
--- @return function
local function env(value)
	return function(name)
		if name == DevSource.ENVIRONMENT then return value end
		return nil
	end
end

helpers.describe("Linux developer source mode", function()
	helpers.it("shares the developer variable with the macOS app", function()
		helpers.assert_eq(DevSource.ENVIRONMENT, require("identifiers").dev_source.environment)
	end)

	helpers.it("is inactive without the launcher's root", function()
		helpers.assert_eq(DevSource.resolve(env(nil), DRIVER), nil)
		helpers.assert_eq(DevSource.resolve(env(""), DRIVER), nil)
	end)

	helpers.it("accepts only the clone this driver runs from", function()
		helpers.assert_eq(DevSource.resolve(env(ROOT), DRIVER), ROOT)
		for _, bad in ipairs({ "relative/clone", ROOT .. "/", "/elsewhere" }) do
			local ok, err = pcall(DevSource.resolve, env(bad), DRIVER)
			helpers.assert_eq(ok, false, "refuses " .. bad)
			helpers.assert_contains(tostring(err), DevSource.ENVIRONMENT)
		end
	end)

	helpers.it("watches the driver and the shared Lua of the clone", function()
		helpers.assert_eq(DevSource.source_dirs(ROOT), { DRIVER, ROOT .. "/static/ergopti_plus/_shared/lua" })
	end)

	helpers.it("(linux-dev-mode-reload) relays the developer launcher on a Reload", function()
		local DaemonRestart = helpers.load_module("infra.daemon_restart")
		DaemonRestart._reset_for_test()
		-- The restart resolves the developer run when it is asked, so the stub
		-- stands in for the running clone only for this call.
		local saved = package.loaded["infra.dev_source"]
		package.loaded["infra.dev_source"] = {
			restart_context = function() return DevSource.restart_context(ROOT) end,
		}
		local commands = {}
		local called, how = pcall(DaemonRestart.restart, {
			reason = "a saved source file",
			args = { "--tray" },
			cgroup = SESSION_CGROUP,
			restarter = Restarter,
			run = function(command) commands[#commands + 1] = command; return true end,
		})
		package.loaded["infra.dev_source"] = saved
		DaemonRestart._reset_for_test()
		helpers.assert_true(called, tostring(how))
		helpers.assert_eq(how, "relay", "a developer checkout can restart without an installation")
		helpers.assert_contains(commands[1], ROOT .. "/tools/dev/run-linux-dev.sh")
		helpers.assert_contains(commands[1], "--tray")
	end)

	helpers.it("names a launcher that exists in this repository", function()
		local clone = helpers.driver_root():gsub("/static/ergopti_plus/linux$", "")
		local launcher = DevSource.restart_context(clone).wrapper
		local handle = io.open(launcher, "r")
		helpers.assert_true(handle ~= nil, "missing developer launcher " .. launcher)
		if handle then handle:close() end
	end)
end)
