--- ui/menu/menu_hotstrings_custom.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings — Custom/personal menu builder
--- DESCRIPTION:
--- Builds the unified personal hotstrings menu (personal + extension TOMLs +
--- custom/dynamic hotstrings), with section toggles, counts, shortcut editor,
--- default-section picker, file links, and per-group bulk enable/disable actions.
--- Sub-module of ui.menu.menu_hotstrings — merged at load time via
--- `for k, v in pairs(sub) do M[k] = v end`.
--- ==============================================================================

local M = {}
local hs     = hs
local i18n   = require("infra.i18n")
local Labels = require("menu.labels")
local text_utils = require("infra.text_utils")
local dialog = require("infra.dialog_util")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

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

-- Thousands separator formatting lives in _shared/lua/menu/labels.lua, so the
-- three drivers render the same count the same way. This file used to carry its
-- own byte-identical copy.
local fmt_count = Labels.fmt_count

--- Checks if a hotstring group is enabled.
--- @param ctx table Context.
--- @param name string Group name.
--- @return boolean
local function groupEnabled(ctx, name)
	return (ctx.keymap and type(ctx.keymap.is_group_enabled) == "function" and ctx.keymap.is_group_enabled(name))
		or (ctx.state.hotstrings[name] ~= false)
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
		if will_enable then
			if not KeymapLifecycle.ensure_started(ctx, "enable custom hotstring section") then return end
			if ctx.keymap and type(ctx.keymap.enable_section) == "function" then pcall(ctx.keymap.enable_section, group_name, sec_name) end
		else
			if ctx.keymap and type(ctx.keymap.disable_section) == "function" then pcall(ctx.keymap.disable_section, group_name, sec_name) end
		end
		ctx.save_prefs()
		ctx.notify_feature(ctx.applyTriggerChar(sec_label or sec_name), will_enable)
		ctx.updateMenu()
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
		if enable and not KeymapLifecycle.ensure_started(ctx, "enable custom group sections") then return end
		local secs = (km and type(km.get_sections) == "function") and km.get_sections(group_name) or nil
		if type(secs) == "table" then
			-- Collect first, apply once. Calling the per-section API in a loop
			-- rebuilt the whole group — and re-sorted the whole corpus — once per
			-- section, so a single click on a 24-section group paid for 24
			-- rebuilds and kept the last one.
			local names = {}
			for _, sec in ipairs(secs) do
				if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
					names[#names + 1] = sec.name
				end
			end
			if #names > 0 and type(km.set_sections_enabled) == "function" then
				pcall(km.set_sections_enabled, group_name, names, enable)
			else
				-- Older keymap surface without the batch API: correctness first.
				for _, name in ipairs(names) do
					if enable and type(km.enable_section) == "function" then
						pcall(km.enable_section, group_name, name)
					elseif not enable and type(km.disable_section) == "function" then
						pcall(km.disable_section, group_name, name)
					end
				end
			end
		end
		if enable then
			ctx.state.hotstrings[group_name] = true
			if type(km.enable_group) == "function" then pcall(km.enable_group, group_name) end
		end
		ctx.save_prefs()
		ctx.updateMenu()
	end
end

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

local function split_personal_ext_stem(stem)
	local parts = {}
	if type(stem) ~= "string" or stem == "" then return parts end
	for part in (stem .. "__"):gmatch("(.-)__") do
		if part ~= "" then table.insert(parts, part) end
	end
	return parts
end

--- Returns the list of personal extension group names present in hotfiles,
--- sorted alphabetically (excludes "personal" itself and "custom").
--- @param ctx table Context.
--- @return table List of group name strings.
local function get_personal_ext_groups(ctx)
	local ext = {}
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		local name = ctx.get_group_name(f)
		if name:sub(1, 13) == "personal_ext_" then
			table.insert(ext, name)
		end
	end
	table.sort(ext)
	return ext
end





-- ==========================
-- ==========================
-- ======= 2/ Builder =======
-- ==========================
-- ==========================

--- Builds the unified personal hotstrings menu (personal_hotstrings.toml sections +
--- extension TOMLs from the hotstrings/ folder + custom/dynamic hotstrings),
--- with editor button, shortcut, and per-section toggles and counts for all groups.
--- @param ctx table Context.
--- @param counts table Pre-calculated counts from HotCounter.count_all().
--- @return table|nil
function M.build_custom(ctx, counts)
	local state  = ctx.state
	local paused = ctx.paused

	local custom_enabled   = groupEnabled(ctx, "custom")
	local custom_secs      = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections("custom") or nil

	-- Collect all personal groups: "personal" first, then extension groups alphabetically
	local personal_group_names = {}
	local has_personal = false
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		if ctx.get_group_name(f) == "personal" then has_personal = true; break end
	end
	if has_personal then table.insert(personal_group_names, "personal") end
	for _, ext_name in ipairs(get_personal_ext_groups(ctx)) do
		table.insert(personal_group_names, ext_name)
	end

	-- Gather all sections across all personal groups
	local all_personal_secs_by_group = {}
	for _, gname in ipairs(personal_group_names) do
		local secs = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(gname) or nil
		all_personal_secs_by_group[gname] = secs
	end
	-- Keep the personal group's sections for the default-section picker (personal only)
	local personal_secs = all_personal_secs_by_group["personal"]

	-- Total count across all personal groups + custom (for the top-level title).
	-- Now uses the pre-calculated totals from the counts structure.
	local total_count = 0
	if counts and counts.group_counts then
		for _, gname in ipairs(personal_group_names) do
			total_count = total_count + (counts.group_counts[gname] or 0)
		end
		total_count = total_count + (counts.group_counts["custom"] or 0)
	end

	-- Use category.personal for the clickable sub-item title (distinct from the greyed section header)
	local base_title = i18n.get("category.personal")
	-- Always show count (even 0) — only enabled sections contribute
	local title_str  = base_title .. " (" .. fmt_count(total_count) .. ")"


	-- =====================
	-- Shortcut helpers
	-- =====================

	local function default_sc()
		return { mods = {"ctrl"}, key = state.trigger_char }
	end

	-- Coerce sc.mods to a table so that a persisted scalar string (e.g. mods="ctrl"
	-- written by an AHK-migrated config) never crashes table.concat/ipairs (M-13).
	local function coerce_mods(mods)
		if type(mods) == "table" then return mods end
		if type(mods) == "string" and mods ~= "" then return { mods } end
		return {}
	end

	local function sc_is_default(sc)
		if not sc or sc == false or type(sc) ~= "table" then return false end
		local def = default_sc()
		if sc.key ~= def.key then return false end
		local m = coerce_mods(sc.mods)
		if #m ~= 1 then return false end
		return m[1] == "ctrl"
	end

	local function sc_label()
		local sc = state.custom_editor_shortcut
		if not sc or sc == false then return i18n.get("menu.hotstrings.shortcut_none") end
		if sc_is_default(sc) then
			return string.format(i18n.get("menu.hotstrings.shortcut_default_ctrl"), state.trigger_char)
		end
		local mods_str = table.concat(coerce_mods(sc.mods), "+")
		return mods_str ~= "" and (mods_str .. " + " .. (sc.key or "?"):upper())
				or (sc.key or "?"):upper()
	end

	local function apply_shortcut(mods, key)
		if mods and key then
			state.custom_editor_shortcut = { mods = mods, key = key }
			if ctx.hotstring_editor and type(ctx.hotstring_editor.set_shortcut) == "function" then pcall(ctx.hotstring_editor.set_shortcut, mods, key) end
		else
			state.custom_editor_shortcut = false
			if ctx.hotstring_editor and type(ctx.hotstring_editor.clear_shortcut) == "function" then pcall(ctx.hotstring_editor.clear_shortcut) end
		end
		ctx.save_prefs(); ctx.updateMenu()
	end

	-- Shortcut item: clicking it opens the customisation dialog directly
	local function sc_fn()
		local current_str = ""
		if type(state.custom_editor_shortcut) == "table" then
			-- coerce_mods guards against a persisted scalar string .mods (M-13):
			-- concatenating that field directly here would throw, same as the
			-- sc_is_default/sc_label call sites it already protects (PF-7 fix).
			current_str = table.concat(coerce_mods(state.custom_editor_shortcut.mods), "+")
				.. "+" .. (state.custom_editor_shortcut.key or "")
		end
		local ok_p, btn, raw = pcall(dialog.text_prompt,
			i18n.get("hotstrings.shortcut_custom"),
			i18n.get("menu.hotstrings.shortcut_prompt"),
			current_str, "OK", i18n.get("common.cancel")
		)
		if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
		raw = raw:match("^%s*(.-)%s*$"):lower()
		if raw == "" then apply_shortcut(nil, nil); return end
		local parts = {}
		for part in raw:gmatch("[^+]+") do table.insert(parts, part) end
		if #parts < 1 then return end
		local key  = parts[#parts]
		local mods = {}
		for i = 1, #parts - 1 do
			local m = parts[i]
			if m == "option" then m = "alt" end
			table.insert(mods, m)
		end
		if #mods == 0 then mods = {"ctrl"} end
		apply_shortcut(mods, key)
	end

	-- Build the default-section sub-menu: "Aucune" first, then one item per personal section
	local function default_section_label()
		if not state.custom_default_section then return i18n.get("menu.hotstrings.default_none") end
		if type(personal_secs) == "table" then
			for _, sec in ipairs(personal_secs) do
				if type(sec) == "table" and sec.name == state.custom_default_section then
					local lbl = resolve_desc(sec.description) ~= "" and resolve_desc(sec.description)
						or tostring(sec.name):gsub("_", " ")
					return ctx.applyTriggerChar(lbl)
				end
			end
		end
		return state.custom_default_section
	end

	local cat_menu = { {
		label   = i18n.get("menu.hotstrings.default_none"),
		checked = (not state.custom_default_section) or nil,
		action      = function()
			state.custom_default_section = nil
			if ctx.hotstring_editor and type(ctx.hotstring_editor.set_default_section) == "function" then
				pcall(ctx.hotstring_editor.set_default_section, nil)
			end
			ctx.save_prefs(); ctx.updateMenu()
		end,
	} }
	if type(personal_secs) == "table" then
		local has_real = false
		for _, sec in ipairs(personal_secs) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
				has_real = true; break
			end
		end
		if has_real then
			table.insert(cat_menu, { separator = true })
			for _, sec in ipairs(personal_secs) do
				if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
					local lbl   = (type(sec.description) == "string" and sec.description ~= "")
						and sec.description or tostring(sec.name):gsub("_", " ")
					lbl = ctx.applyTriggerChar(lbl)
					local sname = sec.name
					table.insert(cat_menu, {
						label   = lbl,
						checked = (state.custom_default_section == sname) or nil,
						action      = function()
							state.custom_default_section = sname
							if ctx.hotstring_editor and type(ctx.hotstring_editor.set_default_section) == "function" then
								pcall(ctx.hotstring_editor.set_default_section, sname)
							end
							ctx.save_prefs(); ctx.updateMenu()
						end,
					})
				end
			end
		end
	end


	-- =====================
	-- Build section rows
	-- =====================

	--- Appends section toggle rows for one group into a target list.
	--- @param target table Destination list.
	--- @param group_name string "personal" or "custom".
	--- @param secs table Section list from keymap.get_sections().
	--- @param group_enabled boolean Whether the group itself is on.
	local function append_section_rows(target, group_name, secs, group_enabled)
		if type(secs) ~= "table" then return end
		local has_real = false
		for _, sec in ipairs(secs) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
				has_real = true; break
			end
		end
		if not has_real then return end

		-- Section-level bulk actions for this personal subgroup.
		target[#target + 1] = {
			label    = i18n.get("menu.hotstrings.enable_all"),
			disabled = paused or nil,
			action       = not paused and setGroupSectionsFn(ctx, group_name, true) or nil,
		}
		target[#target + 1] = {
			label    = i18n.get("menu.hotstrings.disable_all"),
			disabled = paused or nil,
			action       = not paused and setGroupSectionsFn(ctx, group_name, false) or nil,
		}
		target[#target + 1] = { separator = true }

		for _, sec in ipairs(secs) do
			if type(sec) ~= "table" then goto continue_sec end
			if sec.name == "-" then
				target[#target + 1] = { separator = true }
			elseif not sec.is_module_placeholder then
				local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function"
					and ctx.keymap.is_section_enabled(group_name, sec.name) or false
				local lbl = (type(sec.description) == "string" and sec.description ~= "")
					and sec.description or tostring(sec.name):gsub("_", " ")
				lbl = ctx.applyTriggerChar(lbl)
				target[#target + 1] = {
					label    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
					checked  = sec_on or nil,
					action       = (group_enabled and not paused)
							   and toggleSectionFn(ctx, group_name, sec.name, lbl) or nil,
					disabled = not group_enabled or paused or nil,
				}
			end
			::continue_sec::
		end
	end


	-- =====================
	-- Assemble menu items
	local menu_items = {
		{
			label    = i18n.get("menu.hotstrings.open_editor"),
			disabled = paused or nil,
			action       = not paused and function()
				hs.timer.doAfter(0, function() pcall(ctx.hotstring_editor.open) end)
			end or nil,
		},
		{
			label    = i18n.get("menu.hotstrings.open_file"),
			disabled = paused or nil,
			action       = not paused and function() open_toml_path(toml_path_for_group(ctx, "personal")) end or nil,
		},
		{ separator = true },
		{
			-- Clicking this item directly opens the shortcut customisation dialog
			label    = i18n.get("menu.hotstrings.shortcut_prefix") .. sc_label(),
			disabled = paused or nil,
			action       = not paused and sc_fn or nil,
		},
		{
			label = i18n.get("menu.hotstrings.default_category_prefix") .. default_section_label(),
			items  = cat_menu,
		},
		{
			label    = i18n.get("menu.hotstrings.close_on_add"),
			checked  = state.custom_close_on_add or nil,
			action       = not paused and function()
				state.custom_close_on_add = not state.custom_close_on_add
				if ctx.hotstring_editor and type(ctx.hotstring_editor.set_close_on_add) == "function" then
					pcall(ctx.hotstring_editor.set_close_on_add, state.custom_close_on_add)
				end
				ctx.save_prefs(); ctx.updateMenu()
			end or nil,
			disabled = paused or nil,
		},
	}

	local ext_tree = { folders = {}, files = {} }
	local function file_rows_for_group(gname, rows)
		local result = {}
		local path = toml_path_for_group(ctx, gname)
		if path then
			result[#result + 1] = {
				label = i18n.get("menu.hotstrings.open_file"),
				action    = function() open_toml_path(path) end,
			}
			result[#result + 1] = { separator = true }
		end
		for _, row in ipairs(rows) do result[#result + 1] = row end
		return result
	end
	local function sorted_keys(tbl)
		local keys = {}
		for key in pairs(type(tbl) == "table" and tbl or {}) do keys[#keys + 1] = key end
		table.sort(keys)
		return keys
	end
	-- Sum all hotstring counts inside a node and its sub-nodes recursively.
	local function node_total(node)
		local total = 0
		for _, file in ipairs(node.files) do
			-- file.title is already "stem (N)" — extract the count from the raw groups
			if type(file.count) == "number" then total = total + file.count end
		end
		for _, sub in pairs(node.folders) do total = total + node_total(sub) end
		return total
	end

	-- Emits provider rows — `label`/`items` — because `target` is always an array
	-- the `hotstring_personal` provider hands to the renderer.
	--
	-- It wrote `title`/`menu` until 2026-08-07, the hs.menubar field names, and it
	-- READ `file.title`/`file.menu` on nodes that had already been converted to
	-- `label`/`items`. Both halves were wrong in the same direction: every
	-- extension file row reached the renderer with no label and was dropped, every
	-- folder row carried an empty submenu, and `table.sort` compared two nils —
	-- so a folder holding two or more extension files threw inside the provider
	-- and took the whole hotstrings menu with it.
	local function render_ext_tree(node, target, separate_files)
		if separate_files == nil then separate_files = true end
		local folder_names = sorted_keys(node.folders)
		for _, folder_name in ipairs(folder_names) do
			local folder_menu = {}
			render_ext_tree(node.folders[folder_name], folder_menu, true)
			local folder_total = node_total(node.folders[folder_name])
			local folder_label = folder_name .. (folder_total > 0 and (" (" .. fmt_count(folder_total) .. ")") or "")
			target[#target + 1] = { label = folder_label, items = folder_menu }
		end
		if separate_files and #folder_names > 0 and #node.files > 0 then
			target[#target + 1] = { separator = true }
		end
		table.sort(node.files, function(a, b) return a.label < b.label end)
		for _, file in ipairs(node.files) do
			target[#target + 1] = { label = file.label, items = file.items }
		end
	end

	-- All personal groups in order: personal first, then extensions alphabetically
	for _, gname in ipairs(personal_group_names) do
		local g_enabled = groupEnabled(ctx, gname)
		local g_secs    = all_personal_secs_by_group[gname]
		local g_rows    = {}
		append_section_rows(g_rows, gname, g_secs, g_enabled)

		if #g_rows > 0 then
			if gname == "personal" then
				table.insert(menu_items, { separator = true })
				for _, row in ipairs(g_rows) do table.insert(menu_items, row) end
			else
				local stem = gname:sub(14)
				local parts = split_personal_ext_stem(stem)
				if #parts > 0 then
					local node = ext_tree
					for i = 1, #parts - 1 do
						local folder = parts[i]
						node.folders[folder] = node.folders[folder] or { folders = {}, files = {} }
						node = node.folders[folder]
					end
					local g_count = 0
					local g_secs_for_count = all_personal_secs_by_group[gname]
					if type(g_secs_for_count) == "table" then
						for _, sec in ipairs(g_secs_for_count) do
							if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
								and sec.count ~= nil then
								-- `is_sec_enabled_fn` was never defined in this scope (ui-menu-layout-hot-2);
								-- use the same ctx.keymap pattern used everywhere else in this file.
								local sec_enabled_fn = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function"
									and ctx.keymap.is_section_enabled or nil
								local active = not sec_enabled_fn or sec_enabled_fn(gname, sec.name)
								if active then g_count = g_count + tonumber(sec.count) end
							end
						end
					end
					local file_label = parts[#parts] .. (g_count > 0 and (" (" .. fmt_count(g_count) .. ")") or "")
					node.files[#node.files + 1] = {
						label = file_label,
						count = g_count,
						items  = file_rows_for_group(gname, g_rows),
					}
				end
			end
		end
	end

	if #ext_tree.files > 0 or next(ext_tree.folders) ~= nil then
		table.insert(menu_items, { separator = true })
		render_ext_tree(ext_tree, menu_items, false)
	end

	-- Custom/dynamic hotstrings sections (group "custom")
	local custom_rows = {}
	append_section_rows(custom_rows, "custom", custom_secs, custom_enabled)
	if #custom_rows > 0 then
		table.insert(menu_items, { separator = true })
		for _, row in ipairs(custom_rows) do table.insert(menu_items, row) end
	end

	-- All groups toggle together when the user clicks the top-level item
	local all_personal_enabled = true
	for _, gname in ipairs(personal_group_names) do
		if not groupEnabled(ctx, gname) then all_personal_enabled = false; break end
	end
	local both_enabled = all_personal_enabled and custom_enabled
	return {
		label   = title_str,
		checked = both_enabled or nil,
		action      = function()
			local will_enable = not both_enabled
			if will_enable and not KeymapLifecycle.ensure_started(ctx,
				"enable personal and custom hotstrings") then return end
			-- Toggle all personal groups
			for _, gname in ipairs(personal_group_names) do
				state.hotstrings[gname] = will_enable
				if will_enable then
					if ctx.keymap and type(ctx.keymap.enable_group) == "function" then pcall(ctx.keymap.enable_group, gname) end
				else
					if ctx.keymap and type(ctx.keymap.disable_group) == "function" then pcall(ctx.keymap.disable_group, gname) end
				end
			end
			-- Toggle custom group
			state.hotstrings["custom"] = will_enable
			if will_enable then
				if ctx.keymap and type(ctx.keymap.enable_group) == "function" then pcall(ctx.keymap.enable_group, "custom") end
			else
				if ctx.keymap and type(ctx.keymap.disable_group) == "function" then pcall(ctx.keymap.disable_group, "custom") end
			end
			ctx.save_prefs()
			ctx.notify_feature(base_title, will_enable)
			ctx.updateMenu()
		end,
		items = menu_items,
	}
end

return M
