--- tests/unit/infra/lifecycle/test_daemon_restart.lua

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

	helpers.it("(linux-cgroup-unit-owner) relays a daemon in a different unit sharing the service prefix", function()
		for _, suffix in ipairs({ "-backup.service", ".scope", "2", "-helper.slice" }) do
			local cgroup = "0::/user.slice/app.slice/" .. Restarter.UNIT .. suffix .. "\n"
			local opts, record = fixture(cgroup, { kind = "standalone", wrapper = LAUNCHER })
			helpers.assert_eq(DaemonRestart.restart(opts), "relay",
				"a similarly named cgroup cannot restart this process through Ergopti's service")
			helpers.assert_eq(record.resolved, 1, "the actual standalone installation must be resolved")
			helpers.assert_contains(record.commands[1], "setsid sh -c")
		end
	end)

	helpers.it("(linux-cgroup-unit-owner) recognizes exact service ancestors in v1 and v2 records", function()
		for _, cgroup in ipairs({
			"0::/" .. Restarter.UNIT .. "\n",
			"0::/user.slice/" .. Restarter.UNIT .. "/workers\n",
			"12:name=systemd:/user.slice/" .. Restarter.UNIT .. "\n9:cpu:/other\n",
			"9:cpu:/other\n12:name=systemd:/user.slice/" .. Restarter.UNIT .. "/workers\n",
		}) do
			local opts, record = fixture(cgroup, nil)
			helpers.assert_eq(DaemonRestart.restart(opts), "systemd")
			helpers.assert_eq(record.resolved, 0)
			helpers.assert_eq(record.commands, { "systemctl --user --no-block restart " .. Restarter.UNIT })
		end
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


--- Runs each handoff with its own bootstrap file and restores all adapter ports.
local function pause_handoff_fixture(body)
	local Storage, Files = require("adapters.storage"), require("adapters.file_system")
	local Shell = require("adapters.shell_runner")
	local folder = os.tmpname()
	os.remove(folder)
	assert(Shell.run("mkdir -p -- " .. Shell.quote(folder)) == true)
	local original = { path = Storage.path, read = Files.read_with_status,
		write = Files.write_if_unchanged, delete = Files.delete }
	Storage.path = function() return folder .. "/storage.json" end
	local path = Storage.path() .. ".restart-pause"
	local function read() return original.read(path) end
	local function write(bytes)
		local file = assert(io.open(path, "wb"))
		assert(file:write(bytes)); assert(file:close())
	end
	local function restart(paused, run, cgroup)
		return Restarter.restart({ wrapper = LAUNCHER, args = { "--tray", "space ' apostrophe" },
			paused = paused, pid = 123, cgroup = cgroup or SESSION_CGROUP, run = run })
	end
	local ok, failure = xpcall(function()
		body({ path = path, read = read, write = write, restart = restart, files = Files })
	end, debug.traceback)
	Storage.path, Files.read_with_status = original.path, original.read
	Files.write_if_unchanged, Files.delete = original.write, original.delete
	os.remove(path); os.remove(folder)
	if not ok then error(failure, 0) end
end

local function pause_controller(listener)
	return require("modules.shortcuts.script_actions").new({ reset = function() end,
		reload = function() end, quit = function() end, on_pause_change = listener })
end

helpers.describe("restart pause handoff", function()
	helpers.it("forwards the live pause state through the daemon restart owner", function()
		for _, paused in ipairs({ true, false }) do
			local received
			local how = DaemonRestart.restart({ reason = "configuration restored", args = {}, paused = paused,
				cgroup = UNIT_CGROUP, restarter = { UNIT = Restarter.UNIT, under_unit = function() return true end,
					restart = function(opts) received = opts.paused; return "systemd" end } })
			helpers.assert_eq(how, "systemd")
			helpers.assert_eq(received, paused, "a full restart must preserve the controller's live state")
		end
	end)

	helpers.it("publishes the pause before either relay or systemd dispatch without transporting argv", function()
		for _, cgroup in ipairs({ SESSION_CGROUP, UNIT_CGROUP }) do
			pause_handoff_fixture(function(f)
				local seen
				local how = f.restart(true, function(command)
					seen = f.read()
					helpers.assert_type(seen, "string", "pause must survive the old process before dispatch")
					if cgroup == UNIT_CGROUP then
						helpers.assert_eq(command, "systemctl --user --no-block restart " .. Restarter.UNIT)
					end
					return true
				end, cgroup)
				helpers.assert_eq(how, cgroup == UNIT_CGROUP and "systemd" or "relay")
				helpers.assert_eq(f.read(), seen)
			end)
		end
	end)

	helpers.it("applies and consumes true then carries explicit false after the user resumes", function()
		pause_handoff_fixture(function(f)
			helpers.assert_eq(f.restart(true, function() return true end), "relay")
			helpers.assert_type(f.read(), "string", "restart must publish the pause handoff")
			local Pause, seen = require("infra.restart_pause"), {}
			local controller = pause_controller(function(paused) seen[#seen + 1] = paused; return true end)
			helpers.assert_true(Pause.restore(controller))
			helpers.assert_true(controller.is_paused())
			helpers.assert_eq(seen, { true }, "restoration uses the normal pause transition exactly once")
			local _, status = f.read(); helpers.assert_eq(status, "absent")
			helpers.assert_true(controller.toggle_pause())
			helpers.assert_eq(f.restart(controller.is_paused(), function() return true end), "relay")
			helpers.assert_type(f.read(), "string", "resumed state is explicitly handed off")
			local next_controller = pause_controller(function() error("false must not toggle") end)
			helpers.assert_true(Pause.restore(next_controller))
			helpers.assert_eq(next_controller.is_paused(), false)
			_, status = f.read(); helpers.assert_eq(status, "absent")
		end)
	end)

	helpers.it("refuses unreadable or already pending handoffs before dispatch", function()
		for _, unreadable in ipairs({ false, true }) do
			pause_handoff_fixture(function(f)
				local source = "another pending restart\n"
				f.write(source)
				if unreadable then f.files.read_with_status = function() return nil, "error", "denied" end end
				local dispatches = 0
				helpers.assert_nil(f.restart(true, function() dispatches = dispatches + 1; return true end))
				helpers.assert_eq(dispatches, 0, "failed preparation must leave the current generation live")
				local file = assert(io.open(f.path, "rb"))
				helpers.assert_eq(file:read("*a"), source); assert(file:close())
			end)
		end
	end)

	helpers.it("refuses unacknowledged publication before dispatch", function()
		pause_handoff_fixture(function(f)
			f.files.write_if_unchanged = function() return false, "denied" end
			local dispatched = false
			helpers.assert_nil(f.restart(true, function() dispatched = true; return true end))
			helpers.assert_eq(dispatched, false)
		end)
	end)

	helpers.it("compensates its image after refused or thrown dispatch on both routes", function()
		for _, cgroup in ipairs({ SESSION_CGROUP, UNIT_CGROUP }) do
			for _, throws in ipairs({ false, true }) do
				pause_handoff_fixture(function(f)
					local prepared
					local ok, how = pcall(f.restart, true, function()
						prepared = f.read()
						if throws then error("dispatch failed") end
						return false
					end, cgroup)
					helpers.assert_true(ok, "dispatch exceptions must not bypass compensation")
					helpers.assert_nil(how)
					helpers.assert_type(prepared, "string", "a lease existed before dispatch")
					local _, status = f.read(); helpers.assert_eq(status, "absent")
				end)
			end
		end
	end)

	helpers.it("preserves another image when failed dispatch no longer owns the handoff", function()
		pause_handoff_fixture(function(f)
			local prepared
			helpers.assert_nil(f.restart(true, function()
				prepared = f.read(); f.write("replacement owner\n"); return false
			end))
			helpers.assert_type(prepared, "string")
			helpers.assert_eq(f.read(), "replacement owner\n")
		end)
	end)

	helpers.it("keeps a handoff when the normal pause listener refuses or throws", function()
		for _, throws in ipairs({ false, true }) do
			pause_handoff_fixture(function(f)
				helpers.assert_eq(f.restart(true, function() return true end), "relay")
				local image = f.read(); helpers.assert_type(image, "string")
				local controller = pause_controller(function()
					if throws then error("native remapper pause refused") end
					return false
				end)
				helpers.assert_eq(require("infra.restart_pause").restore(controller), false)
				helpers.assert_eq(f.read(), image, "a failed startup must leave pause for the next generation")
				local next_controller = pause_controller(function() return true end)
				helpers.assert_true(require("infra.restart_pause").restore(next_controller))
				helpers.assert_true(next_controller.is_paused())
			end)
		end
	end)

	helpers.it("does not acknowledge startup when consuming its applied pause fails", function()
		pause_handoff_fixture(function(f)
			helpers.assert_eq(f.restart(true, function() return true end), "relay")
			local image = f.read(); helpers.assert_type(image, "string")
			f.files.delete = function() return false end
			local controller = pause_controller(function() return true end)
			helpers.assert_eq(require("infra.restart_pause").restore(controller), false)
			helpers.assert_true(controller.is_paused())
			helpers.assert_eq(f.read(), image)
		end)
	end)
end)


helpers.describe("Main early pause restoration", function()
	helpers.it("applies the normal transition before starting watchers and refuses a native pause failure", function()
		for _, acknowledged in ipairs({ true, false }) do
			pause_handoff_fixture(function(f)
				helpers.assert_eq(f.restart(true, function() return true end), "relay")
				local image = f.read(); helpers.assert_type(image, "string", "restart must carry pause")
				local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
				local source = assert(file:read("*a")); assert(file:close())
				local first = assert(source:find("\tlocal script_actions = ScriptActions.new({", 1, true))
				local last = assert(source:find("\t-- A control can change", first, true))
				local before_watch = source:sub(first, last - 1)
				local applications = 0
				local environment = setmetatable({ ScriptActions = require("modules.shortcuts.script_actions"),
					Logger = require("logger.shim"), LOG = "Main early pause test", privacy_owners = {},
					keystats = { cancel_hold_intervals = function() end }, engine = { reset = function() end },
					MagicKeySource = { cancel_capture = function() end }, perform_reload = function() end,
					shutdown = { request = function() end },
					TapHold = { set_paused = function(paused)
						applications = applications + 1; helpers.assert_true(paused); return acknowledged
					end } }, { __index = _G })
				local text = "return function()\n" .. before_watch .. "\nreturn script_actions\nend"
				local chunk
				if loadstring then chunk = assert(loadstring(text)); setfenv(chunk, environment)
				else chunk = assert(load(text, "Main early pause", "t", environment)) end
				local controller = chunk()()
				helpers.assert_eq(applications, 1, "startup must apply the normal remapper transition once")
				if acknowledged then
					helpers.assert_true(controller.is_paused())
					local _, status = f.read(); helpers.assert_eq(status, "absent")
				else
					helpers.assert_nil(controller, "refused pause must return before watch and native capture")
					helpers.assert_eq(f.read(), image, "the next startup must retain the requested pause")
				end
			end)
		end
	end)
end)
