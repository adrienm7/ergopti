--- modules/llm/mlx_stream_retirement.lua

--- ==============================================================================
--- MODULE: MLX Stream Retirement Ownership
--- DESCRIPTION:
--- An accepted SIGTERM is not a native exit receipt. Retain each exact curl
--- handle until ShellRunner proves settlement, independently of the business
--- generation that may already have been revoked by pause or replacement.
--- ==============================================================================

local M = {}
local observed = setmetatable({}, { __mode = "k" })

--- Cancels one exact stream without releasing a still-live native child.
--- @param stream table Controller-owned streaming state.
--- @param task table Exact ShellRunner handle.
--- @return boolean settled True only after native exit is proven.
--- @return string state settled, pending or refused.
function M.cancel(stream, task)
	local function release()
		if stream.task == task then
			stream.task = nil
			stream.has_chunks = false
		end
	end
	local function settled()
		if type(task.isSettled) ~= "function" then return false end
		local ok, result = pcall(task.isSettled)
		return ok and result == true
	end
	if settled() then release(); return true, "settled" end
	if not observed[task] then
		if type(task.onSettled) ~= "function" then return false, "refused" end
		observed[task] = true
		local ok, registered = pcall(task.onSettled, release)
		if not ok or registered ~= true then
			observed[task] = nil
			return false, "refused"
		end
	end
	local ok, accepted = pcall(task.terminate)
	if settled() then release(); return true, "settled" end
	return false, ok and accepted == true and "pending" or "refused"
end

return M
