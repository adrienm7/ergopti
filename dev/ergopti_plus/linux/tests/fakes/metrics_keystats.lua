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
	local receipts = setmetatable({}, { __mode = "k" })
	keystats.request_session_reset = function(complete)
		if type(complete) ~= "function" or type(keystats.reset_session) ~= "function" then return false end
		local origin = generation
		local success = keystats.reset_session()
		local receipt = {}
		receipts[receipt] = { origin = origin, generation = generation, success = success == true }
		complete(success == true, receipt)
		return true
	end
	keystats.reset_receipt_generation = function(receipt, origin)
		local record = receipts[receipt]
		if not record or record.origin ~= origin or record.generation ~= generation then return nil end
		return record.generation, record.success
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
