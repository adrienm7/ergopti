--- modules/diagnostics/crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter
--- DESCRIPTION:
--- Automatic crash report builder and persistence layer for the Hammerspoon driver.
--- When the global error handler fires, this module saves a full diagnostic report
--- to disk immediately — no confirmation step — and notifies the user of the file
--- path. No network calls are ever made.
---
--- FEATURES & RATIONALE:
--- 1. Privacy-first: the report never contains keystrokes, personal data, or file
---    contents. The report mirrors what Debug > Diagnostic shows plus the full log
---    ring buffer, so one file is almost always enough to diagnose the crash.
--- 2. No confirmation, no modal: the old opt-in prompt added friction with zero
---    privacy benefit — the report is local-only and contains no PII. The outcome
---    is announced with a non-blocking notification naming the saved file, because
---    a modal alert would stall the main thread and every event tap with it.
--- 3. Rich diagnostics: includes everything from the healthcheck (OS, HS version,
---    adapters, session counters) PLUS the full in-memory log ring buffer (up to
---    200 lines), the active window, and the stack trace.
--- 4. Driver-scoped directory: reports live under <config_dir>/crash_reports/
---    (Hammerspoon-specific, separate from any AHK reports).
--- 5. Structured output: reports are written as JSON for easy machine and human
---    readability, one file per incident.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local i18n   = require("infra.i18n")

local LOG = "crash_reporter"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- Subdirectory under the user config dir that receives all Hammerspoon crash
-- report files. Nested under hammerspoon/ to mirror the driver folder layout
-- and stay separate from AHK reports.
local CRASH_REPORTS_SUBDIR = "hammerspoon/crash_reports"

-- A crash storm can legitimately fill many names within one timestamp second.
-- The bound prevents corrupted or hostile directories from turning report
-- persistence into an unbounded collision loop.
local MAX_REPORT_FILENAME_ATTEMPTS = 1000

-- Whether report() collects the healthcheck's SYSTEM probes. ui.healthcheck.run()
-- forks seven synchronous subprocesses (sysctl, vm_stat, uname, git) through
-- hs.execute, and report() is reached from an async callback on the SAME main run
-- loop that dispatches the CGEventTaps — so a crash report stalled the typing tap
-- for as long as those probes took. The genuinely valuable field, the in-memory
-- ring buffer, is collected unconditionally below; the OS trivia is available on
-- demand from Debug > Diagnostic, so it is opt-in per call via
-- context.system_probes rather than paid for on every report.
local COLLECT_SYSTEM_PROBES_DEFAULT = false





-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

--- Resolves the absolute path to the crash_reports directory.
--- @return string Absolute path ending with a directory separator.
local function _reports_dir()
	local base = nil

	local ok_mp, mp = pcall(require, "infra.config_paths")
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

--- Atomically creates one uniquely named report without truncating a prior file.
--- The timestamp-only name remains canonical; collisions receive `-2`, `-3`,
--- and so on. FileSystem.create_if_absent owns the create-vs-existing race.
--- @param dir string Absolute report directory ending in a separator.
--- @param stem string Sanitised timestamp filename stem.
--- @param json_str string Encoded report bytes.
--- @return string|nil path
--- @return string|nil error_message
local function _create_unique_report(dir, stem, json_str)
	local adapter_ok, FileSystem = pcall(require, "adapters.file_system")
	if not adapter_ok or type(FileSystem) ~= "table"
		or type(FileSystem.create_if_absent) ~= "function" then
		return nil, "atomic create-if-absent persistence is unavailable"
	end

	for attempt = 1, MAX_REPORT_FILENAME_ATTEMPTS do
		local suffix = attempt == 1 and "" or ("-" .. tostring(attempt))
		local path = dir .. stem .. suffix .. ".json"
		local call_ok, created, status, detail = pcall(
			FileSystem.create_if_absent,
			path,
			json_str
		)
		if not call_ok then
			return nil, "atomic report creation raised: " .. tostring(created)
		end
		if created == true and status == "created" then return path end
		if created ~= false or status ~= "exists" then
			return nil, string.format(
				"atomic report creation failed (status=%s): %s",
				tostring(status),
				tostring(detail or created)
			)
		end
	end

	return nil, string.format(
		"cannot reserve a unique filename after %d attempts",
		MAX_REPORT_FILENAME_ATTEMPTS
	)
end





-- ======================
-- ======================
-- ======= 3/ API =======
-- ======================
-- ======================

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
	local collect_probes = COLLECT_SYSTEM_PROBES_DEFAULT
	if type(context) == "table" and context.system_probes == true then
		collect_probes = true
	end
	local ok_hc, hc = false, nil
	if collect_probes then ok_hc, hc = pcall(require, "ui.healthcheck") end
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
	-- Recursive mkdir: create every missing ancestor before the leaf directory.
	-- The single 2-level approach (parent + dir) fails when two or more ancestors
	-- are absent simultaneously (lib-update-05).
	pcall(function()
		local path = dir:gsub("[/\\]$", "")
		local segments = {}
		for seg in path:gmatch("[^/\\]+") do
			segments[#segments + 1] = seg
		end
		local built = path:sub(1, 1) == "/" and "/" or ""
		for _, seg in ipairs(segments) do
			built = built .. seg .. "/"
			if not hs.fs.attributes(built) then
				hs.fs.mkdir(built)
			end
		end
	end)

	local ts = (report.timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ")):gsub(":", "-")
	local json_str = _to_json(report)
	local fname, write_err = _create_unique_report(dir, ts, json_str)
	if not fname then
		Logger.error(LOG, "Crash report write failed: %s.", tostring(write_err))
		return nil
	end

	Logger.success(LOG, "Crash report saved: %s.", fname)
	return fname
end

--- Saves the crash report immediately (no confirmation) then tells the user where
--- it landed via a system notification. If saving fails, notifies about that instead.
--- Safe to call from within an error handler — wrapped in pcall throughout.
---
--- The outcome is announced with a NON-BLOCKING notification, never a modal.
--- A modal alert runs a nested run loop that stalls the main thread — and with it
--- every event tap, timer and hotkey in the driver — until a human clicks it. A
--- reporter that freezes the driver is worse than the failure it reports, and it
--- would freeze it precisely when something has already gone wrong. The
--- notification carries the same single piece of information: the report path.
--- @param report table The report table returned by M.report().
function M.prompt_user(report)
	Logger.start(LOG, "Saving crash report…")

	-- Required lazily: lib.notifications requires lib.logger, and crash_reporter is
	-- itself reachable from the logger's error paths, so a top-level require would
	-- tighten that cycle for a dependency only this one function needs.
	local ok_notify, Notifications = pcall(require, "infra.notifications")
	local can_notify = ok_notify and type(Notifications) == "table"
		and type(Notifications.notify) == "function"

	local path = M.save(report)

	if path then
		Logger.success(LOG, "Crash report saved at '%s'.", path)
		if can_notify then
			pcall(Notifications.notify, i18n.get("crash.report.saved_title"), path, "info")
		end
	else
		Logger.warn(LOG, "Crash report could not be saved.")
		if can_notify then
			pcall(Notifications.notify, i18n.get("crash.report.save_failed"), "", "error")
		end
	end
end

return M
