--- tests/hardware/desktop/update_watch_daemon.lua

--- ==============================================================================
--- MODULE: Update Watch Daemon Stand-In
--- DESCRIPTION:
--- One daemon generation for run_update_restart_watcher.sh. It does what the
--- real daemon does around an update, with the real modules: it reports ready
--- through infra/updater_boot_ready.lua, records "<tree> <pid>" in the runs
--- file, and on SIGUSR1 asks modules/updater/restarter.lua to start the
--- installed release under the update watcher, as restart_on_installed_release
--- in ergopti_hotstrings.lua does; in relay mode it then exits, as the daemon's
--- shutdown does, and under the unit systemd stops it.
---
--- Behaviour "quit" plays the user who quits the UPDATED daemon during the
--- watcher's wait, before its ready report: the click reaches the real
--- infra/quit_request.lua handler with the ports ergopti_hotstrings.lua gives
--- it (report_update_quit through infra/updater_boot_ready.lua), the admitted
--- Quit requests the shutdown and the process exits without reporting ready.
--- Arguments: tree name, installation root, runs file, watch log, behaviour
--- ("daemon" or "quit").
--- ==============================================================================

require("core.lifecycle.engine.compat.utf8").install()
local uv = require("luv")
local Restarter = require("modules.updater.restarter")
local BootReady = require("infra.updater_boot_ready")

local tree, root, runs, log, behaviour = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4]), assert(arg[5])
-- Time between the start and the user's click: the tray is up, the boot is not.
local QUIT_CLICK_MS = 1000

local function append(path, line)
	local handle = assert(io.open(path, "ab"))
	handle:write(line, "\n")
	handle:close()
end

local pid = uv.os_getpid()
append(runs, tree .. " " .. tostring(pid))

if behaviour == "quit" then
	local requested = false
	local on_quit = require("infra.quit_request").new({
		shutdown = {
			is_requested = function() return requested end,
			request = function(reason)
				if requested then return false end
				requested = true
				append(runs, "shutdown " .. reason)
				uv.stop()
				return true
			end,
		},
		reload_in_flight = function() return false end,
		abandon_reload = function() return false, "no restart is pending" end,
		writer_active = function() return false end,
		publication_pending = function() return false end,
		apply_pause_layout = function() end,
		-- The port exactly as ergopti_hotstrings.lua wires it.
		report_update_quit = function() BootReady.report_quit("the tray Quit") end,
		schedule = function(seconds, callback)
			local timer = uv.new_timer()
			timer:start(math.floor(seconds * 1000), 0, function() timer:close(); callback() end)
			return true
		end,
		now = function() return uv.now() / 1000 end,
		timeout = 5, poll = 0.1,
		notify_refused = function() append(runs, "quit refused") end,
	})
	local click = uv.new_timer()
	click:start(QUIT_CLICK_MS, 0, function() append(runs, "quit " .. tostring(on_quit())) end)
	uv.run()
	os.exit(0)
end

BootReady.report("proof daemon ready")

--- Requests the restart on the installed release.
local function update()
	local how = Restarter.restart({ wrapper = root .. "/bin/ergopti", args = {},
		successor = { root = root, log = log } })
	append(runs, "restart " .. tostring(how))
	if how == "relay" then uv.stop() end
end

local usr1, term = uv.new_signal(), uv.new_signal()
usr1:start("sigusr1", update)
term:start("sigterm", function() uv.stop() end)
uv.run()
os.exit(0)
