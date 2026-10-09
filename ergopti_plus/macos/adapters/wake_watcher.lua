--- adapters/wake_watcher.lua

--- ==============================================================================
--- MODULE: Wake Watcher Adapter (Hammerspoon)
--- DESCRIPTION:
--- Calls one callback when the Mac wakes from sleep, through
--- hs.caffeinate.watcher, so a module can re-evaluate wall-clock work (the
--- automatic update checks) without depending on the hs API.
---
--- FEATURES & RATIONALE:
--- 1. One event: only systemDidWake reaches the callback; the other power and
---    session events are ignored here.
--- 2. Visible failures: construction, start and stop failures are logged and
---    reported as false, and a throwing callback is logged with its traceback
---    instead of vanishing inside the native watcher.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.wake_watcher"

--- Creates a stopped watcher.
--- @param on_wake function Zero-arity callback run after each wake.
--- @return table watcher { start = function(): boolean, stop = function(): boolean }
function M.new(on_wake)
	if type(on_wake) ~= "function" then error("a wake watcher needs a callback", 2) end
	local watcher = {}
	local native = nil

	--- Starts watching; a second start is a no-op.
	--- @return boolean started
	function watcher.start()
		if native then return true end
		local ok, candidate_or_err = xpcall(function()
			local wake_event = hs.caffeinate.watcher.systemDidWake
			return hs.caffeinate.watcher.new(function(event)
				if event ~= wake_event then return end
				local called, err = xpcall(on_wake, debug.traceback)
				if not called then Logger.error(LOG, "Wake callback raised: %s.", tostring(err)) end
			end)
		end, debug.traceback)
		if not ok or candidate_or_err == nil then
			Logger.error(LOG, "The wake watcher could not be created: %s.", tostring(candidate_or_err))
			return false
		end
		local started, result_or_err = xpcall(function() return candidate_or_err:start() end, debug.traceback)
		if not started or result_or_err ~= candidate_or_err then
			Logger.error(LOG, "The wake watcher could not start: %s.", tostring(result_or_err))
			return false
		end
		native = candidate_or_err
		return true
	end

	--- Stops watching; the exact native watcher is kept when stop fails.
	--- @return boolean stopped
	function watcher.stop()
		if native == nil then return true end
		local ok, err = xpcall(function() native:stop() end, debug.traceback)
		if not ok then
			Logger.error(LOG, "The wake watcher could not stop: %s.", tostring(err))
			return false
		end
		native = nil
		return true
	end

	return watcher
end

return M
