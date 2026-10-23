--- adapters/physical_lifecycle_event.lua

--- Maps an actual native lifecycle callback through the existing shared event policy.
local M = {}
local Observation = require("keystats.physical_lifecycle_observation")

--- Reads existing native constants only; an unknown event grants no awake facts.
---@param event any Existing native caffeinate callback event.
---@return table source Closed lifecycle fact or explicit unknown event.
function M.classify(event)
	local native = rawget(_G, "hs")
	local caffeinate = type(native) == "table" and rawget(native, "caffeinate") or nil
	local constants = type(caffeinate) == "table" and rawget(caffeinate, "watcher") or nil
	return Observation.system_event(constants, event)
end

return M
