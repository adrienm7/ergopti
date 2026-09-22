--- adapters/boot_fatal.lua

--- ==============================================================================
--- MODULE: Fatal Exit Reporter
--- DESCRIPTION:
--- Makes a fatal startup or runtime abort durable and visible before the
--- embedded Hammerspoon process exits.
---
--- FEATURES & RATIONALE:
--- 1. Synchronous persistence: once the native logger transport is committed,
---    Logger lines are only queued in memory until the next pump tick, and
---    os.exit() discards that queue. The fatal line is therefore also appended
---    and flushed to the fallback boot log and to launcher.log, which exist
---    whatever the configured log folder is.
--- 2. Launcher dialog: Hammerspoon reports exit status 0 even after Lua calls
---    os.exit(n), so the launcher cannot tell a fatal abort from a Quit by the
---    status alone. A report file, whose path the launcher exports, carries the
---    stage, the localized message and the developer detail to a modal alert
---    that stays until the user dismisses it.
--- 3. Privacy: callers pass stage names and developer diagnostics only, never
---    typed text, clipboard content or credentials.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local BootJournal = require("adapters.boot_journal")

-- One flushed-and-closed writer for every durable boot channel.
local write_now = BootJournal.write_now

-- Tagged like the boot sequence so the [init] topical fan-out selects the line.
local LOG = "init"

--- Environment variable naming the per-launch report file read by the launcher.
M.REPORT_FILE_ENV = "ERGOPTI_FATAL_REPORT_FILE"

--- Environment variable naming the launcher's own log file.
M.LAUNCHER_LOG_ENV = BootJournal.LAUNCHER_LOG_ENV





-- ===================================
-- ===================================
-- ======= 1/ Durable Writes =========
-- ===================================
-- ===================================

--- Flattens one value onto a single line so a traceback cannot split a record.
--- @param value any Value to render.
--- @return string
local function single_line(value)
	local text = tostring(value == nil and "" or value)
	return (text:gsub("\r?\n", " | "))
end





-- ===================================
-- ===================================
-- ======= 2/ Public API =============
-- ===================================
-- ===================================

--- Reports one fatal abort through every channel that survives os.exit().
--- @param stage string Stable stage name, such as "native_logger_transport".
--- @param detail any Developer-facing cause.
--- @param message string|nil Localized user-facing explanation.
--- @param deps table|nil Test seams: getenv, open, clock, fallback_path.
--- @return boolean launcher_notified True when the launcher report was written.
--- @return table outcomes Per-channel `{ written, detail }` results.
function M.report(stage, detail, message, deps)
	deps = type(deps) == "table" and deps or {}
	local getenv = deps.getenv or os.getenv
	local open = deps.open or io.open
	local clock = deps.clock or function() return os.date("%Y-%m-%d %H:%M:%S") end
	local fallback_path = deps.fallback_path or Logger.FALLBACK_BOOT_LOG_FILE

	local exact_stage = single_line(stage ~= nil and stage or "unknown")
	local exact_detail = single_line(detail ~= nil and detail or "no detail")
	local exact_message = single_line(message or "")
	pcall(Logger.error, LOG, "Fatal abort at boot stage '%s': %s.", exact_stage, exact_detail)

	local line = string.format("%s [ERROR] [init] FATAL at boot stage '%s': %s\n",
		clock(), exact_stage, exact_detail)
	local outcomes = {}
	local function record(channel, written, write_detail)
		outcomes[channel] = { written = written, detail = write_detail }
		if not written then
			pcall(Logger.error, LOG, "Fatal report channel %s refused: %s.", channel,
				tostring(write_detail))
		end
	end

	record("fallback_boot_log", write_now(open, fallback_path, "ab", line))

	local launcher_log = getenv(M.LAUNCHER_LOG_ENV)
	if type(launcher_log) == "string" and launcher_log ~= "" then
		record("launcher_log", write_now(open, launcher_log, "ab",
			string.format("[%s] embedded Hammerspoon FATAL at boot stage '%s': %s\n",
				clock(), exact_stage, exact_detail)))
	else
		outcomes.launcher_log = { written = false, detail = "no launcher log exported" }
	end

	local report_path = getenv(M.REPORT_FILE_ENV)
	if type(report_path) ~= "string" or report_path == "" then
		outcomes.launcher_report = { written = false, detail = "no launcher report file exported" }
		return false, outcomes
	end
	local written, write_detail = write_now(open, report_path, "wb", string.format(
		"stage=%s\nmessage=%s\ndetail=%s\n", exact_stage, exact_message, exact_detail))
	record("launcher_report", written, write_detail)
	return written == true, outcomes
end

return M
