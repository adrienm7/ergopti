--- modules/diagnostics/crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter (Linux)
--- DESCRIPTION:
--- Basic crash diagnostics for the Linux daemon. Writes crash dumps to the
--- crash_reports folder inside the logs folder when a pcall-wrapped operation
--- fails with a non-trivial error. Mirrors macOS infra/crash_reporter.lua in intent but
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
-- Crash dumps live in the logs folder, next to the daily log that explains
-- them, and follow a LogsDirPath override: resolved per call.
--- @return string Absolute folder, no trailing slash.
local function crash_dir()
	return require("infra.logger_sink").crash_reports_dir()
end


-- =========================================
-- =========================================
-- ======= 2/ Path Resolution ==============
-- =========================================
-- =========================================

--- Ensures the crash directory exists.
local function _ensure_dir(directory)
	return os.execute("mkdir -p '" .. directory:gsub("'", "'\\''") .. "' 2>/dev/null")
end

--- Rotates old crash files when the directory exceeds MAX_CRASH_FILES.
local function _rotate(directory)
	local files = {}
	local pipe = io.popen("ls -1t '" .. directory:gsub("'", "'\\''") .. "' 2>/dev/null")
	if not pipe then return end
	for line in pipe:lines() do
		files[#files + 1] = line
	end
	pipe:close()

	while #files > MAX_CRASH_FILES do
		local oldest = files[#files]
		os.remove(directory .. "/" .. oldest)
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

--- Only a fixed failure may bypass the admitted sink through stderr.
local function refused()
	pcall(function() io.stderr:write("[crash_reporter] Crash dump refused; privacy or output acknowledgement unavailable.\n") end)
	return false
end

--- Writes a fully redacted document under the original sink admission.
--- Safe in error handlers: a reporting failure must not replace the real error.
--- @param module_name string Name of the module where the error occurred.
--- @param error_msg string Error message (tostring(err) from pcall).
--- @param context table|nil Optional { stack_trace?, layout?, locale? }.
--- @return boolean True after the redacted file's write and close acknowledge.
function M.dump(module_name, error_msg, context)
	if type(module_name) ~= "string" or type(error_msg) ~= "string" or error_msg == "" then return false end
	local available, Sink = pcall(require, "infra.logger_sink")
	if not available or type(Sink) ~= "table" or type(Sink.capture_redactor) ~= "function"
		or type(Sink.crash_reports_dir) ~= "function" then return refused() end
	local capture, resolve = Sink.capture_redactor, Sink.crash_reports_dir
	local admitted, redact, current = pcall(capture)
	if not admitted or type(redact) ~= "function" or type(current) ~= "function" then return refused() end
	local function live()
		if package.loaded["infra.logger_sink"] ~= Sink or Sink.capture_redactor ~= capture
			or Sink.crash_reports_dir ~= resolve then return false end
		local ok, value = pcall(current)
		return ok and value == true
	end
	local resolved, directory = pcall(resolve)
	if not resolved or type(directory) ~= "string" or directory == "" or not live() then return refused() end
	local prepared, document, name = pcall(function()
		local commit, config, version, app = _build_facts()
		local parts = { "=== Ergopti Linux Crash Dump ===\n", "Timestamp: " .. os.date() .. "\n",
			"Module:    " .. module_name .. "\n", "Error:     " .. error_msg .. "\n",
			"Version:   " .. version .. "\n", "Commit:    " .. commit .. "\n",
			"App dir:   " .. app .. "\n", "Config:    " .. config .. "\n" }
		if type(context) == "table" then
			for _, field in ipairs({ { "stack_trace", "Stack:\n" }, { "layout", "Layout: " }, { "locale", "Locale: " } }) do
				local value = context[field[1]]
				if type(value) == "string" then parts[#parts + 1] = field[2] .. value .. "\n" end
			end
		end
		return redact(table.concat(parts)), redact(module_name)
	end)
	if not prepared or type(document) ~= "string" or type(name) ~= "string" or not live() then return refused() end
	local path = directory .. "/crash_" .. os.date("!%Y-%m-%dT%H-%M-%S") .. "_" .. name:gsub("[^%w_.-]", "_") .. ".txt"
	local made, status = pcall(_ensure_dir, directory)
	if not made or (status ~= true and status ~= 0) or not live() then return refused() end
	local opened, file = pcall(io.open, path, "w")
	if not opened or not file then return refused() end
	local written, ack
	if live() then written, ack = pcall(file.write, file, document) end
	local closed, close_ack = pcall(file.close, file)
	if not written or (ack ~= true and ack ~= file) or not closed or close_ack ~= true or not live() then
		-- The bytes were redacted before opening. Do not unlink by path here:
		-- a reentrant close may already have published a successor at that name.
		return refused()
	end
	pcall(Logger.error, LOG, "Crash dump written: %s", path)
	if live() then pcall(_rotate, directory) end
	return true
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
	return crash_dir()
end

--- Returns the number of crash files currently on disk.
--- @return number
function M.get_crash_count()
	local count = 0
	local pipe = io.popen("ls -1 '" .. crash_dir():gsub("'", "'\\''") .. "' 2>/dev/null | wc -l")
	if pipe then
		local line = pipe:read("*l")
		pipe:close()
		count = tonumber(line) or 0
	end
	return count
end

return M
