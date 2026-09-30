--- infra/daemon_restart.lua

--- ==============================================================================
--- MODULE: Daemon Restart (Linux)
--- DESCRIPTION:
--- Restarts the running daemon so every module starts again from config.toml,
--- the Linux counterpart of hs.reload() and the Windows Reload. It reuses the
--- updater's restarter: under the systemd user unit, systemd restarts the
--- daemon; otherwise a detached relay starts the standalone launcher once this
--- process has exited.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.daemon_restart"

--- Requests a restart.
--- @param opts table `{ reason, args, restarter?, installation?, cgroup?, run? }`:
---   `installation()` resolves the updater's installation context,
---   `restarter` defaults to modules.updater.restarter.
--- @return string|nil how "systemd" or "relay" (the caller must then exit).
--- @return string|nil detail Why no restart could be requested.
function M.restart(opts)
	assert(type(opts) == "table" and type(opts.reason) == "string" and opts.reason ~= ""
		and type(opts.args) == "table", "a daemon restart needs a reason and the daemon arguments")
	local Restarter = opts.restarter or require("modules.updater.restarter")
	local installation = opts.installation
		or function() return require("modules.updater.manager")._resolve_installation() end
	local under_unit = Restarter.under_unit(opts.cgroup)
	local wrapper
	if not under_unit then
		local context = installation()
		if type(context) ~= "table" or context.kind ~= "standalone" or type(context.wrapper) ~= "string" then
			local detail = "no launcher can restart this daemon ("
				.. tostring(type(context) == "table" and context.reason or "no installation context") .. ")"
			Logger.error(LOG, "Restart for %s refused: %s.", opts.reason, detail)
			return nil, detail
		end
		wrapper = context.wrapper
	end
	Logger.start(LOG, "Restarting the daemon for %s…", opts.reason)
	-- Under the unit systemd restarts the service itself and the relay launcher
	-- is never used; the restarter still requires one, so the unit names it.
	local how = Restarter.restart({
		wrapper = wrapper or Restarter.UNIT,
		args = opts.args,
		run = opts.run,
		cgroup = opts.cgroup,
	})
	if how ~= "systemd" and how ~= "relay" then
		Logger.error(LOG, "The restart for %s could not be requested.", opts.reason)
		return nil, "the restart could not be requested"
	end
	Logger.success(LOG, "Restart for %s requested (%s).", opts.reason, how)
	return how
end

return M
