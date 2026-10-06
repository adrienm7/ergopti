--- infra/libuv_exit.lua

--- ==============================================================================
--- MODULE: Native Libuv Process Exit Status
--- DESCRIPTION:
--- Linux libuv reports an exit code and a termination signal separately. A
--- signalled child can have code zero, so native runners must decode both fields
--- before applying their success contract. This helper owns that interpretation.
--- ==============================================================================

local M = {}

-- The shell convention preserves a signal as a non-zero status (SIGTERM = 143).
local SIGNAL_STATUS_BASE = 128

--- Converts one native libuv exit receipt into a caller-visible status.
--- @param code number Exit code reported by libuv.
--- @param signal number|nil Termination signal, zero for an ordinary exit.
--- @return number status Non-zero for any signalled or unknown exit.
function M.status(code, signal)
	local termination_signal = tonumber(signal) or 0
	if termination_signal > 0 then return SIGNAL_STATUS_BASE + termination_signal end
	return tonumber(code) or -1
end

return M
