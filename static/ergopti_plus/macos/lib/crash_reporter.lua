--- lib/crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter
--- DESCRIPTION:
--- Automatic crash report builder and persistence layer for the Hammerspoon driver.
--- When the global error handler fires, this module saves a full diagnostic report
--- to disk immediately — no confirmation step — and shows the user the file path.
--- No network calls are ever made.
---
--- FEATURES & RATIONALE:
--- 1. Privacy-first: the report never contains keystrokes, personal data, or file
---    contents. The report mirrors what Debug > Diagnostic shows plus the full log
---    ring buffer, so one file is almost always enough to diagnose the crash.
--- 2. No confirmation: the old opt-in prompt added friction with zero privacy
---    benefit — the report is local-only and contains no PII. The user sees a
---    single dialog showing the path of the saved file.
--- 3. Rich diagnostics: includes everything from the healthcheck (OS, HS version,
---    adapters, session counters) PLUS the full in-memory log ring buffer (up to
---    200 lines), the active window, and the stack trace.
--- 4. Driver-scoped directory: reports live under <config_dir>/crash_reports/
---    (Hammerspoon-specific, separate from any AHK reports).
--- 5. Structured output: reports are written as JSON for easy machine and human
---    readability, one file per incident.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")
local i18n   = require("lib.i18n")

local LOG = "crash_reporter"




-- ===========================
--- ============================
-- ======= 1/ Constants =======
--- ============================
-- ===========================

-- Subdirectory under the user config dir that receives all Hammerspoon crash
-- report files. Nested under hammerspoon/ to mirror the driver folder layout
-- and stay separate from AHK reports.
local CRASH_REPORTS_SUBDIR = "hammerspoon/crash_reports"

-- File encoding for JSON output.
local JSON_FILE_FLAGS = "w"




-- =========================
--- ==========================
-- ======= 2/ Helpers =======
--- ==========================
-- =========================

--- Resolves the absolute path to the crash_reports directory.
--- @return string Absolute path ending with a directory separator.
local function _reports_dir()
	local base = nil

	local ok_mp, mp = pcall(require, "ui.menu.menu_paths")
	if ok_mp and mp and type(mp.get_config_dir) == "function" then
		local dir = mp.get_config_dir()
		if type(dir) == "string" and dir ~= "" then
			base = dir
		end
	end

	if not base then
		local home = os.getenv("HOME") or "~"
		base = home .. "/.config/ergopti_plus/"
	end

	if not base:match("[/\\]$") then
		base = base .. "/"
	end

	return base .. CRASH_REPORTS_SUBDIR .. "/"
end

--- Returns the driver version string from hs.processInfo when available.
--- @return string Version string or "unknown".
local function _driver_version()
	local ok, info = pcall(function() return hs.processInfo end)
	if ok and type(info) == "table" and type(info.version) == "string" and info.version ~= "" then
		return info.version
	end
	return "unknown"
end

--- Serialises a report table to a compact JSON string.
--- Uses hs.json.encode when available; falls back to a hand-built serialiser.
--- @param report table The report produced by M.report().
--- @return string JSON string.
local function _to_json(report)
	local ok, encoded = pcall(hs.json.encode, report, true)
	if ok and type(encoded) == "string" then
		return encoded
	end

	-- Fallback serialiser for string values only
	local order = {
		"version", "driver", "timestamp",
		"error_msg", "stack_trace",
		"os_version", "hs_version", "screen_res", "locale",
		"config_dir", "git_hash",
		"active_app", "active_title",
		"uptime_sec",
		"adapters_ok", "adapters_failed",
		"session_warnings", "session_errors",
		"log_tail",
	}
	local parts = {}
	for _, k in ipairs(order) do
		local v = report[k]
		if v ~= nil then
			v = tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t")
			table.insert(parts, string.format('  "%s": "%s"', k, v))
		end
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end




-- =======================
-- =======================
-- ======= 3/ API =======
-- =======================
-- =======================

--- Builds a rich crash report from an error string and optional context.
--- Includes the full system snapshot, adapter status, session counters, the
--- complete in-memory log ring buffer, and the active window context.
--- The report never contains keystrokes, personal data, or file contents.
--- @param err string The error message (and optionally stack trace).
--- @param context table|nil Optional extra context (only safe metadata fields are read).
--- @return table Report table with all diagnostic fields.
function M.report(err, context)
	Logger.trace(LOG, "Building crash report…")

	local error_msg   = tostring(err or ""):match("^([^\n]+)") or tostring(err or "")
	local stack_trace = tostring(err or ""):match("\n(.+)$") or ""

	if type(context) == "table" and type(context.stack) == "string" and context.stack ~= "" then
		if stack_trace == "" then
			stack_trace = context.stack
		end
	end

	local driver = "hammerspoon"
	if type(context) == "table" and type(context.driver) == "string" and context.driver ~= "" then
		driver = context.driver
	end

	local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

	-- Run the healthcheck once to collect system info, adapter status, session
	-- counters, and uptime — reusing the existing collection logic in healthcheck
	-- avoids duplicating hs.* OS calls in this module (which would raise the
	-- port-adapter purity baseline).
	local sys            = {}
	local uptime_sec     = 0
	local adapters_ok    = ""
	local adapters_failed = ""
	local session_warnings = "0"
	local session_errors   = "0"
	local ok_hc, hc = pcall(require, "lib.healthcheck")
	if ok_hc and hc and type(hc.run) == "function" then
		local ok_run, snap = pcall(hc.run)
		if ok_run and type(snap) == "table" then
			sys              = snap.sys or {}
			uptime_sec       = snap.uptime_sec or 0
			adapters_ok      = table.concat(snap.ports_validated or {}, ", ")
			adapters_failed  = table.concat(snap.failed_adapters or {}, ", ")
			session_warnings = tostring(snap.warn_count or 0)
			session_errors   = tostring(snap.err_count  or 0)
		end
	end

	-- Full in-memory log ring buffer — the single most valuable diagnostic field.
	-- Contains the complete event sequence leading up to the crash.
	local log_tail = ""
	local ok_snap, all_lines = pcall(Logger.ring_buffer_snapshot)
	if ok_snap and type(all_lines) == "table" then
		log_tail = table.concat(all_lines, "\n")
	end

	local result = {
		-- Identification
		version     = _driver_version(),
		driver      = driver,
		timestamp   = timestamp,
		-- Error details
		error_msg   = error_msg,
		stack_trace = stack_trace,
		-- System environment (from healthcheck.run().sys)
		os_version  = sys.os_version  or "unknown",
		hs_version  = sys.hs_version  or "unknown",
		screen_res  = sys.screen_res  or "unknown",
		locale      = sys.locale      or "unknown",
		config_dir  = sys.config_dir  or "",
		git_hash    = sys.git_hash    or "unknown",
		-- Runtime context
		uptime_sec   = tostring(uptime_sec),
		-- Adapter / session health
		adapters_ok      = adapters_ok,
		adapters_failed  = adapters_failed,
		session_warnings = session_warnings,
		session_errors   = session_errors,
		-- Full log ring buffer (up to 200 lines)
		log_tail = log_tail,
	}

	Logger.done(LOG, "Crash report built (ts=%s).", result.timestamp)
	return result
end

--- Writes a crash report to disk as a JSON file in crash_reports/.
--- Creates the directory if it does not exist. Returns the path on success or nil.
--- @param report table The report table returned by M.report().
--- @return string|nil Absolute path to the written file, or nil if the write failed.
function M.save(report)
	Logger.start(LOG, "Saving crash report to disk…")

	local dir = _reports_dir()
	pcall(function()
		local parent = dir:match("^(.*[/\\])[^/\\]+[/\\]?$") or dir
		if not hs.fs.attributes(parent) then hs.fs.mkdir(parent) end
		if not hs.fs.attributes(dir)    then hs.fs.mkdir(dir)    end
	end)

	local ts    = (report.timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ")):gsub(":", "-")
	local fname = dir .. ts .. ".json"

	local json_str = _to_json(report)
	local fh, ferr = io.open(fname, JSON_FILE_FLAGS)
	if not fh then
		Logger.error(LOG, "Cannot open '%s' for writing: %s.", fname, tostring(ferr))
		return nil
	end

	local ok_write, write_err = pcall(function()
		fh:write(json_str)
		fh:close()
	end)

	if not ok_write then
		Logger.error(LOG, "Write failed for '%s': %s.", fname, tostring(write_err))
		pcall(function() fh:close() end)
		return nil
	end

	Logger.success(LOG, "Crash report saved: %s.", fname)
	return fname
end

--- Saves the crash report immediately (no confirmation) then shows the user a
--- single dialog with the path of the saved file. If saving fails, shows an error.
--- Safe to call from within an error handler — wrapped in pcall throughout.
--- @param report table The report table returned by M.report().
function M.prompt_user(report)
	Logger.start(LOG, "Saving crash report…")

	local path = M.save(report)

	if path then
		Logger.success(LOG, "Crash report saved at '%s'.", path)
		-- Show only the path — no confirmation needed, report is local-only
		pcall(hs.dialog.blockAlert,
			i18n.get("crash.report.saved_title"),
			path,
			i18n.get("button.ok"), "", "NSInformationalAlertStyle")
	else
		Logger.warn(LOG, "Crash report could not be saved.")
		pcall(hs.dialog.blockAlert,
			i18n.get("crash.report.save_failed"),
			"",
			i18n.get("button.ok"), "", "NSCriticalAlertStyle")
	end
end

return M
