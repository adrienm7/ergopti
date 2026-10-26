--- modules/diagnostics/crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter (Linux)
--- DESCRIPTION:
--- Crash reports for the Linux daemon. Writes a report to the crash_reports
--- folder inside the logs folder when a pcall-wrapped operation fails with a
--- non-trivial error, and tells the user where it landed.
---
--- FEATURES & RATIONALE:
--- 1. One content with macOS: the document, its file name and the retention cap
---    come from the shared crash_report module (parity audit D6, R31), so a
---    report from either driver has the same fields in the same order, including
---    the log ring buffer that explains the crash.
--- 2. One notice with macOS: a saved report raises a desktop notification naming
---    the file, a failed save raises the failure notice. The next-start dialog of
---    ui/error_dialog stays: it reads the same report.
--- 3. Low overhead: only writes on actual errors; zero allocations on the
---    hot path (pcall returning ok=true is the common case).
--- 4. Privacy: the whole document goes through the admitted redactor before it
---    reaches the disk, and every effect is re-checked against that admission.
--- ==============================================================================

local M = {}
local CrashReport = require("crash_report")

local Logger = require("logger.shim")
local LOG = "diagnostics.crash_reporter"

-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- A crash storm can fill many names within one timestamp second; the bound keeps
-- a hostile folder from turning persistence into an unbounded collision loop.
local MAX_REPORT_FILENAME_ATTEMPTS = 1000

-- The name of a dump written before the shared JSON report existed:
-- crash_<UTC stamp>_<sanitised module>.txt. The retention and the next-start
-- dialog no longer see these, so they would otherwise stay forever.
local LEGACY_DUMP_PATTERN = "^crash_%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%d_[%w_.-]+%.txt$"

-- Crash reports live in the logs folder, next to the daily log that explains
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
	return os.execute("mkdir -p " .. require("text_utils").shell_quote(directory) .. " 2>/dev/null")
end

--- Deletes the reports beyond the shared cap, oldest first.
--- The names come from the shared policy, which selects report names only, so a
--- file the user keeps in the folder is never removed.
--- @param directory string Crash folder, no trailing slash.
local function _rotate(directory)
	local NativeDirectory = require("infra.native_directory")
	local listed, entries, message = pcall(NativeDirectory.entries, directory)
	if not listed then
		Logger.warn(LOG, "Crash report retention skipped, the folder cannot be listed: %s.", tostring(entries))
		return
	end
	if entries == nil then
		Logger.warn(LOG, "Crash report retention skipped, the folder cannot be listed: %s.", tostring(message))
		return
	end
	local names = {}
	for _, entry in ipairs(entries) do
		if entry.kind == "file" then names[#names + 1] = entry.name end
	end
	local FileSystem = require("adapters.file_system")
	for _, name in ipairs(CrashReport.expired(names)) do
		if FileSystem.delete(directory .. "/" .. name) ~= true then
			Logger.warn(LOG, "Crash report '%s' could not be deleted by the retention policy.", name)
		end
	end
end



--- Deletes the legacy text dumps of the crash folder, once per start.
--- Idempotent: after the first run no name matches, and the exact pattern leaves
--- JSON reports, the next-start marker and any file the user keeps untouched. A
--- refused deletion is a warning: cleanup must never stop the daemon.
--- @param directory string|nil Crash folder (default: the reporter's folder).
--- @return integer removed Number of legacy dumps deleted.
function M.remove_legacy_dumps(directory)
	directory = directory or crash_dir()
	local listed, entries, message = pcall(require("infra.native_directory").entries, directory)
	if not listed then
		Logger.warn(LOG, "Legacy crash dump cleanup skipped, the folder cannot be listed: %s.", tostring(entries))
		return 0
	end
	if entries == nil then
		-- A missing folder only means no crash was ever reported.
		Logger.debug(LOG, "Legacy crash dump cleanup skipped, no crash folder: %s.", tostring(message))
		return 0
	end
	Logger.start(LOG, "Removing the legacy crash text dumps from %s…", directory)
	local FileSystem = require("adapters.file_system")
	local removed = 0
	for _, entry in ipairs(entries) do
		if entry.kind == "file" and entry.name:match(LEGACY_DUMP_PATTERN) then
			if FileSystem.delete(directory .. "/" .. entry.name) == true then
				removed = removed + 1
				Logger.info(LOG, "Legacy crash dump '%s' deleted.", entry.name)
			else
				Logger.warn(LOG, "Legacy crash dump '%s' could not be deleted.", entry.name)
			end
		end
	end
	Logger.success(LOG, "Legacy crash text dumps removed: %d.", removed)
	return removed
end



-- =========================================
-- =========================================
-- ======= 3/ Crash Dump ===================
-- =========================================
-- =========================================

--- The facts of the running build, gathered on the crash path itself.
--- Which build crashed is the first question of every report, so the commit, the
--- version, the install tree and the configuration directory are read here (a few
--- file reads, no subprocess) before the report file is opened. A resolver that
--- fails is written as its own reason rather than costing the report.
--- @return table fields Keys of the shared record: version, git_hash,
---   commit_source, config_dir, script_dir.
local function _build_facts()
	local ok_commit, commit, source = pcall(function()
		return require("infra.diagnostic_snapshot").resolve_commit()
	end)
	local ok_config, config_dir = pcall(function()
		return require("infra.config_paths").get_config_dir()
	end)
	local ok_version, version = pcall(function()
		return require("infra.version").VERSION
	end)
	local ok_app, app_dir = pcall(function()
		return require("infra.paths").driver_root()
	end)
	local function failed(reason) return "unknown (resolution failed: " .. tostring(reason) .. ")" end
	return {
		version = ok_version and tostring(version) or failed(version),
		git_hash = ok_commit and tostring(commit) or failed(commit),
		commit_source = ok_commit and tostring(source) or "unknown",
		config_dir = ok_config and tostring(config_dir) or failed(config_dir),
		script_dir = ok_app and tostring(app_dir) or failed(app_dir),
	}
end

--- The session counters and the log ring buffer, the fields that explain a crash.
--- @return table fields Keys session_warnings, session_errors, log_tail.
local function _session_facts()
	local fields = {}
	local ok_issues, issues = pcall(Logger.session_issues)
	if ok_issues and type(issues) == "table" then
		fields.session_warnings = issues.warn_count
		fields.session_errors = issues.err_count
	end
	local ok_ring, ring = pcall(Logger.ring_buffer_snapshot)
	if ok_ring and type(ring) == "table" then
		fields.log_tail = table.concat(ring, "\n")
	else
		fields.log_tail = "unavailable: " .. tostring(ring)
	end
	return fields
end

--- Tells the user how the save ended, as the macOS reporter does. A desktop
--- notification never blocks, so it is safe in an error handler.
--- @param saved boolean Whether the report is on disk.
--- @param path string|nil The report path, shown when saved.
local function _notify(saved, path)
	pcall(function()
		local i18n = require("infra.i18n")
		local Notifier = require("adapters.notifier")
		if saved then
			Notifier.send(path, { title = i18n.get("crash.report.saved_title"), level = "info" })
		else
			Notifier.send(i18n.get("crash.report.save_failed"), { level = "error" })
		end
	end)
end

--- Only a fixed failure may bypass the admitted sink through stderr.
local function refused()
	pcall(function() io.stderr:write("[crash_reporter] Crash dump refused; privacy or output acknowledgement unavailable.\n") end)
	_notify(false)
	return false
end

--- Reserves the first free report name in the folder.
--- @param directory string Crash folder, no trailing slash.
--- @param stem string From CrashReport.stem.
--- @return string|nil path
local function _free_path(directory, stem)
	local FileSystem = require("adapters.file_system")
	for attempt = 1, MAX_REPORT_FILENAME_ATTEMPTS do
		local path = directory .. "/" .. CrashReport.file_name(stem, attempt)
		if not FileSystem.exists(path) then return path end
	end
	return nil
end

--- Writes a fully redacted report under the original sink admission.
--- Safe in error handlers: a reporting failure must not replace the real error.
--- @param module_name string Name of the module where the error occurred.
--- @param error_msg string Error message (tostring(err) from pcall).
--- @param context table|nil Optional { stack_trace?, locale? }.
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
	local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local prepared, document = pcall(function()
		local fields = _build_facts()
		for key, value in pairs(_session_facts()) do fields[key] = value end
		fields.driver = "linux"
		fields.timestamp = timestamp
		fields.module = module_name
		fields.error_msg = error_msg
		if type(context) == "table" then
			if type(context.stack_trace) == "string" then fields.stack_trace = context.stack_trace end
			if type(context.locale) == "string" then fields.locale = context.locale end
		end
		return redact(CrashReport.encode(CrashReport.build(fields)))
	end)
	if not prepared or type(document) ~= "string" or not live() then return refused() end
	local made, status = pcall(_ensure_dir, directory)
	if not made or (status ~= true and status ~= 0) or not live() then return refused() end
	local reserved, path = pcall(_free_path, directory, CrashReport.stem(timestamp))
	if not reserved or type(path) ~= "string" then return refused() end
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
	pcall(Logger.error, LOG, "Crash report written: %s", path)
	_notify(true, path)
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

--- Returns the number of crash reports currently on disk.
--- Counts report names only, as the retention policy does.
--- @return number
function M.get_crash_count()
	local listed, entries = pcall(require("infra.native_directory").entries, crash_dir())
	if not listed or entries == nil then return 0 end
	local names = {}
	for _, entry in ipairs(entries) do
		if entry.kind == "file" and CrashReport.parse_name(entry.name) then names[#names + 1] = entry.name end
	end
	return #names
end

return M
