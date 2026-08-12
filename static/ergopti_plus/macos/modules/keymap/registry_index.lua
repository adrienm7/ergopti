--- modules/keymap/registry_index.lua

--- ==============================================================================
--- MODULE: Keymap Registry Index
--- DESCRIPTION:
--- Group-lifecycle forwarding layer and section-management surface for the keymap
--- registry. Provides the public API for loading/enabling/disabling hotstring
--- groups and sections, delegating group operations to registry_groups.lua.
--- Sub-module of modules.keymap.registry — merged at load time via
--- `for k, v in pairs(sub) do M[k] = v end`.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local Groups = require("modules.keymap.registry_groups")
local i18n   = require("infra.i18n")
local LOG    = "keymap.registry"

local _state = nil

--- Guard: verifies that M.setup() was called before any state-dependent public
--- function. Mirrors registry_groups.lua's require_state verbatim (section 5.8).
--- @param func_name string Name of the calling function (for error messages).
--- @return boolean True if _state is ready, false otherwise.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.setup() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- Injects the shared CoreState so state-dependent functions become live.
--- Called once from registry.lua's M.init() after the main state is wired up.
--- @param core_state table The shared CoreState from keymap/init.lua.
function M.setup(core_state)
	_state = core_state
end





-- ===========================================
-- ===========================================
-- ======= 1/ Group Loaders (forwards) =======
-- ===========================================
-- ===========================================

-- All group-loading and group-lifecycle logic lives in registry_groups.lua.
-- The public surface below is a thin forward layer so callers of registry.lua
-- keep an identical API without modification.

--- Loads mappings from a Lua file via dofile and records the group.
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the Lua hotstring file.
function M.load_file(name, path)
	return Groups.load_file(name, path)
end

--- Loads and parses mappings from a TOML configuration file.
--- Respects per-section enable/disable state stored in hs.settings.
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the TOML file.
function M.load_toml(name, path)
	return Groups.load_toml(name, path)
end

--- Manually sets the current group context used by M.add() to tag new entries.
--- Must be reset to nil after the relevant block of M.add() calls.
--- @param name string|nil Group name.
function M.set_group_context(name)
	Groups.set_group_context(name)
end

--- Registers a callback invoked after a group is enabled or re-loaded.
--- @param name string Group identifier.
--- @param f function The post-load hook.
function M.set_post_load_hook(name, f)
	Groups.set_post_load_hook(name, f)
end

--- Disables a group: removes its mappings from the live database.
--- No-op when the group is already disabled or unknown.
--- @param name string Group identifier.
function M.disable_group(name)
	return Groups.disable_group(name)
end

--- Returns true when the named group exists and is currently enabled.
--- @param name string Group identifier.
--- @return boolean
function M.is_group_enabled(name)
	return Groups.is_group_enabled(name)
end

--- Returns a flat table of {name → enabled} for all registered groups.
--- @return table
function M.list_groups()
	return Groups.list_groups()
end

--- Registers a programmatic (non-file) group with an optional metadata block.
--- Used by Lua modules that call M.add() directly instead of loading a file.
--- @param name string Group identifier.
--- @param meta_description string|nil Prose description for the menu.
--- @param sections table|nil Array of section descriptor tables.
function M.register_lua_group(name, meta_description, sections)
	Groups.register_lua_group(name, meta_description, sections)
end

--- Runs a caller-owned multi-step registry mutation against one snapshot.
--- @param label string Stable diagnostic label.
--- @param mutation function Callback that must return exact true to commit.
--- @return boolean committed
function M.registry_transaction(label, mutation)
	return Groups.transaction(label, mutation)
end

--- Enables a previously disabled group by reloading its file (or re-running its hook).
--- No-op when the group is already enabled.
--- @param name string Group identifier.
function M.enable_group(name)
	return Groups.enable_group(name)
end





-- =====================================
-- =====================================
-- ======= 2/ Section Management =======
-- =====================================
-- =====================================

--- Returns true when the section is not explicitly disabled.
--- hs.settings stores `false` when the user disables it; nil means enabled.
--- @param group_name string
--- @param section_name string
--- @return boolean
function M.is_section_enabled(group_name, section_name)
	return hs.settings.get("hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(section_name)) ~= false
end

--- Returns true when the magic-key repeat engine is enabled.
--- The repeat feature is now handled by the hotstring engine directly (not by a
--- TOML section), so the gate is a standalone hs.settings key. Defaults to true
--- when the setting has never been written (opt-out, not opt-in).
--- @return boolean
function M.is_repeat_feature_enabled()
	return hs.settings.get("magickey_repeat_enabled") ~= false
end

--- Enable or disable the magic-key repeat engine and persist the choice.
--- @param enabled boolean
function M.set_repeat_feature_enabled(enabled)
	if enabled then
		hs.settings.set("magickey_repeat_enabled", nil)
	else
		hs.settings.set("magickey_repeat_enabled", false)
	end
	-- A user-facing feature toggle with no log line leaves the repeat engine's
	-- state unrecoverable from the logs, which is where every other setting's
	-- applied value can be read back.
	Logger.debug(LOG, "Magic-key repeat engine: %s.", enabled and "on" or "off")
end

--- Builds the persistent settings key for one section.
--- @param group_name string
--- @param section_name string
--- @return string
local function section_setting_key(group_name, section_name)
	return "hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(section_name)
end

--- Writes one setting and verifies the stored postcondition.
--- `set` normally returns nil and `clear` may return false for an absent key,
--- so neither return value is a commitment; exact read-back is authoritative.
--- @param key string
--- @param value boolean|nil
--- @return boolean committed
local function write_section_setting(key, value)
	local ok, result = xpcall(function()
		if value == nil then
			hs.settings.clear(key)
		else
			hs.settings.set(key, value)
		end
		return hs.settings.get(key) == value
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Could not write section setting '%s': %s.", key, tostring(result))
		return false
	end
	return result == true
end

--- Restores settings captured before a failed mutation.
--- Values live inside records so an absent setting (`nil`) remains enumerable.
--- @param previous table Map of settings key to `{ value = boolean|nil }`.
local function restore_section_settings(previous)
	for key, record in pairs(previous) do
		if write_section_setting(key, record.value) ~= true then
			Logger.error(LOG, "Could not roll back section setting '%s'.", key)
		end
	end
end

--- Persists and applies section changes for one or more groups atomically.
--- Each change is `{ name = string, sections = string[], enable_group = bool }`.
--- Exact true means all settings and live groups reached their postcondition;
--- every other outcome restores the previous settings and registry snapshot.
--- @param changes table
--- @param enabled boolean
--- @return boolean committed
function M.set_groups_sections_enabled(changes, enabled)
	if not require_state("set_groups_sections_enabled") then return false end
	if type(changes) ~= "table" or type(enabled) ~= "boolean" then
		Logger.error(LOG, "set_groups_sections_enabled: changes table and boolean enabled are required.")
		return false
	end
	if #changes == 0 then return true end

	local known_groups = Groups.list_groups()
	local keys = {}
	local seen_keys = {}
	for _, change in ipairs(changes) do
		if type(change) ~= "table" or type(change.name) ~= "string" or change.name == ""
			or type(change.sections) ~= "table" or known_groups[change.name] == nil then
			Logger.error(LOG, "set_groups_sections_enabled: invalid or unknown group change.")
			return false
		end
		for _, section_name in ipairs(change.sections) do
			if type(section_name) ~= "string" or section_name == "" then
				Logger.error(LOG, "set_groups_sections_enabled: section names must be non-empty strings.")
				return false
			end
			local key = section_setting_key(change.name, section_name)
			if not seen_keys[key] then
				seen_keys[key] = true
				keys[#keys + 1] = key
			end
		end
	end

	local previous = {}
	local read_ok, read_err = xpcall(function()
		for _, key in ipairs(keys) do previous[key] = { value = hs.settings.get(key) } end
	end, debug.traceback)
	if not read_ok then
		Logger.error(LOG, "Could not snapshot section settings: %s.", tostring(read_err))
		return false
	end

	Logger.debug(LOG, "%s %d section setting(s) across %d group(s).",
		enabled and "Enabling" or "Disabling", #keys, #changes)
	local ok, committed = xpcall(function()
		for _, key in ipairs(keys) do
			local desired
			if enabled then desired = nil else desired = false end
			if write_section_setting(key, desired) ~= true then return false end
		end

		return Groups.transaction("set_groups_sections_enabled", function()
			for _, change in ipairs(changes) do
				if M.is_group_enabled(change.name) then
					if M.disable_group(change.name) ~= true then return false end
					if M.enable_group(change.name) ~= true then return false end
				elseif change.enable_group == true then
					if M.enable_group(change.name) ~= true then return false end
				end
			end
			return true
		end)
	end, debug.traceback)

	if not ok or committed ~= true then
		restore_section_settings(previous)
		Logger.error(LOG, "Section batch rolled back: %s.", tostring(committed))
		return false
	end
	return true
end

--- Persists the enabled state of ONE OR MORE sections and rebuilds their group
--- exactly once.
---
--- Separating "record the user's choice" from "rebuild the group" is the whole
--- point. Each rebuild tears down and fully re-registers the group and re-sorts
--- the entire corpus, and the menu's "toggle every section of this group" helper
--- called the single-section API once per section — twenty-four full-corpus
--- rebuilds for one click on the rolls group, twenty-three of them discarded by
--- the next. The TOML snapshot cache absorbs the re-parse; the re-registration,
--- the global sort and the two index rebuilds are paid in full every time.
--- @param gn string Group name.
--- @param section_names table Array of section names.
--- @param enabled boolean True to enable (clears the explicit false), false to disable.
function M.set_sections_enabled(gn, section_names, enabled)
	if type(section_names) ~= "table" then return false end
	if #section_names == 0 then return true end
	return M.set_groups_sections_enabled({ {
		name = gn,
		sections = section_names,
		enable_group = false,
	} }, enabled)
end

--- Disables a section and reloads its group so the mapping database reflects the change.
--- @param gn string Group name.
--- @param sn string Section name.
function M.disable_section(gn, sn)
	return M.set_sections_enabled(gn, { sn }, false)
end

--- Enables a section (removes the explicit false, restoring the default-enabled state)
--- and reloads its group so the mapping database reflects the change.
--- @param gn string Group name.
--- @param sn string Section name.
function M.enable_section(gn, sn)
	return M.set_sections_enabled(gn, { sn }, true)
end

--- Returns the sections table for a group, or nil if the group is unknown.
--- @param name string Group identifier.
--- @return table|nil
function M.get_sections(name)
	if not require_state("get_sections") then return nil end
	return _state.groups[name] and _state.groups[name].sections or nil
end

--- Returns the prose description from the TOML [_meta] block, or nil.
--- Resolves the active locale when the stored value is a multilingual table.
--- @param name string Group identifier.
--- @return string|nil
function M.get_meta_description(name)
	if not require_state("get_meta_description") then return nil end
	local raw = _state.groups[name] and _state.groups[name].meta_description or nil
	if type(raw) == "table" then
		local code = i18n.get_locale()
		return raw[code] or raw["fr"] or nil
	end
	return raw
end

return M
