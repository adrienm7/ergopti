--- infra/libuv_process_group.lua
--- ==============================================================================
--- MODULE: Native Libuv Process Group Retirement
--- DESCRIPTION:
--- Interprets Linux signal receipts for an owned detached process group. A
--- reaped leader does not release descendants; native ESRCH proves the group
--- is already absent. The backend is supplied by each adapter, not captured.
--- ==============================================================================

local M = {}

--- Sends one signal without treating native group absence as a stop failure.
--- @param backend table Native libuv binding.
--- @param pid number Detached group leader's original PID.
--- @param signal string
--- @return boolean accepted
--- @return boolean absent
function M.signal(backend, pid, signal)
	if not backend or type(backend.kill) ~= "function" or type(pid) ~= "number"
		or pid < 1 or pid % 1 ~= 0 then return false, false end
	local ok, accepted, _, code = pcall(backend.kill, -pid, signal)
	if not ok then return false, false end
	if accepted == nil and code == "ESRCH" then return true, true end
	return accepted ~= nil and accepted ~= false, false
end

--- Retires the group even when descendants ignore the graceful signal.
--- @param backend table Native libuv binding.
--- @param pid number Detached group leader's original PID.
--- @return boolean Accepted retirement or proven native absence.
function M.terminate(backend, pid)
	local accepted, absent = M.signal(backend, pid, "sigterm")
	if not accepted or absent then return accepted end
	local forced = M.signal(backend, pid, "sigkill")
	return forced
end

return M
