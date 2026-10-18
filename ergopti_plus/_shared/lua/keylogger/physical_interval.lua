--- _shared/lua/keylogger/physical_interval.lua

--- Pure permission policy over validated, ordered retained observations.
--- Native clock conversion, history lifetime and capture gaps belong to callers.
local M = {}

--- Checks both endpoints and every observed permission boundary between them.
--- A later allowed observation cannot repair an earlier forbidden part of a hold.
--- Application changes never alter permission or the caller's press attribution.
---@param observations table Ordered scalar snapshots with at and allowed fields.
---@param first_ns integer Original press in the history owner's clock domain.
---@param last_ns integer Original release, at or after the press.
---@return boolean permitted False if initial coverage is missing or any part is forbidden.
function M.permits(observations, first_ns, last_ns)
	local selected
	for _, observation in ipairs(observations) do
		if observation.at > last_ns then break end
		if observation.at <= first_ns then
			selected = observation
		elseif observation.allowed ~= true then
			return false
		end
	end
	return selected ~= nil and selected.allowed == true
end

return M
