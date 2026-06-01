--- ui/menu/init.lua

--- ==============================================================================
--- MODULE: Menu UI Core
--- DESCRIPTION:
--- Orchestrates the macOS Menu Bar icon (System Tray).
--- Acts as the central controller tying together settings, UI building, and OS watchers.
---
--- FEATURES & RATIONALE:
--- 1. Controller Pattern: Wires preferences, builders, and OS watchers together.
--- 2. Sub-module Delegation: Defers logic and UI construction to dedicated modules.
--- ==============================================================================

local M = {}

local hs               = hs
local notifications    = require("lib.notifications")
local hotstring_editor = require("ui.hotstring_editor")
local Logger           = require("lib.logger")
local i18n             = require("lib.i18n")
local ui_restore       = require("lib.ui_restore")

local Preferences   = require("ui.menu.preferences")
local Builder       = require("ui.menu.builder")
local MenuPaths     = require("ui.menu.menu_paths")
local MenuState     = require("ui.menu.menu_state")
local MenuWatchers  = require("ui.menu.menu_watchers")

local LOG = "menu"
local load_errors = {}

--- Safely loads a module and logs any loading failure.
--- @param module_id string Lua module path.
--- @param label string Human label used in logs.
--- @return table|nil Loaded module or nil on failure.
local function safe_require(module_id, label)
	local ok, mod_or_err = pcall(require, module_id)
	if not ok then
		local err_msg = tostring(mod_or_err)
		load_errors[module_id] = err_msg
		Logger.error(LOG, string.format("Failed to load \"%s\" (%s): %s.", tostring(label), tostring(module_id), err_msg))
		return nil
	end
	Logger.debug(LOG, string.format("Module \"%s\" loaded successfully (%s).", tostring(label), tostring(module_id)))
	return mod_or_err
end

-- Load isolated sub-menu builders safely
local menu_mods = {
	gestures        = safe_require("ui.menu.menu_gestures",        "gestures menu"),
	shortcuts       = safe_require("ui.menu.menu_shortcuts",       "shortcuts menu"),
	keyboard_layout = safe_require("ui.menu.menu_keyboard_layout", "keyboard layout menu"),
	hotstrings      = safe_require("ui.menu.menu_hotstrings",      "hotstrings menu"),
	llm             = safe_require("ui.menu.menu_llm",             "AI menu"),
	keylogger       = safe_require("ui.menu.menu_metrics",         "metrics menu"),
	karabiner       = safe_require("ui.menu.menu_karabiner",       "Karabiner menu"),
	apps            = safe_require("ui.menu.menu_apps",            "apps menu"),
	about           = safe_require("ui.menu.menu_about",           "about/update menu"),
}

-- Load core modules
local core_mods = {
	llm           = safe_require("modules.llm", "AI engine"),
	keylogger     = safe_require("modules.keylogger", "metrics engine"),
	shortcuts_mod = safe_require("modules.shortcuts", "shortcuts engine"),
	dyn_hot_mod   = safe_require("modules.dynamic_hotstrings", "dynamic hotstrings engine"),
}

M._active_tasks = {}





-- =================================
--- =================================
-- ======= 1/ Core Lifecycle =======
--- =================================
-- =================================

--- Initializes the menu bar app, loads configurations, and binds modules.
--- @param base_dir string Base directory for configuration.
--- @param hotfiles table List of hotstring files.
--- @param gestures table Gestures module reference.
--- @param keymap table Keymap module reference.
--- @param dynamic_hotstrings table Dynamic hotstrings module reference.
--- @param module_sections table Extra module sections definitions.
--- @return table|nil myMenu The created menubar object.
--- @return table|nil configWatcher The file watcher object.
function M.start(base_dir, hotfiles, gestures, keymap, dynamic_hotstrings, module_sections, karabiner, hotfile_paths)
	base_dir = type(base_dir) == "string" and base_dir or (hs.configdir .. "/")
	-- MenuPaths was already initialized by init.lua before menu.start() is called;
	-- call init() again only as a no-op safety net in case of standalone testing.
	if not MenuPaths.is_initialized() then
		MenuPaths.init(base_dir, function() hs.timer.doAfter(0.25, function() pcall(hs.reload) end) end)
	end
	core_mods.keymap = keymap
	core_mods.gestures = gestures
	core_mods.dyn_hot_mod = dynamic_hotstrings or core_mods.dyn_hot_mod

	local ok, myMenu = pcall(hs.menubar.new)
	if not ok or not myMenu then
		Logger.error(LOG, "Failed to create hs.menubar object.")
		return nil, nil
	end
	Logger.info(LOG, "Menubar created successfully.")

	local updateMenu
	local _suppress_watcher_until = 0

	local state = Preferences.build_initial_state(hotfiles, menu_mods, core_mods)



	-- =================================
	-- ===== 1.1) Internal Helpers =====
	-- =================================

	local function applyTriggerChar(text)
		if type(text) ~= "string" then return text end
		local safe_repl = tostring(state.trigger_char):gsub("%%", "%%%%")
		return text:gsub("★", safe_repl)
	end

	local function update_icon(custom_text)
		local shortcuts = core_mods.shortcuts_mod
		local paused    = shortcuts and type(shortcuts.is_paused) == "function" and shortcuts.is_paused() or false

		-- Logo variant is persisted via hs.settings; default is "simple"
		local variant = hs.settings.get("ergopti_menubar_logo_variant") or "simple"

		-- The shared logo directory lives at static/img/logo (two levels up from
		-- static/ergopti_plus/macos, where base_dir points)
		local logo_dir = base_dir .. "../../img/logo/"
		local logo_file
		if variant == "simple" then
			-- A dedicated disabled simple logo may not yet exist — fall back to logo_simple.png
			if paused then
				local disabled_path = logo_dir .. "logo_simple_disabled.png"
				local f = io.open(disabled_path, "r")
				if f then f:close(); logo_file = "logo_simple_disabled.png" else logo_file = "logo_simple.png" end
			else
				logo_file = "logo_simple.png"
			end
		else
			logo_file = paused and "logo_black.png" or "logo_white.png"
		end

		local ok_img, ico = pcall(hs.image.imageFromPath, logo_dir .. logo_file)

		pcall(function() myMenu:setTitle(custom_text and (" " .. tostring(custom_text)) or "") end)

		if ok_img and ico then
			-- Re-render through hs.canvas at the menubar target size whenever the
			-- source image is materially larger than the menubar height. NSImage's
			-- own setSize() only updates the displayed dimensions and leaves the
			-- backing pixel data untouched, which on retina displays causes the
			-- icon to blow up to its native resolution. Canvas re-rendering forces
			-- a clean downscale so any image (27×27, 512×512, SVG-export, …)
			-- displays at the exact menubar size.
			-- Per-variant target sizes — the simple logo is a tight glyph that
			-- reads well at the standard menubar height; the complex Ergopti
			-- logo carries finer detail and needs a couple more pixels to stay
			-- legible. Keep both constants here so future tweaks live in one spot
			local TARGET_SIMPLE  = 19
			local TARGET_COMPLEX = 26
			local TARGET = (variant == "complex") and TARGET_COMPLEX or TARGET_SIMPLE
			local scaled = ico
			pcall(function()
				local sz = ico.size and ico:size() or nil
				if sz and (sz.w > TARGET + 4 or sz.h > TARGET + 4) and hs.canvas then
					-- Create canvas with tight frame to eliminate padding in source image
					local c = hs.canvas.new({ x = 0, y = 0, w = TARGET, h = TARGET })
					-- Shrink frame inward to crop any margins from the source image
					local crop_margin = 1
					c[1] = {
						type         = "image",
						image        = ico,
						frame        = { x = crop_margin, y = crop_margin, w = TARGET - (crop_margin * 2), h = TARGET - (crop_margin * 2) },
						imageScaling = "scaleProportionally",
					}
					local rendered = c:imageFromCanvas()
					c:delete()
					if rendered then scaled = rendered end
				end
			end)
			pcall(function() if type(scaled.setSize) == "function" then scaled:setSize({ w = TARGET, h = TARGET }) end end)
			pcall(function() myMenu:setIcon(scaled, false) end)
			-- Ensure title is cleared when no custom text provided.
			if not custom_text then pcall(function() myMenu:setTitle("") end) end
		else
			-- If no image available, ensure we explicitly clear any previous icon
			-- and set the default title when no custom text is present.
			if not custom_text then
				pcall(function() myMenu:setIcon(nil) end)
				pcall(function() myMenu:setTitle("🔧") end)
			end
		end
	end

	local function reset_menubar()
		pcall(function() myMenu:setIcon(nil) end)
		pcall(function() myMenu:setTitle("") end)
	end

	local function do_reload(source)
		local msg = source == "watcher"
			and i18n.get("menu.reloading_files")
			or  i18n.get("menu.reloading")
		pcall(notifications.notify, msg, nil, "info")
		hs.timer.doAfter(0.25, function() pcall(hs.reload) end)
	end

	local function notify_feature(label, is_enabled)
		pcall(notifications.notify, tostring(label), nil, is_enabled and "success" or "error")
	end

	local function save_prefs()
		Preferences.save(MenuPaths.get("ConfigTomlPath"), state, hotfiles, core_mods)
	end



	-- =======================================
	-- ===== 1.2) Module Synchronization =====
	-- =======================================

	local _metrics_hk = nil
	local function apply_metrics_shortcut(mods, key)
		if _metrics_hk then pcall(function() _metrics_hk:delete() end); _metrics_hk = nil end
		if mods and key then
			state.metrics_shortcut = { mods = mods, key = key }
			local ok, hk = pcall(hs.hotkey.new, mods, key, function()
				-- Toggle: close the dashboard if already open, otherwise open it.
				-- Using package.loaded so we don't accidentally trigger require() on close.
				local mui = package.loaded["ui.metrics_typing.init"] or package.loaded["ui.metrics_typing"]
				if mui and mui._wv then
					pcall(function() mui._wv:delete() end)
					mui._wv = nil
					return
				end
				local kl = core_mods.keylogger
				if kl and type(kl.show_metrics) == "function" then pcall(kl.show_metrics) end
			end)
			if ok and hk then _metrics_hk = hk; hk:enable() end
		else
			state.metrics_shortcut = false
		end
		-- Keep box in sync so MenuState.sync_state_to_modules can re-enable the hotkey
		if _metrics_hk_box then _metrics_hk_box[1] = _metrics_hk end
		save_prefs()
		if type(updateMenu) == "function" then updateMenu() end
	end

	local _apps_time_hk = nil
	local function apply_apps_time_shortcut(mods, key)
		if _apps_time_hk then pcall(function() _apps_time_hk:delete() end); _apps_time_hk = nil end
		if mods and key then
			state.apps_time_shortcut = { mods = mods, key = key }
			local ok, hk = pcall(hs.hotkey.new, mods, key, function()
				-- Toggle behaviour: close if open, else open
				local at_loaded = package.loaded["ui.metrics_apps"] or package.loaded["ui.metrics_apps.init"]
				if at_loaded and at_loaded._wv then
					pcall(function() at_loaded._wv:delete() end)
					at_loaded._wv = nil
					return
				end
				local ok_mod, at = pcall(require, "ui.metrics_apps")
				if ok_mod and type(at.show) == "function" then pcall(at.show, base_dir .. "logs") end
			end)
			if ok and hk then _apps_time_hk = hk; hk:enable() end
		else
			state.apps_time_shortcut = false
		end
		-- Keep box in sync so MenuState.sync_state_to_modules can re-enable the hotkey
		if _apps_time_hk_box then _apps_time_hk_box[1] = _apps_time_hk end
		save_prefs()
		if type(updateMenu) == "function" then updateMenu() end
	end

	-- Build the dependency bag for MenuState.sync_state_to_modules
	-- _metrics_hk and _apps_time_hk are boxed in single-element tables so
	-- MenuState can read their current value even after they are reassigned
	-- by apply_metrics_shortcut / apply_apps_time_shortcut
	local _metrics_hk_box   = {}
	local _apps_time_hk_box = {}

	local function sync_state_to_modules(saved, config_absent)
		MenuState.sync_state_to_modules(state, saved, config_absent, {
			keymap                   = keymap,
			gestures                 = gestures,
			hotstring_editor         = hotstring_editor,
			core_mods                = core_mods,
			save_prefs               = save_prefs,
			apply_metrics_shortcut   = apply_metrics_shortcut,
			apply_apps_time_shortcut = apply_apps_time_shortcut,
			_metrics_hk              = _metrics_hk_box,
			_apps_time_hk            = _apps_time_hk_box,
		})
	end

	local function set_all_enabled(enabled)
		-- 1. Set global states
		state.keymap                 = enabled
		state.gestures               = enabled
		state.shortcuts              = enabled
		state.llm_enabled            = enabled
		state.keylogger_enabled      = enabled
		state.script_control_enabled = enabled
		
		if core_mods.dyn_hot_mod then state.personal_info = enabled end

		-- 2. Hotstrings groups, sections, and terminators
		if keymap then
			for name in pairs(state.hotstrings) do 
				state.hotstrings[name] = enabled
				
				local secs = type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
				if type(secs) == "table" then
					for _, sec in ipairs(secs) do
						if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
							if enabled then
								pcall(keymap.enable_section, name, sec.name)
							else
								pcall(keymap.disable_section, name, sec.name)
							end
						end
					end
				end
			end

			local defs = type(keymap.get_terminator_defs) == "function" and keymap.get_terminator_defs() or {}
			for _, def in ipairs(defs) do
				if type(def) == "table" and def.key then
					state.terminator_states[def.key] = enabled
					if type(keymap.set_terminator_enabled) == "function" then
						pcall(keymap.set_terminator_enabled, def.key, enabled)
					end
				end
			end
		end

		-- 3. Preview tooltip toggles
		if keymap then
			state.preview_star_enabled        = enabled
			state.preview_autocorrect_enabled = enabled
			state.preview_ai_enabled          = enabled
			if type(keymap.set_preview_star_enabled)        == "function" then pcall(keymap.set_preview_star_enabled,        enabled) end
			if type(keymap.set_preview_autocorrect_enabled) == "function" then pcall(keymap.set_preview_autocorrect_enabled, enabled) end
			if type(keymap.set_preview_ai_enabled)          == "function" then pcall(keymap.set_preview_ai_enabled,          enabled) end
		end

		-- 4. Individual shortcut keys
		if core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.list_shortcuts) == "function" then
			local ok, list = pcall(core_mods.shortcuts_mod.list_shortcuts)
			if ok and type(list) == "table" then
				for _, s in ipairs(list) do
					if type(s) == "table" and s.id then
						if enabled then
							if type(core_mods.shortcuts_mod.enable) == "function" then pcall(core_mods.shortcuts_mod.enable, s.id) end
						else
							if type(core_mods.shortcuts_mod.disable) == "function" then pcall(core_mods.shortcuts_mod.disable, s.id) end
						end
					end
				end
			end
		end
		
		-- 5. Sync engines and Save
		sync_state_to_modules(state, false)
		save_prefs()
		
		notify_feature(enabled and i18n.get("notify.all_features_enabled") or i18n.get("notify.all_features_disabled"), enabled)
		if type(updateMenu) == "function" then updateMenu() end
	end

	local function reset_all_defaults()
		-- Delete config.json so that the next startup uses the default module settings
		pcall(os.remove, MenuPaths.get("ConfigTomlPath"))
		pcall(notifications.notify, i18n.get("notify.defaults_reset"), nil, "info")
		hs.timer.doAfter(0.25, function() pcall(hs.reload) end)
	end



	-- ====================================
	-- ===== 1.3) Final Orchestration =====
	-- ====================================

	pcall(update_icon)

	-- Expose a refresh hook so submenus can re-render the menubar icon after
	-- toggling persisted preferences (e.g. logo variant)
	M.refresh_icon = function() pcall(update_icon) end

	local saved = Preferences.load(MenuPaths.get("ConfigTomlPath"))
	local config_absent = (next(saved) == nil)

	if config_absent then
		for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
			local name = Preferences.get_group_name(f)
			local secs = keymap and type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
			if type(secs) == "table" then
				for _, sec in ipairs(secs) do
					if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
						pcall(hs.settings.set, "hotstrings_section_" .. name .. "_" .. sec.name, nil)
					end
				end
			end
			if keymap then
				if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
				if type(keymap.enable_group) == "function"  then pcall(keymap.enable_group, name) end
			end
		end
	end

	Preferences.merge_saved_data(state, saved)
	sync_state_to_modules(saved, config_absent)

	local llm_handler = nil
	if menu_mods.llm and type(menu_mods.llm.create) == "function" then
		local ok_h, res = pcall(menu_mods.llm.create, {
			state          = state,
			active_tasks   = M._active_tasks,
			update_icon    = update_icon,
			reset_menubar  = reset_menubar,
			update_menu    = function() updateMenu() end,
			save_prefs     = save_prefs,
			keymap         = keymap,
			script_control = core_mods.shortcuts_mod,
		})
		if ok_h then
			llm_handler = res
			Logger.info(LOG, "LLM handler created successfully.")
		else
			Logger.error(LOG, string.format("create() failed for ui.menu.menu_llm: %s.", tostring(res)))
		end
	end
	
	if type(llm_handler) == "table" and type(llm_handler.check_startup) == "function" then pcall(llm_handler.check_startup) end
	if type(hotstring_editor.set_update_menu) == "function" then pcall(hotstring_editor.set_update_menu, function() updateMenu() end) end

	if core_mods.shortcuts_mod then
		if type(core_mods.shortcuts_mod.set_on_pause_change) == "function" then pcall(core_mods.shortcuts_mod.set_on_pause_change, function(_) update_icon(); updateMenu() end) end
		if state.script_control_enabled then
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "return_key", state.script_control_shortcuts.return_key)
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "backspace",  state.script_control_shortcuts.backspace)
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "escape",     state.script_control_shortcuts.escape)
		else
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "return_key", "none")
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "backspace",  "none")
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "escape",     "none")
		end
		pcall(core_mods.shortcuts_mod.set_extras, {
			open_init = function() hs.timer.doAfter(0, function() _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8; pcall(hs.execute, "open \"" .. base_dir .. "init.lua\"") end) end,
			open_personal_toml = function()
				hs.timer.doAfter(0, function()
					local personal_path = MenuPaths.get("PersonalTomlPath")
					pcall(hs.execute, "open \"" .. personal_path .. "\"")
				end)
			end,
			trigger_prediction = function() if keymap and type(keymap.trigger_prediction) == "function" then pcall(keymap.trigger_prediction) end end,
			add_hotstring = function()
				-- Toggle: close if already open, otherwise open
				if hotstring_editor then
					if type(hotstring_editor.is_open) == "function" and hotstring_editor.is_open() then
						if type(hotstring_editor.close) == "function" then pcall(hotstring_editor.close) end
						return
					end
					if type(hotstring_editor.open) == "function" then pcall(hotstring_editor.open, "shortcut") end
				end
			end,
			show_metrics = function()
				-- Toggle: close if already open, otherwise open
				local mui = package.loaded["ui.metrics_typing.init"] or package.loaded["ui.metrics_typing"]
				if mui and mui._wv then
					pcall(function() mui._wv:delete() end); mui._wv = nil; return
				end
				if core_mods.keylogger and type(core_mods.keylogger.show_metrics) == "function" then pcall(core_mods.keylogger.show_metrics) end
			end,
			show_apps_time = function()
				-- Toggle: close if already open, otherwise open
				local at_loaded = package.loaded["ui.metrics_apps"] or package.loaded["ui.metrics_apps.init"]
				if at_loaded and at_loaded._wv then
					pcall(function() at_loaded._wv:delete() end); at_loaded._wv = nil; return
				end
				local ok_at, at = pcall(require, "ui.metrics_apps"); if ok_at and type(at.show) == "function" then pcall(at.show, base_dir .. "logs") end
			end,
			open_config = function() hs.timer.doAfter(0, function() _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8; pcall(hs.execute, "open \"" .. MenuPaths.get("ConfigTomlPath") .. "\"") end) end,
			open_logs = function() hs.timer.doAfter(0, function() pcall(hs.execute, "open \"" .. base_dir .. "logs\"") end) end,
		})
	end

	updateMenu = function()
		local ctx = {
			base_dir                 = base_dir,
			state                    = state,
			paused                   = core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.is_paused) == "function" and core_mods.shortcuts_mod.is_paused() or false,
			save_prefs               = save_prefs,
			updateMenu               = updateMenu,
			refresh_icon             = function() pcall(update_icon) end,
			notify_feature           = notify_feature,
			do_reload                = do_reload,
			applyTriggerChar         = applyTriggerChar,
			get_group_name           = Preferences.get_group_name,
			keymap                   = keymap,
			hotfiles                 = hotfiles,
			hotfile_paths            = type(hotfile_paths) == "table" and hotfile_paths or {},
			module_sections          = module_sections,
			hotstring_editor         = hotstring_editor,
			personal_info            = core_mods.dyn_hot_mod,
			gestures                 = gestures,
			shortcuts                = core_mods.shortcuts_mod,
			script_control           = core_mods.shortcuts_mod,
			apply_metrics_shortcut   = apply_metrics_shortcut,
			apply_apps_time_shortcut = apply_apps_time_shortcut,
			llm_handler              = llm_handler,
			karabiner                = karabiner,
		}

		-- Resolves <config_dir>/hammerspoon/logs/ at click-time so a user who
		-- relocates their config folder via the paths editor picks up the new
		-- path without needing to reload the menu
		local function logs_dir()
			local d = MenuPaths.get_config_dir() or ""
			if not d:match("[/\\]$") then d = d .. "/" end
			return d .. "hammerspoon/logs/"
		end

		--- Helper that opens a path resolved through MenuPaths.get(key).
		--- Returns silently when no path is configured (fresh install with no
		--- personal_info.toml yet, etc.) so a gesture or shortcut binding
		--- doesn't spawn an `open ""` shell with no target.
		local function open_path_via_menu(key)
			local p = MenuPaths.get(key)
			if type(p) == "string" and p ~= "" then
				pcall(hs.execute, string.format("open %q", p))
			end
		end

		--- Action callbacks. Keys mirror the action ids declared in
		--- modules/shortcuts/script_control.ACTION_DEFINITIONS and
		--- modules/gestures/actions.SG_NAMES so the same handler runs whether
		--- the user clicks the menu, fires a gesture, or hits a script-control
		--- key slot. Anything UI-shaped (the bulk-toggle ☑/☐ entries, the
		--- "Reset defaults" entry) lives only in the menu and keeps a
		--- self-explanatory key.
		local actions = {
			-- Menu-only bulk actions (no gesture / shortcut counterpart)
			enable_all                = function() set_all_enabled(true) end,
			disable_all               = function() set_all_enabled(false) end,
			reset_defaults            = function() reset_all_defaults() end,
			-- Aliases used by the menu builder; the canonical ids below remain
			-- the source of truth for gestures / script-control bindings.
			open_paths                = function() hs.timer.doAfter(0.05, function() pcall(MenuPaths.open_editor) end) end,
			reload                    = function() do_reload("menu") end,
			quit                      = function()
				hs.timer.doAfter(0.05, function()
					-- Keep quit responsive: launch cleanup in background and exit.
					pcall(function()
						local ok_k, k = pcall(require, "modules.karabiner")
						local ok_l, kl = pcall(require, "modules.karabiner.ke_lifecycle")
						local ke_enabled = ok_k and k and type(k.get_enabled) == "function" and k.get_enabled() or false
						local _, has_user_ke = hs.execute("/usr/bin/pgrep -x karabiner_console_user_server >/dev/null 2>&1 || /usr/bin/pgrep -x karabiner_session_monitor >/dev/null 2>&1 || /usr/bin/pgrep -x Karabiner-NotificationWindow >/dev/null 2>&1")
						if (ke_enabled or has_user_ke == true) and ok_l and kl and type(kl.run_total_reset_async) == "function" then
							local out, ok = kl.run_total_reset_async()
							Logger.info(LOG, "Quit cleanup KE total reset async: ok=%s out=%s.", tostring(ok), tostring(out))
						end
					end)
					pcall(function() require("ui.menu.menu_llm").stop_mlx_server() end)
					os.exit(0)
				end)
			end,
			open_logs                 = function()
				local dir = logs_dir()
				pcall(hs.execute, string.format("mkdir -p %q && open %q", dir, dir))
			end,
			-- Canonical action ids (mirrored across HS gestures, HS script
			-- control, and the AutoHotkey side):
			open_console              = function() pcall(hs.openConsole) end,
			open_paths_editor         = function() hs.timer.doAfter(0.05, function() pcall(MenuPaths.open_editor) end) end,
			open_hotstrings_editor    = function()
				local ok, ed = pcall(require, "ui.hotstring_editor")
				if ok and type(ed.open) == "function" then pcall(ed.open) end
			end,
			open_metrics_typing       = function()
				local ok, m = pcall(require, "ui.metrics_typing")
				if ok and type(m.toggle) == "function" then pcall(m.toggle) end
			end,
			open_metrics_apps         = function()
				local ok, m = pcall(require, "ui.metrics_apps")
				if ok and type(m.toggle) == "function" then pcall(m.toggle) end
			end,
			open_script_source        = function() pcall(hs.execute, string.format("open \"%sinit.lua\"", base_dir)) end,
			open_personal_shortcuts   = function()
				local ok, ps = pcall(require, "lib.personal_shortcuts")
				if ok and type(ps.open) == "function" then pcall(ps.open) end
			end,
			open_personal_hotstrings  = function() open_path_via_menu("PersonalTomlPath") end,
			open_personal_info        = function() open_path_via_menu("PersonalInfoTomlPath") end,
			open_config               = function() open_path_via_menu("ConfigTomlPath") end,
			open_logs_folder          = function()
				local dir = logs_dir()
				pcall(hs.execute, string.format("mkdir -p %q && open %q", dir, dir))
			end,
			open_today_log            = function()
				local Logger = require("lib.logger")
				local path = Logger.UNIFIED_LOG_FILE
				if type(path) ~= "string" or path == "" then
					path = logs_dir() .. "ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log"
				end
				pcall(hs.execute, string.format("open %q", path))
			end,
			show_setup_wizard         = function()
				local ok, ob = pcall(require, "ui.onboarding")
				if ok and type(ob.run_from_menu) == "function" then
					pcall(ob.run_from_menu, MenuPaths.get("ConfigTomlPath"))
				end
			end,
			set_log_level             = function(level)
				local L = require("lib.logger")
				L.set_level(level)
				pcall(function() hs.settings.set("ergopti.log_level", level) end)
				L.info("menu", "Log level set to %s.", level)
				if type(updateMenu) == "function" then updateMenu() end
			end,
		}

		-- Wire those callbacks into script_control so the right-Alt key slots
		-- and the gesture-driven dispatch share one source of truth.
		if type(core_mods.shortcuts_mod) == "table"
			and type(core_mods.shortcuts_mod.set_extras) == "function" then
			pcall(core_mods.shortcuts_mod.set_extras, actions)
		end

		-- Refresh menu on each click on the icon
		pcall(function()
			myMenu:setMenu(function()
				updateMenu()
				return Builder.generate(ctx, menu_mods, actions)
			end)
		end)
	end

	updateMenu()

	-- Load the user's personal_shortcuts.lua. Done after the menu is built
	-- so any hs.hotkey.bind defined in the user file finds the rest of the
	-- driver fully wired. Errors are caught inside the module so a broken
	-- user file logs to the console without preventing boot.
	pcall(function()
		local ok, ps = pcall(require, "lib.personal_shortcuts")
		if ok and type(ps.load) == "function" then ps.load() end
	end)

	-- Suppress pathwatcher events for the first few seconds after boot.
	-- macOS FSEvents buffers events across process restarts and delivers them
	-- all at once when the new watcher registers — without this window, any
	-- file changes that occurred during the previous (possibly cascading) boot
	-- would immediately trigger another hs.reload(), causing an infinite loop.
	local BOOT_SUPPRESS_SEC = 5
	_suppress_watcher_until = hs.timer.secondsSinceEpoch() + BOOT_SUPPRESS_SEC
	Logger.debug(LOG, "Pathwatcher boot suppression active for %.0f s.", BOOT_SUPPRESS_SEC)

	local configWatcher = MenuWatchers.start_config_watcher(
		base_dir,
		function() do_reload("watcher") end,
		function() return _suppress_watcher_until end,
		ui_restore
	)

	M._menu    = myMenu
	M._watcher = configWatcher

	M._theme_watcher = MenuWatchers.start_theme_watcher(function()
		if type(update_icon) == "function" then update_icon() end
		if type(updateMenu) == "function" then updateMenu() end
	end)

	pcall(notifications.notify, i18n.get("menu.script_ready"), nil, "success")
	return myMenu, configWatcher
end

return M
