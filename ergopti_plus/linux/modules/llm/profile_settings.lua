--- modules/llm/profile_settings.lua

--- ==============================================================================
--- MODULE: LLM Profile Settings (Linux)
--- DESCRIPTION:
--- Owns the active prompt profile, prediction count, and model-driven automatic
--- profile selection. Built-in profile definitions remain in shared profiles.json.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Manifest = require("infra.manifest_reader")
local Selector = require("llm.profile_selector")
local ModelProfile = require("modules.llm.model_profile")
local RegistryCodec = require("modules.llm.profile_registry_codec")
local Json = require("json")
local Codec = require("toml_codec")

local LOG = "modules.llm.profile_settings"
local PREF_PREFIX = "llm.profiles."
local USER_PROFILES_KEY = "llm.user_profiles"

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
local _registry_source = nil
-- Stored entries this version cannot read, kept verbatim and written back on
-- every save: one bad entry used to empty the registry in memory, and the next
-- save then erased every other prompt the user had written.
local _unreadable_profiles = {}
-- The unreadable entries already named, so each is warned once per process.
local _reported_profiles = {}
-- Whether the stored llm.user_profiles is an older build's shape as a whole
-- (no versioned envelope, or not text at all). Its profiles cannot be read
-- back, so no write may replace it: the cleanup removes it first.
local _registry_outdated = false
local _profile_serial = 0

local function forget_registry(refresh_values)
	_user_profiles = nil
	_registry_source = nil
	_unreadable_profiles = {}
	_registry_outdated = false
	if refresh_values then _values = {} end
end

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

local function normalize_user_profile(profile, from_registry)
	if type(profile) ~= "table" then return nil end
	local allowed = { id = true, label = true, system_single = true, system_multi = true,
		system_multi_template = true, raw_prompt = true, batch = true, stop_sequences = true }
	for key in pairs(profile) do if not allowed[key] then return nil end end
	local id = trimmed(profile.id)
	local label = trimmed(profile.label)
	local prompt = trimmed(profile.system_single)
	if not id or not id:match("^user_[%w_%-]+$") or not label or label == ""
			or not prompt or prompt == "" or type(profile.batch) ~= "boolean" then
		return nil
	end
	if profile.system_multi_template ~= nil and type(profile.system_multi_template) ~= "string" then return nil end
	if profile.system_multi ~= nil and type(profile.system_multi) ~= "string" then return nil end
	local multi = profile.system_multi_template or ""
	if profile.batch == true and multi == "" then
		multi = batch_template()
		if not multi then return nil end
	end
	local normalized = {
		id = id,
		label = label,
		system_single = prompt,
		system_multi = profile.system_multi or "",
		system_multi_template = multi,
		batch = profile.batch == true,
	}
	if type(normalized.system_multi) ~= "string" then return nil end
	if profile.raw_prompt ~= nil then
		if type(profile.raw_prompt) ~= "string" then return nil end
		normalized.raw_prompt = profile.raw_prompt
	end
	if profile.stop_sequences ~= nil then
		if type(profile.stop_sequences) ~= "table" or Json.is_null(profile.stop_sequences)
				or (from_registry and not Json.is_array(profile.stop_sequences)) then return nil end
		normalized.stop_sequences = Json.array({})
		for index, value in pairs(profile.stop_sequences) do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #profile.stop_sequences
				or type(value) ~= "string" or value == "" then return nil end
			normalized.stop_sequences[index] = value
		end
		for index = 1, #profile.stop_sequences do
			if profile.stop_sequences[index] == nil then return nil end
		end
	end
	return normalized
end

local function copy_profile(profile)
	local copy = {}
	for key, value in pairs(profile) do
		if type(value) == "table" then
			copy[key] = key == "stop_sequences" and Json.array({}) or {}
			for index, child in pairs(value) do copy[key][index] = child end
		else
			copy[key] = value
		end
	end
	return copy
end

--- Whether a stored registry is not an older build's shape. A damaged or newer
--- one is not outdated: its reader refuses it loudly and it is kept.
--- @param value any The stored llm.user_profiles value.
--- @return boolean
local function registry_current(value)
	return not RegistryCodec.is_outdated(value)
end

--- Names a stored profile this build cannot offer, once per process: it is
--- read at every registry load, and kept in the registry on every write.
--- @param index number Position in the stored registry.
--- @param candidate any The stored entry.
--- @param detail string Why it is not offered.
local function report_unreadable_profile(index, candidate, detail)
	local identity = tostring(index) .. "\0" .. tostring(type(candidate) == "table" and candidate.id) .. "\0" .. detail
	if _reported_profiles[identity] then return end
	_reported_profiles[identity] = true
	Logger.warn(LOG, "Stored user profile at index %d is outdated (%s); it is kept but not offered.", index, detail)
end

local function load_user_profiles()
	if _user_profiles then return _user_profiles end
	local Storage = require("infra.llm_preferences")
	local values, source = Storage.get_many({ USER_PROFILES_KEY })
	assert(type(source) == "table", "user profiles require an exact source snapshot")
	local stored = {}
	-- The value as stored, before the manifest type check read a wrong-typed
	-- one (a TOML array an older build wrote) as absent.
	local document = Codec.decode(source.content or "")
	local llm = type(document) == "table" and type(document.llm) == "table" and document.llm or {}
	local raw = llm[USER_PROFILES_KEY:match("^llm%.(.+)$")]
	local outdated = raw ~= nil and (type(raw) ~= "string" or RegistryCodec.is_outdated(raw))
	if outdated then
		-- An older build's registry: outdated as a whole, offered by the cleanup.
		-- Its profiles are not readable here, so writes refuse until it is gone.
		ConfigOutdated.report(USER_PROFILES_KEY, ConfigOutdated.REFUSED, Logger)
	else
		stored = RegistryCodec.decode(values[USER_PROFILES_KEY])
	end
	_user_profiles = {}
	_registry_source = source
	_unreadable_profiles = {}
	_registry_outdated = outdated
	local seen = {}
	for index, candidate in ipairs(stored) do
		local profile = normalize_user_profile(candidate, true)
		local problem = (not profile and "a field this build does not read, or one it needs is missing")
			or (seen[profile.id] and "its id is already taken")
			or (built_in_exists(profile.id) and "its id is now a built-in profile's")
			or nil
		if problem then
			report_unreadable_profile(index, candidate, problem)
			_unreadable_profiles[#_unreadable_profiles + 1] = candidate
		else
			seen[profile.id] = true
			_user_profiles[#_user_profiles + 1] = profile
		end
	end
	return _user_profiles
end

--- The registry to store: the readable profiles, then the unreadable entries
--- exactly as they were found.
--- @param profiles table
--- @return table
local function stored_registry(profiles)
	local registry = {}
	for index, profile in ipairs(profiles) do registry[index] = profile end
	for _, raw in ipairs(_unreadable_profiles) do registry[#registry + 1] = raw end
	return registry
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

local function persist_one(name, value)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then return false end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage then return false end
	local persisted = Storage.set(PREF_PREFIX .. name, value)
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
		local ok, Storage = pcall(require, "infra.llm_preferences")
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

--- Returns the profile with exactly this ID, built-in or user-defined.
--- For a request that names its own profile (an llm_prompt binding): unlike
--- resolve(), an unknown ID is nil, because a binding naming a deleted prompt
--- must be refused, never run with "basic" instead.
--- @param profile_id string
--- @return table|nil profile Detached copy, nil when no profile has this ID.
function M.resolve_id(profile_id)
	if type(profile_id) ~= "string" or profile_id == "" then return nil end
	for _, profile in ipairs(Selector.get_all_profiles(load_user_profiles(), profiles())) do
		if profile.id == profile_id then return copy_profile(profile) end
	end
	return nil
end

--- Replaces one placeholder when the template holds it. Plain indices, never
--- gsub: a user label may hold "%".
--- @param template string
--- @param placeholder string
--- @param value string
--- @return string
local function fill_if_present(template, placeholder, value)
	local at = template:find(placeholder, 1, true)
	if not at then return template end
	return template:sub(1, at - 1) .. value .. template:sub(at + #placeholder)
end

--- The label the AI menu lists a profile under: a user profile's own label, a
--- built-in's translation with its prediction count filled in.
--- @param profile table A profile record from list(), list_built_in() or list_user().
--- @param count number The AI menu's prediction count.
--- @return string label
function M.menu_label(profile, count)
	if not built_in_exists(profile.id) then return profile.label end
	local label = require("infra.i18n").get("llm.profile." .. profile.id .. ".label")
	label = fill_if_present(label, "{n}", tostring(count))
	return fill_if_present(label, "{s}", count == 1 and "" or "s")
end

--- The prompts a binding may run, as the action picker lists them: the
--- built-ins in menu order, then the user's own, each with its menu label.
--- @return table { { value = profile_id, label = string }, ... }
function M.choices()
	local count = M.get("num_predictions")
	local choices = {}
	for _, profile in ipairs(profiles()) do
		choices[#choices + 1] = { value = profile.id, label = M.menu_label(profile, count) }
	end
	for _, profile in ipairs(load_user_profiles()) do
		choices[#choices + 1] = { value = profile.id, label = M.menu_label(profile, count) }
	end
	return choices
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

--- Refuses a registry write while the stored registry is an older build's
--- shape as a whole: rewriting it would erase every profile it holds. The file
--- is left byte for byte; the user removes the old registry with « Nettoyer
--- config.toml » (it is offered there) before saving a profile again.
--- @param action string What was refused, for the log.
--- @return boolean refused
local function refuse_over_outdated_registry(action)
	if not _registry_outdated then return false end
	Logger.error(LOG, "%s refused: config.toml llm.user_profiles holds an older build's profile registry "
		.. "this build cannot read, and writing would erase it; remove it with the config cleanup first.", action)
	return true
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
	local current = load_user_profiles()
	if refuse_over_outdated_registry("Saving user profile '" .. profile.id .. "'") then return false end
	for _, existing in ipairs(current) do
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

	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage or type(Storage.set_many) ~= "function" then return false end
	local writes = { [USER_PROFILES_KEY] = RegistryCodec.encode(stored_registry(next_profiles)) }
	if activate == true then
		writes[PREF_PREFIX .. "active"] = profile.id
		writes[PREF_PREFIX .. "auto_profile_for_model"] = false
	end
	if Storage.set_many(writes, _registry_source) ~= true then
		forget_registry(true)
		Logger.error(LOG, "User profile '%s' could not be persisted; live registry is unchanged.",
			profile.id)
		return false
	end

	forget_registry(false)
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
	local current = load_user_profiles()
	if refuse_over_outdated_registry("Deleting user profile '" .. profile_id .. "'") then return false end
	for _, profile in ipairs(current) do
		if profile.id == profile_id then
			found = true
		else
			next_profiles[#next_profiles + 1] = copy_profile(profile)
		end
	end
	if not found then return false end

	local active = M.get("active")
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage or type(Storage.set_many) ~= "function" then return false end
	local writes = { [USER_PROFILES_KEY] = RegistryCodec.encode(stored_registry(next_profiles)) }
	if active == profile_id then writes[PREF_PREFIX .. "active"] = "basic" end
	if Storage.set_many(writes, _registry_source) ~= true then
		forget_registry(true)
		Logger.error(LOG, "User profile '%s' could not be deleted; live registry is unchanged.",
			profile_id)
		return false
	end

	forget_registry(false)
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
	_registry_source = nil
	_unreadable_profiles = {}
	_registry_outdated = false
	_reported_profiles = {}
	_profile_serial = 0
	ModelProfile._reset()
end

--- Marks exactly the profile leaves consumed by this owner.
--- @param document table Parsed canonical configuration.
--- @param mark function Consumed-key collector.
function M.mark_config_reads(document, mark)
	local preferences = require("infra.llm_preferences")
	preferences.mark_config_read(document, USER_PROFILES_KEY, mark, registry_current)
	for name, definition in pairs(DEFINITIONS) do
		preferences.mark_config_read(document, definition.path, mark, function(value) return valid(name, value) end)
	end
end

--- Captures registry identity as well as its exact-source cache.
--- Opaque JSON identities remain owned by the codec and are never cloned here.
--- @return table snapshot
function M.configuration_snapshot()
	return { values = _values, users = _user_profiles, source = _registry_source,
		unreadable = _unreadable_profiles, outdated = _registry_outdated }
end

--- Restores an owner-issued registry/cache snapshot without serialization.
--- @param snapshot table Owner-issued snapshot.
--- @return boolean restored
function M.restore_configuration(snapshot)
	_values, _user_profiles = snapshot.values, snapshot.users
	_registry_source, _unreadable_profiles = snapshot.source, snapshot.unreadable
	_registry_outdated = snapshot.outdated == true
	return true
end

--- Reloads profile choices from the transaction's detached candidate.
--- @return boolean applied
function M.reload_configuration()
	forget_registry(true)
	load_user_profiles()
	for name in pairs(DEFINITIONS) do if not valid(name, M.get(name)) then return false end end
	return true
end

return M
