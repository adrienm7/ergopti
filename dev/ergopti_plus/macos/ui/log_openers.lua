--- ui/log_openers.lua

--- ==============================================================================
--- MODULE: Log Openers
--- DESCRIPTION:
--- Opens the logs folder, today's log and today's errors file for the Debug
--- menu and for the gesture and shortcut actions, which only differ in who
--- owns the asynchronous opener.
---
--- FEATURES & RATIONALE:
--- 1. One resolver. Every path comes from the logger at the moment of the
---    click. The menu and the gesture actions each used to rebuild the folder
---    from the configuration folder and read paths the logger fixed at boot,
---    so after midnight both opened yesterday's file.
--- 2. Never a blocking call on the main thread. The caller hands in an
---    asynchronous opener (ShellRunner.open for the menu, the gesture owner for
---    actions); the folder is created in-process, not by forking a shell.
--- 3. A missing errors file is an answer, not a failure. The file only exists
---    once something warned that day; opening a missing path did nothing
---    visible, and the user could not tell "no error" from "broken menu".
--- ==============================================================================

local M = {}
local hs            = hs
local Logger        = require("infra.logger")
local ConfigPaths   = require("infra.config_paths")
local i18n          = require("infra.i18n")
local notifications = require("infra.notifications")
local FileSystem    = require("adapters.file_system")

local LOG = "log_openers"





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- Refuses a call without an opener: a silent no-op is how a broken menu row
--- looks exactly like a working one.
--- @param open_fn any Candidate opener.
local function require_opener(open_fn)
	if type(open_fn) ~= "function" then
		error("log openers need an asynchronous opener function", 3)
	end
end

--- Distinguishes a missing errors file from an inspection failure.
--- @param path string Absolute path.
--- @return string status `present`, `absent`, or `error`.
local function errors_file_status(path)
	local status, attributes = FileSystem.path_status(path)
	if status ~= "present" then return status end
	if type(attributes) ~= "table" then return "error" end
	if attributes.mode == "link" then
		local followed, target = pcall(hs.fs.attributes, path)
		if not followed or type(target) ~= "table" then return "error" end
		attributes = target
	end
	return attributes.mode == "file" and "present" or "error"
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the logs folder, creating it first when it is missing.
--- @param open_fn function Asynchronous opener receiving the absolute folder.
--- @return boolean started False when the folder could not be created or opened.
function M.open_logs_folder(open_fn)
	require_opener(open_fn)
	local folder = Logger.logs_dir()
	if ConfigPaths.ensure_dir(folder) ~= true then
		Logger.error(LOG, "Logs folder '%s' could not be created; nothing opened.", folder)
		return false
	end
	return open_fn(folder) == true
end

--- Opens today's unified log, named by the logger at the moment of the call.
--- @param open_fn function Asynchronous opener receiving the absolute path.
--- @return boolean started
function M.open_today_log(open_fn)
	require_opener(open_fn)
	return open_fn(Logger.today_log_path()) == true
end

--- Opens today's errors file, or says that nothing warned today when it does
--- not exist yet.
--- @param open_fn function Asynchronous opener receiving the absolute path.
--- @return boolean handled True when the file was opened or the user was told.
function M.open_today_errors(open_fn)
	require_opener(open_fn)
	local path = Logger.today_errors_path()
	local status = errors_file_status(path)
	if status == "present" then return open_fn(path) == true end
	if status ~= "absent" then
		Logger.error(LOG, "Today's errors file could not be inspected; nothing opened.")
		return false
	end
	Logger.info(LOG, "No errors file for today at '%s'; the user is told instead.", path)
	local notified, notify_err = notifications.notify(i18n.get("menu.debug.no_errors_today"))
	if notified ~= true then
		Logger.error(LOG, "The no-errors-today notification failed: %s.", tostring(notify_err))
		return false
	end
	return true
end

return M
