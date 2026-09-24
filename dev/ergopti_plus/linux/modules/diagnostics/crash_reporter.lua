--- modules/diagnostics/crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter (Linux)
--- DESCRIPTION:
--- Basic crash diagnostics for the Linux daemon. Writes crash dumps to
--- ~/.local/share/ergopti/crashes/ when a pcall-wrapped operation fails with
--- a non-trivial error. Mirrors macOS infra/crash_reporter.lua in intent but
--- uses filesystem dumps instead of hs.crash.crashReporter.
---
--- FEATURES & RATIONALE:
--- 1. File-based dump: writes timestamped crash files with error message,
---    stack trace, and daemon state snapshot.
--- 2. Low overhead: only writes on actual errors; zero allocations on the
---    hot path (pcall returning ok=true is the common case).
--- 3. Crash history: keeps up to MAX_CRASH_FILES dumps, rotating oldest.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "diagnostics.crash_reporter"

-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

local MAX_CRASH_FILES = 20
local CRASH_DIR = require("infra.config_paths").data("crashes")


-- =========================================
-- =========================================
-- ======= 2/ Path Resolution ==============
-- =========================================
-- =========================================

--- Ensures the crash directory exists.
local function _ensure_dir()
	os.execute("mkdir -p '" .. CRASH_DIR:gsub("'", "'\\''") .. "' 2>/dev/null")
end

--- Rotates old crash files when the directory exceeds MAX_CRASH_FILES.
local function _rotate()
	local files = {}
	local pipe = io.popen("ls -1t '" .. CRASH_DIR:gsub("'", "'\\''") .. "' 2>/dev/null")
	if not pipe then return end
	for line in pipe:lines() do
		files[#files + 1] = line
	end
	pipe:close()

	while #files > MAX_CRASH_FILES do
		local oldest = files[#files]
		os.remove(CRASH_DIR .. "/" .. oldest)
		files[#files] = nil
	end
end


-- =========================================
-- =========================================
-- ======= 3/ Crash Dump ===================
-- =========================================
-- =========================================

--- The build commit and the configuration directory, rendered for the dump.
--- Which build crashed is the first question of every report, so both are read
--- on the crash path itself (a few file reads, no subprocess), before the dump
--- file is opened, and a resolver failure is written as its own reason rather
--- than costing the dump.
--- The version and the application directory are written the same way: the
--- daemon's only caller passes no context, so a dump that depended on it never
--- said which release crashed or which install tree it ran from.
--- @return string commit_line "<commit> (<source>)" or the failure reason.
--- @return string config_line The configuration directory or the failure reason.
--- @return string version_line "<version> (<source>)" or the failure reason.
--- @return string app_dir_line The driver root or the failure reason.
local function _build_facts()
	local ok_commit, commit, source = pcall(function()
		return require("infra.diagnostic_snapshot").resolve_commit()
	end)
	local commit_line = ok_commit and string.format("%s (%s)", tostring(commit), tostring(source))
		or ("unknown (resolution failed: " .. tostring(commit) .. ")")
	local ok_config, config_dir = pcall(function()
		return require("infra.config_paths").get_config_dir()
	end)
	local config_line = ok_config and tostring(config_dir)
		or ("unknown (resolution failed: " .. tostring(config_dir) .. ")")
	local ok_version, version, version_source = pcall(function()
		local Version = require("infra.version")
		return Version.VERSION, Version.SOURCE
	end)
	local version_line = ok_version and string.format("%s (%s)", tostring(version), tostring(version_source))
		or ("unknown (resolution failed: " .. tostring(version) .. ")")
	local ok_app, app_dir = pcall(function()
		return require("infra.paths").driver_root()
	end)
	local app_dir_line = ok_app and tostring(app_dir)
		or ("unknown (resolution failed: " .. tostring(app_dir) .. ")")
	return commit_line, config_line, version_line, app_dir_line
end

--- Writes a crash dump to the crash directory.
--- Safe to call from pcall error handlers — never throws.
---
--- @param module_name string Name of the module where the error occurred.
--- @param error_msg    string The error message (tostring(err) from pcall).
--- @param context      table|nil Optional context: { stack_trace?, state? }.
function M.dump(module_name, error_msg, context)
	if type(module_name) ~= "string" then return end
	if type(error_msg) ~= "string" or error_msg == "" then return end

	_ensure_dir()

	local ts = os.date("!%Y-%m-%dT%H-%M-%S")
	local safe_name = module_name:gsub("[^%w_.-]", "_")
	local path = CRASH_DIR .. "/crash_" .. ts .. "_" .. safe_name .. ".txt"
	local commit_line, config_line, version_line, app_dir_line = _build_facts()

	local fh = io.open(path, "w")
	if not fh then
		-- Last resort: log to stderr.
		io.stderr:write(string.format("[crash_reporter] Cannot write to %s\n", path))
		return
	end

	fh:write(string.format("=== Ergopti Linux Crash Dump ===\n"))
	fh:write(string.format("Timestamp: %s\n", os.date()))
	fh:write(string.format("Module:    %s\n", module_name))
	fh:write(string.format("Error:     %s\n", error_msg))
	fh:write(string.format("Version:   %s\n", version_line))
	fh:write(string.format("Commit:    %s\n", commit_line))
	fh:write(string.format("App dir:   %s\n", app_dir_line))
	fh:write(string.format("Config:    %s\n", config_line))

	if type(context) == "table" then
		if type(context.stack_trace) == "string" then
			fh:write(string.format("Stack:\n%s\n", context.stack_trace))
		end
		if type(context.layout) == "string" then
			fh:write(string.format("Layout: %s\n", context.layout))
		end
		if type(context.locale) == "string" then
			fh:write(string.format("Locale: %s\n", context.locale))
		end
	end

	fh:close()

	Logger.error(LOG, "Crash dump written: %s", path)

	_rotate()
end


-- =========================================
-- =========================================
-- ======= 4/ Convenience Wrappers =========
-- =========================================
-- =========================================

--- pcall wrapper that automatically dumps on error.
--- Usage: M.protect(module_name, function() ... end)
---
--- @param module_name string Module identifier for the crash dump.
--- @param fn           function The function to protect.
--- @param context      table|nil Optional context to include in crash dump.
--- @return boolean ok, any result
function M.protect(module_name, fn, context)
	if type(fn) ~= "function" then return false, "fn is not a function" end

	-- xpcall, not pcall. A traceback taken AFTER pcall returns describes the
	-- caller: the stack that threw has already been unwound, so every crash
	-- report said "crash" and then listed this function and whatever called it —
	-- the same three frames for every failure in the driver. The message handler
	-- runs BEFORE the unwind, which is the only place the real stack still exists.
	local captured = nil
	local ok, result = xpcall(fn, function(err)
		captured = debug.traceback(tostring(err), 2)
		return err
	end)

	if not ok then
		local ctx = type(context) == "table" and context or {}
		ctx.stack_trace = ctx.stack_trace or captured or debug.traceback("crash", 2)
		M.dump(module_name, tostring(result), ctx)
	end
	return ok, result
end

--- Returns the crash directory path (for diagnostics / menu access).
--- @return string
function M.get_crash_dir()
	return CRASH_DIR
end

--- Returns the number of crash files currently on disk.
--- @return number
function M.get_crash_count()
	local count = 0
	local pipe = io.popen("ls -1 '" .. CRASH_DIR:gsub("'", "'\\''") .. "' 2>/dev/null | wc -l")
	if pipe then
		local line = pipe:read("*l")
		pipe:close()
		count = tonumber(line) or 0
	end
	return count
end

return M
