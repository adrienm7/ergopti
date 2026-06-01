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
local Paths      = require("lib.paths")
local LOG        = "builder"
local i18n       = require("lib.i18n")
local HotCounter  = require("ui.menu.hotstring_counter")
local CanvasBadge = require("ui.menu.canvas_badge")


-- Fallback used when the manifest cannot be loaded
local ERGOPTI_GROUPS_FALLBACK = { sfbsreduction = true, rolls = true }

-- Fallback debug menu order — mirrors menu_manifest.json debug_menu.
local DEBUG_MENU_FALLBACK = {
	{ id = "console" },
	{ id = "---" },
	{ id = "log_level" },
	{ id = "open_logs" },
	{ id = "open_today_log" },
	{ id = "---" },
	{ id = "healthcheck" },
}


--- Loads hotstring group classification from the shared menu_manifest.json.
--- Falls back to the hardcoded set if the file cannot be read or parsed.
--- Logs ERROR if manifest is not found (fail-fast philosophy).
--- @return table<string,boolean> Set of group IDs specific to the Ergopti layout.
local function load_ergopti_groups()
	local manifest_path = Paths.find_from_configdir("shared/menu_manifest.json") or ""
	local ok_r, fh = pcall(io.open, manifest_path, "r")
	if not ok_r or not fh then
		Logger.error(LOG, "Cannot open menu_manifest.json at '%s' — Ergopti groups unavailable.", manifest_path)
		return ERGOPTI_GROUPS_FALLBACK
	end
	local content = fh:read("*a")
	fh:close()
	local ok_j, data = pcall(hs.json.decode, content)
	if not ok_j or type(data) ~= "table" or type(data.hotstring_groups) ~= "table" then
		Logger.error(LOG, "Failed to parse menu_manifest.json — using fallback.")
		return ERGOPTI_GROUPS_FALLBACK
	end
	local groups = {}
	for _, id in ipairs(data.hotstring_groups.ergopti or {}) do
		groups[id] = true
	end
	Logger.debug(LOG, "Ergopti groups loaded from manifest (%d group(s)).", #(data.hotstring_groups.ergopti or {}))
	return groups
end


--- Loads the debug_menu ordered array from the shared menu_manifest.json.
--- Filters out entries whose platforms list does not include "hs".
--- Falls back to DEBUG_MENU_FALLBACK on any read or parse failure.
--- Logs ERROR if manifest is not found (fail-fast philosophy).
--- @return table Array of {id} entries in display order.
local function load_debug_menu()
	local manifest_path = Paths.find_from_configdir("shared/menu_manifest.json") or ""
	local ok_r, fh = pcall(io.open, manifest_path, "r")
	if not ok_r or not fh then
		Logger.error(LOG, "Cannot open menu_manifest.json for debug menu — unavailable.")
		return DEBUG_MENU_FALLBACK
	end
	local content = fh:read("*a")
	fh:close()
	local ok_j, data = pcall(hs.json.decode, content)
	if not ok_j or type(data) ~= "table" or type(data.debug_menu) ~= "table" then
		Logger.error(LOG, "Failed to parse debug_menu from manifest — unavailable.")
		return DEBUG_MENU_FALLBACK
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
	return #result > 0 and result or DEBUG_MENU_FALLBACK
end





-- ==================================
--- ==================================
-- ======= 1/ Menu Generation =======
--- ==================================
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
			table.insert(hotstrings_menu, { title = "-" })
		end

		-- 2a. Common hotstring groups (non-Ergopti) with a disabled header
		local function collect_groups(only_filter)
			local result = {}
			if type(menu_mods.hotstrings.build_groups) ~= "function" then return result end
			local built = Logger.build(LOG, "hotstrings.build_groups",
				function(c) return menu_mods.hotstrings.build_groups(c, only_filter) end, ctx)
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
				if name ~= "custom" and name ~= "personal" and name:sub(1, 13) ~= "personal_ext_"
				and not ERGOPTI_GROUPS[name] then
					non_ergopti_filter[name] = true
				end
			end
		end

		local std_groups = collect_groups(non_ergopti_filter)
		if #std_groups > 0 then
			local common_header = "— " .. string.format(i18n.get("menu.hotstrings.header_common_count"), fmt_grand(common_total)) .. " —"
			table.insert(hotstrings_menu, { title = common_header, disabled = true })
			for _, it in ipairs(std_groups) do table.insert(hotstrings_menu, it) end
		end

		-- 2b. Ergopti-layout-specific groups — separated from the standard block
		local ergopti_groups = collect_groups(ERGOPTI_GROUPS)
		if #ergopti_groups > 0 then
			if #std_groups > 0 then table.insert(hotstrings_menu, { title = "-" }) end
			local ergopti_header = "— " .. string.format(i18n.get("menu.hotstrings.header_ergopti_count"), fmt_grand(ergopti_total)) .. " —"
			table.insert(hotstrings_menu, { title = ergopti_header, disabled = true })
			for _, it in ipairs(ergopti_groups) do table.insert(hotstrings_menu, it) end
		end

		-- 3. Personal/custom hotstrings — "Mes hotstrings" header avoids duplication with
		-- the sub-menu item title "Hotstrings personnels" just below it.
		local custom_item = type(menu_mods.hotstrings.build_custom) == "function"
			and Logger.build(LOG, "hotstrings.build_custom", menu_mods.hotstrings.build_custom, ctx)
		if custom_item then
			table.insert(hotstrings_menu, { title = "-" })
			local personal_header = "— " .. string.format(i18n.get("menu.hotstrings.header_personal_count"), fmt_grand(personal_total)) .. " —"
			table.insert(hotstrings_menu, { title = personal_header, disabled = true })
			table.insert(hotstrings_menu, custom_item)
		end

		-- 4. Extensions hotstrings section (counts already included in grand_total via HotCounter)
		do
			local ext_root = ctx.base_dir and (ctx.base_dir .. "../../extensions/")
			local ok_attr, attr = ext_root and pcall(hs.fs.attributes, ext_root) or false
			if ok_attr and type(attr) == "table" and attr.mode == "directory" then
				local ext_ids = {}
				for fname in hs.fs.dir(ext_root) do
					if fname ~= "." and fname ~= ".." then
						local fpath = ext_root .. fname
						local ok_a2, a2 = pcall(hs.fs.attributes, fpath)
						if ok_a2 and type(a2) == "table" and a2.mode == "directory" then
							table.insert(ext_ids, fname)
						end
					end
				end
				table.sort(ext_ids)

				--- Counts hotstring entries in a TOML file by scanning for quoted keys.
				--- Each line starting with `"` inside a [[section]] block is one hotstring.
				local function count_toml_hotstrings(path)
					local total = 0
					local sections = {}
					local current = nil
					local fh = io.open(path, "r")
					if not fh then return 0, {} end
					for line in fh:lines() do
						local sec = line:match("^%[%[([A-Za-z0-9_%-]+)%]%]")
						if sec then
							current = sec
							table.insert(sections, { name = sec, count = 0 })
						elseif line:match('^"') and current then
							sections[#sections].count = sections[#sections].count + 1
							total = total + 1
						end
					end
					fh:close()
					return total, sections
				end

				--- Reads the extension display name from its manifest.toml.
				local function read_ext_name(manifest_path)
					local fh = io.open(manifest_path, "r")
					if not fh then return nil end
					for line in fh:lines() do
						local v = line:match('^name%s*=%s*"(.-)"')
						if v then fh:close(); return v end
					end
					fh:close()
					return nil
				end

				local ext_items_built = {}
				for _, ext_id in ipairs(ext_ids) do
					local ext_dir    = ext_root .. ext_id .. "/"
					local hs_dir     = ext_dir .. "hotstrings/"
					local manifest   = ext_dir .. "manifest.toml"
					local ok_m, am   = pcall(hs.fs.attributes, manifest)
					if not (ok_m and type(am) == "table" and am.mode == "file") then goto continue_ext end
					local ext_name   = read_ext_name(manifest) or ext_id

					local ok_hd, ahd = pcall(hs.fs.attributes, hs_dir)
					if not (ok_hd and type(ahd) == "table" and ahd.mode == "directory") then goto continue_ext end

					local toml_stems = {}
					for fname in hs.fs.dir(hs_dir) do
						if fname:match("%.toml$") and not fname:match("^_") then
							local stem = fname:match("^(.-)%.toml$")
							if stem and stem ~= "" then table.insert(toml_stems, stem) end
						end
					end
					table.sort(toml_stems)

					local ext_hs_total = 0
					local toml_submenus = {}
					for _, stem in ipairs(toml_stems) do
						local toml_path = hs_dir .. stem .. ".toml"
						local total, sections = count_toml_hotstrings(toml_path)
						ext_hs_total = ext_hs_total + total
						local sec_menu = {
							{
								title = i18n.get("menu.hotstrings.open_file"),
								fn    = (function(path)
									return function()
										hs.timer.doAfter(0, function()
											pcall(hs.execute, string.format("open %q", path))
										end)
									end
								end)(toml_path),
							},
						}
						if #sections > 0 then table.insert(sec_menu, { title = "-" }) end
						for _, sec in ipairs(sections) do
							table.insert(sec_menu, {
								title    = sec.name .. " (" .. fmt_grand(sec.count) .. ")",
								disabled = true,
							})
						end
						local toml_label = stem .. (total > 0 and (" (" .. fmt_grand(total) .. ")") or "")
						table.insert(toml_submenus, { title = toml_label, menu = sec_menu })
					end

					local ext_label = ext_name .. (ext_hs_total > 0 and (" (" .. fmt_grand(ext_hs_total) .. ")") or "")
					table.insert(ext_items_built, { title = ext_label, menu = toml_submenus })
					::continue_ext::
				end

				if #ext_items_built > 0 then
					table.insert(hotstrings_menu, { title = "-" })
					local ext_base   = i18n.get("menu.extensions.header")
					local ext_header = ext_has_count
						and ("— " .. ext_base .. " (" .. fmt_grand(ext_total) .. ") —")
						or  ("— " .. ext_base .. " —")
					table.insert(hotstrings_menu, { title = ext_header, disabled = true })
					for _, it in ipairs(ext_items_built) do
						table.insert(hotstrings_menu, it)
					end
				end
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
				checked = all_enabled and not ctx.paused or nil,
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


	-- Actions globales — last item of the features block (sits just above the
	-- separator that closes the block), grouped with the other user-facing
	-- toggles rather than with the About / version / language items.
	table.insert(items, {
		title = i18n.get("menu.global.title"),
		menu = {
			{ title = i18n.get("menu.global.enable_all"),    fn = actions.enable_all },
			{ title = i18n.get("menu.global.disable_all"),   fn = actions.disable_all },
			{ title = i18n.get("menu.global.reset_defaults"), fn = actions.reset_defaults },
		}
	})
	table.insert(items, { title = "-" })
	-- About / Update — sits directly below Actions globales in the same block
	if type(menu_mods.about) == "table" and type(menu_mods.about.build) == "function" then
		local ok_a, about_item = pcall(menu_mods.about.build, ctx)
		if ok_a and about_item then
			table.insert(items, about_item)
		end
	end
	-- Language selector closes the block
	table.insert(items, {
		title = i18n.get("menu.global.language"),
		menu  = i18n.build_language_menu_items(),
	})
	table.insert(items, { title = i18n.get("menu.global.config_folder"), fn = actions.open_paths })
	table.insert(items, { title = i18n.get("menu.global.setup_wizard"),  fn = actions.show_setup_wizard })
	table.insert(items, { title = "-" })
	-- Strip the leading emoji token from the shared i18n string and replace with
	-- plain Unicode symbols — emoji render poorly in native macOS menu bars
	table.insert(items, { title = "↺ " .. i18n.get("menu.global.reload"):gsub("^%S+ ", ""),  fn = actions.reload })
	table.insert(items, { title = "✕ " .. i18n.get("menu.global.quit"):gsub("^%S+ ", ""),    fn = actions.quit })

	-- Build the log level submenu with a checkmark on the active level
	local log_level_items = {}
	local Logger_mod = require("lib.logger")
	local active_level_name = "INFO"
	for _, lvl in ipairs({ "DEBUG", "INFO", "WARNING", "ERROR" }) do
		local lvl_num = Logger_mod.LEVELS[lvl]
		local is_active = (Logger_mod.current_level == lvl_num)
		if is_active then active_level_name = lvl end
		local lvl_capture = lvl
		table.insert(log_level_items, {
			title   = lvl,
			checked = is_active,
			fn      = function() actions.set_log_level(lvl_capture) end,
		})
	end

	local healthcheck  = require("lib.healthcheck")
	local debug_order  = load_debug_menu()
	local debug_items  = {}
	for _, entry in ipairs(debug_order) do
		local id = entry.id
		if id == "---" then
			table.insert(debug_items, { title = "-" })
		elseif id == "console" then
			table.insert(debug_items, { title = i18n.get("menu.debug.console"), fn = actions.open_console })
		elseif id == "log_level" then
			table.insert(debug_items, { title = i18n.get("menu.debug.log_level") .. " : " .. active_level_name, menu = log_level_items })
		elseif id == "open_logs" then
			table.insert(debug_items, { title = i18n.get("menu.debug.open_logs"), fn = actions.open_logs })
		elseif id == "open_today_log" then
			table.insert(debug_items, { title = i18n.get("menu.debug.open_today_log"), fn = actions.open_today_log })
		elseif id == "healthcheck" then
			table.insert(debug_items, { title = i18n.get("menu.debug.healthcheck"), fn = function() healthcheck.show_window() end })
		end
	end
	table.insert(items, {
		title = i18n.get("menu.debug.title"),
		menu  = debug_items,
	})

	-- Collect the download item now so it participates in canvas width calculation below
	local _dl_item = nil
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_download_item) == "function" then
		_dl_item = ctx.llm_handler.build_download_item()
	end
	if _dl_item then
		table.insert(items, 1, { title = "-" })
		table.insert(items, 1, _dl_item)
	end

	CanvasBadge.prepend_to(items, ctx, function()
		if ctx and ctx.script_control then
			if type(ctx.script_control.toggle_script_control) == "function" then pcall(ctx.script_control.toggle_script_control) end
			if type(ctx.script_control.toggle) == "function" then pcall(ctx.script_control.toggle) end
		end
	end)

	return items
end

return M
