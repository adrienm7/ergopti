--- tests/desktop/update_watch_daemon.lua

--- ==============================================================================
--- MODULE: Update Watch Daemon Stand-In
--- DESCRIPTION:
--- One daemon generation for run_update_restart_watcher.sh. It does what the
--- real daemon does around an update, with the real modules: it reports ready
--- through infra/updater_boot_ready.lua, records "<tree> <pid>" in the runs
--- file, and on SIGUSR1 asks modules/updater/restarter.lua to start the
--- installed release under the update watcher (as restart_on_installed_release
--- in ergopti_hotstrings.lua). SIGUSR2 does the same, then cancels it as the
--- Quit that wins over the restart. In relay mode it then exits, as the
--- daemon's shutdown does; under the unit systemd stops it.
--- Arguments: tree name, installation root, runs file, watch log.
--- ==============================================================================

require("compat.utf8").install()
local uv = require("luv")
local Restarter = require("modules.updater.restarter")

local tree, root, runs, log = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])

local function append(path, line)
	local handle = assert(io.open(path, "ab"))
	handle:write(line, "\n")
	handle:close()
end

local pid = uv.os_getpid()
require("infra.updater_boot_ready").report("proof daemon ready")
append(runs, tree .. " " .. tostring(pid))

--- Requests the restart on the installed release, optionally cancelling it.
--- @param quit boolean Whether a Quit cancels the restart right after.
local function update(quit)
	local how = Restarter.restart({ wrapper = root .. "/bin/ergopti", args = {},
		successor = { root = root, log = log } })
	append(runs, "restart " .. tostring(how))
	if quit and how then
		local cancelled, detail = Restarter.cancel(how)
		append(runs, "cancel " .. tostring(cancelled) .. " " .. tostring(detail))
	end
	if how == "relay" then uv.stop() end
end

local usr1, usr2, term = uv.new_signal(), uv.new_signal(), uv.new_signal()
usr1:start("sigusr1", function() update(false) end)
usr2:start("sigusr2", function() update(true) end)
term:start("sigterm", function() uv.stop() end)
uv.run()
os.exit(0)
