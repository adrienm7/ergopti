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
---    kind, the stage, the localized message and the developer detail to a
---    modal alert that stays until the user dismisses it.
--- 3. Boot or runtime: a component that fails after boot completed stopped a
---    running app. Presenting it as "could not start" at a boot "step" sent
---    users looking for a startup problem, so such a report says kind=runtime,
---    names the component and lists the day's log files.
--- 4. Privacy: callers pass stage names and developer diagnostics only, never
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

--- Writes one fatal report through every channel that survives os.exit().
--- @param kind string M.KIND_BOOT or M.KIND_RUNTIME.
--- @param stage any Boot stage, or runtime component.
--- @param detail any Developer-facing cause.
--- @param message string|nil Localized user-facing explanation.
--- @param log_paths table|nil Log files the launcher lists for a runtime stop.
--- @param deps table|nil Test seams: getenv, open, clock, fallback_path.
--- @return boolean launcher_notified True when the launcher report was written.
--- @return table outcomes Per-channel `{ written, detail }` results.
local function write_report(kind, stage, detail, message, log_paths, deps)
	deps = type(deps) == "table" and deps or {}
	local getenv = deps.getenv or os.getenv
	local open = deps.open or io.open
	local clock = deps.clock or function() return os.date("%Y-%m-%d %H:%M:%S") end
	local fallback_path = deps.fallback_path or Logger.FALLBACK_BOOT_LOG_FILE

	local exact_stage = single_line(stage ~= nil and stage or "unknown")
	local exact_detail = single_line(detail ~= nil and detail or "no detail")
	local exact_message = single_line(message or "")
	-- Privacy admission itself can fail before the redactor exists. Only this
	-- exact closed bootstrap report is safe without an admitted text policy.
	local closed_privacy_failure = kind == M.KIND_BOOT and stage == "logger_privacy"
		and detail == "Canonical log privacy admission refused." and message == nil and log_paths == nil
	if not closed_privacy_failure then
		exact_detail = Logger.redact_message(exact_detail)
		exact_message = Logger.redact_message(exact_message)
	end
	-- The boot wording is matched by the packaged launch gate; the runtime
	-- wording must never contain it (tools/diagnostics/macos_launch_gate.py).
	local where = kind == M.KIND_RUNTIME
		and string.format("in runtime component '%s'", exact_stage)
		or string.format("at boot stage '%s'", exact_stage)
	pcall(Logger.error, LOG, "Fatal abort %s: %s.", where, exact_detail)

	local line = string.format("%s [ERROR] [init] FATAL %s: %s\n", clock(), where, exact_detail)
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
			string.format("[%s] embedded Hammerspoon FATAL %s: %s\n", clock(), where, exact_detail)))
	else
		outcomes.launcher_log = { written = false, detail = "no launcher log exported" }
	end

	local report_path = getenv(M.REPORT_FILE_ENV)
	if type(report_path) ~= "string" or report_path == "" then
		outcomes.launcher_report = { written = false, detail = "no launcher report file exported" }
		return false, outcomes
	end
	local body = string.format("kind=%s\nstage=%s\nmessage=%s\ndetail=%s\n",
		kind, exact_stage, exact_message, exact_detail)
	for _, path in ipairs(type(log_paths) == "table" and log_paths or {}) do
		body = body .. "log=" .. single_line(path) .. "\n"
	end
	local written, write_detail = write_now(open, report_path, "wb", body)
	record("launcher_report", written, write_detail)
	return written == true, outcomes
end





-- ===================================
-- ===================================
-- ======= 2/ Public API =============
-- ===================================
-- ===================================

--- Report kind of a failure during startup: "could not start", with the stage.
M.KIND_BOOT = "boot"

--- Report kind of a failure after boot completed: the app was running and
--- stopped, so the launcher names the component and lists the day's logs.
M.KIND_RUNTIME = "runtime"

--- Chooses how one fatal exit is presented. A component that fails after boot
--- completed stopped a running app; reporting it as "could not start" at a boot
--- "step" sent users looking for a startup problem that did not exist.
--- @param owner string|nil Failing owner, such as "native_logger".
--- @param boot_complete boolean Whether the boot sequence had completed.
--- @param current_stage string|nil Boot stage running when boot is incomplete.
--- @return string kind M.KIND_BOOT or M.KIND_RUNTIME.
--- @return string stage Boot stage or runtime component shown to the user.
--- @return string message_key Default localized explanation for that kind.
function M.presentation(owner, boot_complete, current_stage)
	local exact_owner = tostring(owner or "runtime_dependency")
	if boot_complete == true then
		return M.KIND_RUNTIME, exact_owner, "dialog.fatal_error.runtime_stopped"
	end
	-- The generic post-onboarding owner names the boot stage that was running.
	if exact_owner == "boot" and type(current_stage) == "string" and current_stage ~= "" then
		return M.KIND_BOOT, current_stage, "dialog.fatal_error.cannot_start"
	end
	return M.KIND_BOOT, exact_owner, "dialog.fatal_error.cannot_start"
end

--- Reports one failed start through every channel that survives os.exit().
--- @param stage string Stable stage name, such as "native_logger_transport".
--- @param detail any Developer-facing cause.
--- @param message string|nil Localized user-facing explanation.
--- @param deps table|nil Test seams: getenv, open, clock, fallback_path.
--- @return boolean launcher_notified True when the launcher report was written.
--- @return table outcomes Per-channel `{ written, detail }` results.
function M.report(stage, detail, message, deps)
	return write_report(M.KIND_BOOT, stage, detail, message, nil, deps)
end

--- Reports one runtime stop, after boot completed, through the same channels.
--- @param component string Failing owner, such as "native_logger".
--- @param detail any Developer-facing cause.
--- @param message string|nil Localized user-facing explanation.
--- @param log_paths table Today's log files, listed in the launcher alert.
--- @param deps table|nil Test seams: getenv, open, clock, fallback_path.
--- @return boolean launcher_notified True when the launcher report was written.
--- @return table outcomes Per-channel `{ written, detail }` results.
function M.report_runtime(component, detail, message, log_paths, deps)
	return write_report(M.KIND_RUNTIME, component, detail, message, log_paths, deps)
end

return M
