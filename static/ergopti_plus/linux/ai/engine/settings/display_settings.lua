--- ai/engine/settings/display_settings.lua

--- ==============================================================================
--- MODULE: LLM Display Settings (Linux)
--- DESCRIPTION:
--- Owns the durable presentation controls consumed by the Linux suggestion
--- surface. Defaults come from the shared feature manifest and only explicit
--- user changes are persisted.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ConfigOutdated = require("settings.engine.migration.outdated")
local Manifest = require("menu.engine.manifest_reader")
local DisplayPolicy = require("ai.engine.settings.display_policy")
local ConfigKeys = require("settings.engine.keys")

local LOG = "ai.engine.settings.display_settings"
local PREF_PREFIX = "llm.display."

local DEFINITIONS = {
	pred_indent = {
		path = ConfigKeys.KEY.LLM_DISPLAY_PRED_INDENT,
		type = "number",
	},
	show_info_bar = { path = ConfigKeys.KEY.LLM_DISPLAY_SHOW_INFO_BAR, type = "boolean" },
	streaming = { path = ConfigKeys.KEY.LLM_DISPLAY_STREAMING, type = "boolean" },
	streaming_multi = { path = ConfigKeys.KEY.LLM_DISPLAY_STREAMING_MULTI, type = "boolean" },
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
	local ok, Storage = pcall(require, "ai.engine.preferences")
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
local function set(name, value, expected_source, on_notice, admission, publication_guard)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then
		Logger.error(LOG, "Refused invalid display setting %s=%s.", tostring(name), tostring(value))
		return false, "invalid"
	end
	local ok, Storage = pcall(require, "ai.engine.preferences")
	if not ok or not Storage then
		Logger.error(LOG, "No storage; display setting '%s' was not changed.", name)
		return false, "unconfirmed"
	end
	local values_owner, previous_value = _values, _values[name]
	local persisted
	if on_notice then
		persisted = Storage.set_many_with_notice({[PREF_PREFIX .. name] = value}, expected_source, admission, on_notice)
	elseif expected_source ~= nil then
		persisted = Storage.set_many({[PREF_PREFIX .. name] = value}, expected_source)
	else
		persisted = Storage.set(PREF_PREFIX .. name, value)
	end
	if persisted ~= true then
		Logger.error(LOG, "Display setting '%s' could not be persisted; live state is unchanged.", name)
		return false, "unconfirmed"
	end
	local may_publish = not publication_guard or publication_guard()
	if _values == values_owner and _values[name] == previous_value then
		if may_publish then _values[name] = value
		else _values[name] = nil end
	end
	Logger.info(LOG, "%s: %s.", name, tostring(value))
	return true
end

function M.set(name, value, expected_source)
	local committed = set(name, value, expected_source)
	return committed
end

--- Sets one value and returns its refusal reason and own notice receipt.
--- @return boolean committed
--- @return string|nil reason
--- @return boolean noticed
function M.set_with_reason_notice(name, value, expected_source, admission, publication_guard)
	local noticed = false
	local receipt = { admit = admission, acknowledge = function() noticed = true end }
	local committed, reason = set(name, value, expected_source, receipt, admission, publication_guard)
	return committed, reason, noticed
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
	local preferences = require("ai.engine.preferences")
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
