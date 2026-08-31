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
local USER_PROFILES_KEY = PREF_PREFIX .. "user_profiles"

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
local _user_profiles = nil
local _profile_serial = 0

local function profiles()
	if _profiles then return _profiles end
	_profiles = Selector.load_built_in_profiles()
	return _profiles
end

local function trimmed(value)
	return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
end

local function built_in_exists(profile_id)
	for _, profile in ipairs(profiles()) do
		if profile.id == profile_id then return true end
	end
	return false
end

local function batch_template()
	for _, profile in ipairs(profiles()) do
		if profile.batch == true and type(profile.system_multi_template) == "string"
				and profile.system_multi_template ~= "" then
			return profile.system_multi_template
		end
	end
	return nil
end

local function normalize_user_profile(profile)
	if type(profile) ~= "table" then return nil end
	local id = trimmed(profile.id)
	local label = trimmed(profile.label)
	local prompt = trimmed(profile.system_single)
	if not id or not id:match("^user_[%w_%-]+$") or not label or label == ""
			or not prompt or prompt == "" or type(profile.batch) ~= "boolean" then
		return nil
	end
	local multi = type(profile.system_multi_template) == "string"
		and profile.system_multi_template or ""
	if profile.batch == true and multi == "" then
		multi = batch_template()
		if not multi then return nil end
	end
	return {
		id = id,
		label = label,
		system_single = prompt,
		system_multi_template = multi,
		batch = profile.batch == true,
	}
end

local function copy_profile(profile)
	local copy = {}
	for key, value in pairs(profile) do copy[key] = value end
	return copy
end

local function load_user_profiles()
	if _user_profiles then return _user_profiles end
	_user_profiles = {}
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then return _user_profiles end
	local stored = Storage.get(USER_PROFILES_KEY, {})
	if type(stored) ~= "table" then
		Logger.error(LOG, "Stored user-profile registry is not an array; ignoring it.")
		return _user_profiles
	end
	local seen = {}
	for index, candidate in ipairs(stored) do
		local profile = normalize_user_profile(candidate)
		if not profile or seen[profile.id] or built_in_exists(profile.id) then
			Logger.error(LOG, "Stored user profile at index %d is invalid; ignoring the registry.", index)
			_user_profiles = {}
			return _user_profiles
		end
		seen[profile.id] = true
		_user_profiles[#_user_profiles + 1] = profile
	end
	return _user_profiles
end

local function profile_exists(profile_id)
	if type(profile_id) ~= "string" or profile_id == "" then return false end
	for _, profile in ipairs(Selector.get_all_profiles(load_user_profiles(), profiles())) do
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
	return Selector.get_active_profile(
		M.effective_profile(current_model), load_user_profiles(), profiles())
end

--- Returns the merged built-in and user-defined catalogue.
--- @return table
function M.list()
	local copy = {}
	for index, profile in ipairs(Selector.get_all_profiles(load_user_profiles(), profiles())) do
		copy[index] = copy_profile(profile)
	end
	return copy
end

--- Returns the immutable built-in side of the catalogue.
--- @return table
function M.list_built_in()
	local copy = {}
	for index, profile in ipairs(profiles()) do copy[index] = copy_profile(profile) end
	return copy
end

--- Returns detached copies of every user-defined profile.
--- @return table
function M.list_user()
	local copy = {}
	for index, profile in ipairs(load_user_profiles()) do copy[index] = copy_profile(profile) end
	return copy
end

--- Reports whether an ID belongs to the user-owned registry.
--- @param profile_id string
--- @return boolean
function M.is_user_profile(profile_id)
	for _, profile in ipairs(load_user_profiles()) do
		if profile.id == profile_id then return true end
	end
	return false
end

--- Allocates an unused user-profile identity for a new editor session.
--- @return string
function M.next_user_profile_id()
	local base = "user_" .. tostring(os.time())
	repeat
		_profile_serial = _profile_serial + 1
		local candidate = base .. "_" .. tostring(_profile_serial)
		if not M.is_user_profile(candidate) then return candidate end
	until false
end

--- Persists one detached user profile, optionally selecting a newly-created one.
--- @param candidate table
--- @param activate boolean|nil
--- @param expected_existing boolean|nil True for edit, false for create.
--- @return boolean
function M.save_user_profile(candidate, activate, expected_existing)
	local profile = normalize_user_profile(candidate)
	if not profile or built_in_exists(profile.id) then
		Logger.error(LOG, "Refused invalid user-profile candidate.")
		return false
	end

	local next_profiles = {}
	local replaced = false
	for _, existing in ipairs(load_user_profiles()) do
		if existing.id == profile.id then
			next_profiles[#next_profiles + 1] = profile
			replaced = true
		else
			next_profiles[#next_profiles + 1] = copy_profile(existing)
		end
	end
	if not replaced then next_profiles[#next_profiles + 1] = profile end
	if (expected_existing == true and not replaced)
			or (expected_existing == false and replaced) then
		Logger.error(LOG, "User profile '%s' changed identity before persistence.", profile.id)
		return false
	end

	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage or type(Storage.set_many) ~= "function" then return false end
	local writes = { [USER_PROFILES_KEY] = next_profiles }
	if activate == true then
		writes[PREF_PREFIX .. "active"] = profile.id
		writes[PREF_PREFIX .. "auto_profile_for_model"] = false
	end
	if Storage.set_many(writes) ~= true then
		Logger.error(LOG, "User profile '%s' could not be persisted; live registry is unchanged.",
			profile.id)
		return false
	end

	_user_profiles = next_profiles
	if activate == true then
		_values.active = profile.id
		_values.auto_profile_for_model = false
	end
	Logger.info(LOG, "User profile '%s' %s.", profile.id, replaced and "updated" or "created")
	return true
end

--- Deletes one user profile and atomically falls back when it was active.
--- @param profile_id string
--- @return boolean
function M.delete_user_profile(profile_id)
	if type(profile_id) ~= "string" or profile_id == "" then return false end
	local next_profiles = {}
	local found = false
	for _, profile in ipairs(load_user_profiles()) do
		if profile.id == profile_id then
			found = true
		else
			next_profiles[#next_profiles + 1] = copy_profile(profile)
		end
	end
	if not found then return false end

	local active = M.get("active")
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage or type(Storage.set_many) ~= "function" then return false end
	local writes = { [USER_PROFILES_KEY] = next_profiles }
	if active == profile_id then writes[PREF_PREFIX .. "active"] = "basic" end
	if Storage.set_many(writes) ~= true then
		Logger.error(LOG, "User profile '%s' could not be deleted; live registry is unchanged.",
			profile_id)
		return false
	end

	_user_profiles = next_profiles
	if active == profile_id then _values.active = "basic" end
	Logger.info(LOG, "User profile '%s' deleted.", profile_id)
	return true
end

--- Test seam: forgets cached state and shared catalogue reads.
function M._reset()
	_defaults = {}
	_values = {}
	_profiles = nil
	_user_profiles = nil
	_profile_serial = 0
	ModelProfile._reset()
end

return M
