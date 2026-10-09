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

local Logger = require("infra.logger")
local Storage = require("adapters.storage")
local Groups = require("modules.keymap.registry_groups")
local i18n   = require("infra.i18n")
local ManifestReader = require("infra.manifest_reader")
local Languages = require("hotstrings.languages")
local PersonalFiles = require("hotstrings.personal_files")
local LOG    = "keymap.registry"

local _state = nil
local _repeat_enabled = ManifestReader.default_for("hotstrings.repeat_key_enabled")

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
--- @return boolean committed True only when the requested binding is active.
function M.setup(core_state)
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.setup(): core_state must be a table — initialization refused.")
		return false
	end
	if _state then
		if _state == core_state then
			Logger.warn(LOG, "M.setup() called more than once with the active state — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.setup(): a different state is already active — replacement refused.")
		return false
	end
	_state = core_state
	return true
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
--- @param section_sources table|nil Sections a layout extension's files supply.
function M.load_toml(name, path, section_sources, personal_source)
	return Groups.load_toml(name, path, section_sources, personal_source)
end

--- Replaces a registered native personal source inside its existing journal.
--- @param name string
--- @param path string
--- @param candidate string
--- @param publish function
--- @return boolean committed
function M.replace_personal_source(name, path, candidate, publish, resolution)
	return Groups.replace_personal_source(name, path, candidate, publish, resolution)
end

--- Atomically replaces one enabled TOML group while preserving a deliberately
--- disabled group and rolling the live corpus back on loader failure.
--- @param name string Existing group identifier.
--- @param path string Absolute TOML path.
--- @return boolean committed
function M.reload_toml(name, path)
	return Groups.reload_toml(name, path)
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

--- Commits the canonical delay projection and its conditional source publication.
--- @param resolve function Pure resolver using the candidate override source.
--- @param publish function Exact conditional publication callback.
--- @return boolean committed
function M.with_hotstring_delays(resolve, publish)
	return Groups.with_hotstring_delays(resolve, publish)
end

--- Returns every registered TOML group's sections and corpus delay metadata.
--- @return table|nil inventory Detached copies keyed by group name.
function M.hotstring_delay_inventory()
	return Groups.hotstring_delay_inventory()
end

--- Captures the current native owner used by file-labelled scope callbacks.
--- @param name string Registered group identity.
--- @return table|nil binding Detached metadata and an exact owner predicate.
function M.personal_file_scope_binding(name)
	return Groups.personal_file_scope_binding(name)
end

--- Captures the private native journal of one admitted personal publisher.
--- @return table|nil owner Bound publication and inverse acknowledgements.
function M.capture_publication_owner()
	return Groups.capture_publication_owner()
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

--- Returns the section's effective enable state.
--- hs.settings stores the user's explicit choice (`true` or `false`). A section
--- the user never touched takes the feature manifest's shipped default — every
--- bundled section ships disabled — and a section the manifest does not declare
--- (personal and extension packs) is the user's own and stays enabled.
--- @param group_name string
--- @param section_name string
--- @return boolean
function M.is_section_enabled(group_name, section_name)
	local stored = Storage.get("hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(section_name))
	if stored ~= nil then return stored ~= false end
	local shipped = Languages.section_default(ManifestReader.features(), group_name, section_name)
	if shipped == nil then return true end
	return shipped
end

--- Returns true when the magic-key repeat engine is enabled.
--- The repeat feature is now handled by the hotstring engine directly (not by a
--- TOML section), so the gate is a standalone hs.settings key. Defaults to true
--- when the setting has never been written (opt-out, not opt-in).
--- @return boolean
function M.is_repeat_feature_enabled()
	return _repeat_enabled
end

--- Enable or disable the magic-key repeat engine and persist the choice.
--- @param enabled boolean
function M.set_repeat_feature_enabled(enabled)
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "Magic-key repeat state must be a boolean.")
		return false
	end
	Groups.note_registry_mutation()
	_repeat_enabled = enabled
	-- A user-facing feature toggle with no log line leaves the repeat engine's
	-- state unrecoverable from the logs, which is where every other setting's
	-- applied value can be read back.
	Logger.debug(LOG, "Magic-key repeat engine: %s.", enabled and "on" or "off")
	return true
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
	if value == nil then return Storage.delete_exact(key) == true end
	if Storage.set(key, value) ~= true then return false end
	local read_ok, stored = Storage.read_exact(key)
	return read_ok == true and stored == value
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
--- Each change is `{ name, sections, enable_group|nil, group_enabled|nil }`.
--- Exact true means all settings and live groups reached their postcondition;
--- every other outcome restores the previous settings and registry snapshot.
--- @param changes table
--- @param enabled boolean
--- @param publish function|nil Exact persistence acknowledgement, inside rollback.
--- @return boolean committed
function M.set_groups_sections_enabled(changes, enabled, publish)
	if not require_state("set_groups_sections_enabled") then return false end
	if type(changes) ~= "table" or type(enabled) ~= "boolean" then
		Logger.error(LOG, "set_groups_sections_enabled: changes table and boolean enabled are required.")
		return false
	end
	if publish ~= nil and type(publish) ~= "function" then return false end
	if #changes == 0 then return true end

	local known_groups = Groups.list_groups()
	local keys = {}
	local seen_keys = {}
	for _, change in ipairs(changes) do
		if type(change) ~= "table" or type(change.name) ~= "string" or change.name == ""
			or type(change.sections) ~= "table" or known_groups[change.name] == nil
			or (change.group_enabled ~= nil and type(change.group_enabled) ~= "boolean") then
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
	for _, key in ipairs(keys) do
		local read_ok, value = Storage.read_exact(key)
		if not read_ok then
			Logger.error(LOG, "Could not snapshot section setting '%s'.", key)
			return false
		end
		previous[key] = { value = value }
	end

	Logger.debug(LOG, "%s %d section setting(s) across %d group(s).",
		enabled and "Enabling" or "Disabling", #keys, #changes)
	local ok, committed = xpcall(function()
		-- Both choices are written explicitly: an absent key means "the manifest's
		-- shipped default", which is disabled for every bundled section, so clearing
		-- the key would switch the section straight back off.
		for _, key in ipairs(keys) do
			if write_section_setting(key, enabled) ~= true then return false end
		end

		return Groups.transaction("set_groups_sections_enabled", function()
			for _, change in ipairs(changes) do
				if change.group_enabled == false then
					if M.disable_group(change.name) ~= true then return false end
				elseif M.is_group_enabled(change.name) then
					if M.disable_group(change.name) ~= true then return false end
					if M.enable_group(change.name) ~= true then return false end
				elseif change.enable_group == true or change.group_enabled == true then
					if M.enable_group(change.name) ~= true then return false end
				end
			end
			if publish then return publish() == true end
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

--- Sets selected category gates and all their hotstring sections together.
--- The engine master is owned separately; callers do not start it here.
--- @param targets table Dense category ids from the discovered registry.
--- @param enabled boolean
--- @param publish function|nil Persistence owner callback returning exact true.
--- @return boolean committed
function M.set_category_scope_enabled(targets, enabled, publish)
	if not require_state("set_category_scope_enabled") then return false end
	local inventory = {}
	for id in pairs(Groups.list_groups()) do
		inventory[id] = {}
		for _, section in ipairs(M.get_sections(id) or {}) do
			if Languages.section_actionable(ManifestReader.features(), id, section) then
				inventory[id][#inventory[id] + 1] = section.name
			end
		end
	end
	local plan, reason = require("hotstrings.personal_adoption").plan_selection(inventory, targets, enabled)
	if not plan then
		Logger.error(LOG, "Category selection refused: %s.", reason)
		return false
	end
	for _, id in ipairs(targets) do
		if PersonalFiles.components(id) then
			local record = require("infra.personal_hotstrings").adoption(id)
			local native = M.personal_file_scope_binding(id)
			if not record or not native or native.current() ~= true
				or require("infra.personal_hotstrings").adoption_current(record) ~= true then return false end
		end
	end
	local personal = false
	for _, id in ipairs(targets) do if PersonalFiles.components(id) then personal = true; break end end
	if personal and require("infra.preferences").personal_choices_available(plan) ~= true then return false end
	local changes, by_id = {}, {}
	for _, choice in ipairs(plan) do
		if choice.section == nil then
			local change = { name = choice.group, sections = {}, group_enabled = choice.enabled }
			changes[#changes + 1], by_id[choice.group] = change, change
		else
			local sections = by_id[choice.group].sections
			sections[#sections + 1] = choice.section
		end
	end
	return M.set_groups_sections_enabled(changes, enabled, publish)
end

--- Replaces the derived section cache and group posture from canonical preferences.
--- Loading or clearing a sparse file may never recover choices from the derived cache.
--- @param saved table Flat preferences from config.toml, or an ordinary-save snapshot.
--- @return boolean committed Every selected setting and registry group acknowledged.
function M.apply_hotstring_preferences(saved)
	if not require_state("apply_hotstring_preferences") then return false end
	local projected, desired = pcall(require("infra.preferences").project_hotstring_preferences,
		saved, Groups.list_groups(), M.get_sections)
	if not projected then
		Logger.error(LOG, "Canonical hotstring projection was refused: %s.", tostring(desired))
		return false
	end
	local previous, selected, names, changed = {}, {}, {}, {}
	for group, sections in pairs(desired.section_states) do
		names[#names + 1] = group
		for section, enabled in pairs(sections) do
			local key = section_setting_key(group, section)
			local read_ok, value = Storage.read_exact(key)
			if not read_ok then return false end
			assert(selected[key] == nil, "hotstring cache identities are ambiguous")
			previous[key], selected[key] = { value = value }, { enabled = enabled }
			if value ~= enabled then changed[group] = true end
		end
	end
	table.sort(names)
	local ok, committed = xpcall(function()
		return Groups.transaction("canonical hotstring preferences", function()
			for key, record in pairs(selected) do
				if previous[key].value ~= record.enabled
					and write_section_setting(key, record.enabled) ~= true then return false end
			end
			for _, name in ipairs(names) do
				-- Rebuild changed groups once; a later menu sync must retain a settled corpus.
				if M.is_group_enabled(name) and (changed[name] or not desired.hotstrings[name])
					and M.disable_group(name) ~= true then return false end
				if desired.hotstrings[name] and not M.is_group_enabled(name)
					and M.enable_group(name) ~= true then return false end
				if M.is_group_enabled(name) ~= desired.hotstrings[name] then return false end
			end
			return true
		end)
	end, debug.traceback)
	if not ok or committed ~= true then
		restore_section_settings(previous)
		Logger.error(LOG, "Canonical hotstring preferences did not commit: %s.", tostring(committed))
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
--- @param enabled boolean The explicit choice persisted for every listed section.
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

--- Enables a section (persists an explicit true over the shipped default) and
--- reloads its group so the mapping database reflects the change.
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
