--- ui/menu/builder.lua

--- ==============================================================================
--- MODULE: Menu Builder
--- DESCRIPTION:
--- Constructs the visual hierarchy of the macOS menubar.
---
--- FEATURES & RATIONALE:
--- 1. Stateless Rendering: Consumes the context and returns pure UI tables.
--- 2. Delegation: Relies on specific menu_* submodules for component building.
--- 3. Dynamic Centering: Creates a transparent full-width canvas to center the badge.
--- ==============================================================================

local M = {}
local PersonalFiles = require("hotstrings.personal_files")
local hs         = hs
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local LOG        = "builder"
local i18n       = require("infra.i18n")
-- The single reader of menu_manifest.json. See load_manifest below for why this
-- module no longer has one of its own.
local ManifestMenu = require("infra.manifest_menu")

--- Checks raw dense arrays without triggering source metamethods.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function debug_dense(value, records)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local count, maximum = 0, 0
	for index, row in next, value do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return false end
		if records and (type(row) ~= "table" or getmetatable(row) ~= nil) then return false end
		count, maximum = count + 1, math.max(maximum, index)
	end
	return count == maximum
end

--- Admits the actual Debug source structure without interpreting choice grammar.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function debug_source(renderer, platform)
	if type(renderer) ~= "table" or type(rawget(renderer, "get_root")) ~= "function"
		or type(rawget(renderer, "build")) ~= "function" or type(rawget(renderer, "group_row")) ~= "function" then return nil end

	local root = renderer.get_root()
	if type(root) ~= "table" or getmetatable(root) ~= nil then return nil end
	local top, children = rawget(root, "top_level"), rawget(root, "debug_menu")
	if not debug_dense(top, true) or not debug_dense(children, true) then return nil end
	local parent
	for _, row in next, top do
		if rawget(row, "id") == "debug" then
			if parent then return nil end
			parent = row
		end
	end
	if parent == nil or rawget(parent, "type") ~= "group" or type(rawget(parent, "i18n")) ~= "string"
		or rawget(parent, "i18n") == "" or not debug_dense(rawget(parent, "rows"), true) then return nil end
	local platforms = rawget(parent, "platforms")
	if platforms ~= nil then
		if not debug_dense(platforms, false) then return nil end
		local visible = false
		for _, token in next, platforms do
			if type(token) ~= "string" then return nil end
			if token == platform then visible = true end
		end
		if not visible then return nil end
	end
	local fields = {}
	for key, value in next, parent do fields[key] = value end
	return root, top, children, parent, fields
end

--- Rechecks the captured direct parent fields without source metamethods.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function debug_parent_unchanged(parent, fields)
	for key, value in next, parent do
		if not rawequal(value, rawget(fields, key)) then return false end
	end
	for key, value in next, fields do
		if not rawequal(value, rawget(parent, key)) then return false end
	end
	return true
end

--- Checks raw dense arrays without triggering source metamethods.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function configuration_dense(value, records)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local count, maximum = 0, 0
	for index, row in next, value do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return false end
		if records and (type(row) ~= "table" or getmetatable(row) ~= nil) then return false end
		count, maximum = count + 1, math.max(maximum, index)
	end
	return count == maximum
end

--- Admits the actual Configuration source structure without interpreting command grammar.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function configuration_source(renderer, platform)
	if type(renderer) ~= "table" or type(rawget(renderer, "get_root")) ~= "function"
		or type(rawget(renderer, "build")) ~= "function" or type(rawget(renderer, "group_row")) ~= "function" then return nil end

	local root = renderer.get_root()
	if type(root) ~= "table" or getmetatable(root) ~= nil then return nil end
	local top, children = rawget(root, "top_level"), rawget(root, "configuration_menu")
	if not configuration_dense(top, true) or not configuration_dense(children, true) then return nil end
	local parent
	for _, row in next, top do
		if rawget(row, "id") == "configuration" then
			if parent then return nil end
			parent = row
		end
	end
	if parent == nil or rawget(parent, "type") ~= "group" or type(rawget(parent, "i18n")) ~= "string"
		or rawget(parent, "i18n") == "" or not configuration_dense(rawget(parent, "rows"), true) then return nil end
	local platforms = rawget(parent, "platforms")
	if platforms ~= nil then
		if not configuration_dense(platforms, false) then return nil end
		local visible = false
		for _, token in next, platforms do
			if type(token) ~= "string" then return nil end
			if token == platform then visible = true end
		end
		if not visible then return nil end
	end
	local fields = {}
	for key, value in next, parent do fields[key] = value end
	return root, top, children, parent, fields
end

--- Rechecks the captured direct parent fields without source metamethods.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function configuration_parent_unchanged(parent, fields)
	for key, value in next, parent do
		if not rawequal(value, rawget(fields, key)) then return false end
	end
	for key, value in next, fields do
		if not rawequal(value, rawget(parent, key)) then return false end
	end
	return true
end


local HotCounter  = require("ui.menu.hotstring_counter")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local CanvasBadge = require("ui.menu.canvas_badge")
local Labels      = require("menu.labels")


local Languages   = require("hotstrings.languages")
local Extensions  = require("hotstrings.extensions")
local TomlCodec   = require("toml_codec.codec")
local LocaleTable = require("_generated.locale_table")

local _language_packs_cache    = nil
local _top_level_cache         = nil

--- Returns the parsed menu_manifest.json root.
---
--- ONE READER, NOT THREE. This used to be a second open/read/hs.json.decode with
--- a second session cache, byte-for-byte the shape of infra/manifest_menu's own
--- get_manifest_root() down to the two error messages — and menu_remap carried a
--- third. Three copies of a file read is three places for a path change to land
--- in one of, and it cost a duplicate decode of an 11.9 KB file on the boot path,
--- which is precisely the cost the Windows driver's manifest loader records
--- having removed on its side.
---
--- infra/manifest_menu owns it because it is infra and because it already
--- exposed get_root(); this module is a UI builder. There is no require cycle:
--- manifest_menu pulls in logger, paths and i18n only.
--- @return table|nil Parsed manifest data, or nil on failure.
local function load_manifest()
	return ManifestMenu.get_root()
end

--- The bundled categories each installed extension binds whole, in menu order.
---
--- A layout extension may carry a whole category written for its geometry
--- (Ergopti's SFB reduction and rolls). The category keeps its historical id, so
--- the registry, the preferences and the counters address it as before, and the
--- menu lists it under the extension that supplies it rather than among the
--- common categories.
--- @param ctx table Menu context carrying `extension_packs` and `hotfiles`.
--- @return table by_extension Map of extension id to { name, groups }.
--- @return table groups Set of every bound category loaded this boot.
function M.bound_groups(ctx)
	local loaded = {}
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		loaded[ctx.get_group_name and ctx.get_group_name(f) or f] = true
	end
	local by_extension, groups = {}, {}
	for _, pack in ipairs(type(ctx.extension_packs) == "table" and ctx.extension_packs or {}) do
		for _, file in ipairs(pack.bound_files or {}) do
			local category = file.binding.category
			if file.binding.sections == nil and loaded[category] then
				local entry = by_extension[pack.id] or { name = pack.name, groups = {} }
				by_extension[pack.id] = entry
				entry.groups[#entry.groups + 1] = category
				groups[category] = true
			end
		end
	end
	-- The menu manifest's order, the one Windows walks too, not the stems'.
	local manifest = load_manifest()
	for _, entry in pairs(by_extension) do
		entry.groups = Extensions.menu_order(entry.groups, type(manifest) == "table" and manifest.hotstring_groups or nil)
	end
	return by_extension, groups
end

--- The « Hotstrings <extension> » submenus to draw, in catalogue order: each
--- installed extension with the categories it binds whole, then its packs.
--- An extension that supplies no loaded category draws no submenu.
--- @param ctx table Menu context carrying `extension_packs`.
--- @param counts table Result of HotCounter.count_all().
--- @param by_extension table First result of M.bound_groups().
--- @param bound_sections table|nil First result of menu_hotstrings.bound_sections().
--- @return table Array of { id, name, groups, sections, total }.
function M.extension_menus(ctx, counts, by_extension, bound_sections)
	local ext_by_id = {}
	for _, ext in ipairs(counts.ext_details) do ext_by_id[ext.id] = ext end
	local menus = {}
	for _, pack in ipairs(type(ctx.extension_packs) == "table" and ctx.extension_packs or {}) do
		local bound, ext = by_extension[pack.id], ext_by_id[pack.id]
		local names, total = {}, ext and ext.total or 0
		for _, name in ipairs(bound and bound.groups or {}) do
			names[#names + 1] = name
			total = total + ((counts.group_counts and counts.group_counts[name]) or 0)
		end
		for _, name in ipairs(ext and ext.groups or {}) do names[#names + 1] = name end
		local sections = (bound_sections or {})[pack.id] or {}
		if #names > 0 or #sections > 0 then
			menus[#menus + 1] = { id = pack.id, name = pack.name, groups = names, sections = sections, total = total }
		end
	end
	return menus
end


--- Language packs declared by the shared hotstring index, read once per session.
--- An unreadable index raises: the language submenus cannot be drawn without it
--- and an empty list would hide every language without a word.
--- @return table Array of { id, locale, categories }.
local function load_language_packs()
	if _language_packs_cache then return _language_packs_cache end
	local path = Paths.shared("modules/hotstrings/_index.toml")
	local fh = io.open(path, "r")
	if not fh then error("[builder] hotstring index is unreadable: " .. tostring(path)) end
	local raw = fh:read("*a")
	fh:close()
	_language_packs_cache = Languages.packs(TomlCodec.decode(raw))
	return _language_packs_cache
end

--- Flag and native name of a locale code, from the generated locale table.
--- @param code string
--- @return string
local function language_label(code)
	return Languages.label(code, LocaleTable)
end

--- Loads the whole top_level array from menu_manifest.json, separators
--- included, filtered for the "hs" platform.
---
--- The WHOLE array, not a tail cut at an anchor id. The feature rows used to be
--- a fixed sequence of calls in generate() and only the rows from
--- "global_actions" onward were read here, so a manifest that reordered the
--- feature rows, put a separator among them or renamed the anchor left this
--- tray in its old order — and a missing anchor emptied the tail, taking
--- Reload, Quit and Debug with it.
---
--- Each entry keeps the manifest's `greyed_when_paused` mark: the feature rows a
--- pause greys, declared once for the three trays.
--- Returns an empty array on failure and logs ERROR (fail-loud — no stale copy).
--- @return table Array of {id, greyed_when_paused} entries in display order.
local function load_top_level()
	if _top_level_cache then return _top_level_cache end
	local data = load_manifest()
	if not data or type(data.top_level) ~= "table" then
		Logger.error(LOG, "Failed to load top_level from manifest — the tray has no row.")
		return {}
	end
	local result = {}
	for _, entry in ipairs(data.top_level) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" then goto continue end
		if type(entry.platforms) == "table" then
			local for_hs = false
			for _, p in ipairs(entry.platforms) do
				if p == "hs" then for_hs = true; break end
			end
			if not for_hs then goto continue end
		end
		table.insert(result, { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true })
		::continue::
	end
	Logger.debug(LOG, "Top level loaded from manifest (%d item(s)).", #result)
	_top_level_cache = result
	return _top_level_cache
end


--- Invalidates locale-dependent caches — call after hot-reload or locale change.
--- Does NOT clear the manifest cache (_manifest_cache, _ergopti_groups_cache):
--- these are derived from a static file and are safe to keep across toggles;
--- only a full hs.reload() should reset them.
function M.invalidate_cache()
	-- Intentionally empty: manifest-derived caches are session-stable.
	-- HotCounter's file-content cache is similarly preserved (see hotstring_counter.lua).
end





-- ==================================
-- ==================================
-- ======= 1/ Menu Generation =======
-- ==================================
-- ==================================

--- Builds the Hotstrings top-level row: its submenu is the manifest's
--- `hotstrings_menu`, filled from the hotstrings module and the live counts.
--- @param ctx table The global UI context.
--- @param menu_mods table The loaded menu submodules.
--- @return table The row to place, or no row when there is nothing to show.
local function build_hotstrings_rows(ctx, menu_mods)
	if type(menu_mods.hotstrings) ~= "table" then
		Logger.warn(LOG, "Hotstrings module missing — submenu ignored.")
		return {}
	end
	Logger.debug(LOG, "Building hotstrings submenu…")

	-- The categories an installed extension binds whole: counted apart from the
	-- common ones and listed under that extension's submenu.
	local BOUND_BY_EXTENSION, BOUND_GROUPS = M.bound_groups(ctx)

	local counts = HotCounter.count_all(ctx, BOUND_GROUPS)
	local fmt_grand = HotCounter.fmt_grand

	local common_total      = counts.common
	local personal_total    = counts.personal
	-- The extensions header counts the packs and the categories they bind.
	local ext_total         = counts.ext + counts.ergopti
	local personal_has_count= counts.has_personal
	local ext_has_count     = counts.has_ext or counts.has_ergopti
	local grand_total       = counts.grand
	local grand_has_count   = counts.has_grand

	-- The master is the typing engine's switch, hotstrings.enabled: the value
	-- the boot synchronization starts or stops the engine from, published only
	-- once a start or a stop committed. The tick used to be « every category
	-- on », a different question: the wizard's Yes turns the master on with one
	-- recommended section, so a fresh configuration showed Hotstrings unticked
	-- while ★ expanded, and a click then switched every category on.
	local master_on = ctx.state.keymap == true

	--- Switches the typing engine, keeping every category's choice under it
	--- as Windows' category gate does; « all sections » switches the choices.
	--- @return boolean committed
	local function toggle_hotstrings_master()
		local enable = not master_on
		local switched
		if enable then
			switched = KeymapLifecycle.ensure_started(ctx, "enable hotstrings")
		else
			switched = KeymapLifecycle.ensure_stopped(ctx, "disable hotstrings")
		end
		if not switched then return false end
		if ctx.save_prefs() ~= true then return false end
		ctx.notify_feature(i18n.get("notify.hotstrings"), enable)
		ctx.updateMenu()
		return true
	end

	local hotstrings_title = "⚡ Hotstrings (" .. fmt_grand(grand_total) .. ")"

	-- Every row below is collected for the manifest slot that declares it, and
	-- the SHARED renderer places them. This menu was assembled here by hand
	-- from the day it was written — the manifest declared two bulk commands, a
	-- params group, four section headers and five list rows, and this file read
	-- none of it. The repository carries a drift gate
	-- (tests/meta/test_menu_hotstrings_layout_drift_gate.lua) whose entire job
	-- was to notice when the two descriptions disagreed, because nothing else
	-- could.
	local hotstrings_menu = {}

	local function collect_groups(only_filter, counts_arg)
		local result = {}
		if type(menu_mods.hotstrings.build_groups) ~= "function" then return result end
		local built = Logger.build(LOG, "hotstrings.build_groups",
			function(c) return menu_mods.hotstrings.build_groups(c, only_filter, counts_arg) end, ctx)
		if type(built) == "table" then
			if built[1] ~= nil then
				for _, it in ipairs(built) do table.insert(result, it) end
			elseif next(built) ~= nil then
				-- An empty list (no group matched the filter) is no row at all;
				-- inserting it handed the renderer a row with no label.
				table.insert(result, built)
			end
		end
		return result
	end

	-- Language-pack groups render under their language's own submenu, and
	-- extension packs under their extension's, never among the neutral categories.
	local LANGUAGE_PACKS = load_language_packs()
	local LANGUAGE_GROUPS = Languages.groups(LANGUAGE_PACKS)

	local common_filter = {}
	if ctx and ctx.hotfiles and type(ctx.hotfiles) == "table" then
		for _, f in ipairs(ctx.hotfiles) do
			local name = ctx.get_group_name and ctx.get_group_name(f) or f
			if name ~= "custom" and name ~= "personal" and name:sub(1, 13) ~= "personal_ext_"
			and not PersonalFiles.components(name)
			and not LANGUAGE_GROUPS[name] and not Extensions.parse_category_key(name)
			and not BOUND_GROUPS[name] then
				common_filter[name] = true
			end
		end
	end

	local std_groups = collect_groups(common_filter, counts)

	-- One row per language: its native name, then one « all sections »
	-- checkbox for every category of that language, then the language's
	-- category submenus built exactly like the neutral ones.
	local language_rows = {}
	for _, pack in ipairs(LANGUAGE_PACKS) do
		local only = {}
		local names = {}
		for _, stem in ipairs(pack.categories) do
			local name = Languages.group_id(pack.id, stem)
			only[name] = true
			names[#names + 1] = name
		end
		local bulk = type(menu_mods.hotstrings.build_language_bulk_actions) == "function"
			and menu_mods.hotstrings.build_language_bulk_actions(ctx, names) or {}
		local categories = collect_groups(only, counts)
		local items = ManifestMenu.template_rows("hotstring_language_frame", {}, {}, {
			hotstring_language_switch = function() return bulk end,
			hotstring_language_categories = function() return categories end,
		})
		local total = 0
		for _, name in ipairs(names) do
			total = total + ((counts and counts.group_counts and counts.group_counts[name]) or 0)
		end
		if items then
			local parents = ManifestMenu.template_rows("hotstring_language_parent_lua", {}, {
				hotstring_language_name = function() return language_label(pack.locale) end,
				hotstring_language_count = function() return fmt_grand(total) end,
			}, { hotstring_language_children = items })
			for _, row in ipairs(parents or {}) do language_rows[#language_rows + 1] = row end
		end
	end
	local custom_item = type(menu_mods.hotstrings.build_custom) == "function"
		and Logger.build(LOG, "hotstrings.build_custom", function(c) return menu_mods.hotstrings.build_custom(c, counts) end, ctx)

	-- 4. The manifest's `hotstring_extensions` row (counts already included in
	-- grand_total via HotCounter). Named here because the id is what the
	-- action↔handler bijection gate matches on, and this section was built
	-- anonymously — so the manifest could restrict the row to Windows on the
	-- grounds that "neither Lua driver ships an extensions directory" while
	-- hotstring_counter.lua was walking exactly that directory and this block
	-- was rendering the result. A row nothing names is a row nothing can check.
	-- Each installed extension is one « Hotstrings <extension> » submenu holding
	-- the categories it binds (Ergopti's SFB reduction and rolls) and its loaded
	-- packs, built like a language: one « all sections » checkbox for the whole
	-- extension, then each category's own rows with its switch and sections.
	local manifest_row = "hotstring_extensions"
	local extension_rows = {}
	local BOUND_SECTIONS = type(menu_mods.hotstrings.bound_sections) == "function"
		and menu_mods.hotstrings.bound_sections(ctx) or {}
	for _, menu in ipairs(M.extension_menus(ctx, counts, BOUND_BY_EXTENSION, BOUND_SECTIONS)) do
		local pack_rows = {}
		local bulk = type(menu_mods.hotstrings.build_extension_bulk_actions) == "function"
			and menu_mods.hotstrings.build_extension_bulk_actions(ctx, menu.groups, menu.sections) or nil
		-- One group at a time: a single pass over the loaded groups would draw them
		-- in load order instead of the submenu's own.
		for _, name in ipairs(menu.groups) do
			for _, row in ipairs(collect_groups({ [name] = true }, counts)) do pack_rows[#pack_rows + 1] = row end
		end
		-- The sections it binds inside a bundled category (the repeat corrections).
		local section_rows, section_total = {}, 0
		if #menu.sections > 0 and type(menu_mods.hotstrings.build_bound_section_rows) == "function" then
			section_rows, section_total = menu_mods.hotstrings.build_bound_section_rows(ctx, menu.sections)
		end
		local items = type(bulk) == "table" and ManifestMenu.template_rows("hotstring_extension_content_frame", {}, {}, {
			["extension_bulk_head"] = function() return bulk end,
			["extension_pack_rows"] = function() return pack_rows end,
			["extension_bound_boundary"] = function()
				if #section_rows > 0 and #menu.groups > 0 then
					return ManifestMenu.template_rows("hotstrings_parameter_boundary", {}, {}, {})
				end
				return {}
			end,
			["extension_bound_tail"] = function() return section_rows end,
		}) or nil
		if items then extension_rows[#extension_rows + 1] = {
			label = string.format(i18n.get("menu.extensions.hotstrings_of"), menu.name)
				.. " (" .. fmt_grand(menu.total + section_total) .. ")",
			items = items,
		} end
	end
	Logger.debug(LOG, "Built manifest row '%s' (%d extension(s)).", manifest_row, #extension_rows)


	-- ===== The manifest's own rows, placed by the shared renderer =====

	-- Section headers carry a count here and a plain key in the manifest, so
	-- the label is enriched through the renderer's hook rather than by
	-- building the header — and the manifest still owns whether the header
	-- exists and where it sits.
	local section_labels = {
		["menu.hotstrings.header_common"] = i18n.decorate_section(
			string.format(i18n.get("menu.hotstrings.header_common_count"), fmt_grand(common_total))),
		["menu.hotstrings.personal_header"] = i18n.decorate_section(
			string.format(i18n.get("menu.hotstrings.header_personal_count"), fmt_grand(personal_total))),
		["menu.extensions.header"] = ext_has_count
			and i18n.decorate_section(i18n.get("menu.extensions.header") .. " (" .. fmt_grand(ext_total) .. ")")
			or  i18n.decorate_section(i18n.get("menu.extensions.header")),
	}

	local hs_ctx = {}
	for key, value in pairs(ctx) do hs_ctx[key] = value end
	hs_ctx.section_label = function(key) return section_labels[key] end
	-- The « all sections » checkbox is a `check` declaration, so the renderer
	-- builds the row and this driver supplies only its tick and behaviour.
	-- Taken from the hotstrings module rather than reimplemented: it owns the
	-- section walk, and a second copy of that walk is exactly the kind of
	-- duplicate this migration exists to remove.
	local all_sections = type(menu_mods.hotstrings.all_sections_switch) == "function"
		and menu_mods.hotstrings.all_sections_switch(ctx) or nil
	hs_ctx.commands = {
		-- The category switch, first row of the submenu. It used to be the
		-- parent row's `action`, which AppKit never sends for an item that
		-- opens a submenu, so the Hotstrings master could not be switched from
		-- the menu bar at all.
		["hotstrings_toggle"]      = function()
			if ctx.paused then
				Logger.warn(LOG, "Hotstrings switch refused: the script is paused.")
				return false
			end
			return toggle_hotstrings_master()
		end,
	}
	-- « Restore recommended » and « Clear » run the Hotstrings scope owner, which
	-- asks first and changes config.toml and the override file as one
	-- transaction; the ordinary save path never writes them.
	for command, mode in pairs({ scope_restore = "recommended", scope_clear = "clear" }) do
		hs_ctx.commands[command] = function()
			if ctx.paused or type(ctx.apply_preference_scope) ~= "function" then return false end
			return ctx.apply_preference_scope("hotstrings", mode) == true
		end
	end
	-- Registered only when the module provides it: an unregistered command is
	-- reported by the renderer and its row is not drawn, where an empty stand-in
	-- drew a row that did nothing when clicked.
	if all_sections then
		hs_ctx.commands["hotstrings_all_sections"] = function()
			if type(all_sections.action) ~= "function" then
				Logger.warn(LOG, "All-sections switch refused: the script is paused.")
				return false
			end
			return all_sections.action()
		end
	end
	hs_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do hs_ctx.state_getters[key] = value end
	hs_ctx.state_getters["hotstrings_enabled"] = function() return master_on end
	hs_ctx.state_getters["hotstrings_all_sections_enabled"] = function()
		return all_sections ~= nil and all_sections.checked == true
	end

	local providers = {
		["hotstring_categories_standard"] = function() return std_groups end,
		["hotstring_languages"]           = function() return language_rows end,
		-- Provider data straight from menu_hotstrings_custom since 2026-08-07:
		-- that builder emits `label`/`action`/`items` itself, so there is no
		-- translation step and the renderer materialises the tree.
		["hotstring_personal"]            = function()
			return custom_item and { custom_item } or {}
		end,
		["hotstring_extensions"]          = function() return extension_rows end,
		-- The dynamic-rule categories are Windows' and Linux's; this driver has
		-- no separate block for them, and an empty provider is what says so
		-- without the renderer warning about an unanswered row.
		["hotstring_categories_dynamic"]  = function() return {} end,
	}

	local group_builders = {
		["hotstrings_params"] = function(c)
			local built = type(menu_mods.hotstrings.build_management) == "function"
				and Logger.build(LOG, "hotstrings.build_management", menu_mods.hotstrings.build_management, c)
				or nil
			if not built then return nil end
			return { menu = built.menu, disabled = built.disabled }
		end,
	}

	do
		local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
		if ok_mm and type(ManifestMenu.build) == "function" then
			local rendered = ManifestMenu.build("hotstrings_menu", "Hotstrings",
				nil, group_builders, hs_ctx, providers)
			for _, row in ipairs(rendered or {}) do table.insert(hotstrings_menu, row) end
		else
			Logger.error(LOG, "Manifest renderer unavailable — the hotstrings submenu has no row.")
		end
	end

	-- Grand total already includes extensions (computed by HotCounter.count_all)
	-- From the shared key, not a literal. Windows and Linux both read
	-- `menu.hotstrings.title` for this same entry, and it is translated in all
	-- twenty-one locales — « ⚡ ホットストリング » in Japanese — so the hardcoded
	-- string was the one top-level menu this driver refused to translate.
	local hotstrings_label = i18n.get("menu.hotstrings.title")
	hotstrings_title = grand_has_count
		and (hotstrings_label .. " (" .. fmt_grand(grand_total) .. ")")
		or  hotstrings_label

	if #hotstrings_menu == 0 then
		Logger.warn(LOG, "Hotstrings submenu is empty — ignored.")
		return {}
	end
	-- The tick mirrors the switch; the switch itself is the submenu's first
	-- row, since a row that opens a submenu is never clicked.
	return { {
		label = hotstrings_title,
		submenu = hotstrings_menu,
		checked = master_on or nil,
	} }
end

--- Generates the complete items list for the Hammerspoon menubar.
---
--- Every top-level row, separators included, is placed in the order the
--- manifest's `top_level` declares for this platform: the loop below reads that
--- array and dispatches each id to its builder. The feature rows used to be a
--- fixed sequence of calls here, ahead of a tail read from the manifest, so the
--- declared order reached only half of the tray.
--- @param ctx table The global UI context.
--- @param menu_mods table The loaded menu submodules.
--- @param actions table Callbacks for global system actions.
--- @return table The assembled menu structure.
function M.generate(ctx, menu_mods, actions)
	--- Runs one component builder and returns what it built as a list of rows.
	--- @param label string Component name for the log.
	--- @param fn function Builder.
	--- @param arg any Builder argument.
	--- @return table Rows built, empty when the builder failed or built nothing.
	local function collect(label, fn, arg)
		local rows = {}
		local result = Logger.build(LOG, label, fn, arg)
		if result then
			if type(result) == "table" and result[1] ~= nil then
				-- Result is a list (build_groups)
				for _, it in ipairs(result) do rows[#rows + 1] = it end
			else
				rows[#rows + 1] = result
			end
			Logger.debug(LOG, string.format("Component '%s' added successfully.", label))
		else
			Logger.warn(LOG, string.format("Component '%s' missing or in error — ignored.", label))
		end
		return rows
	end

	--- Builds the row a menu module owns, when the module is loaded.
	--- @param key string Key of the module in menu_mods.
	--- @param arg any Builder argument, ctx by default.
	--- @return table Rows built.
	local function module_rows(key, arg)
		local mod = menu_mods[key]
		if type(mod) ~= "table" or type(mod.build) ~= "function" then
			Logger.warn(LOG, "Menu module '%s' missing — its row is not drawn.", key)
			return {}
		end
		return collect(key .. ".build", mod.build, arg or ctx)
	end

	-- One builder per top-level id. Each returns the rows it places, and the
	-- loop after this table decides WHERE: the manifest's order, not this
	-- table's. tools/test/test-menu-top-level-parity.cjs holds these keys to the
	-- ids the manifest declares for macOS, in both directions.
	local builders = {
		["keyboard_layout"] = function() return module_rows("keyboard_layout") end,
		["hotstrings"]      = function() return build_hotstrings_rows(ctx, menu_mods) end,
		["llm"]             = function()
			if type(ctx.llm_handler) ~= "table" or type(ctx.llm_handler.build_item) ~= "function" then
				Logger.warn(LOG, "LLM handler missing or incomplete — AI component ignored.")
				return {}
			end
			Logger.debug(LOG, "Building AI component…")
			local ok_b, llm_item = pcall(ctx.llm_handler.build_item)
			if not ok_b then
				Logger.error(LOG, string.format("Error building AI component: %s.", tostring(llm_item)))
				return {}
			end
			Logger.debug(LOG, "AI component added successfully.")
			return llm_item and { llm_item } or {}
		end,
		["agent"]           = function()
			-- The AI agent's settings share the AI menu's transaction owner, so
			-- its handler builds this row too.
			if type(ctx.llm_handler) ~= "table" or type(ctx.llm_handler.build_agent_item) ~= "function" then
				Logger.warn(LOG, "LLM handler missing or incomplete — AI agent component ignored.")
				return {}
			end
			local ok_b, agent_item = pcall(ctx.llm_handler.build_agent_item)
			if not ok_b then
				Logger.error(LOG, string.format("Error building the AI agent component: %s.", tostring(agent_item)))
				return {}
			end
			return agent_item and { agent_item } or {}
		end,
		["metrics"]         = function() return module_rows("keylogger") end,
		-- The shortcuts submodule surfaces the edit-shortcuts callback, so it gets
		-- the actions on top of the context.
		["shortcuts"]       = function()
			return module_rows("shortcuts", setmetatable({ actions = actions }, { __index = ctx }))
		end,
		["tap_holds"]       = function() return module_rows("tap_holds") end,
		["gestures"]        = function() return module_rows("gestures") end,
		["apps"]            = function() return module_rows("apps") end,
		["configuration"]   = function()
			local root, top, section, parent, fields = configuration_source(ManifestMenu, "hs")
			if root == nil then return {} end
			-- Every row is `type = "command"` in the manifest: labels, order and
			-- the separators are declared, and this file supplies only what each
			-- row does. Read once, so the pause gate below can tell the rows apart
			-- by the handler they carry. The global scope's restore and clear open
			-- the menu, like every settings menu's.
			local restore = actions.reset_defaults
			local clear = actions.clear_to_system
			local clean = actions.clean_unused_keys
			local cfg_ctx = {}
			for key, value in pairs(ctx or {}) do cfg_ctx[key] = value end
			cfg_ctx.commands = {
				["scope_restore"]       = restore,
				["scope_clear"]         = clear,
				["clean_unused_keys"]   = clean,
				["config_folder"]       = actions.open_paths,
				["setup_wizard"]        = actions.show_setup_wizard,
			}
			cfg_ctx.state_getters = {}
			for key, value in pairs(ctx.state_getters or {}) do cfg_ctx.state_getters[key] = value end
			-- « Ergopti uses Karabiner » and « Remove Ergopti from Karabiner »
			-- need the remap owner; without it the renderer skips both rows.
			if type(ctx.karabiner) == "table" then
				local switch_commands, switch_getters = require("ui.menu.remap_switch")
					.rows(ctx.karabiner, ctx.updateMenu)
				for id, fn in pairs(switch_commands) do cfg_ctx.commands[id] = fn end
				for id, fn in pairs(switch_getters) do cfg_ctx.state_getters[id] = fn end
			end
			-- Pause owns the bindings axis for the whole pause window: pause_all()
			-- snapshots what was running and resume_all() restores that snapshot.
			-- A row that rewrites the configuration in between is either discarded
			-- on resume or breaks the « pause = tout éteint » invariant, so those
			-- three are greyed AND stripped of their handler: a disabled row whose
			-- fn survives still fires the moment the greying is rendered wrong
			-- somewhere else. The rows that only open a window stay live.
			local pause_gated = {}
			-- pairs, not ipairs: an unregistered command is nil, and ipairs would
			-- stop there and leave the rows after it ungated.
			for _, fn in pairs({ restore = restore, clear = clear, clean = clean }) do
				-- An unregistered command draws no row, so it has nothing to gate.
				if type(fn) == "function" then pause_gated[fn] = true end
			end
			local rows = ManifestMenu.build("configuration_menu", "Configuration", nil, nil, cfg_ctx)
			if not configuration_dense(rows, true) then return {} end
			if ctx.paused then
				for _, row in ipairs(rows) do
					if row.fn ~= nil and pause_gated[row.fn] then
						row.disabled = true
						row.fn = nil
					end
				end
			end
			local current_root, current_top, current_section, current_parent = configuration_source(ManifestMenu, "hs")
			if not rawequal(root, current_root) or not rawequal(top, current_top)
				or not rawequal(section, current_section) or not rawequal(parent, current_parent)
				or not configuration_parent_unchanged(parent, fields) then return {} end
			local row = ManifestMenu.group_row("top_level", "configuration", rows, cfg_ctx.state_getters)
			return row and { row } or {}
		end,
		["language"]        = function()
			-- The locale rows reach the tray through the manifest's `language_menu`.
			-- They were the same twenty-one entries on every driver, from the same
			-- shared catalogue, and nothing described the menu holding them.
			if type(i18n.build_language_menu_items) ~= "function" then return {} end
			local ok_locales, locales = pcall(i18n.build_language_menu_items)
			if not ok_locales then return {} end
			local admitted = ManifestMenu.template_rows("language_menu", {}, {}, {
				["locales"] = function() return locales end,
			})
			if not admitted then return {} end
			local rendered = ManifestMenu.render_rows(admitted, "language_menu")
			local parent = ManifestMenu.group_row("top_level", "language", rendered, {})
			return parent and { parent } or {}
		end,
		["about"]           = function()
			if type(menu_mods.about) ~= "table" or type(menu_mods.about.build) ~= "function" then
				Logger.warn(LOG, "About module missing — its row is not drawn.")
				return {}
			end
			-- The actions carry startup and the uninstall transaction, whose row closes it.
			local ok_a, about_item = pcall(menu_mods.about.build, ctx, actions)
			if not ok_a then
				Logger.error(LOG, "Error building the About submenu: %s.", tostring(about_item))
				return {}
			end
			return about_item and { about_item } or {}
		end,
		["reload"]          = function()
			local row = ManifestMenu.command_row("top_level", "reload", { reload = actions.reload })
			if not row then return {} end
			return { row }
		end,
		["quit"]            = function()
			local row = ManifestMenu.command_row("top_level", "quit", { quit = actions.quit })
			if not row then return {} end
			return { row }
		end,
		["debug"]           = function()
			local root, top, section, parent, fields = debug_source(ManifestMenu, "hs")
			if root == nil then return {} end
			-- The manifest declares every row of this submenu and the shared
			-- renderer places them; this file supplies only what each one does.
			local active_level_name
			for level, severity in pairs(Logger.LEVELS) do
				if Logger.current_level == severity then active_level_name = level; break end
			end
			local healthcheck = require("ui.healthcheck")
			local dbg_ctx = {}
			for key, value in pairs(ctx or {}) do dbg_ctx[key] = value end
			dbg_ctx.commands = {
				["console"]        = actions.open_console,
				["log_level"]      = actions.set_log_level,
				["open_logs"]      = actions.open_logs,
				["open_today_log"] = actions.open_today_log,
				["open_error_log"] = actions.open_error_log,
				["healthcheck"]    = function() healthcheck.show_window({ state = ctx.state }) end,
				["report_bug"]      = function() require("ui.healthcheck.report").report_bug({ state = ctx.state }) end,
				["suggest_feature"] = function() require("ui.healthcheck.report").suggest_feature() end,
				["show_error_dialog"] = actions.toggle_error_dialog,
			}
			dbg_ctx.state_getters = {}
			for key, value in pairs(ctx.state_getters or {}) do dbg_ctx.state_getters[key] = value end
			dbg_ctx.state_getters["script.log_level"] = function() return active_level_name end
			dbg_ctx.state_getters["error_dialog_enabled"] = function()
				return require("ui.error_dialog").is_enabled()
			end
			local debug_items = ManifestMenu.build("debug_menu", "Debug", nil, nil, dbg_ctx, {})
			if not debug_dense(debug_items, true) then return {} end
			local current_root, current_top, current_section, current_parent = debug_source(ManifestMenu, "hs")
			if not rawequal(root, current_root) or not rawequal(top, current_top)
				or not rawequal(section, current_section) or not rawequal(parent, current_parent)
				or not debug_parent_unchanged(parent, fields) then return {} end
			local row = ManifestMenu.group_row("top_level", "debug", debug_items, dbg_ctx.state_getters)
			return row and { row } or {}
		end,
	}

	local items = {}
	for _, entry in ipairs(load_top_level()) do
		local id = entry.id
		if id == "---" then
			table.insert(items, { separator = true })
		elseif type(builders[id]) ~= "function" then
			-- A declared row this driver has no builder for is a row the user was
			-- promised and will not see.
			Logger.error(LOG, "No builder for top-level row '%s' — the entry is missing.", tostring(id))
		else
			for _, row in ipairs(builders[id]() or {}) do
				-- « Pause = tout éteint »: every row the manifest marks as a feature
				-- is greyed and stripped of its handler in one place. Each builder
				-- used to decide this for itself, so Shortcuts and Gestures greyed
				-- while Hotstrings, AI, Metrics and Tap-Holds stayed live (Metrics
				-- could even be toggled mid-pause). The unmarked rows (configuration,
				-- language, about, reload, quit, debug) and the title row that
				-- resumes the script stay live: they are how the user inspects,
				-- resumes or leaves a paused script.
				if ctx.paused == true and entry.greyed_when_paused and type(row) == "table" and row.separator ~= true then
					row.disabled = true
					row.action = nil
					row.fn = nil
				end
				table.insert(items, row)
			end
		end
	end

	-- Everything above collected row DATA; this is where the shared renderer turns
	-- it into the table hs.menubar consumes, dropping any separator that would not
	-- sit between two rows.
	local rendered = ManifestMenu.render_rows(items, "top_level")

	-- Collect the download item now so it participates in canvas width calculation below.
	-- pcall-isolated like every component builder above — an exception here must
	-- degrade to "no download item", not take down the whole menu-build pipeline.
	--
	-- The native AI owner returns its finished hs.menubar row. Canonical root
	-- composition owns its transient placement without converting it to DATA.
	local _dl_item = nil
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_download_item) == "function" then
		local ok_dl, dl_result = pcall(ctx.llm_handler.build_download_item)
		if ok_dl then
			_dl_item = dl_result
		else
			Logger.error(LOG, string.format("Error building LLM download item: %s.", tostring(dl_result)))
		end
	end
	local compose_download = ManifestMenu.native_composition("macos_download_root")
	if type(compose_download) ~= "function"
		or compose_download({ download = _dl_item and { _dl_item } or {}, body = rendered }) ~= true then
		Logger.error(LOG, "Declared download root composition refused.")
	end

	-- This is the single highest-blast-radius call in the whole build pipeline:
	-- it is the LAST step and mutates the menu in place, so an unguarded exception
	-- here would unwind past every component built above and turn one broken
	-- badge render into a total menu-rebuild failure.
	--
	-- Its native owner captures the badge image after sizing the completed root.
	-- Canonical completed-row composition then owns badge/boundary/body order.
	local ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()
		if ctx and ctx.script_control then
			if type(ctx.script_control.toggle_script_control) == "function" then pcall(ctx.script_control.toggle_script_control) end
			if type(ctx.script_control.toggle) == "function" then pcall(ctx.script_control.toggle) end
		end
	end)
	if not ok_badge then
		Logger.error(LOG, string.format("Error building canvas badge: %s.", tostring(badge_err)))
	end

	return rendered
end

return M
