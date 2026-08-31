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
local Manifest = require("infra.manifest_reader")

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
}

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

local function valid(name, value)
	local def = definition(name)
	if not def or type(value) ~= def.type then return false end
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
	local ok, Storage = pcall(require, "adapters.storage")
	if ok and Storage then
		local stored = Storage.get(PREF_PREFIX .. name, nil)
		if valid(name, stored) then
			_values[name] = stored
			return stored
		elseif stored ~= nil then
			Logger.warn(LOG, "Stored '%s' value is invalid; using the manifest default.", name)
		end
	end
	_values[name] = shipped
	return shipped
end

--- Persists before publishing the live value.
--- @param name string
--- @param value number|boolean
--- @return boolean
function M.set(name, value)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then
		Logger.error(LOG, "Refused invalid trigger setting %s=%s.", tostring(name), tostring(value))
		return false
	end
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then
		Logger.error(LOG, "No storage; trigger setting '%s' was not changed.", name)
		return false
	end
	local persisted = value == shipped
		and Storage.delete(PREF_PREFIX .. name)
		or Storage.set(PREF_PREFIX .. name, value)
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

return M
