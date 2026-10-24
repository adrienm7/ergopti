--- _shared/lua/error_dialog/core.lua

--- ==============================================================================
--- MODULE: Error Window Core
--- DESCRIPTION:
--- The part of the error window that does not depend on the host: loading the
--- shared policy once, the Debug menu switch, the report of one error and the
--- page's first message. The macOS host (ui/error_dialog/init.lua) and the
--- Linux bridge (ui/error_dialog/bridge.lua) keep their windows, timers and
--- scope ownership, and call these with their own logger, storage and paths.
---
--- FEATURES & RATIONALE:
--- 1. One copy: the two hosts carried the same initialisation, setting rules
---    and report composition (59 identical 8-line windows); a refusal or a
---    report field added on one host was missing on the other.
--- 2. Ports, not requires: every host dependency is passed in, so this module
---    names no driver path and holds no state of its own.
--- 3. Same lifecycle lines: init() logs the start/success pair (or the error
---    that ends it) under the host's own module tag.
--- ==============================================================================

local M = {}
local Policy = require("diagnostics.error_policy")
local ErrorReport = require("diagnostics.error_report")
local Json = require("json")

-- The record time format the window shows, the same on every host.
local RECORD_TIME_FORMAT = "%Y-%m-%d %H:%M:%S"





-- =================================
-- =================================
-- ======= 1/ Initialisation =======
-- =================================
-- =================================

--- Reads and validates the shared policy.
--- @param path string Path of _shared/modules/diagnostics/error_policy.json.
--- @return table policy Validated policy.
function M.load_policy(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("the error policy cannot be read: " .. tostring(err)) end
	local raw = fh:read("*a")
	fh:close()
	return Policy.validate(Json.decode(raw))
end

--- Loads the policy once, under the host's lifecycle lines.
--- @param logger table Host logger (start, success, error).
--- @param log string Host module tag.
--- @param initialised boolean Whether the host already holds a policy.
--- @param policy_path function Returns the policy path; may raise.
--- @param adopt function Receives (policy, decisions), stores them and returns
---   whether the window is enabled.
--- @return boolean initialised
function M.init(logger, log, initialised, policy_path, adopt)
	if initialised then
		logger.error(log, "The error window was initialised twice; the second call is refused.")
		return false
	end
	logger.start(log, "Initialising the error window…")
	local ok, policy = pcall(function() return M.load_policy(policy_path()) end)
	if not ok then
		logger.error(log, "The error window cannot start: %s.", tostring(policy))
		return false
	end
	local enabled = adopt(policy, Policy.new_state())
	logger.success(log, "Error window ready (%s).", enabled and "enabled" or "disabled")
	return true
end





-- ===================================
-- ===================================
-- ======= 2/ The Debug switch =======
-- ===================================
-- ===================================

--- Reads the stored switch, else the features manifest's boolean default.
--- @param storage table Host Storage port (get).
--- @param default_for function Returns the manifest default of a path.
--- @param setting string The feature path.
--- @return boolean enabled
function M.stored_enabled(storage, default_for, setting)
	local stored = storage.get(setting, nil)
	if type(stored) == "boolean" then return stored end
	local default = default_for(setting)
	if type(default) ~= "boolean" then
		error("the features manifest declares no boolean default for " .. setting)
	end
	return default
end

--- Persists one switch value; the host adopts it only when this answers true.
--- @param logger table Host logger (error).
--- @param log string Host module tag.
--- @param storage function Returns the host Storage port (set).
--- @param setting string The feature path.
--- @param enabled any The requested value.
--- @return boolean saved
function M.save_enabled(logger, log, storage, setting, enabled)
	if type(enabled) ~= "boolean" then
		logger.error(log, "set_enabled() needs a boolean, got %s.", type(enabled))
		return false
	end
	if storage().set(setting, enabled) ~= true then
		logger.error(log, "The error window setting could not be saved; it is unchanged.")
		return false
	end
	return true
end





-- =============================
-- =============================
-- ======= 3/ The Report =======
-- =============================
-- =============================

--- The record of one logged error, as the window shows it.
--- @param module_name any Logging module.
--- @param message any Formatted message.
--- @return table record { kind, module, message, time }
function M.error_record(module_name, message)
	return { kind = "error", module = tostring(module_name), message = tostring(message),
		time = os.date(RECORD_TIME_FORMAT) }
end

--- Composes the report of one error from a diagnostics snapshot.
--- @param record table { kind, module, message, time, log_path? }
--- @param snapshot table Diagnostics snapshot (sections.versions, system, issues, paths).
--- @param driver string The host's diagnostics driver name.
--- @return table fields { report, paths, open_id, log_path }
function M.compose(record, snapshot, driver)
	local sections = snapshot.sections
	local versions, system, issues = sections.versions or {}, sections.system or {}, sections.issues or {}
	local identity = {
		version       = tostring(versions.ergopti_version or "unknown"),
		commit        = tostring(versions.commit or ""),
		os            = tostring(system.os or "unknown"),
		driver        = driver,
		generated_utc = tostring(snapshot.generated_at),
		warn_count    = tonumber(issues.warn_count) or 0,
		err_count     = tonumber(issues.err_count) or 0,
	}
	-- The recent warnings and errors of today's errors file, as many as the
	-- diagnostics window shows (_shared/modules/diagnostics/recent_issues.json)
	local recent = {}
	for _, entry in ipairs(issues.recent or {}) do recent[#recent + 1] = tostring(entry) end
	local report = ErrorReport.compose({
		kind = record.kind, module = record.module, message = record.message, time = record.time,
		recent = recent,
	}, identity)
	local paths = {}
	for id, path in pairs(sections.paths or {}) do paths[id] = path end
	local open_id = "errors_today"
	if record.kind == "crash" then
		open_id = "crash_report"
		paths.crash_report = record.log_path
	end
	local log_path = paths[open_id]
	if type(log_path) ~= "string" or log_path == "" then error("the file this error is logged in is unknown") end
	return { report = report, paths = paths, open_id = open_id, log_path = log_path }
end

--- The page's first message: the error and its report, redacted.
--- @param record table The error record.
--- @param report table Its composed report.
--- @param log_path string The file it is logged in.
--- @param more integer Errors folded into this window so far.
--- @param redact function Redacts one text under the host's rules.
--- @return table message
function M.init_message(record, report, log_path, more, redact)
	return {
		type     = "init",
		kind     = record.kind,
		module   = redact(record.module),
		message  = redact(record.message),
		log_path = redact(log_path),
		text     = redact(report.text),
		more     = more,
	}
end

return M
