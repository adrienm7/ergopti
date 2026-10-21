--- infra/native_timer.lua

--- ==============================================================================
--- MODULE: Native Relative Timer Arming
--- DESCRIPTION:
--- Refreshes libuv's cached loop clock immediately before arming a relative
--- delay, including after blocking work inside a native callback. Callers retain
--- ownership of their handles, start receipts and protected cleanup paths.
--- Every delay is admitted against the shared timer ceiling first: LuaJIT's
--- conversion of a double beyond the native range to libuv's uint64 timeout is
--- undefined and armed a timer that never fired.
--- ==============================================================================
local M = {}

local NumberPolicy = require("number_policy")

--- @param luv table Native backend, passed explicitly to preserve dependency isolation.
--- @param handle any Owned native timer.
--- @param timeout_ms number Initial relative delay in milliseconds.
--- @param repeat_ms number Repeat delay; zero for a one-shot timer.
--- @param callback function Native timer callback.
--- @return any start_result Native timer_start receipt, or nil when a delay is refused.
--- @return any detail Native error detail, or the refusal reason.
function M.start(luv, handle, timeout_ms, repeat_ms, callback)
	-- Refused in libuv's own failure shape, so every caller's receipt check
	-- already treats it as a timer that was not armed.
	if not NumberPolicy.within_timer_ceiling(timeout_ms) or not NumberPolicy.within_timer_ceiling(repeat_ms) then
		return nil, string.format("timer delay %s/%s ms is not finite or exceeds the %.0f ms ceiling",
			tostring(timeout_ms), tostring(repeat_ms), NumberPolicy.MAX_TIMER_DELAY_MS)
	end
	-- libuv caches loop time. Blocking work since the last iteration must not
	-- consume a delay that is only being requested now. update_time returns void;
	-- retain timer_start's own result tuple for the caller's admission checks.
	luv.update_time()
	return luv.timer_start(handle, timeout_ms, repeat_ms, callback)
end

return M
