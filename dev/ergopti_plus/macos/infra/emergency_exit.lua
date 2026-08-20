--- infra/emergency_exit.lua

--- ==============================================================================
--- MODULE: Bounded Emergency Exit
--- DESCRIPTION:
--- Requests a normal exact-fence exit while arming a hard deadline first. If
--- the asynchronous fence never settles, process exit closes the native worker's
--- stdin and transfers revocation to the surviving guardian.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "infra.emergency_exit"

--- Emits diagnostics without allowing a broken logger to defeat the native EOF
--- backstop this module exists to guarantee.
local function report_error(...)
	pcall(Logger.error, LOG, ...)
end

--- Starts one bounded exit request.
--- @param options table reason/deadline/exit_code/schedule/request_exit/exit capabilities.
--- @return boolean accepted True only when the controlled request was accepted.
function M.request(options)
	if type(options) ~= "table"
		or type(options.reason) ~= "string" or options.reason == ""
		or type(options.deadline_seconds) ~= "number" or options.deadline_seconds <= 0
		or type(options.exit_code) ~= "number" or options.exit_code % 1 ~= 0
		or options.exit_code < 1 or options.exit_code > 255
		or type(options.schedule) ~= "function"
		or type(options.request_exit) ~= "function"
		or type(options.exit) ~= "function" then
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
		report_error("Forcing process exit so native stdin EOF revokes the exact lease: %s",
			tostring(detail))
		local exit_ok, exit_err = xpcall(function()
			return options.exit(options.exit_code)
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
