--- infra/reload_restart.lua

--- ==============================================================================
--- MODULE: Reload As A Daemon Restart (Linux)
--- DESCRIPTION:
--- The Reload command as the other drivers run it: the daemon restarts, so
--- every module reads config.toml again. The tray item, SIGHUP, the paths
--- editor, the reload shortcut and the local reload control all reach one
--- owner built here.
---
--- FEATURES & RATIONALE:
--- 1. Cleanup debt refuses first. A window operation or a user program that
---    still owns native cleanup debt postpones the request ("busy" for the
---    local control) before anything is written or restarted.
--- 2. One restart at a time. A request made while a restart is in flight joins
---    it; the successor completes both.
--- 3. No silent fallback. When no restart can be requested the request fails
---    and the daemon keeps running; it never reloads half of itself in process.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.reload_restart"

--- Builds the reload owner.
--- @param opts table { gestures = table|nil, restart = function(reason) -> boolean }
--- @return function perform `perform(trigger)` -> started, why
function M.new(opts)
	assert(type(opts) == "table" and type(opts.restart) == "function", "the reload owner needs its restart")
	local in_flight = false
	return function(trigger)
		if in_flight then
			Logger.info(LOG, "Reload requested by %s joins the restart already in flight.", trigger)
			return true
		end
		local gestures = opts.gestures
		if gestures and gestures.stop_window_switches() ~= true then
			Logger.warn(LOG, "Reload postponed while a window operation owns native cleanup debt.")
			return false, "postponed"
		end
		if gestures and gestures.stop_programs() ~= true then
			Logger.warn(LOG, "Reload postponed while a user program owns native cleanup debt.")
			return false, "postponed"
		end
		Logger.info(LOG, "Reload requested by %s — restarting the daemon…", trigger)
		local called, started = pcall(opts.restart, "reload")
		if not called or started ~= true then
			Logger.error(LOG, "Reload requested by %s failed: no restart could be requested (%s).", trigger,
				tostring(called and "refused" or started))
			return false, "failed"
		end
		in_flight = true
		return true
	end
end

return M
