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
--- @param opts table { gestures = table|nil, restart = function(reason) -> boolean,
---   cancel = function() -> boolean, detail|nil }
--- @return function perform `perform(trigger)` -> started, why
--- @return function in_flight `in_flight()` -> whether a restart was requested and owns the process
--- @return function abandon `abandon()` -> cancelled, detail: a Quit that wins over the reload
function M.new(opts)
	assert(type(opts) == "table" and type(opts.restart) == "function", "the reload owner needs its restart")
	local in_flight = false
	local function perform(trigger)
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
	--- Cancels the restart in flight; the daemon then keeps running, or quits on the caller's request.
	local function abandon()
		if not in_flight then return true end
		assert(type(opts.cancel) == "function", "the reload owner needs its cancel to abandon a restart")
		local cancelled, detail = opts.cancel()
		if cancelled == true then
			in_flight = false
			Logger.info(LOG, "The reload in flight was abandoned.")
			return true
		end
		Logger.error(LOG, "The reload in flight could not be abandoned (%s): the quit goes on, but "
			.. "the restart may still start a new daemon after this one exits.", tostring(detail))
		return false, detail
	end
	return perform, function() return in_flight end, abandon
end

return M
