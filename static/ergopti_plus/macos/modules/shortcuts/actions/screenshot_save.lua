--- modules/shortcuts/actions/screenshot_save.lua

--- ==============================================================================
--- MODULE: Screenshot Save Transaction
--- DESCRIPTION:
--- Owns the asynchronous mkdir -> screencapture lifecycle shared by configurable
--- shortcuts and gestures. Every accepted action gets a process-unique target;
--- native construction, start, and exit failures are logged and notified.
--- ==============================================================================

local M = {}

local hs            = hs
local ShellRunner   = require("adapters.shell_runner")
local FileSystem    = require("adapters.file_system")
local Logger        = require("infra.logger")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")

local LOG = "shortcuts.actions.screenshot_save"

local MKDIR_BIN         = "/bin/mkdir"
local SCREENCAPTURE_BIN = "/usr/sbin/screencapture"
local SCREENSHOT_DIR_REL = "/Pictures/screenshots"
local SCREENSHOT_STAMP_FMT = "%Y%m%d%H%M%S"

local _target_sequence = 0





-- ==========================================
-- ==========================================
-- ======= 1/ Transaction Helpers ===========
-- ==========================================
-- ==========================================

--- Emits one user-visible failure without allowing notification code to escape.
--- @param context string Failure context.
--- @param detail any Failure detail.
local function report_failure(context, detail)
	Logger.error(LOG, "Screenshot %s failed: %s.", context, tostring(detail))
	local notified, notify_error = pcall(
		notifications.notify,
		i18n.get("shortcuts.screenshot_failed"),
		nil,
		"error"
	)
	if not notified then
		Logger.error(LOG, "Screenshot failure notification failed: %s.", tostring(notify_error))
	end
end

--- Starts one ShellRunner owner and contains hostile test/native shapes.
--- @param executable string Absolute executable path.
--- @param args table Argument vector.
--- @param on_done function Completion callback.
--- @param context string Diagnostic context.
--- @return boolean started
local function start_task(executable, args, on_done, context)
	local constructed, task_or_error = xpcall(
		ShellRunner.spawn,
		debug.traceback,
		executable,
		args,
		on_done
	)
	if not constructed or type(task_or_error) ~= "table"
		or type(task_or_error.start) ~= "function" then
		report_failure(context .. " construction", task_or_error or "no task owner")
		return false
	end

	local start_ok, started = xpcall(task_or_error.start, debug.traceback)
	if not start_ok or started ~= true then
		report_failure(context .. " start", started)
		return false
	end
	return true
end

--- Allocates a collision-resistant target for one process/run-loop action.
--- @param prefix string Filename prefix.
--- @return string|nil target
--- @return string|nil error_message
local function next_target(prefix)
	local home_ok, home = pcall(FileSystem.expand_path, "~")
	if not home_ok or type(home) ~= "string" or home:sub(1, 1) ~= "/" then
		return nil, home or "home directory is unavailable"
	end

	local time_ok, ticks = pcall(hs.timer.absoluteTime)
	if not time_ok or type(ticks) ~= "number" then
		return nil, ticks or "hs.timer.absoluteTime is unavailable"
	end
	local pid_ok, process_id = pcall(function()
		return hs.processInfo.processID
	end)
	if not pid_ok or tonumber(process_id) == nil then
		return nil, process_id or "Hammerspoon process id is unavailable"
	end
	local stamp_ok, stamp = pcall(os.date, SCREENSHOT_STAMP_FMT)
	if not stamp_ok or type(stamp) ~= "string" then
		return nil, stamp or "wall-clock timestamp is unavailable"
	end

	_target_sequence = _target_sequence + 1
	local directory = home .. SCREENSHOT_DIR_REL
	local filename = string.format(
		"%s_%s_%d_%.0f_%d.png",
		prefix,
		stamp,
		tonumber(process_id),
		ticks,
		_target_sequence
	)
	return directory .. "/" .. filename
end





-- ==========================================
-- ==========================================
-- ======= 2/ Public Transaction ============
-- ==========================================
-- ==========================================

--- Saves one screenshot after its parent directory has committed.
--- @param flags table screencapture flags, excluding the final target path.
--- @param prefix string Filename prefix.
--- @return boolean accepted True only when the mkdir task was started.
function M.save(flags, prefix)
	if type(flags) ~= "table" or type(prefix) ~= "string" or prefix == "" then
		report_failure("request validation", "flags table and non-empty prefix are required")
		return false
	end

	local target, target_error = next_target(prefix)
	if not target then
		report_failure("target allocation", target_error)
		return false
	end
	local directory = target:match("^(.*)/[^/]+$")
	if not directory then
		report_failure("target allocation", "target directory is invalid")
		return false
	end

	return start_task(MKDIR_BIN, { "-p", directory }, function(exit_code)
		if exit_code ~= 0 then
			report_failure("directory creation", "exit code " .. tostring(exit_code))
			return false
		end

		local args = {}
		for _, flag in ipairs(flags) do args[#args + 1] = tostring(flag) end
		args[#args + 1] = target
		return start_task(SCREENCAPTURE_BIN, args, function(capture_exit_code)
			if capture_exit_code ~= 0 then
				report_failure("capture", "exit code " .. tostring(capture_exit_code))
				return false
			end
			local notified, notify_error = pcall(
				notifications.notify,
				string.format(i18n.get("shortcuts.saved"), target),
				nil,
				"success"
			)
			if not notified then
				Logger.error(LOG, "Screenshot success notification failed: %s.",
					tostring(notify_error))
			end
			return true
		end, "capture")
	end, "directory")
end

return M
