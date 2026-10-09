--- ui/log_openers.lua

--- ==============================================================================
--- MODULE: Log Openers (Linux)
--- DESCRIPTION:
--- Opens the logs folder, today's log and today's errors file for the tray
--- menu and for the gesture and shortcut actions, which only differ in how
--- they hand a path to xdg-open. The macOS and Windows twins are
--- ui/log_openers.lua and ui/log_openers.ahk.
---
--- FEATURES & RATIONALE:
--- 1. One resolver. Every path comes from the logger sink (LogsDirPath, or
---    ${XDG_STATE_HOME:-~/.local/state}/ergopti_plus/logs) at the moment of
---    the click, so a daemon up past midnight never opens yesterday's file.
--- 2. A missing errors file is an answer, not a failure. It only exists once
---    something warned that day, and xdg-open on a missing path fails without
---    a word; the user is now told that nothing warned today.
--- ==============================================================================

local M = {}

local Logger     = require("logger.shim")
local LoggerSink = require("infra.logger_sink")

local LOG = "log_openers"





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- Refuses a call without an opener: a silent no-op looks exactly like a
--- working menu row.
--- @param fn any Candidate function.
--- @param what string Which argument, for the error.
local function require_function(fn, what)
	if type(fn) ~= "function" then error("log openers need " .. what, 3) end
end

--- True when `path` names a readable file.
--- @param path string Absolute path.
--- @return boolean
local function file_exists(path)
	local handle = io.open(path, "r")
	if not handle then return false end
	handle:close()
	return true
end

--- The default notification: the desktop notifier with the localized text.
--- @param key string i18n key.
--- @return boolean delivered
local function notify_default(key)
	local message = require("infra.i18n").get(key)
	return require("adapters.application_notifier").send(message, { level = "info" }) == true
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the logs folder the sink writes to.
--- @param open_fn function Receives the absolute folder; returns true when started.
--- @return boolean started
function M.open_logs_folder(open_fn)
	require_function(open_fn, "an opener function")
	return open_fn(LoggerSink.log_dir()) == true
end

--- Opens today's unified log, named by the sink at the moment of the call.
--- @param open_fn function Receives the absolute path; returns true when started.
--- @return boolean started
function M.open_today_log(open_fn)
	require_function(open_fn, "an opener function")
	return open_fn(LoggerSink.main_log_path()) == true
end

--- Opens today's errors file, or says that nothing warned today.
--- @param open_fn function Receives the absolute path; returns true when started.
--- @param notify_fn function|nil Receives an i18n key; defaults to the desktop notifier.
--- @return boolean handled True when the file was opened or the user was told.
function M.open_today_errors(open_fn, notify_fn)
	require_function(open_fn, "an opener function")
	notify_fn = notify_fn or notify_default
	require_function(notify_fn, "a notification function")
	local path = LoggerSink.errors_log_path()
	if file_exists(path) then return open_fn(path) == true end
	Logger.info(LOG, "No errors file for today at '%s'; the user is told instead.", path)
	local delivered = notify_fn("menu.debug.no_errors_today")
	if delivered ~= true then
		Logger.error(LOG, "The no-errors-today notification was not delivered.")
		return false
	end
	return true
end

return M
