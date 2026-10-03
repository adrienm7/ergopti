--- modules/llm/display_settings.lua

--- ==============================================================================
--- MODULE: LLM Display Settings (Linux)
--- DESCRIPTION:
--- Owns the durable presentation controls consumed by the Linux suggestion
--- surface. Defaults come from the shared feature manifest and only explicit
--- user changes are persisted.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Manifest = require("infra.manifest_reader")
local DisplayPolicy = require("llm.display_policy")

local LOG = "modules.llm.display_settings"
local PREF_PREFIX = "llm.display."

local DEFINITIONS = {
	pred_indent = {
		path = "llm.display.pred_indent",
		type = "number",
	},
	show_info_bar = { path = "llm.display.show_info_bar", type = "boolean" },
	streaming = { path = "llm.display.streaming", type = "boolean" },
	streaming_multi = { path = "llm.display.streaming_multi", type = "boolean" },
}

local _defaults = {}
local _values = {}

local function definition(name)
	local def = DEFINITIONS[name]
	if not def then Logger.error(LOG, "Unknown display setting '%s'.", tostring(name)) end
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
		for _, accepted in ipairs(M.indent_values()) do if value == accepted then return true end end
		return false
	end
	return true
end

--- Returns one active display setting.
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

--- Persists before publishing one live display setting.
--- @param name string
--- @param value number|boolean
--- @param expected_source table|nil Exact canonical snapshot for guarded menu commands.
--- @return boolean
function M.set(name, value, expected_source)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then
		Logger.error(LOG, "Refused invalid display setting %s=%s.", tostring(name), tostring(value))
		return false
	end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage then
		Logger.error(LOG, "No storage; display setting '%s' was not changed.", name)
		return false
	end
	local persisted
	if expected_source ~= nil then
		persisted = Storage.set_many({[PREF_PREFIX .. name] = value}, expected_source)
	else
		persisted = Storage.set(PREF_PREFIX .. name, value)
	end
	if persisted ~= true then
		Logger.error(LOG, "Display setting '%s' could not be persisted; live state is unchanged.", name)
		return false
	end
	_values[name] = value
	Logger.info(LOG, "%s: %s.", name, tostring(value))
	return true
end

--- Flips one boolean display setting.
--- @param name string
--- @return boolean
function M.toggle(name)
	local current = M.get(name)
	if type(current) ~= "boolean" then return false end
	return M.set(name, not current)
end

--- Returns the accepted indentation range.
--- @return table
function M.indent_values()
	return DisplayPolicy.indentation_values(Manifest.find_entry_by_path(DEFINITIONS.pred_indent.path))
end

--- Test seam: forgets cached reads.
function M._reset()
	_defaults = {}
	_values = {}
end

--- Marks only display leaves consumed by this owner.
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
