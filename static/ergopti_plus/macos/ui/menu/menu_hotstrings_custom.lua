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

local PersonalFileScope = require("infra.personal_file_scope")
local M = {}
local hs     = hs
local i18n   = require("infra.i18n")
local DeferredWork = require("infra.deferred_work")
local Labels = require("menu.labels")
local text_utils = require("infra.text_utils")
local dialog = require("infra.dialog_util")
local Chord = require("chord")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local ManifestMenu = require("infra.manifest_menu")





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
	if ctx.keymap and type(ctx.keymap.is_group_enabled) == "function" then
		local live = ctx.keymap.is_group_enabled(name)
		if live ~= nil then return live == true end
	end
	return ctx.state.hotstrings[name] ~= false
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

--- Generates a function to toggle a specific section.
--- @param ctx table Context.
--- @param group_name string Group name.
--- @param sec_name string Section name.
--- @param sec_label string Section display label.
--- @param admission function|nil Current exclusive personal-file owner check.
--- @return function
local function toggleSectionFn(ctx, group_name, sec_name, sec_label, admission)
	return function()
		if admission ~= nil then
			local ok, admitted = pcall(admission)
			if not ok or admitted ~= true then
				return KeymapLifecycle.commit_mutation(ctx, "admit personal file section", function() return false end)
			end
		end
		local will_enable = not (ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(group_name, sec_name) or false)
		if will_enable and not KeymapLifecycle.ensure_started(ctx, "enable custom hotstring section") then return end
		local mutator
		if ctx.keymap then
			if will_enable then mutator = ctx.keymap.enable_section else mutator = ctx.keymap.disable_section end
		end
		KeymapLifecycle.commit_mutation(ctx, "toggle custom hotstring section", function()
			if type(mutator) ~= "function" then return false end
			return mutator(group_name, sec_name)
		end, function()
			if ctx.save_prefs() ~= true then return false end
			ctx.notify_feature(ctx.applyTriggerChar(sec_label or sec_name), will_enable)
			ctx.updateMenu()
		end)
	end
end

--- Captures declared external module owners selected by the actual shared index.
--- Placeholders without a binding remain outside this scope; an unsupported
--- declared module refuses before any category, module or file can change.
--- @param ctx table Native menu context.
--- @param group_names table Selected registry group identities.
--- @return table choices Exact runtime and sparse menu-state inverses.
local function category_module_choices(ctx, group_names)
	local choices, selected = {}, {}
	for _, group in ipairs(group_names) do
		local modules = type(ctx.module_sections) == "table" and ctx.module_sections[group]
		if type(modules) == "table" then
			for _, section in ipairs(ctx.keymap.get_sections(group) or {}) do
				local binding = modules[section.name]
				local id = type(binding) == "table" and binding.mod_id or binding
				if section.is_module_placeholder and id ~= nil then
					assert(id == "personal_info", "selected hotstring module has no scope owner")
					if not selected[id] then
						local owner = ctx[id]
						assert(type(owner) == "table" and type(owner.set_enabled) == "function"
							and type(owner.is_enabled) == "function", "hotstring module acknowledgement owner is unavailable")
						local enabled = owner.is_enabled()
						assert(type(enabled) == "boolean", "hotstring module snapshot must be boolean")
						selected[id] = true
						choices[#choices + 1] = { id = id, owner = owner, enabled = enabled, state = ctx.state[id] }
					end
				end
			end
		end
	end
	return choices
end

--- Applies only explicit external-module choices through their acknowledged owner.
--- @param choices table Captured native module choices.
--- @param enabled boolean|nil nil restores each independent runtime snapshot.
--- @return boolean committed
local function apply_category_modules(choices, enabled)
	for _, choice in ipairs(choices) do
		local value = enabled
		if value == nil then value = choice.enabled end
		if (enabled ~= nil or choice.attempted) and choice.owner.is_enabled() ~= value then
			choice.attempted = true
			if choice.owner.set_enabled(value) ~= true or choice.owner.is_enabled() ~= value then return false end
		end
	end
	return true
end

--- Commits a category gate and its section choices in the registry transaction.
--- The canonical save participates in that transaction; a failed save cannot
--- leave the live category changed or rebuild the tray as though it succeeded.
--- @param ctx table Menu context.
--- @param group_names table Native registry category ids.
--- @param enabled boolean Explicit requested posture.
--- @param admission function|nil Current exclusive personal-file owner check.
--- @return function
function M.category_scope_fn(ctx, group_names, enabled, admission)
	return function()
		local prior = {}
		for _, name in ipairs(group_names) do
			prior[#prior + 1] = { name = name, value = ctx.state.hotstrings[name] }
		end
		local scope_committed, module_choices = false, {}
		local committed = KeymapLifecycle.commit_mutation(ctx, "set hotstring category scope", function()
			local km = ctx.keymap
			if not km or type(km.set_category_scope_enabled) ~= "function" then return false end
			if admission ~= nil and admission() ~= true then return false end
			module_choices = category_module_choices(ctx, group_names)
			local result = km.set_category_scope_enabled(group_names, enabled, function()
				if apply_category_modules(module_choices, enabled) ~= true then return false end
				for _, choice in ipairs(module_choices) do ctx.state[choice.id] = enabled end
				for _, name in ipairs(group_names) do ctx.state.hotstrings[name] = enabled end
				if ctx.save_prefs() ~= true then return false end
				return true
			end)
			scope_committed = result == true
			return result
		end, function() ctx.updateMenu() end)
		-- A refresh failure cannot undo an acknowledged file and registry choice.
		if not scope_committed then
			if #module_choices > 0 then
				KeymapLifecycle.commit_mutation(ctx, "restore hotstring module choices", function()
					return apply_category_modules(module_choices)
				end)
				for _, choice in ipairs(module_choices) do ctx.state[choice.id] = choice.state end
			end
			for _, choice in ipairs(prior) do ctx.state.hotstrings[choice.name] = choice.value end
		end
		return committed
	end
end

--- Whether every group of `group_names` is on and every one of its real sections
--- is on: the tick of an « all sections » checkbox. menu_hotstrings reads it too,
--- for the category, language and whole-tree checkboxes, so there is one answer
--- to « is all of this on ». A set with no group is not « all on »: there is
--- nothing the checkbox could have switched on.
--- @param ctx table Context.
--- @param group_names table Array of group names.
--- @return boolean
function M.all_sections_on(ctx, group_names)
	if #group_names == 0 then return false end
	local km = ctx.keymap
	local section_on = km and type(km.is_section_enabled) == "function" and km.is_section_enabled or nil
	for _, name in ipairs(group_names) do
		if not groupEnabled(ctx, name) then return false end
		for _, section in ipairs(section_names_for(km, name)) do
			if not (section_on and section_on(name, section)) then return false end
		end
	end
	local ok, choices = pcall(category_module_choices, ctx, group_names)
	if not ok then return false end
	for _, choice in ipairs(choices) do if not choice.enabled then return false end end
	return true
end

--- One checkbox for every section of `group_names`, where a « tout activer » /
--- « tout désactiver » pair used to be: two rows and two keys for one control,
--- whose state the user could only guess. Ticked when all of them are on; a click
--- switches them all to the other side through `set_fn(enable)`, the scope's
--- batched writer. Greyed and inert while the script is paused, like every
--- hotstring row.
--- @param ctx table Context.
--- @param group_names table Array of group names.
--- @param set_fn function Returns the writer for one target state.
--- @return table Provider row.
function M.all_sections_row(ctx, group_names, set_fn)
	local all_on = M.all_sections_on(ctx, group_names)
	return {
		label    = i18n.get("menu.hotstrings.enable_all_sections"),
		checked  = all_on,
		disabled = ctx.paused or nil,
		action   = not ctx.paused and set_fn(not all_on) or nil,
	}
end

local function open_toml_path(path)
	if type(path) ~= "string" or path == "" then return end
	DeferredWork.after(0, function()
		pcall(hs.execute, "open " .. text_utils.shell_quote(path))
	end, "menu_hotstrings_custom.open_toml")
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
		if type(sc) ~= "table" then return i18n.get("menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment") end
		if sc_is_default(sc) then
			return string.format(i18n.get("menu.hotstrings.shortcut_default_ctrl"), state.trigger_char)
		end
		local mods_str = table.concat(coerce_mods(sc.mods), "+")
		return mods_str ~= "" and (mods_str .. " + " .. tostring(sc.key or "?"):upper())
				or tostring(sc.key or "?"):upper()
	end

	local function apply_shortcut(mods, key)
		local editor = ctx.hotstring_editor
		local committed = KeymapLifecycle.commit_mutation(ctx,
			"change personal hotstring editor shortcut", function()
				if mods and key then
					if not editor or type(editor.set_shortcut) ~= "function" then return false end
					return editor.set_shortcut(mods, key)
				end
				if not editor or type(editor.clear_shortcut) ~= "function" then return false end
				return editor.clear_shortcut()
			end)
		if not committed then return false end
		state.custom_editor_shortcut = mods and key and { mods = mods, key = key } or false
		if ctx.save_prefs() ~= true then return false end
		ctx.updateMenu()
		return true
	end

	-- Shortcut item: clicking it opens the customisation dialog directly
	local function sc_fn()
		local current_str = ""
		if type(state.custom_editor_shortcut) == "table" then
			-- coerce_mods guards against a persisted scalar string .mods (M-13):
			-- concatenating that field directly here would throw, same as the
			-- sc_is_default/sc_label call sites it already protects (PF-7 fix).
			current_str = table.concat(coerce_mods(state.custom_editor_shortcut.mods), "+")
				.. "+" .. tostring(state.custom_editor_shortcut.key or "")
		end
		local ok_p, btn, raw = pcall(dialog.text_prompt,
			i18n.get("hotstrings.shortcut_custom"),
			i18n.get("menu.hotstrings.shortcut_prompt"),
			current_str, "OK", i18n.get("common.cancel")
		)
		if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return false end
		raw = raw:match("^%s*(.-)%s*$"):lower()
		if raw == "" then return apply_shortcut(nil, nil) end
		local chord_input = raw:find("+", 1, true) and raw or ("ctrl+" .. raw)
		local parsed = Chord.parse(chord_input)
		if not parsed then
			return KeymapLifecycle.commit_mutation(ctx,
				"validate personal hotstring editor shortcut", function() return false end)
		end
		return apply_shortcut(parsed.mods, parsed.key)
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
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
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
							if ctx.save_prefs() ~= true then return false end
							ctx.updateMenu()
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
	--- @param admission function|nil Current exclusive personal-file owner check.
	local function append_section_rows(target, group_name, secs, group_enabled, admission)
		if type(secs) ~= "table" then return end
		local has_real = false
		for _, sec in ipairs(secs) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
				has_real = true; break
			end
		end
		if not has_real then return end

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
							   and toggleSectionFn(ctx, group_name, sec.name, lbl, admission) or nil,
					disabled = not group_enabled or paused or nil,
				}
			end
			::continue_sec::
		end
	end


	-- =====================
	-- Assemble menu items
	local function editor_ready()
		if ctx.paused == true or type(ctx.hotstring_editor) ~= "table"
			or type(ctx.hotstring_editor.open) ~= "function"
			or type(ctx.script_control) ~= "table"
			or type(ctx.script_control.is_paused) ~= "function" then return false end
		local ok, current = pcall(ctx.script_control.is_paused)
		return ok and current == false
	end
	local function open_editor()
		return DeferredWork.after(0, function()
			if editor_ready() then pcall(ctx.hotstring_editor.open) end
		end, "menu_hotstrings_custom.open_editor")
	end
	local editor_row = ManifestMenu.command_row("personal_hotstring_commands", "personal_hotstring_open_editor",
		{ personal_hotstring_open_editor = open_editor },
		{ personal_hotstring_editor_ready = editor_ready })
	local menu_items = {
		{
			label    = i18n.get("menu.hotstrings.open_file"),
			disabled = paused or nil,
			action       = not paused and function() open_toml_path(toml_path_for_group(ctx, "personal")) end or nil,
		},
		{ separator = true },
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
				if ctx.save_prefs() ~= true then return false end
				ctx.updateMenu()
			end or nil,
			disabled = paused or nil,
		},
	}
	if editor_row then table.insert(menu_items, 1, editor_row) end
	-- An unsupported legacy chord retains its acknowledged owner and editing
	-- surface until the ordinary-slot migration can prove a replacement.
	if state.custom_editor_shortcut ~= nil then
		table.insert(menu_items, 4, {
			label = i18n.get("menu.hotstrings.shortcut_prefix") .. sc_label(),
			disabled = paused or nil,
			action = not paused and sc_fn or nil,
		})
	end

	local ext_tree = { folders = {}, files = {} }
	local function scope_menu(names, file_rows, section_rows)
		return ManifestMenu.build("hotstring_category_menu", "Hotstrings", nil, nil,
			{ commands = {
				["hotstring_category_enable_all"] = M.category_scope_fn(ctx, names, true),
				["hotstring_category_disable_all"] = M.category_scope_fn(ctx, names, false),
			} }, {
				["hotstring_category_file"] = function() return file_rows end,
				["hotstring_category_sections"] = function() return section_rows end,
			})
	end
	local function file_menu_for_group(gname, rows, check)
		local file_rows = {}
		local path = toml_path_for_group(ctx, gname)
		if path then
			file_rows[1] = {
				label = i18n.get("menu.hotstrings.open_file"),
				action = function() open_toml_path(path) end,
			}
		end
		return ManifestMenu.build("hotstring_category_menu", "Hotstrings", nil, nil,
			{ commands = {
				["hotstring_category_enable_all"] = M.category_scope_fn(ctx, { gname }, true, check),
				["hotstring_category_disable_all"] = M.category_scope_fn(ctx, { gname }, false, check),
			} }, {
				["hotstring_category_file"] = function() return file_rows end,
				["hotstring_category_sections"] = function() return rows end,
			})
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
			target[#target + 1] = { label = file.label, submenu = file.submenu }
		end
	end

	local used_sources = {}
	-- All personal groups in order: personal first, then extensions alphabetically
	for _, gname in ipairs(personal_group_names) do
		local record
		for index, source in ipairs(ctx.personal_files or {}) do
			if source.name == gname and not used_sources[index] then
				record, used_sources[index] = source, true
				break
			end
		end
		local g_enabled = groupEnabled(ctx, gname)
		local g_secs    = all_personal_secs_by_group[gname]
		local g_rows    = {}
		local admission = gname ~= "personal" and PersonalFileScope.bind(ctx, record) or nil
		append_section_rows(g_rows, gname, g_secs, g_enabled, admission)

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
						submenu = file_menu_for_group(gname, g_rows, admission),
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

	-- The parent tick summarizes the desired gates. The shared commands select
	-- these groups together without starting capture or inferring mixed state.
	local all_personal_enabled = true
	for _, gname in ipairs(personal_group_names) do
		if not groupEnabled(ctx, gname) then all_personal_enabled = false; break end
	end
	local both_enabled = all_personal_enabled and custom_enabled
	local scope_names = {}
	for _, name in ipairs(personal_group_names) do scope_names[#scope_names + 1] = name end
	if type(custom_secs) == "table" then scope_names[#scope_names + 1] = "custom" end
	return {
		label   = title_str,
		checked = both_enabled or nil,
		submenu = scope_menu(scope_names, {}, menu_items),
	}
end

return M
