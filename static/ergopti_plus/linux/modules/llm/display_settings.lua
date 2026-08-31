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
local Manifest = require("infra.manifest_reader")

local LOG = "modules.llm.display_settings"
local PREF_PREFIX = "llm.display."

local DEFINITIONS = {
	pred_indent = {
		path = "llm.display.pred_indent",
		type = "number",
		min = -7,
		max = 7,
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
		return value == math.floor(value) and value >= def.min and value <= def.max
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

--- Persists before publishing one live display setting.
--- @param name string
--- @param value number|boolean
--- @return boolean
function M.set(name, value)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then
		Logger.error(LOG, "Refused invalid display setting %s=%s.", tostring(name), tostring(value))
		return false
	end
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then
		Logger.error(LOG, "No storage; display setting '%s' was not changed.", name)
		return false
	end
	local persisted = value == shipped
		and Storage.delete(PREF_PREFIX .. name)
		or Storage.set(PREF_PREFIX .. name, value)
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
	local values = {}
	for value = DEFINITIONS.pred_indent.min, DEFINITIONS.pred_indent.max do
		values[#values + 1] = value
	end
	return values
end

--- Test seam: forgets cached reads.
function M._reset()
	_defaults = {}
	_values = {}
end

return M
