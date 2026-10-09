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
local _scope_busy = false
local _scope_owner, _scope_generation, _scope_receipts = nil, 0, setmetatable({}, { __mode = "k" })

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
	if _scope_owner ~= nil then return false end
	_scope_generation = _scope_generation + 1
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
	if _scope_owner ~= nil then return false end
	_scope_generation = _scope_generation + 1
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

--- Reads only the logger state this module owns; no persistence occurs here.
local function scope_backend_current()
	return rawequal(package.loaded["logger.shim"], Logger) and rawequal(package.loaded["logger"], Logger)
end

local function scope_state()
	return { module = package.loaded["infra.script_settings"], active = _active, level = Logger.get_level(), setter = Logger.set_level, getter = Logger.get_level,
		backend_parent = package.loaded["logger.shim"], core_parent = package.loaded["logger"] }
end

local function scope_equal(left, right)
	return rawequal(left.module, right.module) and left.active == right.active and left.level == right.level and left.setter == right.setter and left.getter == right.getter
		and rawequal(left.backend_parent, right.backend_parent) and rawequal(left.core_parent, right.core_parent)
end

--- Acquires the declared runtime field for one primary transaction token.
--- @param owner table Exact token; pending() describes primary compensation only.
--- @return boolean acquired
function M.scope_acquire(owner)
	if type(owner) ~= "table" or type(owner.pending) ~= "function" or _scope_owner ~= nil or _scope_busy
		or not rawequal(package.loaded["infra.script_settings"], M) or not scope_backend_current() then return false end
	_scope_owner = owner
	return true
end

--- Releases the admission gate while retaining opaque inverse receipts.
--- @param owner table Exact token.
--- @return boolean released
function M.scope_release(owner)
	if _scope_busy or not rawequal(_scope_owner, owner) or owner.pending() ~= false then return false end
	_scope_owner = nil
	return true
end

--- Captures an opaque, source-bound runtime inverse under the native claim.
--- @param owner table Exact token.
--- @return table|nil receipt
local function scope_capture_impl(owner)
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["infra.script_settings"], M) or not scope_backend_current() then return nil end
	local generation = _scope_generation
	local receipt, before = {}, scope_state()
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["infra.script_settings"], M) or _scope_generation ~= generation or not scope_backend_current() then return nil end
	_scope_receipts[receipt] = { owner = owner, before = before, expected = before, generation = _scope_generation }
	return receipt
end

function M.scope_capture(owner)
	if _scope_busy then return nil end
	_scope_busy = true
	local called, result = pcall(scope_capture_impl, owner)
	_scope_busy = false
	if not called then return nil end
	return result
end

--- Applies one canonical value after proving the captured runtime still owns it.
--- @param owner table Exact token.
--- @param receipt table Native opaque receipt.
--- @param value string Canonical declared log token.
--- @return boolean applied
local function scope_apply_impl(owner, receipt, value)
	local data = _scope_receipts[receipt]
	if not rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or data.forgotten or data.attempted
		or data.generation ~= _scope_generation or not scope_backend_current() or not scope_equal(scope_state(), data.expected)
		or not rawequal(package.loaded["infra.script_settings"], M) or not scope_backend_current() then return false end
	local level = canonical(value)
	if level ~= value then return false end
	local next_value = { module = M, active = level, level = threshold(level), setter = data.before.setter, getter = data.before.getter,
		backend_parent = data.before.backend_parent, core_parent = data.before.core_parent }
	_scope_generation = _scope_generation + 1
	data.generation, data.expected, data.attempted = _scope_generation, next_value, true
	local called = pcall(function()
		if Logger.set_level(next_value.level) == false then error("native logger setter refused") end
		_active = next_value.active
	end)
	local observed = scope_state()
	return called and scope_equal(observed, next_value) and rawequal(_scope_owner, owner)
		and rawequal(package.loaded["infra.script_settings"], M) and scope_backend_current() and data.generation == _scope_generation
end

function M.scope_apply(owner, receipt, value)
	if _scope_busy then return false end
	_scope_busy = true
	local called, result = pcall(scope_apply_impl, owner, receipt, value)
	_scope_busy = false
	if not called then return false end
	return result
end

--- Restores only this receipt's acknowledged or interrupted scalar publication.
--- @param owner table Exact token.
--- @param receipt table Native opaque receipt.
--- @return boolean restored
local function scope_restore_impl(owner, receipt)
	local data = _scope_receipts[receipt]
	if not rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or data.forgotten or data.generation ~= _scope_generation or not scope_backend_current() then return false end
	local current = scope_state()
	if not rawequal(current.module, M) or not rawequal(package.loaded["infra.script_settings"], M) or not scope_backend_current() or not (rawequal(current.backend_parent, data.before.backend_parent)
		and rawequal(current.core_parent, data.before.core_parent) and current.setter == data.before.setter and current.getter == data.before.getter
		and (current.active == data.before.active or current.active == data.expected.active)
		and (current.level == data.before.level or current.level == data.expected.level)) then return false end
	if not data.attempted or data.restored then return scope_equal(current, data.before) end
	local called = pcall(function()
		if Logger.set_level(data.before.level) == false then error("native logger restore refused") end
		_active = data.before.active
	end)
	local observed = scope_state()
	if not called or not scope_equal(observed, data.before) or not rawequal(_scope_owner, owner)
		or not rawequal(package.loaded["infra.script_settings"], M) or not scope_backend_current() or data.generation ~= _scope_generation then return false end
	_scope_generation = _scope_generation + 1
	data.generation, data.expected, data.restored = _scope_generation, data.before, true
	return true
end

function M.scope_restore(owner, receipt)
	if _scope_busy then return false end
	_scope_busy = true
	local called, result = pcall(scope_restore_impl, owner, receipt)
	_scope_busy = false
	if not called then return false end
	return result
end

--- Forgets only a finalized inverse, without changing live native state.
--- @param owner table Exact primary token.
--- @param receipt table Native opaque receipt.
--- @return boolean forgotten
function M.scope_forget(owner, receipt)
	local data = _scope_receipts[receipt]
	if _scope_busy or rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or owner.pending() ~= false then return false end
	if data.forgotten then return true end
	data.before, data.expected, data.generation = nil, nil, nil
	data.forgotten = true
	return true
end

return M
