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

local Preferences = require("ui.menu.preferences")
local Builder     = require("ui.menu.builder")

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
	gestures   = safe_require("ui.menu.menu_gestures", "gestures menu"),
	shortcuts  = safe_require("ui.menu.menu_shortcuts", "shortcuts menu"),
	hotstrings = safe_require("ui.menu.menu_hotstrings", "hotstrings menu"),
	llm        = safe_require("ui.menu.menu_llm", "AI menu"),
	keylogger  = safe_require("ui.menu.menu_keylogger", "metrics menu"),
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
-- =================================
-- ======= 1/ Core Lifecycle =======
-- =================================
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
function M.start(base_dir, hotfiles, gestures, keymap, dynamic_hotstrings, module_sections)
	base_dir = type(base_dir) == "string" and base_dir or (hs.configdir .. "/")
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
		
		local logo_file = paused and "logo_black.png" or "logo_white.png"
		
		local ok_img, ico = pcall(hs.image.imageFromPath, base_dir .. "images/" .. logo_file)
		
		pcall(function() myMenu:setTitle(custom_text and (" " .. tostring(custom_text)) or "") end)
		
		if ok_img and ico then
			pcall(function() if type(ico.setSize) == "function" then ico:setSize({ w = 18, h = 18 }) end end)
			pcall(function() myMenu:setIcon(ico, false) end)
		elseif not custom_text then
			pcall(function() myMenu:setTitle("🔧") end)
		end
	end

	local function do_reload(source)
		local msg = source == "watcher"
			and "Fichiers modifiés — Rechargement…"
			or  "Rechargement du script…"
		pcall(notifications.notify, msg)
		hs.timer.doAfter(0.25, function() pcall(hs.reload) end)
	end

	local function notify_feature(label, is_enabled)
		pcall(notifications.notify, is_enabled and "🟢 ACTIVÉ" or "🔴 DÉSACTIVÉ", tostring(label))
	end

	local function save_prefs()
		Preferences.save(base_dir .. "config.json", state, hotfiles, core_mods)
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
				local kl = core_mods.keylogger
				if kl and type(kl.show_metrics) == "function" then pcall(kl.show_metrics) end
			end)
			if ok and hk then _metrics_hk = hk; hk:enable() end
		else
			state.metrics_shortcut = false
		end
		save_prefs()
		if type(updateMenu) == "function" then updateMenu() end
	end

	local function sync_state_to_modules(saved, config_absent)
		-- Sync section states
		if type(saved.section_states) == "table" then
			for group_name, secs in pairs(saved.section_states) do
				if type(secs) == "table" then
					for sec_name, sec_enabled in pairs(secs) do
						local key = "hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(sec_name)
						pcall(hs.settings.set, key, sec_enabled == false and false or nil)
					end
				end
			end
		end

		-- Sync terminators
		if type(saved.terminator_states) == "table" then
			for key, enabled in pairs(saved.terminator_states) do
				if keymap and type(keymap.set_terminator_enabled) == "function" then pcall(keymap.set_terminator_enabled, key, enabled) end
			end
		end

		-- Re-register custom terminators created by the user (persisted in state)
		if keymap and type(keymap.add_custom_terminator) == "function" then
			for _, ct in ipairs(type(state.custom_terminators) == "table" and state.custom_terminators or {}) do
				if type(ct) == "table" and ct.key and ct.char then
					pcall(keymap.add_custom_terminator, ct.key, ct.char, ct.label or ct.char, ct.consume or false)
					local enabled_ct = (type(state.terminator_states) == "table" and state.terminator_states[ct.key])
					if enabled_ct ~= nil and type(keymap.set_terminator_enabled) == "function" then
						pcall(keymap.set_terminator_enabled, ct.key, enabled_ct)
					end
				end
			end
		end

		-- Sync delays
		if type(state.expansion_delay) == "number" then
			if keymap and type(keymap.set_base_delay) == "function" then pcall(keymap.set_base_delay, state.expansion_delay) end
		end
		if keymap and type(keymap.set_delay) == "function" then
			local defs = keymap.DELAYS_DEFAULT or {}
			for k, default_val in pairs(defs) do
				pcall(keymap.set_delay, k, state.delays[k] or default_val)
			end
		end

		-- Sync gestures
		if gestures and type(saved.gesture_actions) == "table" then
			for slot, action in pairs(saved.gesture_actions) do 
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, action) end
			end
		end
		if gestures and type(gestures.apply_all_overrides) == "function" then pcall(gestures.apply_all_overrides) end

		-- Sync keymap options
		if keymap then
			local map = {
				{ fn = "set_preview_star_enabled",        val = state.preview_star_enabled },
				{ fn = "set_preview_autocorrect_enabled", val = state.preview_autocorrect_enabled },
				{ fn = "set_preview_ai_enabled",          val = state.preview_ai_enabled },
				{ fn = "set_preview_colored_tooltips",    val = state.preview_colored_tooltips },
				{ fn = "set_llm_after_hotstring",         val = state.llm_after_hotstring },
				{ fn = "set_llm_enabled",                 val = state.llm_enabled },
				{ fn = "set_llm_debounce",                val = state.llm_debounce },
				{ fn = "set_llm_model",                   val = state.llm_model },
				{ fn = "set_trigger_char",                val = state.trigger_char },
				{ fn = "set_llm_context_length",          val = state.llm_context_length },
				{ fn = "set_llm_reset_on_nav",            val = state.llm_reset_on_nav },
				{ fn = "set_llm_temperature",             val = state.llm_temperature },
				{ fn = "set_llm_num_predictions",         val = state.llm_num_predictions },
				{ fn = "set_llm_arrow_nav_enabled",       val = state.llm_arrow_nav_enabled },
				{ fn = "set_llm_nav_modifiers",           val = state.llm_nav_modifiers },
				{ fn = "set_llm_show_info_bar",           val = state.llm_show_info_bar },
				{ fn = "set_llm_val_modifiers",           val = state.llm_val_modifiers },
				{ fn = "set_llm_pred_indent",             val = state.llm_pred_indent },
				{ fn = "set_llm_disabled_apps",           val = state.llm_disabled_apps },
			}
			for _, item in ipairs(map) do
				if type(keymap[item.fn]) == "function" then pcall(keymap[item.fn], item.val) end
			end
		end

		-- Sync editor options
		if type(hotstring_editor.set_trigger_char) == "function"    then pcall(hotstring_editor.set_trigger_char, state.trigger_char) end
		if type(hotstring_editor.set_default_section) == "function" then pcall(hotstring_editor.set_default_section, state.custom_default_section) end
		if type(hotstring_editor.set_close_on_add) == "function"    then pcall(hotstring_editor.set_close_on_add, state.custom_close_on_add) end

		local sc = state.custom_editor_shortcut
		if sc == nil then
			local def = { mods = {"ctrl"}, key = state.trigger_char }
			state.custom_editor_shortcut = def
			if type(hotstring_editor.set_shortcut) == "function" then pcall(hotstring_editor.set_shortcut, def.mods, def.key) end
		elseif type(sc) == "table" and type(sc.mods) == "table" and type(sc.key) == "string" then
			if type(hotstring_editor.set_shortcut) == "function" then pcall(hotstring_editor.set_shortcut, sc.mods, sc.key) end
		end

		if type(state.metrics_shortcut) == "table" then
			apply_metrics_shortcut(state.metrics_shortcut.mods, state.metrics_shortcut.key)
		end

		-- Sync keylogger engine
		local kl = core_mods.keylogger
		if kl then
			if type(kl.set_options) == "function" then
				pcall(kl.set_options, {
					encrypt     = state.keylogger_encrypt,
					menubar     = state.keylogger_menubar_wpm,
					float       = state.keylogger_float_wpm,
					float_graph = state.keylogger_float_graph,
				})
			end
			if type(kl.set_disabled_apps) == "function" then pcall(kl.set_disabled_apps, state.keylogger_disabled_apps or {}) end
			if state.keylogger_enabled then
				if type(kl.start) == "function" then pcall(kl.start, core_mods.shortcuts_mod) end
			else
				if type(kl.stop) == "function" then pcall(kl.stop) end
			end
		end

		-- Start/stop engines
		if keymap then
			if state.keymap then
				if type(keymap.start) == "function" then pcall(keymap.start) end

				-- Recover from a stale paused state when script control is not paused
				local paused = core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.is_paused) == "function" and core_mods.shortcuts_mod.is_paused() or false
				if not paused and type(keymap.is_processing_paused) == "function" and keymap.is_processing_paused() then
					if type(keymap.resume_processing) == "function" then pcall(keymap.resume_processing) end
				end
			else
				if type(keymap.stop) == "function" then pcall(keymap.stop) end
			end
		end
		if gestures then
			if state.gestures then if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end else if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end end
		end
		if core_mods.shortcuts_mod then
			if state.shortcuts then if type(core_mods.shortcuts_mod.start) == "function" then pcall(core_mods.shortcuts_mod.start) end else if type(core_mods.shortcuts_mod.stop) == "function" then pcall(core_mods.shortcuts_mod.stop) end end
		end
		if core_mods.dyn_hot_mod then
			if state.personal_info then if type(core_mods.dyn_hot_mod.enable) == "function" then pcall(core_mods.dyn_hot_mod.enable) end else if type(core_mods.dyn_hot_mod.disable) == "function" then pcall(core_mods.dyn_hot_mod.disable) end end
		end

		-- Sync hotstrings & shortcuts
		if keymap then
			for name, enabled in pairs(state.hotstrings) do
				if enabled then
					if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
					if type(keymap.enable_group) == "function" then pcall(keymap.enable_group, name) end
				else
					if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
				end
			end
		end
		if core_mods.shortcuts_mod and type(saved) == "table" and type(saved.shortcut_keys) == "table" then
			if type(core_mods.shortcuts_mod.enable) == "function" and type(core_mods.shortcuts_mod.disable) == "function" then
				for id, enabled in pairs(saved.shortcut_keys) do
					if enabled then pcall(core_mods.shortcuts_mod.enable, id) else pcall(core_mods.shortcuts_mod.disable, id) end
				end
			end
		end

		if config_absent then save_prefs() end
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

		-- 3. Individual shortcut keys
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
		
		-- 4. Sync engines and Save
		sync_state_to_modules(state, false)
		save_prefs()
		
		notify_feature(enabled and "Toutes les fonctionnalités ont été activées" or "Toutes les fonctionnalités ont été désactivées", enabled)
		if type(updateMenu) == "function" then updateMenu() end
	end

	local function reset_all_defaults()
		-- Delete config.json so that the next startup uses the default module settings
		pcall(os.remove, base_dir .. "config.json")
		pcall(notifications.notify, "↺ Valeurs par défaut réinitialisées — Rechargement…")
		hs.timer.doAfter(0.25, function() pcall(hs.reload) end)
	end



	-- ====================================
	-- ===== 1.3) Final Orchestration =====
	-- ====================================

	pcall(update_icon)

	local saved = Preferences.load(base_dir .. "config.json")
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
		else
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "return_key", "none")
			pcall(core_mods.shortcuts_mod.set_shortcut_action, "backspace",  "none")
		end
		pcall(core_mods.shortcuts_mod.set_extras, {
			open_init = function() hs.timer.doAfter(0, function() _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8; pcall(hs.execute, "open \"" .. base_dir .. "init.lua\"") end) end,
			open_ahk = function()
				hs.timer.doAfter(0, function()
					local path = (state.ahk_source_path ~= "") and state.ahk_source_path or nil
					if not path then path = os.getenv("LOCAL_AHK_PATH") end
					if not path then
						local ok_lf, lf = pcall(io.open, base_dir .. "../hotstrings/.local_ahk_path", "r")
						if ok_lf and lf then
							local raw = lf:read("*a")
							pcall(function() lf:close() end)
							raw = raw:match("^%s*(.-)%s*$")
							if raw ~= "" then path = raw end
						end
					end
					if not path then path = base_dir .. "../autohotkey/ErgoptiPlus.ahk" end
					
					local app_name = hs.execute(string.format("osascript -e 'tell application \"Finder\" to return name of (default application of (info for POSIX file \"%s\"))' 2>/dev/null", path))
					app_name = type(app_name) == "string" and app_name:match("^%s*(.-)%s*$") or ""
					if app_name ~= "" then pcall(hs.execute, string.format("open -a \"%s\" \"%s\"", app_name, path)) else pcall(hs.execute, string.format("open -t \"%s\"", path)) end
				end)
			end,
			open_personal_toml = function()
				hs.timer.doAfter(0, function()
					local custom_path = base_dir .. "custom.toml"
					pcall(hs.execute, "open \"" .. custom_path .. "\"")
				end)
			end,
			trigger_prediction = function() if keymap and type(keymap.trigger_prediction) == "function" then pcall(keymap.trigger_prediction) end end,
			add_hotstring = function() if hotstring_editor and type(hotstring_editor.open) == "function" then pcall(hotstring_editor.open, "shortcut") end end,
			show_metrics = function() if core_mods.keylogger and type(core_mods.keylogger.show_metrics) == "function" then pcall(core_mods.keylogger.show_metrics) end end,
			open_config = function() hs.timer.doAfter(0, function() _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8; pcall(hs.execute, "open \"" .. base_dir .. "config.json\"") end) end,
			open_logs = function() hs.timer.doAfter(0, function() pcall(hs.execute, "open \"" .. base_dir .. "logs\"") end) end,
		})
	end

	updateMenu = function()
		local ctx = {
			state                  = state,
			paused                 = core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.is_paused) == "function" and core_mods.shortcuts_mod.is_paused() or false,
			save_prefs             = save_prefs,
			updateMenu             = updateMenu,
			notify_feature         = notify_feature,
			do_reload              = do_reload,
			applyTriggerChar       = applyTriggerChar,
			get_group_name         = Preferences.get_group_name,
			keymap                 = keymap,
			hotfiles               = hotfiles,
			module_sections        = module_sections,
			hotstring_editor       = hotstring_editor,
			personal_info          = core_mods.dyn_hot_mod,
			gestures               = gestures,
			shortcuts              = core_mods.shortcuts_mod,
			script_control         = core_mods.shortcuts_mod,
			apply_metrics_shortcut = apply_metrics_shortcut,
			llm_handler            = llm_handler,
		}

		local actions = {
			enable_all      = function() set_all_enabled(true) end,
			disable_all     = function() set_all_enabled(false) end,
			reset_defaults  = function() reset_all_defaults() end,
			open_console    = function() pcall(hs.openConsole) end,
			open_init       = function() pcall(hs.execute, string.format("open \"%sinit.lua\"", base_dir)) end,
			open_prefs      = function() pcall(hs.openPreferences) end,
			reload          = function() do_reload("menu") end,
			quit            = function() hs.timer.doAfter(0.1, function() os.exit(0) end) end,
		}

		local items = Builder.generate(ctx, menu_mods, actions)
		pcall(function() myMenu:setMenu(function() return items end) end)
	end

	updateMenu()

	local function reloadConfig(files)
		-- Only reload for code files — config.json and runtime-generated files must never trigger a reload
		if hs.timer.secondsSinceEpoch() < _suppress_watcher_until then return end
		if type(files) == "table" then
			for _, file in pairs(files) do
				if type(file) == "string"
					and (file:match("%.lua$") or file:match("%.html$") or file:match("%.css$") or file:match("%.js$") or file:match("%.toml$"))
					and not file:match("logs/") then
					do_reload("watcher"); return
				end
			end
		end
	end
	
	local ok_w, configWatcher = pcall(hs.pathwatcher.new, base_dir, reloadConfig)
	if ok_w and configWatcher then pcall(function() configWatcher:start() end) else configWatcher = nil end

	M._menu    = myMenu
	M._watcher = configWatcher
	
	M._theme_watcher = hs.distributednotifications.new(function(name)
		if name == "AppleInterfaceThemeChangedNotification" then
			if type(update_icon) == "function" then update_icon() end
			if type(updateMenu) == "function" then updateMenu() end
		end
	end, "AppleInterfaceThemeChangedNotification")
	M._theme_watcher:start()

	pcall(notifications.notify, "Script prêt ! 🚀")
	return myMenu, configWatcher
end

return M
