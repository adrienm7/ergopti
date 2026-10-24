--- modules/llm/trigger_settings.lua

--- ==============================================================================
--- MODULE: LLM Trigger Settings (Linux)
--- DESCRIPTION:
--- Owns the durable automatic-trigger policy and privacy filters consumed by
--- the Linux prediction path. Shipped values come from the feature manifest;
--- only user changes are stored.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Manifest = require("infra.manifest_reader")
local AppIdentity = require("llm.app_identity")

local LOG = "modules.llm.trigger_settings"
local PREF_PREFIX = "llm.trigger."

local DEFINITIONS = {
	debounce_ms = {
		path = "llm.trigger.debounce_ms",
		type = "number",
		min = 50,
		max = 10000,
		presets = { 50, 100, 200, 300, 500, 750, 1000, 2000 },
	},
	instant_on_word_end = {
		path = "llm.trigger.instant_on_word_end",
		type = "boolean",
	},
	after_hotstring = {
		path = "llm.trigger.after_hotstring",
		type = "boolean",
	},
	secure_filter_enabled = {
		path = "llm.trigger.secure_filter_enabled",
		type = "boolean",
	},
	url_bar_filter_enabled = {
		path = "llm.trigger.url_bar_filter_enabled",
		type = "boolean",
	},
	-- The applications no prediction runs in, as the identifiers the session reports.
	disabled_apps = {
		path = "llm.trigger.disabled_apps",
		type = "table",
		apps = true,
	},
}

-- A hand-edited list cannot hold the menu hostage
local MAX_APPS = 200

local _defaults = {}
local _values = {}

local function definition(name)
	local def = DEFINITIONS[name]
	if not def then Logger.error(LOG, "Unknown trigger setting '%s'.", tostring(name)) end
	return def
end

local function default_for(name)
	if _defaults[name] ~= nil then return _defaults[name] end
	local def = definition(name)
	if not def then return nil end
	local ok, value = pcall(Manifest.default_for, def.path)
	if not ok or type(value) ~= def.type then
		Logger.error(LOG, "Manifest default for '%s' is unavailable or has the wrong type.", def.path)
		return nil
	end
	_defaults[name] = value
	return value
end

--- Whether a value is a dense list of distinct, normalised application identifiers.
--- @param value any
--- @return boolean
local function valid_apps(value)
	if type(value) ~= "table" or #value > MAX_APPS then return false end
	local seen, count = {}, 0
	for index, app in pairs(value) do
		count = count + 1
		if type(index) ~= "number" or type(app) ~= "string" or AppIdentity.normalize(app) ~= app or seen[app] then return false end
		seen[app] = true
	end
	return count == #value
end

local function valid(name, value)
	local def = definition(name)
	if not def or type(value) ~= def.type then return false end
	if def.apps then return valid_apps(value) end
	if def.type == "number" then
		return value == math.floor(value) and value >= def.min and value <= def.max
	end
	return true
end

--- Returns the active setting, falling back to the manifest when no valid
--- durable override exists.
--- @param name string
--- @return number|boolean|nil
function M.get(name)
	if _values[name] ~= nil then return _values[name] end
	local shipped = default_for(name)
	if shipped == nil then return nil end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if ok and Storage then
		local stored = Storage.get(PREF_PREFIX .. name, nil)
		if valid(name, stored) then
			_values[name] = stored
			return stored
		elseif stored ~= nil then
			-- Outdated configuration: named once, offered by the cleanup.
			ConfigOutdated.report(PREF_PREFIX .. name, ConfigOutdated.REFUSED, Logger)
		end
	end
	_values[name] = shipped
	return shipped
end

--- The applications the trigger never runs in, as a detached list.
--- @return table apps Normalised identifiers.
function M.disabled_apps()
	local copy = {}
	for index, app in ipairs(M.get("disabled_apps") or {}) do copy[index] = app end
	return copy
end

--- Whether the trigger is switched off in an application.
--- @param app any The identifier the session reports for the focused application.
--- @return boolean disabled
function M.is_app_disabled(app)
	local key = AppIdentity.normalize(app)
	if not key then return false end
	for _, disabled in ipairs(M.get("disabled_apps") or {}) do
		if disabled == key then return true end
	end
	return false
end

--- Replaces the list of applications the trigger never runs in.
--- @param apps table Identifiers; each is normalised and duplicates are merged.
--- @param expected_source table|nil Exact source retained by a deferred editor.
--- @param admission function|nil Final originating configuration admission.
--- @return boolean committed
function M.set_disabled_apps(apps, expected_source, admission)
	if type(apps) ~= "table" then return false end
	local list, seen = {}, {}
	for _, app in ipairs(apps) do
		local key = AppIdentity.normalize(app)
		if not key then
			Logger.error(LOG, "Refused an unusable application identifier for the trigger exclusions.")
			return false
		end
		if not seen[key] then seen[key] = true; list[#list + 1] = key end
	end
	return M.set("disabled_apps", list, expected_source, admission)
end

--- Persists before publishing the live value.
--- @param name string
--- @param value number|boolean
--- @param expected_source table|nil Exact source retained by a deferred editor.
--- @param admission function|nil Final originating configuration admission.
--- @return boolean
function M.set(name, value, expected_source, admission)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then
		Logger.error(LOG, "Refused invalid trigger setting %s=%s.", tostring(name), tostring(value))
		return false
	end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage then
		Logger.error(LOG, "No storage; trigger setting '%s' was not changed.", name)
		return false
	end
	local persisted
	if expected_source ~= nil or admission ~= nil then
		if type(expected_source) ~= "table" or admission ~= nil and type(admission) ~= "function"
			or type(Storage.set_many) ~= "function" then return false end
		persisted = Storage.set_many({[PREF_PREFIX .. name] = value}, expected_source, admission)
	else
		persisted = Storage.set(PREF_PREFIX .. name, value)
	end
	if persisted ~= true then
		Logger.error(LOG, "Trigger setting '%s' could not be persisted; live state is unchanged.", name)
		return false
	end
	_values[name] = value
	Logger.info(LOG, "%s: %s.", name, tostring(value))
	return true
end

--- Flips one boolean setting transactionally.
--- @param name string
--- @return boolean
function M.toggle(name)
	if type(M.get(name)) ~= "boolean" then return false end
	return M.set(name, not M.get(name))
end

--- Returns menu presets for a numeric setting.
--- @param name string
--- @return table
function M.presets(name)
	local def = definition(name)
	local values = {}
	for index, value in ipairs(def and def.presets or {}) do values[index] = value end
	return values
end

--- Returns the accepted numeric range.
--- @param name string
--- @return table|nil
function M.bounds(name)
	local def = definition(name)
	if not def or def.type ~= "number" then return nil end
	return { min = def.min, max = def.max }
end

--- Test seam: forgets all cached reads.
function M._reset()
	_defaults = {}
	_values = {}
end

--- Marks only trigger leaves consumed by this owner.
--- @param document table Parsed canonical configuration.
--- @param mark function Consumed-key collector.
function M.mark_config_reads(document, mark)
	local preferences = require("infra.llm_preferences")
	for name, definition in pairs(DEFINITIONS) do
		preferences.mark_config_read(document, definition.path, mark, function(value) return valid(name, value) end)
	end
end

--- Captures the current cache without reading or publishing preferences.
--- @return table snapshot
function M.configuration_snapshot()
	return { values = _values, defaults = _defaults }
end

--- Restores the exact cache after a refused configuration transaction.
--- @param snapshot table Owner-issued snapshot.
--- @return boolean restored
function M.restore_configuration(snapshot)
	_values = snapshot.values
	_defaults = snapshot.defaults
	return true
end

--- Resolves the detached configuration through this owner's validation rules.
--- @return boolean applied
function M.reload_configuration()
	_values = {}
	for name in pairs(DEFINITIONS) do if not valid(name, M.get(name)) then return false end end
	return true
end

return M
