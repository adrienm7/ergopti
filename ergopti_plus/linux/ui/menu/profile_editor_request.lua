--- ui/menu/profile_editor_request.lua

--- ==============================================================================
--- MODULE: Profile Editor Request Ownership (Linux)
--- DESCRIPTION:
--- Retains the registry image that supplied a menu's profile drafts through the
--- editor's eventual conditional write, including configuration-folder changes.
--- ==============================================================================

local M = {}

--- Captures a profile menu's source and returns its save and currentness ports.
--- @param owner table Original profile settings module.
--- @return function|nil save
--- @return function|nil current
--- @return function|nil select
--- @return function|nil delete
function M.capture(owner)
	local Prefs = require("infra.llm_preferences")
	local Paths = require("infra.config_paths")
	local list, snapshot, save = owner.list_user, owner.configuration_snapshot, owner.save_user_profile
	local select_profile, delete_profile = owner.set, owner.delete_user_profile
	local config, get_many, generation = Paths.config, Prefs.get_many, Prefs.generation
	local revision_current, publish = Prefs.is_current_revision, Prefs.set_many
	if type(list) ~= "function" or type(snapshot) ~= "function" or type(save) ~= "function"
		or type(select_profile) ~= "function" or type(delete_profile) ~= "function"
		or type(config) ~= "function" or type(get_many) ~= "function" or type(generation) ~= "function"
		or type(revision_current) ~= "function" or type(publish) ~= "function" then return nil end
	local function ports_current()
		return package.loaded["modules.llm.profile_settings"] == owner and owner.list_user == list
			and owner.configuration_snapshot == snapshot and owner.save_user_profile == save
			and owner.set == select_profile and owner.delete_user_profile == delete_profile
			and package.loaded["infra.llm_preferences"] == Prefs and Prefs.get_many == get_many
			and Prefs.generation == generation and Prefs.is_current_revision == revision_current
			and Prefs.set_many == publish and package.loaded["infra.config_paths"] == Paths and Paths.config == config
	end
	local root_ok, root = pcall(config, "config.toml")
	if not root_ok or type(root) ~= "string" or not ports_current() then return nil end
	local loaded = pcall(list, true)
	local captured, registry = pcall(snapshot)
	local read, _values, source, revision = pcall(get_many, { "llm.user_profiles" })
	if not loaded or not captured or type(registry) ~= "table" or type(registry.source) ~= "table"
		or not read or type(source) ~= "table" or source.status ~= registry.source.status
		or source.content ~= registry.source.content or type(revision) ~= "number" then return nil end
	local function current()
		if not ports_current() then return false end
		local checked, selected = pcall(config, "config.toml")
		return checked and selected == root and ports_current()
			and revision_current(revision) == true and ports_current()
	end
	if not current() then return nil end
	local function ready()
		if not current() then return false end
		local checked, actual = pcall(generation)
		return checked and actual == revision and current()
	end
	return function(candidate, activate, expected_existing)
		if not ready() then return false end
		return save(candidate, activate, expected_existing, current) == true
	end, ready, function(profile_id, model)
		if not ready() then return false end
		return select_profile("active", profile_id, model, current) == true
	end, function(profile_id)
		if not ready() then return false end
		return delete_profile(profile_id, current) == true
	end
end

return M
