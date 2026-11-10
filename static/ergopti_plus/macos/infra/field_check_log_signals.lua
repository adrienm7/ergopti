--- infra/field_check_log_signals.lua

--- ==============================================================================
--- MODULE: Field Check, Named Log Signals
--- DESCRIPTION:
--- The field run's count of the day-log lines several Mac checks are read from
--- (TODO, To confirm on the Mac): the gesture timing error a reload must not
--- bring back (L46), the window toggles that must log no error, the starts a
--- hotstring reload rolled back, the three-finger candidates a gate rejected,
--- the synthetic text moved off a held key (`asa` typed fast) and the pending
--- predictions a user activity cancelled. A person reading the report then
--- knows which of those happened today without opening the log.
---
--- FEATURES & RATIONALE:
--- 1. One POSIX awk pass over today's log prints counts and enumerated names
---    only (a gate, an activity kind): no logged text reaches the report, and a
---    task's output is read when it exits, so the lines never reach the pipe.
--- 2. An error signal fails its step by name when it appeared at all; an
---    activity signal is information, with its most frequent name.
--- 3. The activity lines are DEBUG lines: the field run asks for Debug > Log
---    level > DEBUG, and a count of 0 at a higher level says nothing.
--- ==============================================================================

local Report = require("field_check_report")

local M = {}

local PASS, FAIL, INFO = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO

local AWK = "/usr/bin/awk"
-- One pass over one day log.
local TOOL_SECONDS = 10





-- ==============================
-- ==============================
-- ======= 1/ The signals =======
-- ==============================
-- ==============================

--- The error signals, each failing its step when the day log holds one. The
--- patterns are the canonical Logger lines "TS [LEVEL] [module] message".
--- @type table { { step, name } } in report order
M.ERROR_SIGNALS = {
	-- modules/gestures/init.lua: a touch frame without the trackpad's stamp.
	{ step = "log_capture_stamp_errors", name = "capture_stamp" },
	-- ui/window_toggle.lua: a window-toggle action that could not act.
	{ step = "log_window_toggle_errors", name = "window_toggle" },
	-- modules/dynamic_hotstrings: a personal or dynamic start rolled back.
	{ step = "log_start_rollbacks", name = "start_rollback" },
}

-- POSIX awk only: macOS ships the BWK awk.
M.LOG_SIGNALS_AWK = [=[
function top(names,   name, best, best_n) {
	best = "none"; best_n = 0
	for (name in names) if (names[name] > best_n) { best_n = names[name]; best = name }
	return best
}
/\[ERROR\] \[gestures\] Touch frame from device=.* has no capture timestamp/ { capture_stamp++ }
/\[ERROR\] \[window_toggle\] / { window_toggle++ }
/\[ERROR\] \[[^]]*\] .*(start rolled back after|publication transaction rolled back)/ { start_rollback++ }
match($0, /Three-finger candidate rejected by [A-Za-z_][A-Za-z0-9_]*/) {
	rejections++; gate[substr($0, RSTART + 35, RLENGTH - 35)]++
}
/Synthetic text moved off a held key/ { held_key++ }
match($0, /User activity \([A-Za-z_][A-Za-z0-9_]*\)/) {
	cancels++; reason[substr($0, RSTART + 15, RLENGTH - 16)]++
}
END {
	printf "capture_stamp %d\nwindow_toggle %d\nstart_rollback %d\n", capture_stamp, window_toggle, start_rollback
	printf "rejections %d %s\nheld_key %d\ncancels %d %s\n", rejections, top(gate), held_key, cancels, top(reason)
}
]=]

--- Reads the awk summary.
--- @param text any
--- @return table|nil summary { capture_stamp, window_toggle, start_rollback, held_key = number,
---   rejections = { count, top }, cancels = { count, top } }, nil when a line is missing
function M.parse_summary(text)
	local summary = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local name, count = line:match("^([%a_]+) (%d+)$")
		if name then summary[name] = tonumber(count) end
		local named, named_count, top = line:match("^([%a_]+) (%d+) ([%w_]+)$")
		if named then summary[named] = { count = tonumber(named_count), top = top } end
	end
	for _, signal in ipairs(M.ERROR_SIGNALS) do
		if type(summary[signal.name]) ~= "number" then return nil end
	end
	if type(summary.held_key) ~= "number" or type(summary.rejections) ~= "table"
		or type(summary.cancels) ~= "table" then
		return nil
	end
	return summary
end





-- ============================
-- ============================
-- ======= 2/ The check =======
-- ============================
-- ============================

--- Runs the check.
--- ports.today_log_path(), exec.
--- @param ports table
--- @param report table field_check_report report.
--- @param finish function
function M.log_signals(ports, report, finish)
	local path = ports.today_log_path()
	if type(path) ~= "string" or path == "" then
		report.step("signals_log", FAIL, "no_log")
		return finish()
	end
	ports.exec(AWK, { M.LOG_SIGNALS_AWK, path }, TOOL_SECONDS, function(code, output)
		local summary = code == 0 and M.parse_summary(output) or nil
		if summary == nil then
			report.step("signals_log", FAIL, code == nil and "timeout" or "unreadable")
			return finish()
		end
		report.step("signals_log", PASS)
		for _, signal in ipairs(M.ERROR_SIGNALS) do
			local count = summary[signal.name]
			report.step(signal.step, count == 0 and PASS or FAIL, count)
		end
		report.step("log_three_finger_rejections", INFO,
			summary.rejections.count .. ":" .. summary.rejections.top)
		report.step("log_held_key_moves", INFO, summary.held_key)
		report.step("log_prediction_activity_cancels", INFO, summary.cancels.count .. ":" .. summary.cancels.top)
		finish()
	end)
end

return M
