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
local Logger     = require("infra.logger")
local DeferredWork = require("infra.deferred_work")
local text_utils = require("infra.text_utils")
local Paths      = require("infra.paths")
local LOG        = "builder"
local i18n       = require("infra.i18n")
-- The single reader of menu_manifest.json. See load_manifest below for why this
-- module no longer has one of its own.
local ManifestMenu = require("infra.manifest_menu")
local HotCounter  = require("ui.menu.hotstring_counter")
local MenuUtils   = require("ui.menu.menu_utils")
local CanvasBadge = require("ui.menu.canvas_badge")
local Labels      = require("menu.labels")


local _ergopti_groups_cache    = nil
local _top_level_tail_cache    = nil
local _global_actions_cache    = nil

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
			if ctx.save_prefs() ~= true then return false end
			ctx.notify_feature(i18n.get("notify.hotstrings"), enable)
			ctx.updateMenu()
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
		local ergopti_groups_built = collect_groups(ERGOPTI_GROUPS, counts)
		local custom_item = type(menu_mods.hotstrings.build_custom) == "function"
			and Logger.build(LOG, "hotstrings.build_custom", function(c) return menu_mods.hotstrings.build_custom(c, counts) end, ctx)

		-- 4. The manifest's `hotstring_extensions` row (counts already included in
		-- grand_total via HotCounter). Named here because the id is what the
		-- action↔handler bijection gate matches on, and this section was built
		-- anonymously — so the manifest could restrict the row to Windows on the
		-- grounds that "neither Lua driver ships an extensions directory" while
		-- hotstring_counter.lua was walking exactly that directory and this block
		-- was rendering the result. A row nothing names is a row nothing can check.
		local manifest_row = "hotstring_extensions"
		Logger.debug(LOG, "Building manifest row '%s' (%d extension(s)).", manifest_row, #counts.ext_details)
		local extension_items = {}
		do
			for _, ext in ipairs(counts.ext_details) do
				local toml_submenus = {}
				for _, f in ipairs(ext.files) do
					local sec_menu = {
						{
							title = i18n.get("menu.hotstrings.open_file"),
							fn    = (function(path)
								return function()
									DeferredWork.after(0, function()
										pcall(hs.execute, "open " .. text_utils.shell_quote(path))
									end, "menu_builder.open_extension")
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
				table.insert(extension_items, { title = ext_label, menu = toml_submenus })
			end
		end


		-- ===== The manifest's own rows, placed by the shared renderer =====

		-- Section headers carry a count here and a plain key in the manifest, so
		-- the label is enriched through the renderer's hook rather than by
		-- building the header — and the manifest still owns whether the header
		-- exists and where it sits.
		local section_labels = {
			["menu.hotstrings.header_common"] = i18n.decorate_section(
				string.format(i18n.get("menu.hotstrings.header_common_count"), fmt_grand(common_total))),
			["menu.hotstrings.header_ergopti"] = i18n.decorate_section(
				string.format(i18n.get("menu.hotstrings.header_ergopti_count"), fmt_grand(ergopti_total))),
			["menu.hotstrings.personal_header"] = i18n.decorate_section(
				string.format(i18n.get("menu.hotstrings.header_personal_count"), fmt_grand(personal_total))),
			["menu.extensions.header"] = ext_has_count
				and i18n.decorate_section(i18n.get("menu.extensions.header") .. " (" .. fmt_grand(ext_total) .. ")")
				or  i18n.decorate_section(i18n.get("menu.extensions.header")),
		}

		--- Converts already-built hs rows into the provider data a `list` row
		--- takes. These builders return menu trees, and rewriting all four of them
		--- to emit provider rows is a larger job than this one; adapting here is
		--- what lets the renderer own the placement today.
		--- @param built table Menu rows in this driver's shape.
		--- @return table Provider rows.
		--- The extension rows are still built in this driver's dialect below, so
		--- they alone are adapted. The category and personal builders emit provider
		--- rows themselves since 2026-08-07.
		--- @param built table Rows in this driver's shape.
		--- @return table Provider rows.
		local function as_rows(built)
			local out = {}
			for _, entry in ipairs(built or {}) do
				out[#out + 1] = MenuUtils.as_provider_row(entry)
			end
			return out
		end

		local hs_ctx = {}
		for key, value in pairs(ctx) do hs_ctx[key] = value end
		hs_ctx.section_label = function(key) return section_labels[key] end
		-- The two bulk rows are `command` declarations, so the renderer builds the
		-- row and this driver supplies only the behaviour. Taken from the existing
		-- builder rather than reimplemented: it owns the section-walk both rows
		-- perform, and a second copy of that walk is exactly the kind of duplicate
		-- this migration exists to remove.
		local bulk_rows = type(menu_mods.hotstrings.build_bulk_actions) == "function"
			and menu_mods.hotstrings.build_bulk_actions(ctx) or {}
		hs_ctx.commands = {
			["hotstrings_enable_all"]  = bulk_rows[1] and bulk_rows[1].action or function() end,
			["hotstrings_disable_all"] = bulk_rows[2] and bulk_rows[2].action or function() end,
		}

		local providers = {
			["hotstring_categories_standard"] = function() return std_groups end,
			["hotstring_categories_ergopti"]  = function() return ergopti_groups_built end,
			-- Provider data straight from menu_hotstrings_custom since 2026-08-07:
			-- that builder emits `label`/`action`/`items` itself, so there is no
			-- translation step and the renderer materialises the tree.
			["hotstring_personal"]            = function()
				return custom_item and { custom_item } or {}
			end,
			["hotstring_extensions"]          = function() return as_rows(extension_items) end,
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

		if #hotstrings_menu > 0 then
			table.insert(items, {
				label = hotstrings_title,
				submenu = hotstrings_menu,
				checked = all_enabled or nil,
				action = not ctx.paused and toggle_all_hotstrings or nil
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
	local Logger_mod = require("infra.logger")
	local active_level_name = "INFO"
	local log_level_items = {}
	for _, lvl in ipairs({ "DEBUG", "INFO", "WARNING", "ERROR" }) do
		local lvl_num  = Logger_mod.LEVELS[lvl]
		local is_active = (Logger_mod.current_level == lvl_num)
		if is_active then active_level_name = lvl end
		local lvl_capture = lvl
		-- Provider rows: these are the `items` of the log-level list row below.
		table.insert(log_level_items, {
			label   = Labels.log_level_emoji(lvl) .. " " .. lvl,
			checked = is_active,
			action  = function() actions.set_log_level(lvl_capture) end,
		})
	end
	local healthcheck = require("ui.healthcheck")

	for _, entry in ipairs(load_top_level_tail()) do
		local id = entry.id
		if id == "---" then
			table.insert(items, { separator = true })
		elseif id == "global_actions" then
			local ga_items = {}

			-- Pause owns the bindings axis for the whole pause window: pause_all()
			-- snapshots what was running and resume_all() restores that snapshot.
			-- A global action taken in between is therefore either silently
			-- discarded on resume, or — for « Tout activer » — binds every hotkey
			-- immediately and breaks the « pause = tout éteint » invariant the
			-- pause exists to guarantee. The per-feature toggles were gated for
			-- exactly this; these three, which move ALL of them at once, were not.
			-- The three rows are `type = "command"` in the manifest: their labels
			-- and their order are declared, and this file supplies only what each
			-- one does. The chain of `elseif` that used to map id → label → action
			-- was the manifest's own table written out a second time, in a third
			-- language, and the separator before the reset was written out here too.
			local ok_ga, ManifestMenu = pcall(require, "infra.manifest_menu")
			if ok_ga and type(ManifestMenu.build) == "function" then
				local ga_ctx = {}
				for key, value in pairs(ctx or {}) do ga_ctx[key] = value end
				ga_ctx.commands = {
					["enable_all"]      = actions.enable_all,
					["disable_all"]     = actions.disable_all,
					["reset_defaults"]  = actions.reset_defaults,
				}
				for _, row in ipairs(ManifestMenu.build("global_actions", "Global", nil, nil, ga_ctx) or {}) do
					if ctx.paused then
						-- Greyed AND stripped of its handler, not merely greyed. A
						-- disabled row whose fn survives still fires the moment the
						-- greying is rendered wrong somewhere else, and these three move
						-- every binding at once — which is the whole reason the pause
						-- window has to own that axis alone.
						row.disabled = true
						row.fn = nil
					end
					table.insert(ga_items, row)
				end
			else
				Logger.error(LOG, "Manifest renderer unavailable — the global actions are not rendered.")
			end
			table.insert(items, { label = i18n.get("menu.global.title"), submenu = ga_items })
		elseif id == "language" then
			-- The locale rows reach the tray through the manifest's `language_menu`
			-- now. They were the same twenty-one entries on every driver, from the
			-- same shared catalogue, and nothing described the menu holding them.
			local rendered = ManifestMenu.build("language_menu", "Language", nil, nil, ctx, {
				["locales"] = function() return i18n.build_language_menu_items() or {} end,
			})
			table.insert(items, { label = i18n.get("menu.global.language"), submenu = rendered })
		elseif id == "config_folder" then
			table.insert(items, { label = i18n.get("menu.global.config_folder"), action = actions.open_paths })
		elseif id == "setup_wizard" then
			table.insert(items, { label = i18n.get("menu.global.setup_wizard"), action = actions.show_setup_wizard })
		elseif id == "about" then
			if type(menu_mods.about) == "table" and type(menu_mods.about.build) == "function" then
				local ok_a, about_item = pcall(menu_mods.about.build, ctx)
				if ok_a and about_item then table.insert(items, about_item) end
			end
		elseif id == "reload" then
			-- Strip the leading emoji token — emoji render poorly in native macOS menu bars
			table.insert(items, { label = "↺ " .. i18n.get("menu.global.reload"):gsub("^%S+ ", ""), action = actions.reload })
		elseif id == "quit" then
			table.insert(items, { label = "✕ " .. i18n.get("menu.global.quit"):gsub("^%S+ ", ""), action = actions.quit })
		elseif id == "debug" then
			-- The manifest declares every row of this submenu and the shared renderer
			-- places them; this file supplies only what each one does.
			--
			-- It used to iterate the SAME array and then write the label for each id
			-- by hand, in a chain of `elseif` — so the manifest decided the order and
			-- this file decided everything else, in a second language. Linux has read
			-- this section through the renderer since 2026-08-06 and Windows since
			-- this morning; macOS was the last of the three.
			local debug_items = {}
			local ok_dbg, ManifestMenu = pcall(require, "infra.manifest_menu")
			if ok_dbg and type(ManifestMenu.build) == "function" then
				local dbg_ctx = {}
				for key, value in pairs(ctx or {}) do dbg_ctx[key] = value end
				dbg_ctx.commands = {
					["console"]        = actions.open_console,
					["open_logs"]      = actions.open_logs,
					["open_today_log"] = actions.open_today_log,
					["open_error_log"] = actions.open_error_log,
					["healthcheck"]    = function() healthcheck.show_window() end,
				}
				-- The picker's own row carries the level currently set, which is why it
				-- is a `list` and not a `command`: a declaration cannot spell a label
				-- that changes with the state behind it.
				debug_items = ManifestMenu.build("debug_menu", "Debug", nil, nil, dbg_ctx, {
					["log_level"] = function()
						return { {
							label = i18n.get("menu.debug.log_level") .. " : "
								.. Labels.log_level_emoji(active_level_name) .. " " .. active_level_name,
							items = log_level_items,
						} }
					end,
				}) or {}
			else
				Logger.error(LOG, "Manifest renderer unavailable — the debug submenu is empty.")
			end
			table.insert(items, { label = i18n.get("menu.debug.title"), submenu = debug_items })
		end
	end

	-- Everything above collected row DATA; this is where the shared renderer turns
	-- it into the table hs.menubar consumes.
	--
	-- Each component builder used to end with the row that hangs its submenu on
	-- the tray — `title` + `menu`, written by hand once per submenu, a dozen times
	-- over — and this function returned that array untouched. Linux made the same
	-- move on 2026-08-07 and it was overdue here for a harder reason than symmetry:
	-- two of those builders had ALREADY started returning provider rows, so the
	-- Karabiner and « Disposition » entries reached the menu bar with no title and
	-- their subtrees on a field hs.menubar does not read. Both were simply gone
	-- from the menu, and nothing said so.
	local rendered = {}
	local ok_root, ManifestMenu = pcall(require, "infra.manifest_menu")
	if ok_root and type(ManifestMenu.render_rows) == "function" then
		rendered = ManifestMenu.render_rows(items, "top_level")
	else
		Logger.error(LOG, "Manifest renderer unavailable — the tray menu cannot be drawn.")
	end

	-- Collect the download item now so it participates in canvas width calculation below.
	-- pcall-isolated like every other component builder above (e.g. the AI zone at
	-- line ~447) — an exception here must degrade to "no download item", not take
	-- down the whole menu-build pipeline.
	--
	-- Prepended AFTER the render, in the hs.menubar shape: it is a transient
	-- progress row the LLM module owns and rebuilds on its own timer, not a row of
	-- the declared menu.
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
		table.insert(rendered, 1, { title = "-" })
		table.insert(rendered, 1, _dl_item)
	end

	-- This is the single highest-blast-radius call in the whole build pipeline:
	-- it is the LAST step and mutates the menu in place, so an unguarded exception
	-- here would unwind past every component built above and turn one broken
	-- badge render into a total menu-rebuild failure.
	--
	-- It too runs after the render: the badge is an IMAGE with no text, and a
	-- provider row with an empty label is dropped by the renderer — correctly, for
	-- every row but this one.
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
