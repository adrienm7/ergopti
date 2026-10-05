--- ui/menu/menu_hotstrings.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings
--- DESCRIPTION:
--- Builds the hotstrings and personal info sub-menus for the tray menu.
--- ==============================================================================

local M = {}
local PersonalFiles = require("hotstrings.personal_files")
local hs            = hs
local Logger        = require("infra.logger")
local DeferredWork  = require("infra.deferred_work")
local text_utils = require("infra.text_utils")
local dialog        = require("infra.dialog_util")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")
local Labels        = require("menu.labels")
local Extensions    = require("hotstrings.extensions")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local ManifestMenu = require("infra.manifest_menu")
-- Owns the « all sections » checkbox, which the personal submenu draws too.
local Custom        = require("ui.menu.menu_hotstrings_custom")
local LOG           = "menu_hotstrings"

--- Resolves a description value that may be a plain string or a multilingual table.
--- Falls back to the "fr" locale, then to an empty string.
--- @param desc string|table|nil The raw description field.
--- @return string The resolved description.
local function resolve_desc(desc)
	if type(desc) == "table" then
		local code = i18n.get_locale()
		return desc[code] or desc["fr"] or ""
	end
	return type(desc) == "string" and desc or ""
end

local dh_mod       = require("modules.dynamic_hotstrings")
-- Keymap is already loaded by init.lua before this module is required;
-- require() returns the cached module with no side-effects.
local keymap       = require("modules.keymap")
-- Per-category delays (magic key, autocorrection) are owned by hotstrings_config
-- (persisted to hotstrings_config.toml, shared with the config window). The quick
-- menu items below read/write through it so the two UIs never desync.
local hotstrings_config = require("modules.hotstrings.hotstrings_config")
local HotstringLanguages = require("hotstrings.languages")
local BulkScope = require("hotstrings.bulk_scope")
local ManifestReader = require("infra.manifest_reader")
local ProgrammableHotstrings = require("ui.menu.programmatic_hotstrings")
local ProgrammableMenuPolicy = require("menu.programmable_hotstrings")





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

-- Preview defaults are the canonical values owned by modules/keymap/init.lua.
-- We read them here so there is a single source of truth — never re-declare them.
local KM = keymap.DEFAULT_STATE

M.DEFAULT_STATE = {
	-- Preview toggle defaults — read from keymap, never duplicated here.
	preview_star_enabled          = KM.preview_star_enabled,
	preview_autocorrect_enabled   = KM.preview_autocorrect_enabled,
	preview_ai_enabled            = KM.preview_ai_enabled,
	preview_colored_tooltips      = KM.preview_colored_tooltips,
	-- Editor & UI preferences — owned by this menu module.
	custom_close_on_add           = false,
	custom_default_section        = nil,
	custom_editor_shortcut        = nil,
	sections_order_overrides      = {},
	terminator_states             = {},
	custom_terminators            = {},
	custom_delimiters             = {},
	hotstrings                    = {},
	delays                        = {},
	-- Dynamic hotstrings defaults — read from their canonical module.
	personal_info                 = dh_mod.DEFAULT_STATE.personal_info,
	dynamichotstrings_enabled     = dh_mod.DEFAULT_STATE.dynamichotstrings_enabled,
}

local function open_toml_path(path)
	if type(path) ~= "string" or path == "" then return false end
	return DeferredWork.after(0, function()
		pcall(hs.execute, "open " .. text_utils.shell_quote(path))
	end, "menu_hotstrings.open_toml")
end

local function toml_path_for_group(ctx, group_name)
	local paths = type(ctx.hotfile_paths) == "table" and ctx.hotfile_paths or {}
	local path = paths[group_name]
	return type(path) == "string" and path ~= "" and path or nil
end





-- ====================================
-- ====================================
-- ======= 2/ Menu Construction =======
-- ====================================
-- ====================================

-- Thousands separator formatting lives in _shared/lua/menu/labels.lua, so the
-- three drivers render the same count the same way. This file used to carry its
-- own byte-identical copy.
local fmt_count = Labels.fmt_count

--- Checks if a hotstring group is enabled.
--- @param ctx table Context.
--- @param name string Group name.
--- @return boolean
local function groupEnabled(ctx, name)
	if ctx.keymap and type(ctx.keymap.is_group_enabled) == "function" then
		local live = ctx.keymap.is_group_enabled(name)
		if live ~= nil then return live == true end
	end
	return ctx.state.hotstrings[name] ~= false
end

--- Gets the display label for a group.
--- @param ctx table Context.
--- @param name string Group name.
--- @return string
local function groupLabel(ctx, name)
	local meta = ctx.keymap and type(ctx.keymap.get_meta_description) == "function" and ctx.keymap.get_meta_description(name)
	-- An extension pack without a description is named by its file, not by the
	-- namespaced key the registry files it under.
	local _, stem = Extensions.parse_category_key(name)
	local lbl = (type(meta) == "string" and meta ~= "") and meta or tostring(stem or name):gsub("_", " ")
	return ctx.applyTriggerChar(lbl)
end

--- Returns only actionable section names for one registry group.
--- @param keymap_api table|nil
--- @param group_name string
--- @return table
local function section_names_for(keymap_api, group_name)
	local sections = keymap_api and type(keymap_api.get_sections) == "function"
		and keymap_api.get_sections(group_name) or nil
	local names = {}
	for _, section in ipairs(type(sections) == "table" and sections or {}) do
		if HotstringLanguages.section_actionable(ManifestReader.features(), group_name, section) then
			names[#names + 1] = section.name
		end
	end
	return names
end

--- Generates a function to toggle a hotstring group.
--- @param ctx table Context.
--- @param name string Group name.
--- @return function
local function toggleGroupFn(ctx, name)
	return function()
		local will_enable = not groupEnabled(ctx, name)
		if will_enable and not KeymapLifecycle.ensure_started(ctx, "enable hotstring group") then return end
		local mutator
		if ctx.keymap then
			if will_enable then mutator = ctx.keymap.enable_group else mutator = ctx.keymap.disable_group end
		end
		KeymapLifecycle.commit_mutation(ctx, "toggle hotstring group", function()
			if type(mutator) ~= "function" then return false end
			return mutator(name)
		end, function()
			ctx.state.hotstrings[name] = will_enable
			if ctx.save_prefs() ~= true then return false end
			ctx.notify_feature(groupLabel(ctx, name), will_enable)
			ctx.updateMenu()
		end)
	end
end

--- Generates a function to toggle a specific section.
--- @param ctx table Context.
--- @param group_name string Group name.
--- @param sec_name string Section name.
--- @param sec_label string Section display label.
--- @return function
local function toggleSectionFn(ctx, group_name, sec_name, sec_label)
	return function()
		local will_enable = not (ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(group_name, sec_name) or false)
		if will_enable and not KeymapLifecycle.ensure_started(ctx, "enable hotstring section") then return end
		local mutator
		if ctx.keymap then
			if will_enable then mutator = ctx.keymap.enable_section else mutator = ctx.keymap.disable_section end
		end
		KeymapLifecycle.commit_mutation(ctx, "toggle hotstring section", function()
			if type(mutator) ~= "function" then return false end
			return mutator(group_name, sec_name)
		end, function()
			if ctx.save_prefs() ~= true then return false end
			ctx.notify_feature(ctx.applyTriggerChar(sec_label or sec_name), will_enable)
			ctx.updateMenu()
		end)
	end
end

--- Force every section of EVERY hotstring group on or off (whole-tree bulk
--- action for the top of the Hotstrings menu). Enabling lifts each group gate so
--- the activation is immediately effective.
--- @param ctx table Context.
--- @param enable boolean true = enable everything, false = disable everything.
--- @return function
local function setAllSectionsFn(ctx, enable)
	return function()
		local km = ctx.keymap
		if enable and not KeymapLifecycle.ensure_started(ctx, "enable all hotstring sections") then return end
		local changes = {}
		for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
			local name = ctx.get_group_name and ctx.get_group_name(f) or f
			local section_names = section_names_for(km, name)
			if enable or #section_names > 0 then
				changes[#changes + 1] = {
					name = name,
					sections = section_names,
					enable_group = enable,
				}
			end
		end
		KeymapLifecycle.commit_mutation(ctx, "set all hotstring sections", function()
			if not km or type(km.set_groups_sections_enabled) ~= "function" then return false end
			return km.set_groups_sections_enabled(changes, enable)
		end, function()
			if enable then
				for _, change in ipairs(changes) do ctx.state.hotstrings[change.name] = true end
			end
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
		end)
	end
end

--- Force every section of a SET of groups on or off — one language pack's
--- « tout activer » / « tout désactiver ». One batch, so the whole language
--- commits or rolls back together; enabling lifts each group gate as the
--- per-category action does.
--- @param ctx table Context.
--- @param group_names table Array of group names.
--- @param enable boolean
--- @return function
local function setGroupListSectionsFn(ctx, group_names, enable)
	return function()
		local km = ctx.keymap
		if enable and not KeymapLifecycle.ensure_started(ctx, "enable language sections") then return end
		local changes = {}
		for _, name in ipairs(group_names) do
			changes[#changes + 1] = {
				name = name,
				sections = section_names_for(km, name),
				enable_group = enable,
			}
		end
		KeymapLifecycle.commit_mutation(ctx, "set language hotstring sections", function()
			if not km or type(km.set_groups_sections_enabled) ~= "function" then return false end
			return km.set_groups_sections_enabled(changes, enable)
		end, function()
			if enable then
				for _, change in ipairs(changes) do ctx.state.hotstrings[change.name] = true end
			end
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
		end)
	end
end

--- Builds menu items for personal information.
--- @param ctx table Context.
--- @param description string Description of the item.
--- @return table|nil
local function buildPersonalInfoItems(ctx, description)
	if not ctx.personal_info then return nil end
	description = ctx.applyTriggerChar(description)
	return {
		{
			label   = description,
			checked = ctx.state.personal_info or nil,
			action      = function()
				ctx.state.personal_info = not ctx.state.personal_info
				if ctx.state.personal_info then 
					if type(ctx.personal_info.enable) == "function" then pcall(ctx.personal_info.enable) end
				else 
					if type(ctx.personal_info.disable) == "function" then pcall(ctx.personal_info.disable) end 
				end
				if ctx.save_prefs() ~= true then return false end
				ctx.notify_feature(description or i18n.get("notify.personal_info"), ctx.state.personal_info)
				ctx.updateMenu()
			end,
		},
		{
			label = i18n.get("menu.shortcuts.edit_personal_info"),
			action    = function()
				return DeferredWork.after(0.1,
					function() pcall(ctx.personal_info.open_editor) end,
					"menu_hotstrings.open_personal_info")
			end,
		},
	}
end

--- The sections each installed extension binds inside a bundled category
--- (Ergopti's repeat corrections in the magic key category), from the boot's
--- discovery catalogue.
--- @param ctx table Menu context carrying `extension_packs`.
--- @return table Map of extension id to array of { group, section }.
--- @return table Map of group to set of bound section names.
function M.bound_sections(ctx)
	local by_extension, by_group = {}, {}
	for _, pack in ipairs(type(ctx.extension_packs) == "table" and ctx.extension_packs or {}) do
		for _, file in ipairs(pack.bound_files or {}) do
			for _, section in ipairs(file.binding.sections or {}) do
				local list = by_extension[pack.id] or {}
				by_extension[pack.id] = list
				list[#list + 1] = { group = file.binding.category, section = section }
				by_group[file.binding.category] = by_group[file.binding.category] or {}
				by_group[file.binding.category][section] = true
			end
		end
	end
	return by_extension, by_group
end

--- The rows of the sections an extension binds, drawn in its « Hotstrings
--- <extension> » submenu rather than in their category's: each keeps its
--- category, so its switch and its preference are the category's section.
--- @param ctx table Context.
--- @param bound table Array of { group, section } from M.bound_sections().
--- @return table rows
--- @return number total Entries of the sections that are on.
function M.build_bound_section_rows(ctx, bound)
	local rows, total = {}, 0
	for _, entry in ipairs(bound) do
		local sections = ctx.keymap and type(ctx.keymap.get_sections) == "function"
			and ctx.keymap.get_sections(entry.group) or {}
		for _, sec in ipairs(type(sections) == "table" and sections or {}) do
			if type(sec) == "table" and sec.name == entry.section then
				local enabled = groupEnabled(ctx, entry.group)
				local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function"
					and ctx.keymap.is_section_enabled(entry.group, sec.name) or false
				local lbl = resolve_desc(sec.description) ~= "" and resolve_desc(sec.description)
					or tostring(sec.name):gsub("_", " ")
				lbl = ctx.applyTriggerChar(lbl)
				rows[#rows + 1] = {
					label    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
					checked  = sec_on or nil,
					action   = (enabled and not ctx.paused) and function()
						if ctx.paused or (type(ctx.is_paused) == "function" and ctx.is_paused())
							or not groupEnabled(ctx, entry.group) then return false end
						local enable = not ctx.keymap.is_section_enabled(entry.group, entry.section)
						return M.commit_extension_selection(ctx, {}, { entry }, enable)
					end or nil,
					disabled = not enabled or ctx.paused or nil,
				}
				if enabled and sec_on and sec.count ~= nil then total = total + tonumber(sec.count) end
			end
		end
	end
	return rows, total
end

--- Commits the extension's exact whole-category and bound-section choices together.
--- Persistence participates in the registry owner's rollback, so a refused save
--- restores both its native gates and the settings cache.
--- @param ctx table Menu context.
--- @param groups table Whole category ids supplied by the extension.
--- @param bound table Exact `{ group, section }` bindings.
--- @param enabled boolean Explicit choice.
--- @return boolean committed
function M.commit_extension_selection(ctx, groups, bound, enabled)
	if ctx.paused or (type(ctx.is_paused) == "function" and ctx.is_paused()) then return false end
	local km = ctx.keymap
	if not km or type(km.set_groups_sections_enabled) ~= "function" then return false end
	local inventory = {}
	for _, file in ipairs(ctx.hotfiles or {}) do
		local name = ctx.get_group_name and ctx.get_group_name(file) or file
		inventory[name] = section_names_for(km, name)
	end
	local plan = BulkScope.plan(inventory, groups, enabled, bound)
	if not plan then return false end
	if enabled and not KeymapLifecycle.ensure_started(ctx, "enable extension hotstrings") then return false end
	local changes, by_group, previous = {}, {}, {}
	for _, choice in ipairs(plan) do
		local change = by_group[choice.group]
		if not change then
			change = { name = choice.group, sections = {} }
			changes[#changes + 1], by_group[choice.group] = change, change
		end
		if choice.section then
			change.sections[#change.sections + 1] = choice.section
		else
			change.group_enabled = choice.enabled
			previous[choice.group] = { value = ctx.state.hotstrings[choice.group] }
		end
	end
	local committed = KeymapLifecycle.commit_mutation(ctx, "extension hotstring selection", function()
		return km.set_groups_sections_enabled(changes, enabled, function()
			for _, change in ipairs(changes) do
				if change.group_enabled ~= nil then ctx.state.hotstrings[change.name] = change.group_enabled end
			end
			return ctx.save_prefs() == true
		end)
	end)
	if not committed then
		for name, record in pairs(previous) do ctx.state.hotstrings[name] = record.value end
		return false
	end
	ctx.updateMenu()
	return true
end

--- The extension-wide switch includes its native bound feature choices.
--- @param ctx table Menu context.
--- @param groups table Whole category ids.
--- @param bound table Exact section bindings.
--- @return table rows
function M.build_extension_bulk_actions(ctx, groups, bound)
	local all_on = #groups > 0 or #bound > 0
	for _, name in ipairs(groups) do
		if not groupEnabled(ctx, name) then all_on = false end
		for _, section in ipairs(section_names_for(ctx.keymap, name)) do
			if ctx.keymap.is_section_enabled(name, section) ~= true then all_on = false end
		end
	end
	for _, leaf in ipairs(bound) do
		if not groupEnabled(ctx, leaf.group) or ctx.keymap.is_section_enabled(leaf.group, leaf.section) ~= true then
			all_on = false
		end
	end
	return { {
		label = i18n.get("menu.hotstrings.enable_all_sections"),
		checked = all_on,
		disabled = ctx.paused or nil,
		action = not ctx.paused and function()
			return M.commit_extension_selection(ctx, groups, bound, not all_on)
		end or nil,
	} }
end

--- Builds the main hotstring groups menu.
--- @param ctx table Context.
--- @param only table|nil Optional set of group names to include (nil = all common groups).
--- @param counts table Pre-calculated counts from HotCounter.count_all().
--- @return table
function M.build_groups(ctx, only, counts)
	local top_names = {}
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		top_names[#top_names + 1] = ctx.get_group_name(f)
	end
	if #top_names == 0 then return {} end

	local items = {}
	-- A section an extension binds is drawn in that extension's submenu instead.
	local _, bound_by_group = M.bound_sections(ctx)
	for _, name in ipairs(top_names) do
		if name == "custom" or name == "personal" or name:sub(1, 13) == "personal_ext_"
			or PersonalFiles.components(name) then goto continue_group end
		if type(only) == "table" and not only[name] then goto continue_group end

		local enabled  = groupEnabled(ctx, name)
		local sections = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(name) or nil
		local has_secs = type(sections) == "table" and #sections > 0

		local total = (counts and counts.group_counts) and (counts.group_counts[name] or 0) or 0
		if name == "dynamichotstrings" and enabled and dh_mod.user_code_is_enabled() then
			total = total + dh_mod.user_code_count()
		end
		local base_label = groupLabel(ctx, name)
		local item = {
			-- Always show count (even 0) — only enabled sections contribute
			label   = base_label .. " (" .. fmt_count(total) .. ")",
			checked = enabled or nil,
			-- Clickable only as a leaf. A category with sections opens a submenu,
			-- and a row that opens a submenu is never clicked: its gate is the
			-- submenu's first row instead.
			action  = (not has_secs) and toggleGroupFn(ctx, name) or nil,
		}

		if has_secs then
			local override    = (type(ctx.state.sections_order_overrides) == "table" and ctx.state.sections_order_overrides)[name]
			local ordered_secs

			if type(override) == "table" then
				local by_name = {}
				for _, sec in ipairs(sections) do if type(sec) == "table" then by_name[sec.name] = sec end end
				local seen = {}
				ordered_secs = {}
				for _, entry in ipairs(override) do
					if entry == "-" then table.insert(ordered_secs, { name = "-" })
					elseif by_name[entry] then
						table.insert(ordered_secs, by_name[entry]); seen[entry] = true
					end
				end
				for _, sec in ipairs(sections) do
					if type(sec) == "table" and not seen[sec.name] and sec.name ~= "-" then
						table.insert(ordered_secs, sec)
					end
				end
			else
				ordered_secs = sections
			end

			local sec_menu = {}
			local prev_was_sep = true -- Suppress a potential leading separator
			for _, sec in ipairs(ordered_secs) do
				if type(sec) == "table" then
					if sec.name == "-" then
						if not prev_was_sep then
							sec_menu[#sec_menu + 1] = { separator = true }
							prev_was_sep = true
						end
					elseif bound_by_group[name] and bound_by_group[name][sec.name] then
						-- Skip: shown in the « Hotstrings <extension> » submenu
					elseif sec.is_module_placeholder then
						local ms       = type(ctx.module_sections) == "table" and ctx.module_sections[name]
						local ms_entry = type(ms) == "table" and ms[sec.name]
						local mod_id   = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
						if mod_id == "personal_info" then
							local desc = resolve_desc((type(ms_entry) == "table" and ms_entry.description) or sec.description)
							local pi_items = buildPersonalInfoItems(ctx, desc)
							if pi_items then
								for _, pi in ipairs(pi_items) do
									sec_menu[#sec_menu + 1] = pi
								end
								prev_was_sep = false
							end
						end
					else
						local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(name, sec.name) or false
						local lbl    = resolve_desc(sec.description) ~= "" and resolve_desc(sec.description)
									   or tostring(sec.name):gsub("_", " ")
						lbl = ctx.applyTriggerChar(lbl)
						sec_menu[#sec_menu + 1] = {
							label    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
							checked  = sec_on or nil,
							action       = (enabled and not ctx.paused)
									   and toggleSectionFn(ctx, name, sec.name, lbl) or nil,
							disabled = not enabled or ctx.paused or nil,
						}
						prev_was_sep = false
					end
				end
			end
			if name == "dynamichotstrings" then
				local programmable = ProgrammableMenuPolicy.build_entry_rows(ManifestMenu,
					function() return ProgrammableHotstrings.build(ctx) end)
				for _, row in ipairs(programmable) do sec_menu[#sec_menu + 1] = row end
			end
			local toml_path = toml_path_for_group(ctx, name)
			local render_ctx = { commands = {
				["hotstring_category_enable_all"] = Custom.category_scope_fn(ctx, { name }, true),
				["hotstring_category_disable_all"] = Custom.category_scope_fn(ctx, { name }, false),
			} }
			-- The renderer owns the head and separator order. A rendered child is
			-- attached as `submenu` so its native commands are not rendered twice.
			item.submenu = ManifestMenu.build("hotstring_category_menu", "Hotstrings", nil, nil,
				render_ctx, {
					["hotstring_category_file"] = function()
						if not toml_path then return {} end
						local row = ManifestMenu.command_row("hotstring_file_commands", "hotstring_file_open",
							{ hotstring_file_open = function() return open_toml_path(toml_path) end },
							{ hotstring_file_ready = function() return type(hs.execute) == "function" end })
						return row and { row } or {}
					end,
					["hotstring_category_sections"] = function() return sec_menu end,
				})
		end
		items[#items + 1] = item
		::continue_group::
	end
	return items
end

--- The whole-tree « all sections » switch of the main Hotstrings menu: its tick
--- and its behaviour, since the manifest declares the row itself as a `check`.
--- Ticked when every hotstring group and every one of its sections is on; the
--- action switches them all to the other side, and is nil while paused.
--- @param ctx table Context.
--- @return table { checked = boolean, action = function|nil }
function M.all_sections_switch(ctx)
	local names = {}
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		names[#names + 1] = ctx.get_group_name and ctx.get_group_name(f) or f
	end
	local all_on = Custom.all_sections_on(ctx, names)
	return {
		checked = all_on,
		action  = not ctx.paused and setAllSectionsFn(ctx, not all_on) or nil,
	}
end

--- The one « all sections » checkbox at the top of a language submenu, for
--- every section of the language's categories.
--- @param ctx table Context.
--- @param group_names table The language's group names.
--- @return table List of menu items.
function M.build_language_bulk_actions(ctx, group_names)
	return {
		Custom.all_sections_row(ctx, group_names, function(enable)
			return setGroupListSectionsFn(ctx, group_names, enable)
		end),
	}
end

local _mgmt = require("ui.menu.menu_hotstrings_management")
for k, v in pairs(_mgmt) do M[k] = v end
local _custom = require("ui.menu.menu_hotstrings_custom")
for k, v in pairs(_custom) do M[k] = v end

return M
