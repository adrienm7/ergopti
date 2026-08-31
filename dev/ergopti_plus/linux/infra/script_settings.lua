--- infra/script_settings.lua

--- ==============================================================================
--- MODULE: Script Settings (Linux)
--- DESCRIPTION:
--- Owns the Linux runtime state for the canonical `script.log_level` feature.
--- Reads its default and accepted values from the generated feature manifest,
--- persists an explicit user choice, and applies the matching shared-logger
--- threshold before the daemon emits its first line.
---
--- WHY THIS MODULE EXISTS:
--- The tray used to call Logger.set_level() directly. The choice therefore died
--- with the process, startup ignored the manifest's INFO default, and the menu
--- could not show which level was active. A declared setting is supported only
--- when the user's choice survives a restart and reaches the runtime consumer.
---
--- FEATURES & RATIONALE:
--- 1. Manifest-owned policy: the default and enum are read from
---    `script.log_level`; this driver does not keep another accepted-values list.
--- 2. Durable-before-live transaction: a menu choice becomes active only after
---    storage confirms it, so a failed write cannot present a temporary state as
---    saved.
--- 3. Explicit variant mapping: TRACE/DONE share DEBUG's threshold and
---    START/SUCCESS share INFO's threshold, as defined by the shared logger core.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")
local Storage = require("adapters.storage")

local LOG = "infra.script_settings"
local FEATURE_PATH = "script.log_level"

local VARIANT_BY_LEVEL = {
	DEBUG = "debug",
	TRACE = "trace",
	DONE = "done",
	INFO = "info",
	START = "start",
	SUCCESS = "success",
	WARNING = "warn",
	ERROR = "error",
}

local _entry = nil
local _active = nil





-- =========================================
-- =========================================
-- ======= 1/ Canonical declaration ========
-- =========================================
-- =========================================

--- Returns the canonical feature declaration and validates its runtime shape.
--- @return table
local function declaration()
	if _entry then return _entry end
	local entry = Manifest.find_entry_by_path(FEATURE_PATH)
	if type(entry) ~= "table" or type(entry.default) ~= "string"
		or type(entry.enum_values) ~= "table" then
		error("[script_settings] invalid manifest declaration for '" .. FEATURE_PATH .. "'.")
	end
	_entry = entry
	return entry
end

--- Normalises and validates one canonical log-level token.
--- @param value any
--- @return string|nil
local function canonical(value)
	if type(value) ~= "string" then return nil end
	local candidate = value:upper()
	for _, accepted in ipairs(declaration().enum_values) do
		if candidate == accepted then return candidate end
	end
	return nil
end

--- Resolves one canonical token to the shared logger's numeric threshold.
--- @param level string
--- @return number
local function threshold(level)
	local variant = VARIANT_BY_LEVEL[level]
	local value = variant and Logger.level_of(variant) or nil
	if type(value) ~= "number" then
		error("[script_settings] logger has no threshold for '" .. tostring(level) .. "'.")
	end
	return value
end





-- =========================================
-- =========================================
-- ======== 2/ Reading and applying ========
-- =========================================
-- =========================================

--- Returns the persisted level, or the canonical shipped default.
--- @return string
function M.get()
	local entry = declaration()
	local stored = Storage.get(FEATURE_PATH, nil)
	local value = canonical(stored)
	if value then return value end
	if stored ~= nil then
		Logger.warn(LOG, "Stored log level '%s' is invalid — using the shipped default.",
			tostring(stored))
	end
	local default = canonical(entry.default)
	if not default then
		error("[script_settings] manifest default is not one of its enum values.")
	end
	return default
end

--- Applies either a one-run override or the persisted/default level.
--- @param override string|nil Canonical level used only for this process.
--- @return boolean
function M.apply(override)
	local level = override == nil and M.get() or canonical(override)
	if not level then
		Logger.error(LOG, "Cannot apply invalid log level '%s'.", tostring(override))
		return false
	end
	Logger.set_level(threshold(level))
	_active = level
	return true
end

--- Returns the level currently applied to the logger.
--- @return string
function M.current()
	return _active or M.get()
end





-- =========================================
-- =========================================
-- ======= 3/ Durable mutation =============
-- =========================================
-- =========================================

--- Persists and applies a user-selected level.
--- @param value any
--- @return boolean Whether persistence and application both succeeded.
function M.set(value)
	local level = canonical(value)
	if not level then
		Logger.error(LOG, "Refusing invalid log level '%s'.", tostring(value))
		return false
	end
	if Storage.set(FEATURE_PATH, level) ~= true then
		Logger.error(LOG, "Log level '%s' could not be persisted — active state is unchanged.", level)
		return false
	end
	Logger.set_level(threshold(level))
	_active = level
	return true
end

return M
