--- tests/fakes/metrics_keystats.lua

--- Explicit synchronous flush protocol for dashboard reader test doubles.
local M = {}

--- Adds a coherent, initialized flush owner to an existing keystats double.
--- @param keystats table Reader and mutation test implementation.
--- @return table keystats
function M.synchronous(keystats)
	local generation = 1
	if type(keystats.reset_session) == "function" then
		local reset = keystats.reset_session
		keystats.reset_session = function(...)
			local accepted = reset(...)
			if accepted == true then generation = generation + 1 end
			return accepted
		end
	end
	keystats.get_flush_status = function()
		return { phase = "idle", pending = false, has_debt = false, read_safe = true,
			committed = true, stopping = false, generation = generation }
	end
	keystats.is_flush_pending = function() return false end
	keystats.has_flush_debt = function() return false end
	keystats.when_flush_settled = function(callback)
		callback(keystats.get_flush_status())
		return true
	end
	return keystats
end

return M
