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

--- How the restart this process requested is carried out ("systemd" or "relay"), until cancelled.
local _pending = nil

--- Requests a restart.
--- @param opts table `{ reason, args, paused?, restarter?, installation?, cgroup?, run? }`:
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
		paused = opts.paused,
		run = opts.run,
		cgroup = opts.cgroup,
	})
	if how ~= "systemd" and how ~= "relay" then
		Logger.error(LOG, "The restart for %s could not be requested.", opts.reason)
		return nil, "the restart could not be requested"
	end
	Logger.success(LOG, "Restart for %s requested (%s).", opts.reason, how)
	_pending = how
	return how
end

--- Cancels the restart this process requested, for a Quit that wins over a reload.
--- @param opts table|nil `{ restarter?, run?, pid? }`, restarter defaults to modules.updater.restarter.
--- @return boolean cancelled
--- @return string|nil detail Why it could not be cancelled.
function M.cancel(opts)
	opts = opts or {}
	if _pending == nil then return false, "no restart is pending" end
	local Restarter = opts.restarter or require("modules.updater.restarter")
	local cancelled, detail = Restarter.cancel(_pending, { run = opts.run, pid = opts.pid })
	if cancelled then
		Logger.info(LOG, "The pending %s restart was cancelled.", _pending)
		_pending = nil
		return true
	end
	Logger.error(LOG, "The pending %s restart could not be cancelled: %s.", _pending, tostring(detail))
	return false, detail
end

--- Test seam: forgets the pending restart.
function M._reset_for_test()
	_pending = nil
end

return M
