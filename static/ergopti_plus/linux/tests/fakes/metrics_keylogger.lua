--- tests/fakes/metrics_keylogger.lua

--- Explicit synchronous flush protocol for dashboard reader test doubles.
local M = {}

--- Adds a coherent, initialized flush owner to an existing keylogger double.
--- @param keylogger table Reader and mutation test implementation.
--- @return table keylogger
function M.synchronous(keylogger)
	local generation = 1
	if type(keylogger.reset_session) == "function" then
		local reset = keylogger.reset_session
		keylogger.reset_session = function(...)
			local accepted = reset(...)
			if accepted == true then generation = generation + 1 end
			return accepted
		end
	end
	keylogger.get_flush_status = function()
		return { phase = "idle", pending = false, has_debt = false, read_safe = true,
			committed = true, stopping = false, generation = generation }
	end
	keylogger.is_flush_pending = function() return false end
	keylogger.has_flush_debt = function() return false end
	keylogger.when_flush_settled = function(callback)
		callback(keylogger.get_flush_status())
		return true
	end
	return keylogger
end

return M
