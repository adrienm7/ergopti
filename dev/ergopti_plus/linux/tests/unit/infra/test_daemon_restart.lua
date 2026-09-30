--- tests/unit/infra/test_daemon_restart.lua

--- ==============================================================================
--- MODULE: Daemon Restart Tests
--- DESCRIPTION:
--- The setup wizard's answers take effect when every module starts again from
--- config.toml. These tests pin how the daemon asks for that restart: systemd
--- restarts the user unit, a standalone installation relays its own launcher,
--- and a daemon nothing can relaunch reports it instead of exiting.
--- ==============================================================================

local helpers = require("tests.helpers")
local DaemonRestart = helpers.load_module("infra.daemon_restart")
local Restarter = helpers.load_module("modules.updater.restarter")

local UNIT_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/" .. Restarter.UNIT .. "\n"
local SESSION_CGROUP = "0::/user.slice/user-1000.slice/session-2.scope\n"
local LAUNCHER = "/home/user/.local/bin/ergopti-hotstrings"

local function fixture(cgroup, context, accepted)
	local record = { commands = {}, resolved = 0 }
	return {
		reason = "the setup wizard",
		args = { "--tray" },
		cgroup = cgroup,
		restarter = Restarter,
		installation = function()
			record.resolved = record.resolved + 1
			return context
		end,
		run = function(command)
			record.commands[#record.commands + 1] = command
			return accepted ~= false
		end,
	}, record
end

helpers.describe("daemon restart", function()
	helpers.it("asks systemd to restart the user unit without resolving an installation", function()
		local opts, record = fixture(UNIT_CGROUP, nil)
		helpers.assert_eq(DaemonRestart.restart(opts), "systemd")
		helpers.assert_eq(record.commands, { "systemctl --user --no-block restart " .. Restarter.UNIT })
		helpers.assert_eq(record.resolved, 0, "the unit restarts itself; no launcher is needed")
	end)

	helpers.it("relays the standalone launcher with the daemon's own arguments", function()
		local opts, record = fixture(SESSION_CGROUP, { kind = "standalone", wrapper = LAUNCHER })
		helpers.assert_eq(DaemonRestart.restart(opts), "relay")
		helpers.assert_eq(#record.commands, 1)
		helpers.assert_contains(record.commands[1], LAUNCHER)
		helpers.assert_contains(record.commands[1], "--tray")
		helpers.assert_contains(record.commands[1], "setsid sh -c")
	end)

	helpers.it("refuses to exit a daemon no launcher can bring back", function()
		for _, context in ipairs({
			{ kind = "package", reason = "owned by the system package manager" },
			{ kind = "standalone" },
			false,
		}) do
			local opts, record = fixture(SESSION_CGROUP, context or nil)
			local how, detail = DaemonRestart.restart(opts)
			helpers.assert_nil(how, "exiting here would leave the user without a daemon")
			helpers.assert_type(detail, "string")
			helpers.assert_eq(#record.commands, 0)
		end
	end)

	helpers.it("reports a restart the system refused", function()
		local opts = fixture(UNIT_CGROUP, nil, false)
		local how, detail = DaemonRestart.restart(opts)
		helpers.assert_nil(how)
		helpers.assert_type(detail, "string")
	end)

	helpers.it("requires a reason and the daemon arguments", function()
		local opts, record = fixture(UNIT_CGROUP, nil)
		opts.reason = ""
		helpers.assert_contains(tostring(helpers.assert_throws(function() DaemonRestart.restart(opts) end)),
			"needs a reason and the daemon arguments")
		opts.reason, opts.args = "the setup wizard", nil
		helpers.assert_contains(tostring(helpers.assert_throws(function() DaemonRestart.restart(opts) end)),
			"needs a reason and the daemon arguments")
		helpers.assert_eq(#record.commands, 0, "a refused request runs nothing")
	end)
end)
