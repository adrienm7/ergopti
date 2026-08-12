--- ui/menu/menu_hotstrings.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings
--- DESCRIPTION:
--- Builds the hotstrings and personal info sub-menus for the tray menu.
--- ==============================================================================

local M = {}
local hs            = hs
local Logger        = require("infra.logger")
local text_utils = require("infra.text_utils")
local dialog        = require("infra.dialog_util")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")
local Labels        = require("menu.labels")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
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
	if type(path) ~= "string" or path == "" then return end
	hs.timer.doAfter(0, function()
		pcall(hs.execute, "open " .. text_utils.shell_quote(path))
	end)
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
	local lbl = (type(meta) == "string" and meta ~= "") and meta or tostring(name):gsub("_", " ")
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
		if type(section) == "table" and section.name ~= "-" and not section.is_module_placeholder then
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

--- Force every section of one group on or off (bulk action). Enabling also
--- lifts the group gate (and starts the engine) so the change is immediately
--- effective; disabling just clears the sections.
--- @param ctx table Context.
--- @param group_name string Group name.
--- @param enable boolean true = enable all sections, false = disable all.
--- @return function
local function setGroupSectionsFn(ctx, group_name, enable)
	return function()
		local km = ctx.keymap
		if enable and not KeymapLifecycle.ensure_started(ctx, "enable group sections") then return end
		local changes = { {
			name = group_name,
			sections = section_names_for(km, group_name),
			enable_group = enable,
		} }
		KeymapLifecycle.commit_mutation(ctx, "set hotstring group sections", function()
			if not km or type(km.set_groups_sections_enabled) ~= "function" then return false end
			return km.set_groups_sections_enabled(changes, enable)
		end, function()
			if enable then ctx.state.hotstrings[group_name] = true end
			if ctx.save_prefs() ~= true then return false end
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
			action    = function() hs.timer.doAfter(0.1, function() pcall(ctx.personal_info.open_editor) end) end,
		},
	}
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
	for _, name in ipairs(top_names) do
		if name == "custom" or name == "personal" or name:sub(1, 13) == "personal_ext_" then goto continue_group end
		if type(only) == "table" and not only[name] then goto continue_group end

		local enabled  = groupEnabled(ctx, name)
		local sections = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(name) or nil
		local has_secs = type(sections) == "table" and #sections > 0

		local total = (counts and counts.group_counts) and (counts.group_counts[name] or 0) or 0
		local base_label = groupLabel(ctx, name)
		local item = {
			-- Always show count (even 0) — only enabled sections contribute
			label   = base_label .. " (" .. fmt_count(total) .. ")",
			checked = enabled or nil,
			action      = toggleGroupFn(ctx, name),
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

			-- THE ORDER BELOW IS THE SHARED ONE, and the three drivers had three of
			-- them until 2026-08-07:
			--
			--   1. the category gate — everything under it is inert while it is off
			--   2. « ouvrir le fichier », when the category has one
			--   3. ─────────
			--   4. « tout activer »
			--   5. « tout désactiver »
			--   6. ─────────
			--   7. the sections
			--
			-- The gate row is NEW here. Windows and Linux have shown it since they
			-- were written; this driver relied on the parent row toggling the group
			-- when clicked, which works and which nobody discovers — the parent of a
			-- submenu reads as something you open, not something you switch off. The
			-- parent keeps its behaviour; this row makes it visible.
			local sec_menu = {}
			sec_menu[#sec_menu + 1] = {
				label  = i18n.get(enabled and "menu.hotstrings.category_on" or "menu.hotstrings.category_off"),
				action = not ctx.paused and toggleGroupFn(ctx, name) or nil,
				disabled = ctx.paused or nil,
			}
			local toml_path = toml_path_for_group(ctx, name)
			if toml_path then
				sec_menu[#sec_menu + 1] = {
					label = i18n.get("menu.hotstrings.open_file"),
					action    = function() open_toml_path(toml_path) end,
				}
			end
			sec_menu[#sec_menu + 1] = { separator = true }
			-- Section-level bulk actions for this category.
			sec_menu[#sec_menu + 1] = {
				label    = i18n.get("menu.hotstrings.enable_all"),
				disabled = ctx.paused or nil,
				action       = not ctx.paused and setGroupSectionsFn(ctx, name, true) or nil,
			}
			sec_menu[#sec_menu + 1] = {
				label    = i18n.get("menu.hotstrings.disable_all"),
				disabled = ctx.paused or nil,
				action       = not ctx.paused and setGroupSectionsFn(ctx, name, false) or nil,
			}
			sec_menu[#sec_menu + 1] = { separator = true }
			-- "replace" (J→★ key remapping) is shown in Disposition Ergopti instead.
			local prev_was_sep = true -- Suppress a potential leading separator
			for _, sec in ipairs(ordered_secs) do
				if type(sec) == "table" then
					if sec.name == "-" then
						if not prev_was_sep then
							sec_menu[#sec_menu + 1] = { separator = true }
							prev_was_sep = true
						end
					elseif name == "magic_key" and sec.name == "replace" then
						-- Skip: shown in Disposition Ergopti
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
			-- `items`, not `menu`: this row is DATA handed to a `list` provider, and
			-- the renderer reads `items` for nested rows. Written as `menu` — the
			-- hs.menubar field — the sections were attached to a field nothing reads,
			-- so every standard and Ergopti category rendered as a bare clickable row
			-- with its whole submenu gone: no « ouvrir le fichier », no bulk actions,
			-- no section toggles, and not one warning to say so.
			item.items = sec_menu
		end
		items[#items + 1] = item
		::continue_group::
	end
	return items
end

--- Builds the whole-tree bulk-action items (force every hotstring section on /
--- off). Rendered in the main Hotstrings menu as siblings of the Paramètres
--- sub-menu (after its separator), not inside it.
--- @param ctx table Context.
--- @return table List of menu items.
function M.build_bulk_actions(ctx)
	return {
		{
			label    = i18n.get("menu.hotstrings.enable_all"),
			disabled = ctx.paused or nil,
			action       = not ctx.paused and setAllSectionsFn(ctx, true) or nil,
		},
		{
			label    = i18n.get("menu.hotstrings.disable_all"),
			disabled = ctx.paused or nil,
			action       = not ctx.paused and setAllSectionsFn(ctx, false) or nil,
		},
	}
end

local _mgmt = require("ui.menu.menu_hotstrings_management")
for k, v in pairs(_mgmt) do M[k] = v end
local _custom = require("ui.menu.menu_hotstrings_custom")
for k, v in pairs(_custom) do M[k] = v end

return M
