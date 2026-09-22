--- adapters/boot_journal.lua

--- ==============================================================================
--- MODULE: Boot Journal
--- DESCRIPTION:
--- Synchronous, crash-proof trail of boot stages written outside the Logger
--- pipeline.
---
--- FEATURES & RATIONALE:
--- 1. Survives every failure mode: Logger lines are queued in memory once the
---    native worker owns persistence, and os.exit() discards that queue. Each
---    journal line is appended and closed before the stage continues.
--- 2. Findable before the user folder exists: lines always reach the fallback
---    boot log, and reach launcher.log until the configured log folder is
---    committed, so a failure at config-path or logger setup is readable in
---    ~/Library/Logs/ErgoptiPlus.
--- 3. Privacy: callers pass stage names, paths and durations only.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

--- Environment variable naming the launcher's own log file.
M.LAUNCHER_LOG_ENV = "ERGOPTI_LAUNCHER_LOG_FILE"

-- Test seams; production keeps the process environment and real files.
local _deps = {}

-- Set once the configured log folder is committed; launcher.log then stops
-- receiving the per-stage trail and keeps only fatal lines.
local _user_log_ready = false

--- Appends or writes one complete text and closes the handle before returning.
--- @param open function io.open-compatible opener.
--- @param path string Absolute destination.
--- @param mode string "ab" or "wb"; binary mode keeps LF on every host.
--- @param text string Complete content.
--- @return boolean written
--- @return string|nil detail
function M.write_now(open, path, mode, text)
	local ok, handle, open_err = pcall(open, path, mode)
	if not ok or not handle then
		return false, tostring(ok and open_err or handle)
	end
	local write_ok, write_err = pcall(function()
		assert(handle:write(text))
		assert(handle:flush())
	end)
	local close_ok, closed = pcall(function() return handle:close() end)
	if not write_ok then return false, tostring(write_err) end
	if not close_ok or not closed then return false, "close refused" end
	return true
end

--- Replaces the test seams: getenv, open, clock and fallback_path.
--- @param deps table|nil Nil restores production behaviour.
function M.configure_for_tests(deps)
	_deps = type(deps) == "table" and deps or {}
	_user_log_ready = false
end

--- Records that the configured log folder now holds the daily log.
--- @param ready boolean
function M.set_user_log_ready(ready)
	_user_log_ready = ready == true
end

--- Describes how one folder resolves, for the boot trail: users version their
--- configuration in Git through symbolic links, and a link to another volume or
--- a dangling target explains most folder refusals.
--- @param path string Absolute folder path.
--- @return string description "folder", "symbolic link to <target>", or "absent".
function M.describe_path(path)
	local fs = type(hs) == "table" and hs.fs or nil
	if type(path) ~= "string" or path == "" or type(fs) ~= "table" then return "unknown" end
	local trimmed = path:gsub("/+$", "")
	local link_ok, link = pcall(fs.symlinkAttributes, trimmed)
	if not link_ok or type(link) ~= "table" then return "absent" end
	if link.mode ~= "link" then return tostring(link.mode) end
	local target_ok, target = pcall(fs.pathToAbsolute, trimmed)
	if not target_ok or type(target) ~= "string" then return "symbolic link to a missing target" end
	return "symbolic link to " .. target
end

--- Appends one boot-stage line to the fallback boot log and, while the user
--- log folder is not committed, to launcher.log.
--- @param variant string Log variant label such as "START" or "SUCCESS".
--- @param message string Stage message without timestamp.
--- @return boolean written True when the fallback boot log accepted the line.
function M.append(variant, message)
	local open = _deps.open or io.open
	local getenv = _deps.getenv or os.getenv
	local clock = _deps.clock or function() return os.date("%Y-%m-%d %H:%M:%S") end
	local stamp = clock()
	local written = M.write_now(open, _deps.fallback_path or Logger.FALLBACK_BOOT_LOG_FILE, "ab",
		string.format("%s [%s] [init] %s\n", stamp, tostring(variant), tostring(message)))
	if not _user_log_ready then
		local launcher_log = getenv(M.LAUNCHER_LOG_ENV)
		if type(launcher_log) == "string" and launcher_log ~= "" then
			M.write_now(open, launcher_log, "ab", string.format("[%s] embedded Hammerspoon boot %s: %s\n",
				stamp, tostring(variant), tostring(message)))
		end
	end
	return written
end

return M
