--- modules/llm/profile_settings.lua

--- ==============================================================================
--- MODULE: LLM Profile Settings (Linux)
--- DESCRIPTION:
--- Owns the active prompt profile, prediction count, and model-driven automatic
--- profile selection. Built-in profile definitions remain in shared profiles.json.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")
local Selector = require("llm.profile_selector")
local ModelProfile = require("modules.llm.model_profile")

local LOG = "modules.llm.profile_settings"
local PREF_PREFIX = "llm.profiles."

local DEFINITIONS = {
	active = { path = "llm.profiles.active", type = "string" },
	num_predictions = {
		path = "llm.profiles.num_predictions",
		type = "number",
		min = 1,
		max = 10,
	},
	auto_profile_for_model = {
		path = "llm.profiles.auto_profile_for_model",
		type = "boolean",
	},
}

local _defaults = {}
local _values = {}
local _profiles = nil

local function profiles()
	if _profiles then return _profiles end
	_profiles = Selector.load_built_in_profiles()
	return _profiles
end

local function profile_exists(profile_id)
	if type(profile_id) ~= "string" or profile_id == "" then return false end
	for _, profile in ipairs(profiles()) do
		if profile.id == profile_id then return true end
	end
	return false
end

local function definition(name)
	local def = DEFINITIONS[name]
	if not def then Logger.error(LOG, "Unknown profile setting '%s'.", tostring(name)) end
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
	if name == "active" then return profile_exists(value) end
	if def.type == "number" then
		return value == math.floor(value) and value >= def.min and value <= def.max
	end
	return true
end

--- Returns one persisted-or-shipped profile setting.
--- @param name string
--- @return string|number|boolean|nil
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

local function persist_one(name, value)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then return false end
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then return false end
	local persisted = value == shipped
		and Storage.delete(PREF_PREFIX .. name)
		or Storage.set(PREF_PREFIX .. name, value)
	if persisted ~= true then return false end
	_values[name] = value
	return true
end

--- Persists one profile setting before publishing it.
--- Manually selecting a non-recommended profile also disables auto-selection in
--- the same storage transaction, matching the Windows/macOS interaction.
--- @param name string
--- @param value string|number|boolean
--- @param current_model string|nil
--- @return boolean
function M.set(name, value, current_model)
	if not valid(name, value) or default_for(name) == nil then
		Logger.error(LOG, "Refused invalid profile setting %s=%s.", tostring(name), tostring(value))
		return false
	end
	if name == "active" and M.get("auto_profile_for_model") == true
			and value ~= ModelProfile.recommend(current_model) then
		local ok, Storage = pcall(require, "adapters.storage")
		if not ok or not Storage or type(Storage.set_many) ~= "function"
				or Storage.set_many({
					[PREF_PREFIX .. "active"] = value,
					[PREF_PREFIX .. "auto_profile_for_model"] = false,
				}) ~= true then
			Logger.error(LOG, "Manual profile selection could not be persisted atomically.")
			return false
		end
		_values.active = value
		_values.auto_profile_for_model = false
	else
		if not persist_one(name, value) then
			Logger.error(LOG, "Profile setting '%s' could not be persisted; live state is unchanged.", name)
			return false
		end
	end
	Logger.info(LOG, "%s: %s.", name, tostring(value))
	return true
end

--- Returns the profile that should drive the next request.
--- @param current_model string|nil
--- @return string
function M.effective_profile(current_model)
	if M.get("auto_profile_for_model") == true then
		local recommended = ModelProfile.recommend(current_model)
		if profile_exists(recommended) then return recommended end
	end
	return M.get("active")
end

--- Returns a built-in profile by effective ID.
--- @param current_model string|nil
--- @return table|nil
function M.resolve(current_model)
	return Selector.get_active_profile(M.effective_profile(current_model), nil, profiles())
end

--- Returns the built-in catalogue.
--- @return table
function M.list()
	local copy = {}
	for index, profile in ipairs(profiles()) do copy[index] = profile end
	return copy
end

--- Test seam: forgets cached state and shared catalogue reads.
function M._reset()
	_defaults = {}
	_values = {}
	_profiles = nil
	ModelProfile._reset()
end

return M
