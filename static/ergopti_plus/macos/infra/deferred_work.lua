--- infra/deferred_work.lua

--- ==============================================================================
--- MODULE: Retained Deferred Work
--- DESCRIPTION:
--- Owns fire-and-forget one-shot callbacks through TimerScheduler. A raw
--- hs.timer.doAfter return value that exists only in a function local can be
--- finalized as soon as that function returns, silently cancelling its work.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "deferred_work"

--- Schedules one callback behind the process-wide strong timer registry.
--- @param delay number Delay in seconds.
--- @param callback function Zero-argument work callback.
--- @param label string Stable diagnostic owner label.
--- @return boolean committed True only when the native timer committed.
function M.after(delay, callback, label)
	if type(delay) ~= "number" or delay < 0 or delay ~= delay
		or delay == math.huge or delay == -math.huge
	then
		Logger.error(LOG, "Deferred work refused: invalid delay for '%s'.", tostring(label))
		return false
	end
	if type(callback) ~= "function" then
		Logger.error(LOG, "Deferred work refused: callback missing for '%s'.", tostring(label))
		return false
	end
	if type(label) ~= "string" or label == "" then
		Logger.error(LOG, "Deferred work refused: owner label is required.")
		return false
	end

	local ok, handle_or_err, committed, detail = xpcall(function()
		return TimerScheduler.after(delay, callback)
	end, debug.traceback)
	if not ok or committed ~= true then
		local refusal = ok and (detail or committed) or handle_or_err
		Logger.error(LOG, "Deferred work '%s' did not commit: %s.", label,
			tostring(refusal))
		return false
	end
	return true
end

return M
