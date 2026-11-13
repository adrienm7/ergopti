--- platform/system/power_source.lua

--- ==============================================================================
--- MODULE: Power Source
--- DESCRIPTION:
--- Answers whether this Mac runs on its battery, for background work that
--- paces itself by it.
---
--- FEATURES & RATIONALE:
--- 1. One read: the native call stays here, outside the purity-scanned modules.
--- 2. Fail towards the battery: an unreadable source must never make background
---    work spin on a laptop; the cost is a slower job, and it is logged.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")

local LOG = "platform.system.power_source"

--- The source hs.battery names when the Mac runs on its battery.
local BATTERY_SOURCE = "Battery Power"

--- The last read refusal already logged; each change is reported once.
local _reported_failure = nil

--- Reports whether the Mac runs on its battery.
--- @return boolean on_battery
function M.on_battery()
	local ok, source = pcall(function() return hs.battery.powerSource() end)
	if ok and (source == BATTERY_SOURCE or source == "AC Power" or source == "UPS Power") then
		_reported_failure = nil
		return source ~= "AC Power"
	end
	local failure = tostring(source)
	if _reported_failure ~= failure then
		_reported_failure = failure
		Logger.warn(LOG, "The power source cannot be read; background work paces for the battery: %s.", failure)
	end
	return true
end

return M
