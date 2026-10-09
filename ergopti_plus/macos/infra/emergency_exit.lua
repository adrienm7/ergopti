--- infra/emergency_exit.lua

--- ==============================================================================
--- MODULE: Bounded Emergency Exit
--- DESCRIPTION:
--- Requests a normal exact-fence exit while arming a hard deadline first. If
--- the asynchronous fence never settles, process exit closes the native worker's
--- stdin and transfers revocation to the surviving guardian.
---
--- FEATURES & RATIONALE:
--- 1. Deadline First: the timer is armed before the request, so a request that
---    never settles (lease fence, input drain, teardown, logger drain) still ends.
--- 2. Distinct Codes: a controlled request may exit 0 (user Quit) while the
---    deadline, rejection, or fence-failure fallback always exits non-zero.
--- 3. Stuck Stage: an optional describe() capability names the pending stage in
---    the forced-exit diagnostic, so a hang is attributable after the fact.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "infra.emergency_exit"

--- Emits diagnostics without allowing a broken logger to defeat the native EOF
--- backstop this module exists to guarantee.
local function report_error(...)
	pcall(Logger.error, LOG, ...)
end

--- Reports whether a value is an integer process status within [minimum, 255].
--- @param value any Candidate status.
--- @param minimum integer Smallest admissible status.
--- @return boolean valid
local function is_exit_code(value, minimum)
	return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= 255
end

--- Returns the optional stuck-stage description without letting a broken
--- describer defeat the forced exit it annotates.
--- @param describe function|nil Stage describer.
--- @return string stage
local function describe_stage(describe)
	if type(describe) ~= "function" then return "unknown" end
	local ok, stage = xpcall(describe, debug.traceback)
	if not ok then return "describer-failed: " .. tostring(stage) end
	return tostring(stage)
end

--- Starts one bounded exit request.
--- @param options table reason/deadline_seconds/exit_code/schedule/request_exit/exit
---   capabilities. `exit_code` is the controlled request status; the optional
---   `forced_exit_code` (default `exit_code`) is used by every fallback and must be
---   non-zero. The optional `describe()` names the pending stage on a forced exit.
--- @return boolean accepted True only when the controlled request was accepted.
function M.request(options)
	local forced_exit_code = type(options) == "table"
		and (options.forced_exit_code == nil and options.exit_code or options.forced_exit_code)
		or nil
	if type(options) ~= "table"
		or type(options.reason) ~= "string" or options.reason == ""
		or type(options.deadline_seconds) ~= "number" or options.deadline_seconds <= 0
		or not is_exit_code(options.exit_code, 0)
		or not is_exit_code(forced_exit_code, 1)
		or type(options.schedule) ~= "function"
		or type(options.request_exit) ~= "function"
		or type(options.exit) ~= "function"
		or (options.describe ~= nil and type(options.describe) ~= "function") then
		report_error("Emergency exit options are invalid.")
		return false
	end

	local exit_requested = false
	local deadline_timer = nil
	local function force_exit(detail)
		if exit_requested then return end
		exit_requested = true
		if deadline_timer then
			local stop_ok, stop_result = xpcall(function() return deadline_timer:stop() end, debug.traceback)
			if not stop_ok or stop_result == false then
				report_error("Emergency exit deadline timer could not be stopped: %s",
					tostring(stop_result))
			end
			deadline_timer = nil
		end
		report_error("Forcing process exit so native stdin EOF revokes the exact lease: %s (pending stage: %s)",
			tostring(detail), describe_stage(options.describe))
		local exit_ok, exit_err = xpcall(function()
			return options.exit(forced_exit_code)
		end, debug.traceback)
		if not exit_ok then
			report_error("Emergency process exit failed: %s", tostring(exit_err))
		end
	end

	local schedule_ok, timer_or_err = xpcall(function()
		return options.schedule(options.deadline_seconds, function()
			force_exit("deadline-expired")
		end)
	end, debug.traceback)
	if not schedule_ok or not timer_or_err then
		report_error("Emergency exit deadline could not be armed: %s", tostring(timer_or_err))
		force_exit("deadline-unavailable")
		return false
	end
	deadline_timer = timer_or_err
	-- A scheduler double may fire inline before returning its handle. Production
	-- hs.timer is asynchronous, but retaining a handle after the deadline already
	-- forced exit would make the module's ownership depend on that assumption.
	if exit_requested then
		local stop_ok, stop_result = xpcall(function() return deadline_timer:stop() end, debug.traceback)
		if not stop_ok or stop_result == false then
			report_error("Inline emergency deadline timer could not be stopped: %s",
				tostring(stop_result))
		end
		deadline_timer = nil
		return false
	end

	local request_ok, accepted_or_err = xpcall(function()
		return options.request_exit(options.reason, options.exit_code, function(detail)
			force_exit("exact-fence-failed: " .. tostring(detail))
		end)
	end, debug.traceback)
	if not request_ok or accepted_or_err ~= true then
		report_error("Controlled emergency exit request failed: %s", tostring(accepted_or_err))
		force_exit("request-rejected")
		return false
	end
	return true
end

return M
