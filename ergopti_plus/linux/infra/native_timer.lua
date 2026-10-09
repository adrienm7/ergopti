--- infra/native_timer.lua

--- ==============================================================================
--- MODULE: Native Relative Timer Arming
--- DESCRIPTION:
--- Refreshes libuv's cached loop clock immediately before arming a relative
--- delay, including after blocking work inside a native callback. Callers retain
--- ownership of their handles, start receipts and protected cleanup paths.
--- ==============================================================================
local M = {}

--- @param luv table Native backend, passed explicitly to preserve dependency isolation.
--- @param handle any Owned native timer.
--- @param timeout_ms number Initial relative delay in milliseconds.
--- @param repeat_ms number Repeat delay; zero for a one-shot timer.
--- @param callback function Native timer callback.
--- @return any start_result Native timer_start receipt, with any error detail.
function M.start(luv, handle, timeout_ms, repeat_ms, callback)
	-- libuv caches loop time. Blocking work since the last iteration must not
	-- consume a delay that is only being requested now. update_time returns void;
	-- retain timer_start's own result tuple for the caller's admission checks.
	luv.update_time()
	return luv.timer_start(handle, timeout_ms, repeat_ms, callback)
end

return M
