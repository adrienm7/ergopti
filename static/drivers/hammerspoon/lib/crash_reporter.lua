--- lib/crash_reporter.lua

--- ==============================================================================
--- MODULE: Crash Reporter
--- DESCRIPTION:
--- Opt-in crash report builder and persistence layer for the Hammerspoon driver.
--- When the global error handler fires, this module offers the user a choice to
--- save a sanitized report to disk for later inspection or support. No network
--- calls are made — the report is written locally only. A future version could
--- offer an upload path once a backend exists.
---
--- FEATURES & RATIONALE:
--- 1. Privacy-first: the report contains only version, OS, driver, error message,
---    and stack trace. Keystrokes, personal data, and file contents are never
---    included, not even in debug fields.
--- 2. Opt-in: the user is always prompted before anything is written to disk.
--- 3. Structured output: reports are written as JSON for easy machine and human
---    readability, one file per incident under crash_reports/.
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

-- Subdirectory under the user config dir that receives all crash report files.
-- Created on demand — never fails if the parent dir does not exist yet.
local CRASH_REPORTS_SUBDIR = "crash_reports"

-- Version string used when hs.processInfo is unavailable (e.g. unit tests).
local FALLBACK_VERSION = "unknown"

-- File encoding for JSON output — all crash reports are plain UTF-8.
local JSON_FILE_FLAGS = "w"




-- =========================
--- ==========================
-- ======= 2/ Helpers =======
--- ==========================
-- =========================

--- Resolves the absolute path to the crash_reports directory.
--- The config dir is obtained from the cached menu_paths module when available;
--- falls back to ~/.config/ergopti_plus/ so the module stays self-contained.
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

	-- Ensure base ends with a separator
	if not base:match("[/\\]$") then
		base = base .. "/"
	end

	return base .. CRASH_REPORTS_SUBDIR .. "/"
end

--- Returns the driver version string from hs.processInfo when available.
--- @return string Version string or FALLBACK_VERSION.
local function _driver_version()
	local ok, info = pcall(function() return hs.processInfo end)
	if ok and type(info) == "table" and type(info.version) == "string" and info.version ~= "" then
		return info.version
	end
	return FALLBACK_VERSION
end

--- Returns a human-readable OS version string.
--- @return string OS version or "unknown".
local function _os_version()
	local ok, ver = pcall(function()
		return hs.host.operatingSystemVersionString()
	end)
	if ok and type(ver) == "string" and ver ~= "" then
		return ver
	end
	return "unknown"
end

--- Serialises a report Map to a compact JSON string.
--- Uses hs.json.encode when available; falls back to a hand-built string that
--- covers the fixed set of fields so the module never fails even without hs.json.
--- @param report table The report Map produced by M.report().
--- @return string JSON string.
local function _to_json(report)
	local ok, encoded = pcall(hs.json.encode, report, true)
	if ok and type(encoded) == "string" then
		return encoded
	end

	-- Fallback serialiser — only handles string values (all fields here are strings)
	local parts = {}
	local order = { "version", "os", "driver", "timestamp", "error_msg", "stack_trace" }
	for _, k in ipairs(order) do
		local v = report[k] or ""
		-- Escape backslashes and double-quotes for minimal JSON safety
		v = tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
		table.insert(parts, string.format('  "%s": "%s"', k, v))
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end




-- =======================
-- =======================
-- ======= 3/ API =======
-- =======================
-- =======================

--- Builds a sanitized crash report from an error string and optional context.
--- The report never contains keystrokes, personal data, or file content.
--- @param err string The error message (and optionally stack trace).
--- @param context table|nil Optional extra context (only safe metadata fields are read).
--- @return table Report Map with fields: version, os, driver, timestamp, error_msg, stack_trace.
function M.report(err, context)
	Logger.trace(LOG, "Building crash report…")

	-- Separate message from stack trace when err is a combined string
	local error_msg   = tostring(err or ""):match("^([^\n]+)") or tostring(err or "")
	local stack_trace = tostring(err or ""):match("\n(.+)$") or ""

	-- Pull a separate stack trace from context if provided and richer than what err carries
	if type(context) == "table" and type(context.stack) == "string" and context.stack ~= "" then
		if stack_trace == "" then
			stack_trace = context.stack
		end
	end

	local driver = "hammerspoon"
	if type(context) == "table" and type(context.driver) == "string" and context.driver ~= "" then
		driver = context.driver
	end

	local result = {
		version     = _driver_version(),
		os          = _os_version(),
		driver      = driver,
		timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		error_msg   = error_msg,
		stack_trace = stack_trace,
	}

	Logger.done(LOG, "Crash report built (ts=%s).", result.timestamp)
	return result
end

--- Writes a crash report to disk as a JSON file in the crash_reports directory.
--- Creates the directory if it does not exist. Returns the path on success or
--- nil on failure.
--- @param report table The report Map returned by M.report().
--- @return string|nil Absolute path to the written file, or nil if the write failed.
function M.save(report)
	Logger.start(LOG, "Saving crash report to disk…")

	local dir = _reports_dir()
	-- Create the directory tree (best-effort, any failure is caught below)
	local ok_dir = pcall(function()
		-- hs.fs.mkdir only creates one level; walk up if parent is missing
		local parent = dir:match("^(.*[/\\])[^/\\]+[/\\]?$") or dir
		if not hs.fs.attributes(parent) then
			hs.fs.mkdir(parent)
		end
		if not hs.fs.attributes(dir) then
			hs.fs.mkdir(dir)
		end
	end)
	if not ok_dir then
		Logger.warn(LOG, "Could not create crash_reports directory at '%s'.", dir)
	end

	-- Build a timestamped filename (colons replaced for filesystem compatibility)
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

--- Displays a blocking dialog asking the user whether to save the crash report.
--- If the user confirms, calls M.save() and notifies them of the outcome.
--- Safe to call from within an error handler — wrapped in pcall throughout.
--- @param report table The report Map returned by M.report().
function M.prompt_user(report)
	Logger.start(LOG, "Prompting user for crash report opt-in…")

	local title = i18n.get("crash.report.prompt_title")
	local body  = i18n.get("crash.report.prompt_body")

	local choice = nil
	pcall(function()
		-- blockAlert returns the button label pressed
		local ok_btn  = i18n.get("button.ok")
		local cancel  = i18n.get("button.cancel")
		choice = hs.dialog.blockAlert(title, body, ok_btn, cancel, "NSCriticalAlertStyle")
	end)

	if choice == i18n.get("button.ok") then
		local path = M.save(report)
		if path then
			pcall(hs.dialog.blockAlert,
				i18n.get("crash.report.saved"),
				path,
				i18n.get("button.ok"), "", "NSInformationalAlertStyle")
			Logger.success(LOG, "User accepted crash report opt-in.")
		else
			Logger.warn(LOG, "Crash report save failed after user accepted prompt.")
		end
	else
		Logger.info(LOG, "User declined crash report opt-in.")
		pcall(hs.dialog.blockAlert,
			i18n.get("crash.report.declined"), "",
			i18n.get("button.ok"), "", "NSInformationalAlertStyle")
	end
end

return M
