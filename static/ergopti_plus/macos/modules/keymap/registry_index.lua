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
	Groups.load_file(name, path)
end

--- Loads and parses mappings from a TOML configuration file.
--- Respects per-section enable/disable state stored in hs.settings.
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the TOML file.
function M.load_toml(name, path)
	Groups.load_toml(name, path)
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
	Groups.disable_group(name)
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

--- Enables a previously disabled group by reloading its file (or re-running its hook).
--- No-op when the group is already enabled.
--- @param name string Group identifier.
function M.enable_group(name)
	Groups.enable_group(name)
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
	if type(section_names) ~= "table" or #section_names == 0 then return end
	Logger.debug(LOG, "%s %d section(s) of '%s'.",
		enabled and "Enabling" or "Disabling", #section_names, tostring(gn))

	-- Every setting first: the rebuild below reads them all, so a rebuild
	-- interleaved between writes would register a half-applied state.
	for _, sn in ipairs(section_names) do
		local key = "hotstrings_section_" .. tostring(gn) .. "_" .. tostring(sn)
		-- Nil is the enabled sentinel and cannot be selected by Lua's and/or
		-- ternary idiom: `true and nil or false` always evaluates to false.
		if enabled then
			hs.settings.set(key, nil)
		else
			hs.settings.set(key, false)
		end
	end

	if M.is_group_enabled(gn) then
		M.disable_group(gn)
		M.enable_group(gn)
	end
end

--- Disables a section and reloads its group so the mapping database reflects the change.
--- @param gn string Group name.
--- @param sn string Section name.
function M.disable_section(gn, sn)
	M.set_sections_enabled(gn, { sn }, false)
end

--- Enables a section (removes the explicit false, restoring the default-enabled state)
--- and reloads its group so the mapping database reflects the change.
--- @param gn string Group name.
--- @param sn string Section name.
function M.enable_section(gn, sn)
	M.set_sections_enabled(gn, { sn }, true)
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
