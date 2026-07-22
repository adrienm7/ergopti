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
local hs         = hs
local Logger     = require("lib.logger")
local text_utils = require("lib.text_utils")
local Paths      = require("lib.paths")
local LOG        = "builder"
local i18n       = require("lib.i18n")
local HotCounter  = require("ui.menu.hotstring_counter")
local CanvasBadge = require("ui.menu.canvas_badge")
local Labels      = require("menu.labels")


-- Single parsed representation of menu_manifest.json for the session.
-- Both load_ergopti_groups() and load_debug_menu() share this cache so the
-- file is read and parsed only once, no matter how many menu rebuilds occur.
-- Never invalidated on toggle (the manifest is a static asset that never
-- changes at runtime); only a full hs.reload() resets this module.
local _manifest_cache          = nil
local _ergopti_groups_cache    = nil
local _debug_menu_cache        = nil
local _top_level_tail_cache    = nil
local _global_actions_cache    = nil

--- Loads and caches menu_manifest.json once per session.
--- @return table|nil Parsed manifest data, or nil on failure.
local function load_manifest()
	if _manifest_cache then return _manifest_cache end
	local manifest_path = Paths.shared("modules/menu/menu_manifest.json") or ""
	local ok_r, fh = pcall(io.open, manifest_path, "r")
	if not ok_r or not fh then
		Logger.error(LOG, "Cannot open menu_manifest.json at '%s'.", manifest_path)
		return nil
	end
	local content = fh:read("*a")
	fh:close()
	local ok_j, data = pcall(hs.json.decode, content)
	if not ok_j or type(data) ~= "table" then
		Logger.error(LOG, "Failed to parse menu_manifest.json.")
		return nil
	end
	_manifest_cache = data
	Logger.debug(LOG, "menu_manifest.json loaded and cached.")
	return data
end

--- Loads hotstring group classification from the shared menu_manifest.json.
--- Returns an empty set on failure and logs ERROR (fail-loud — no stale copy).
--- @return table<string,boolean> Set of group IDs specific to the Ergopti layout.
local function load_ergopti_groups()
	if _ergopti_groups_cache then return _ergopti_groups_cache end
	local data = load_manifest()
	if not data or type(data.hotstring_groups) ~= "table" then
		Logger.error(LOG, "Cannot load Ergopti groups from manifest — groups will be empty.")
		return {}
	end
	local groups = {}
	for _, id in ipairs(data.hotstring_groups.ergopti or {}) do
		groups[id] = true
		-- Support both underscored (manifest) and flattened (file stems) IDs
		local flattened = id:gsub("_", "")
		if flattened ~= id then groups[flattened] = true end
	end
	Logger.debug(LOG, "Ergopti groups loaded from manifest (%d group(s)).", #(data.hotstring_groups.ergopti or {}))
	_ergopti_groups_cache = groups
	return groups
end


--- Loads the debug_menu ordered array from the shared menu_manifest.json.
--- Filters out entries whose platforms list does not include "hs".
--- Returns an empty array on failure and logs ERROR (fail-loud — no stale copy).
--- @return table Array of {id} entries in display order.
local function load_debug_menu()
	if _debug_menu_cache then return _debug_menu_cache end
	local data = load_manifest()
	if not data or type(data.debug_menu) ~= "table" then
		Logger.error(LOG, "Failed to load debug_menu from manifest — debug submenu will be empty.")
		return {}
	end

	local result = {}
	for _, entry in ipairs(data.debug_menu) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" then goto continue end
		-- Filter by platform: skip entries that explicitly exclude "hs"
		if type(entry.platforms) == "table" then
			local for_hs = false
			for _, p in ipairs(entry.platforms) do
				if p == "hs" then for_hs = true; break end
			end
			if not for_hs then goto continue end
		end
		table.insert(result, { id = entry.id })
		::continue::
	end

	Logger.debug(LOG, "Debug menu order loaded from manifest (%d item(s)).", #result)
	_debug_menu_cache = result
	return _debug_menu_cache
end


--- Loads the top_level tail (including the separator immediately before
--- "global_actions", when declared) from menu_manifest.json,
--- filtered for the "hs" platform.
--- Returns an empty array on failure and logs ERROR (fail-loud — no stale copy).
--- @return table Array of {id} entries in display order.
local function load_top_level_tail()
	if _top_level_tail_cache then return _top_level_tail_cache end
	local data = load_manifest()
	if not data or type(data.top_level) ~= "table" then
		Logger.error(LOG, "Failed to load top_level from manifest — tail will be empty.")
		return {}
	end
	local tail_start = nil
	for i, entry in ipairs(data.top_level) do
		if type(entry) == "table" and entry.id == "global_actions" then
			tail_start = i
			break
		end
	end
	if not tail_start then
		Logger.error(LOG, "top_level has no 'global_actions' entry — tail will be empty.")
		return {}
	end
	-- The shared manifest owns the visual boundary between feature menus and
	-- system-wide actions. Preserve a separator directly before global_actions,
	-- matching the Windows manifest loader and Linux menu builder.
	local previous = tail_start > 1 and data.top_level[tail_start - 1] or nil
	if type(previous) == "table" and previous.id == "---" then
		tail_start = tail_start - 1
	end
	local result = {}
	for i = tail_start, #data.top_level do
		local entry = data.top_level[i]
		if type(entry) ~= "table" or type(entry.id) ~= "string" then goto continue end
		if type(entry.platforms) == "table" then
			local for_hs = false
			for _, p in ipairs(entry.platforms) do
				if p == "hs" then for_hs = true; break end
			end
			if not for_hs then goto continue end
		end
		table.insert(result, { id = entry.id })
		::continue::
	end
	Logger.debug(LOG, "Top-level tail loaded from manifest (%d item(s)).", #result)
	_top_level_tail_cache = result
	return _top_level_tail_cache
end


--- Loads the global_actions array from menu_manifest.json, filtered for "hs".
--- Returns an empty array on failure and logs ERROR (fail-loud — no stale copy).
--- @return table Array of {id} entries.
local function load_global_actions()
	if _global_actions_cache then return _global_actions_cache end
	local data = load_manifest()
	if not data or type(data.global_actions) ~= "table" then
		Logger.error(LOG, "Failed to load global_actions from manifest — submenu will be empty.")
		return {}
	end
	local result = {}
	for _, entry in ipairs(data.global_actions) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" then goto continue end
		if type(entry.platforms) == "table" then
			local for_hs = false
			for _, p in ipairs(entry.platforms) do
				if p == "hs" then for_hs = true; break end
			end
			if not for_hs then goto continue end
		end
		table.insert(result, { id = entry.id })
		::continue::
	end
	Logger.debug(LOG, "Global actions loaded from manifest (%d item(s)).", #result)
	_global_actions_cache = result
	return _global_actions_cache
end


--- Invalidates locale-dependent caches — call after hot-reload or locale change.
--- Does NOT clear the manifest cache (_manifest_cache, _ergopti_groups_cache,
--- _debug_menu_cache): these are derived from a static file and are safe to
--- keep across toggles; only a full hs.reload() should reset them.
function M.invalidate_cache()
	-- Intentionally empty: manifest-derived caches are session-stable.
	-- HotCounter's file-content cache is similarly preserved (see hotstring_counter.lua).
end





-- ==================================
-- ==================================
-- ======= 1/ Menu Generation =======
-- ==================================
-- ==================================

--- Generates the complete items list for the Hammerspoon menubar.
--- @param ctx table The global UI context.
--- @param menu_mods table The loaded menu submodules.
--- @param actions table Callbacks for global system actions.
--- @return table The assembled menu structure.
function M.generate(ctx, menu_mods, actions)
	local items = {}

	-- Helper function to insert only valid components and log errors
	local function push_into(target, label, fn, arg)
		local result = Logger.build(LOG, label, fn, arg)
		if result then
			if type(result) == "table" and result[1] ~= nil then
				-- Result is a list (build_groups)
				for _, it in ipairs(result) do table.insert(target, it) end
			else
				table.insert(target, result)
			end
			Logger.debug(LOG, string.format("Component '%s' added successfully.", label))
		else
			Logger.warn(LOG, string.format("Component '%s' missing or in error — ignored.", label))
		end
	end

	local function push(label, fn, arg)
		push_into(items, label, fn, arg)
	end

	-- Keyboard layout zone — placed just before hotstrings so it sits at the
	-- top of the user-facing submenus
	if type(menu_mods.keyboard_layout) == "table" and type(menu_mods.keyboard_layout.build) == "function" then
		push("keyboard_layout.build", menu_mods.keyboard_layout.build, ctx)
	end

	-- Hotstrings zone avec activation globale
	if type(menu_mods.hotstrings) == "table" then
		Logger.debug(LOG, "Building hotstrings submenu…")

		-- Groups that are specific to the Ergopti keyboard layout — sourced from menu_manifest.json
		local ERGOPTI_GROUPS = load_ergopti_groups()

		local counts = HotCounter.count_all(ctx, ERGOPTI_GROUPS)
		local fmt_grand = HotCounter.fmt_grand

		local common_total      = counts.common
		local ergopti_total     = counts.ergopti
		local personal_total    = counts.personal
		local ext_total         = counts.ext
		local common_has_count  = counts.has_common
		local ergopti_has_count = counts.has_ergopti
		local personal_has_count= counts.has_personal
		local ext_has_count     = counts.has_ext
		local grand_total       = counts.grand
		local grand_has_count   = counts.has_grand

		-- Détection de l’état global : tous les hotstrings activés ?
		local all_enabled = true
		local any_enabled = false
		if ctx and ctx.hotfiles and type(ctx.hotfiles) == "table" then
			for _, f in ipairs(ctx.hotfiles) do
				local name = ctx.get_group_name and ctx.get_group_name(f) or f
				if name ~= "custom" and name ~= "personal" then
					local enabled = false
					if ctx.keymap and type(ctx.keymap.is_group_enabled) == "function" then
						enabled = ctx.keymap.is_group_enabled(name)
					elseif ctx.state and ctx.state.hotstrings then
						enabled = ctx.state.hotstrings[name] ~= false
					end
					if enabled then any_enabled = true else all_enabled = false end
				end
			end
		end

		local function toggle_all_hotstrings()
			if not ctx or not ctx.hotfiles or type(ctx.hotfiles) ~= "table" then return end
			local enable = not all_enabled
			for _, f in ipairs(ctx.hotfiles) do
				local name = ctx.get_group_name and ctx.get_group_name(f) or f
				if name ~= "custom" and name ~= "personal" then
					if ctx.keymap and type(ctx.keymap.enable_group) == "function" and type(ctx.keymap.disable_group) == "function" then
						if enable then
							-- Also enable every individual section so sub-menus appear checked
							if type(ctx.keymap.get_sections) == "function"
							and type(ctx.keymap.enable_section) == "function" then
								local secs = ctx.keymap.get_sections(name)
								if type(secs) == "table" then
									for _, sec in ipairs(secs) do
										if type(sec) == "table" and sec.name and sec.name ~= "-" then
											pcall(ctx.keymap.enable_section, name, sec.name)
										end
									end
								end
							end
							pcall(ctx.keymap.enable_group, name)
						else
							pcall(ctx.keymap.disable_group, name)
						end
					end
					if ctx.state and ctx.state.hotstrings then ctx.state.hotstrings[name] = enable end
				end
			end
			ctx.save_prefs()
			ctx.notify_feature(i18n.get("notify.hotstrings"), enable)
			ctx.updateMenu()
		end

		local hotstrings_title = "⚡ Hotstrings (" .. fmt_grand(grand_total) .. ")"

		-- Build the three groups in order: paramètres, communs, personnels
		local hotstrings_menu = {}

		-- 1. Paramètres at top, followed by a separator
		local mgmt_item = type(menu_mods.hotstrings.build_management) == "function"
			and Logger.build(LOG, "hotstrings.build_management", menu_mods.hotstrings.build_management, ctx)
		if mgmt_item then
			table.insert(hotstrings_menu, mgmt_item)
		end

		-- Whole-tree bulk actions, siblings of the Paramètres sub-menu (directly
		-- under it, with the separator AFTER them), so they sit at the top of the
		-- menu rather than buried inside it.
		if type(menu_mods.hotstrings.build_bulk_actions) == "function" then
			local bulk = menu_mods.hotstrings.build_bulk_actions(ctx)
			if type(bulk) == "table" and #bulk > 0 then
				for _, it in ipairs(bulk) do table.insert(hotstrings_menu, it) end
			end
		end
		table.insert(hotstrings_menu, { title = "-" })

		-- 2a. Common hotstring groups (non-Ergopti) with a disabled header
		local function collect_groups(only_filter, counts_arg)
			local result = {}
			if type(menu_mods.hotstrings.build_groups) ~= "function" then return result end
			local built = Logger.build(LOG, "hotstrings.build_groups",
				function(c) return menu_mods.hotstrings.build_groups(c, only_filter, counts_arg) end, ctx)
			if type(built) == "table" then
				if built[1] ~= nil then
					for _, it in ipairs(built) do table.insert(result, it) end
				else
					table.insert(result, built)
				end
			end
			return result
		end

		local non_ergopti_filter = {}
		if ctx and ctx.hotfiles and type(ctx.hotfiles) == "table" then
			for _, f in ipairs(ctx.hotfiles) do
				local name = ctx.get_group_name and ctx.get_group_name(f) or f
				local flattened_name = name:gsub("_", "")
				if name ~= "custom" and name ~= "personal" and name:sub(1, 13) ~= "personal_ext_"
				and not (ERGOPTI_GROUPS[name] or ERGOPTI_GROUPS[flattened_name]) then
					non_ergopti_filter[name] = true
				end
			end
		end

		local std_groups = collect_groups(non_ergopti_filter, counts)
		if #std_groups > 0 then
			local common_header = i18n.decorate_section(string.format(i18n.get("menu.hotstrings.header_common_count"), fmt_grand(common_total)))
			table.insert(hotstrings_menu, { title = common_header, disabled = true })
			for _, it in ipairs(std_groups) do table.insert(hotstrings_menu, it) end
		end

		-- 2b. Ergopti-layout-specific groups — separated from the standard block
		local ergopti_groups_built = collect_groups(ERGOPTI_GROUPS, counts)
		if #ergopti_groups_built > 0 then
			if #std_groups > 0 then table.insert(hotstrings_menu, { title = "-" }) end
			local ergopti_header = i18n.decorate_section(string.format(i18n.get("menu.hotstrings.header_ergopti_count"), fmt_grand(ergopti_total)))
			table.insert(hotstrings_menu, { title = ergopti_header, disabled = true })
			for _, it in ipairs(ergopti_groups_built) do table.insert(hotstrings_menu, it) end
		end

		-- 3. Personal/custom hotstrings — "Mes hotstrings" (section header) vs "Hotstrings personnels" (sub-item).
		local custom_item = type(menu_mods.hotstrings.build_custom) == "function"
			and Logger.build(LOG, "hotstrings.build_custom", function(c) return menu_mods.hotstrings.build_custom(c, counts) end, ctx)
		if custom_item then
			table.insert(hotstrings_menu, { title = "-" })
			local personal_header = i18n.decorate_section(string.format(i18n.get("menu.hotstrings.header_personal_count"), fmt_grand(personal_total)))
			table.insert(hotstrings_menu, { title = personal_header, disabled = true })
			table.insert(hotstrings_menu, custom_item)
		end

		-- 4. Extensions hotstrings section (counts already included in grand_total via HotCounter)
		if #counts.ext_details > 0 then
			table.insert(hotstrings_menu, { title = "-" })
			local ext_base   = i18n.get("menu.extensions.header")
			local ext_header = ext_has_count
				and i18n.decorate_section(ext_base .. " (" .. fmt_grand(ext_total) .. ")")
				or  i18n.decorate_section(ext_base)
			table.insert(hotstrings_menu, { title = ext_header, disabled = true })

			for _, ext in ipairs(counts.ext_details) do
				local toml_submenus = {}
				for _, f in ipairs(ext.files) do
					local sec_menu = {
						{
							title = i18n.get("menu.hotstrings.open_file"),
							fn    = (function(path)
								return function()
									hs.timer.doAfter(0, function()
										pcall(hs.execute, "open " .. text_utils.shell_quote(path))
									end)
								end
							end)(f.path),
						},
					}
					if #f.sections > 0 then table.insert(sec_menu, { title = "-" }) end
					for _, sec in ipairs(f.sections) do
						table.insert(sec_menu, {
							title    = sec.name .. " (" .. fmt_grand(sec.count) .. ")",
							disabled = true,
						})
					end
					local toml_label = f.stem .. (f.total > 0 and (" (" .. fmt_grand(f.total) .. ")") or "")
					table.insert(toml_submenus, { title = toml_label, menu = sec_menu })
				end
				local ext_label = ext.name .. (ext.total > 0 and (" (" .. fmt_grand(ext.total) .. ")") or "")
				table.insert(hotstrings_menu, { title = ext_label, menu = toml_submenus })
			end
		end

		-- Grand total already includes extensions (computed by HotCounter.count_all)
		hotstrings_title = grand_has_count
			and ("⚡ Hotstrings (" .. fmt_grand(grand_total) .. ")")
			or  "⚡ Hotstrings"

		if #hotstrings_menu > 0 then
			table.insert(items, {
				title = hotstrings_title,
				menu = hotstrings_menu,
				checked = all_enabled or nil,
				fn = not ctx.paused and toggle_all_hotstrings or nil
			})
		else
			Logger.warn(LOG, "Hotstrings submenu is empty — ignored.")
		end
	else
		Logger.warn(LOG, "Hotstrings module missing — submenu ignored.")
	end

	-- AI zone
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_item) == "function" then
		Logger.debug(LOG, "Building AI component…")
		local ok_b, llm_item = pcall(ctx.llm_handler.build_item)
		if ok_b and llm_item then
			table.insert(items, llm_item)
			Logger.debug(LOG, "AI component added successfully.")
		elseif not ok_b then
			Logger.error(LOG, string.format("Error building AI component: %s.", tostring(llm_item)))
		end
	else
		Logger.warn(LOG, "LLM handler missing or incomplete — AI component ignored.")
	end

	-- Metrics zone
	if type(menu_mods.keylogger) == "table" then
		push("keylogger.build", menu_mods.keylogger.build, ctx)
	else
		Logger.warn(LOG, "Keylogger module missing.")
	end

	if type(menu_mods.shortcuts) == "table" then
		-- Inject the edit-shortcuts callback so the shortcuts submodule can surface it
		local shortcuts_ctx = setmetatable({ actions = actions }, { __index = ctx })
		push("shortcuts.build", menu_mods.shortcuts.build, shortcuts_ctx)
	end

	-- Karabiner then Gestures — keyboard first, then trackpad
	if type(menu_mods.karabiner) == "table" and type(menu_mods.karabiner.build) == "function" then
		push("karabiner.build", menu_mods.karabiner.build, ctx)
	end
	if type(menu_mods.gestures) == "table" then
		push("gestures.build", menu_mods.gestures.build, ctx)
	end
	if type(menu_mods.apps) == "table" then
		push("apps.build", menu_mods.apps.build, ctx)
	end


	-- ── Tail: order driven by the shared manifest top_level (MENU-1/MENU-2).
	-- Build log-level items first (needed only when "debug" id is dispatched).
	local Logger_mod = require("lib.logger")
	local active_level_name = "INFO"
	local log_level_items = {}
	for _, lvl in ipairs({ "DEBUG", "INFO", "WARNING", "ERROR" }) do
		local lvl_num  = Logger_mod.LEVELS[lvl]
		local is_active = (Logger_mod.current_level == lvl_num)
		if is_active then active_level_name = lvl end
		local lvl_capture = lvl
		table.insert(log_level_items, {
			title   = Labels.log_level_emoji(lvl) .. " " .. lvl,
			checked = is_active,
			fn      = function() actions.set_log_level(lvl_capture) end,
		})
	end
	local healthcheck = require("ui.healthcheck")

	for _, entry in ipairs(load_top_level_tail()) do
		local id = entry.id
		if id == "---" then
			table.insert(items, { title = "-" })
		elseif id == "global_actions" then
			local ga_items = {}
			for _, ga in ipairs(load_global_actions()) do
				local gid = ga.id
				if gid == "---" then
					table.insert(ga_items, { title = "-" })
				elseif gid == "enable_all" then
					table.insert(ga_items, { title = i18n.get("menu.global.enable_all"),    fn = actions.enable_all })
				elseif gid == "disable_all" then
					table.insert(ga_items, { title = i18n.get("menu.global.disable_all"),   fn = actions.disable_all })
				elseif gid == "reset_defaults" then
					table.insert(ga_items, { title = i18n.get("menu.global.reset_defaults"), fn = actions.reset_defaults })
				end
			end
			table.insert(items, { title = i18n.get("menu.global.title"), menu = ga_items })
		elseif id == "language" then
			table.insert(items, { title = i18n.get("menu.global.language"), menu = i18n.build_language_menu_items() })
		elseif id == "config_folder" then
			table.insert(items, { title = i18n.get("menu.global.config_folder"), fn = actions.open_paths })
		elseif id == "setup_wizard" then
			table.insert(items, { title = i18n.get("menu.global.setup_wizard"), fn = actions.show_setup_wizard })
		elseif id == "about" then
			if type(menu_mods.about) == "table" and type(menu_mods.about.build) == "function" then
				local ok_a, about_item = pcall(menu_mods.about.build, ctx)
				if ok_a and about_item then table.insert(items, about_item) end
			end
		elseif id == "reload" then
			-- Strip the leading emoji token — emoji render poorly in native macOS menu bars
			table.insert(items, { title = "↺ " .. i18n.get("menu.global.reload"):gsub("^%S+ ", ""), fn = actions.reload })
		elseif id == "quit" then
			table.insert(items, { title = "✕ " .. i18n.get("menu.global.quit"):gsub("^%S+ ", ""), fn = actions.quit })
		elseif id == "debug" then
			local debug_items = {}
			for _, dbg in ipairs(load_debug_menu()) do
				local did = dbg.id
				if did == "---" then
					table.insert(debug_items, { title = "-" })
				elseif did == "console" then
					table.insert(debug_items, { title = i18n.get("menu.debug.console"), fn = actions.open_console })
				elseif did == "log_level" then
					local lbl = i18n.get("menu.debug.log_level") .. " : " .. Labels.log_level_emoji(active_level_name) .. " " .. active_level_name
					table.insert(debug_items, { title = lbl, menu = log_level_items })
				elseif did == "open_logs" then
					table.insert(debug_items, { title = i18n.get("menu.debug.open_logs"), fn = actions.open_logs })
				elseif did == "open_today_log" then
					table.insert(debug_items, { title = i18n.get("menu.debug.open_today_log"), fn = actions.open_today_log })
				elseif did == "open_error_log" then
					table.insert(debug_items, { title = i18n.get("menu.debug.open_error_log"), fn = actions.open_error_log })
				elseif did == "healthcheck" then
					table.insert(debug_items, { title = i18n.get("menu.debug.healthcheck"), fn = function() healthcheck.show_window() end })
				end
			end
			table.insert(items, { title = i18n.get("menu.debug.title"), menu = debug_items })
		end
	end

	-- Collect the download item now so it participates in canvas width calculation below.
	-- pcall-isolated like every other component builder above (e.g. the AI zone at
	-- line ~447) — an exception here must degrade to "no download item", not take
	-- down the whole menu-build pipeline.
	local _dl_item = nil
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_download_item) == "function" then
		local ok_dl, dl_result = pcall(ctx.llm_handler.build_download_item)
		if ok_dl then
			_dl_item = dl_result
		else
			Logger.error(LOG, string.format("Error building LLM download item: %s.", tostring(dl_result)))
		end
	end
	if _dl_item then
		table.insert(items, 1, { title = "-" })
		table.insert(items, 1, _dl_item)
	end

	-- This is the single highest-blast-radius call in the whole build pipeline:
	-- it is the LAST step and mutates `items` in place, so an unguarded exception
	-- here would unwind past every component built above and turn one broken
	-- badge render into a total menu-rebuild failure.
	local ok_badge, badge_err = pcall(CanvasBadge.prepend_to, items, ctx, function()
		if ctx and ctx.script_control then
			if type(ctx.script_control.toggle_script_control) == "function" then pcall(ctx.script_control.toggle_script_control) end
			if type(ctx.script_control.toggle) == "function" then pcall(ctx.script_control.toggle) end
		end
	end)
	if not ok_badge then
		Logger.error(LOG, string.format("Error building canvas badge: %s.", tostring(badge_err)))
	end

	return items
end

return M
