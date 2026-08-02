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
local notifications    = require("infra.notifications")
local hotstring_editor = require("ui.hotstring_editor")
local Logger           = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n             = require("infra.i18n")
local ui_restore       = require("infra.ui_restore")

local Preferences   = require("ui.menu.preferences")
local Builder       = require("ui.menu.builder")
local HotCounter    = require("ui.menu.hotstring_counter")
local MenuPaths     = require("ui.menu.menu_paths")
local MenuState     = require("ui.menu.menu_state")
local MenuWatchers  = require("ui.menu.menu_watchers")
local Updater       = require("modules.updater")
local TrayMenu      = require("adapters.tray_menu")

local LOG = "menu"
local load_errors = {}

-- Delay before applying the user's "resume" keyboard layout at startup / reload.
-- The script boots in the active (non-paused) state, so the resume layout should
-- become the active one — but only after KE's first deploy + prime have settled,
-- so the input-source-change rebuild does not race the boot deploy.
local STARTUP_LAYOUT_SWITCH_DELAY_SEC = 4

-- Delay before warming the menu's discovery caches (keyboard-layout HIToolbox
-- probe, apps directory scan). Kept off the boot path so it never delays startup,
-- but soon enough that the first user click on the menubar renders instantly
-- instead of synchronously paying the python3 cold start + directory scans. See
-- ui.menu.menu_keyboard_layout and ui.menu.menu_apps for the cache rationale.
local MENU_CACHE_PRIME_DELAY_SEC = 2

-- Debounce window for coalescing a burst of state changes (each marks the menu
-- dirty) into a single static-menu rebuild on the next tick, instead of one
-- rebuild per change. Short enough to feel immediate, long enough to collapse
-- the rapid updateMenu() calls a single user action can fan out into.
local MENU_REFRESH_COALESCE_SEC = 0.05

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
--- Stops the watchers this module owns.
---
--- The shutdown callback stops everything pinned in _G.script_watchers, but the
--- menubar's config pathwatcher and theme watcher are held here instead — so
--- they could still fire during the Lua-state teardown window, which is exactly
--- the hazard that loop's own comment cites. This module holds the handles, so
--- it is the only place that can stop them.
function M.stop_watchers()
	if M._watcher then
		pcall(function() M._watcher:stop() end)
		M._watcher = nil
	end
	if M._theme_watcher then
		pcall(function() M._theme_watcher:stop() end)
		M._theme_watcher = nil
	end
	Logger.debug(LOG, "Menubar watchers stopped.")
end

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
	TrayMenu.adopt(myMenu)
	Logger.info(LOG, "Menubar created successfully.")

	local updateMenu
	local _suppress_watcher_until = 0

	-- Menu-cache state. Builder.generate() is expensive (counts every hotstring
	-- group, builds the layout/apps/karabiner submenus, renders the badge), and
	-- Hammerspoon evaluates the setMenu callback on EVERY click — so rebuilding it
	-- per click was the ~1 s menu-open latency. We cache the generated tree and
	-- only rebuild when a state change marks it dirty (or the pause state flips),
	-- so the common "open → browse → close" path returns the cached tree instantly.
	local _cached_menu_items = nil
	local _menu_dirty        = true   -- forces the first build; set true on any state change
	local _cached_paused     = false  -- pause state baked into the cached tree
	-- Once the prewarm build has run, the menubar is switched from the dynamic
	-- setMenu(callback) form — which makes Hammerspoon rebuild the NATIVE NSMenu
	-- from the Lua table on EVERY click (the residual open latency) — to a STATIC
	-- prebuilt NSMenu that AppKit reuses, so clicks open instantly. State changes
	-- then re-push the static menu (coalesced) instead of rebuilding per click.
	local _menu_primed       = false
	local _menu_refresh_timer = nil
	-- Forward declarations so updateMenu (assigned below) can schedule a refresh
	-- whose implementation is defined further down.
	local schedule_menu_refresh
	local push_static_menu

	local state = Preferences.build_initial_state(hotfiles, menu_mods, core_mods)



	-- =================================
	-- ===== 1.1) Internal Helpers =====
	-- =================================

	local function applyTriggerChar(text)
		if type(text) ~= "string" then return text end
		-- Single source of truth for the escape (lib.text_utils) rather than a fourth
		-- private copy of the same "%" doubling. Inlined at the use site so the
		-- class guard can see the escape without having to trace a local.
		return (text:gsub("★", text_utils.escape_gsub_replacement(state.trigger_char)))
	end

	-- Inputs the menubar icon was last rendered for. Declared above update_icon:
	-- a local below the closure would bind the nil global instead.
	local _last_icon_key = nil


	local function update_icon(custom_text)
		local shortcuts = core_mods.shortcuts_mod
		local paused    = shortcuts and type(shortcuts.is_paused) == "function" and shortcuts.is_paused() or false

		-- Logo variant is persisted via hs.settings; default is "simple"
		local variant = hs.settings.get("ergopti_menubar_logo_variant") or "simple"

		-- Skip the whole rebuild when nothing that determines the icon changed.
		--
		-- This function reads a PNG off disk, decodes it, and re-renders it
		-- through an off-screen hs.canvas — and the pause listener runs it
		-- SYNCHRONOUSLY inside the script-control eventtap callback, the same tap
		-- that carries the key needed to un-pause. It also ran twice per toggle,
		-- once from the listener and once from the menu refresh that follows.
		-- The icon depends on exactly two inputs; when neither moved there is
		-- nothing to redraw.
		local icon_key = tostring(variant) .. "|" .. tostring(paused)
		if custom_text == nil and icon_key == _last_icon_key then return end
		_last_icon_key = (custom_text == nil) and icon_key or nil

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
		if type(Builder.invalidate_cache) == "function" then Builder.invalidate_cache() end
		if type(HotCounter.invalidate_cache) == "function" then HotCounter.invalidate_cache() end
		-- A persisted preference change (group/section toggle, trigger char, …)
		-- alters the menu tree → force a rebuild on the next open.
		_menu_dirty = true
	end



	-- =======================================
	-- ===== 1.2) Module Synchronization =====
	-- =======================================

	-- Forward-declared so apply_metrics_shortcut and apply_apps_time_shortcut
	-- (defined below) capture these as upvalues rather than seeing global nil.
	local _metrics_hk_box   = {}
	local _apps_time_hk_box = {}

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
	-- by apply_metrics_shortcut / apply_apps_time_shortcut.
	-- (Boxes forward-declared above so apply_metrics/apps_time_shortcut can
	-- capture them as upvalues at definition time.)

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

	local gestures_core_mod = safe_require("modules.gestures", "gestures core")

	local function clear_keyboard_shortcut_settings()
		local prefix = "keyboard_shortcut_"
		local prefix_len = #prefix
		local keys = hs.settings.getKeys() or {}
		for _, k in ipairs(keys) do
			if k:sub(1, prefix_len) == prefix then
				local slot = k:sub(prefix_len + 1)
				if core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.set_keyboard_action) == "function" then
					pcall(core_mods.shortcuts_mod.set_keyboard_action, slot, "none")
				else
					pcall(function() hs.settings.set(k, "none") end)
				end
			end
		end
	end

	local function clear_all_bindings()
		local disabled_action = "none"
		if gestures and gestures_core_mod and type(gestures_core_mod.SINGLE_SLOTS) == "table" then
			for _, slot in ipairs(gestures_core_mod.SINGLE_SLOTS) do
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, disabled_action) end
			end
		end
		if karabiner then
			for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS or {}) do
				pcall(karabiner.set_tap_action,  key_def.id, disabled_action)
				pcall(karabiner.set_hold_action, key_def.id, disabled_action)
			end
			for _, combo_def in ipairs(karabiner.MOD_COMBOS or {}) do
				pcall(karabiner.set_combo_combo_action, combo_def.id, disabled_action)
				pcall(karabiner.set_combo_tap_action,   combo_def.id, disabled_action)
				pcall(karabiner.set_combo_hold_action,  combo_def.id, disabled_action)
			end
			if type(karabiner.regenerate) == "function" then pcall(karabiner.regenerate) end
		end
		clear_keyboard_shortcut_settings()
		if core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.set_shortcut_action) == "function" then
			if type(state.script_control_shortcuts) ~= "table" then state.script_control_shortcuts = {} end
			for _, keyname in ipairs({ "return_key", "backspace", "escape" }) do
				state.script_control_shortcuts[keyname] = disabled_action
				pcall(core_mods.shortcuts_mod.set_shortcut_action, keyname, disabled_action)
			end
		end
	end

	local function restore_factory_bindings()
		if gestures and gestures_core_mod and type(gestures_core_mod.DEFAULT_GESTURES) == "table" then
			for slot, action in pairs(gestures_core_mod.DEFAULT_GESTURES) do
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, action) end
			end
		end
		if karabiner and type(karabiner.reset_to_defaults) == "function" then
			pcall(karabiner.reset_to_defaults)
			if type(karabiner.regenerate) == "function" then pcall(karabiner.regenerate) end
		end
		clear_keyboard_shortcut_settings()
		local sc_defaults = core_mods.shortcuts_mod
			and core_mods.shortcuts_mod.DEFAULT_STATE
			and core_mods.shortcuts_mod.DEFAULT_STATE.script_control_shortcuts
		if sc_defaults and core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.set_shortcut_action) == "function" then
			if type(state.script_control_shortcuts) ~= "table" then state.script_control_shortcuts = {} end
			for keyname, action in pairs(sc_defaults) do
				state.script_control_shortcuts[keyname] = action
				pcall(core_mods.shortcuts_mod.set_shortcut_action, keyname, action)
			end
		end
	end

	local function clear_persisted_binding_overrides()
		clear_keyboard_shortcut_settings()
		pcall(function() hs.settings.set("llm_api_entries", {}) end)
		pcall(function() hs.settings.set("llm_api_entry_id", "") end)
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
		
		-- 5. « Tout désactiver » also empties gesture / shortcut / tap-hold slots.
		if not enabled then
			clear_all_bindings()
		end

		-- 6. Sync engines and Save
		sync_state_to_modules(state, false)
		save_prefs()
		
		notify_feature(enabled and i18n.get("notify.all_features_enabled") or i18n.get("notify.all_features_disabled"), enabled)
		if type(updateMenu) == "function" then updateMenu() end
	end

	local function reset_all_defaults()
		-- Restore the full factory state, not only the config.toml-backed toggles.
		-- Bindings live in several stores: config.toml (gestures, script shortcuts),
		-- config_karabiner.toml (tap/hold), and hs.settings (keyboard shortcuts,
		-- LLM API entries). Wipe every store so the reload seeds factory defaults.
		restore_factory_bindings()
		clear_persisted_binding_overrides()
		pcall(os.remove, MenuPaths.get("ConfigTomlPath"))
		pcall(os.remove, MenuPaths.get("KarabinerConfigPath"))
		-- NO save_prefs() here. It rewrote config.toml from the still-current
		-- in-memory `state`, which restore_factory_bindings does not touch: it
		-- resets bindings only, never the feature toggles. The reload that
		-- follows then found a NON-empty config, so config_absent was false, the
		-- factory-seed branch was skipped, and merge_saved_data re-hydrated every
		-- toggle the user had just asked to reset. Deleting the files and letting
		-- the reload take the config_absent path is what actually seeds defaults;
		-- the two calls above already clear the bindings through their own stores,
		-- which is the job this save_prefs() was added for.
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

	local saved, load_status = Preferences.load(MenuPaths.get("ConfigTomlPath"))
	-- A CORRUPT file must never be treated as absent. Both yield an empty table,
	-- but only "absent" means the user has no settings to lose: it seeds factory
	-- defaults and then saves them, which on a corrupt file overwrites settings
	-- that were still recoverable. Anything that is not positively absent is
	-- therefore treated as present-but-unusable - defaults in memory for this
	-- session, and nothing written back.
	local config_absent = (load_status == "absent") and (next(saved) == nil)

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
	-- Sync the core LLM backend from the just-merged persisted state BEFORE
	-- sync_state_to_modules pushes the model into the engine. sync_state_to_modules
	-- calls set_llm_model / set_llm_enabled, each of which schedules a warmup against
	-- whatever backend the core module currently holds. The LLM handler asserts the
	-- backend later (menu_llm.start), so without this the boot warmup runs against the
	-- DEFAULT backend: an MLX user warms Ollama, the MLX server is never primed, and
	-- predictions only start working after a manual model switch re-asserts the backend.
	if type(state.llm_backend) == "string" and state.llm_backend ~= "" then
		local ok_llm, core_llm = pcall(require, "modules.llm")
		if ok_llm and type(core_llm) == "table" and type(core_llm.set_backend) == "function" then
			pcall(core_llm.set_backend, state.llm_backend)
		end
	end
	sync_state_to_modules(saved, config_absent)

	local llm_handler = nil
	if menu_mods.llm and type(menu_mods.llm.create) == "function" then
		local ok_h, res = pcall(menu_mods.llm.create, {
			state          = state,
			active_tasks   = M._active_tasks,
			update_icon    = update_icon,
			reset_menubar  = reset_menubar,
			-- updateMenu is a forward-declared upvalue assigned later in this file;
			-- the LLM startup path can call ctx.update_menu() during boot BEFORE that
			-- assignment runs, so guard it like every other updateMenu call site.
			-- Without the guard this threw "attempt to call a nil value (upvalue
			-- 'updateMenu')" and the swallowed error silently killed the LLM startup.
			update_menu    = function() if type(updateMenu) == "function" then updateMenu() end end,
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
	if type(hotstring_editor.set_update_menu) == "function" then pcall(hotstring_editor.set_update_menu, function() if type(updateMenu) == "function" then updateMenu() end end) end

	-- At startup / reload the script is in the active (non-paused) state, so honour
	-- the user's chosen "resume" layout the same way a resume would: if the
	-- pause-layout feature is on and a resume layout is configured, make it the
	-- active layout. Deferred so it never blocks boot and runs after KE's first
	-- deploy/prime. schedule_pause_layout_switch(false, …) is a no-op when the
	-- feature is off or no resume layout is set.
	hs.timer.doAfter(STARTUP_LAYOUT_SWITCH_DELAY_SEC, function()
		local kbd_layout_mod = menu_mods.keyboard_layout
		if kbd_layout_mod and type(kbd_layout_mod.schedule_pause_layout_switch) == "function" then
			pcall(kbd_layout_mod.schedule_pause_layout_switch, false, state)
		end
	end)

	if core_mods.shortcuts_mod then
		if type(core_mods.shortcuts_mod.set_on_pause_change) == "function" then
			pcall(core_mods.shortcuts_mod.set_on_pause_change, function(is_paused)
				-- Switch keyboard layout when pausing or resuming, if the feature is enabled.
				-- The switch MUST stay deferred: this callback runs synchronously inside
				-- the script-control eventtap callback, and the switch spawns blocking
				-- osascript subprocesses that would otherwise stall the tap long enough for
				-- macOS to disable it (killing AltGr+Enter). schedule_pause_layout_switch
				-- owns that deferral and the « do nothing » defaults — see its docstring.
				local kbd_layout_mod = menu_mods.keyboard_layout
				if kbd_layout_mod and type(kbd_layout_mod.schedule_pause_layout_switch) == "function" then
					pcall(kbd_layout_mod.schedule_pause_layout_switch, is_paused, state)
				end
				-- updateMenu's first statement is pcall(update_icon), so a bare call
				-- here rendered the icon twice per toggle — off disk, through an
				-- off-screen canvas — from inside the script-control eventtap callback
				-- that carries the key needed to un-pause. Going through updateMenu
				-- also puts the refresh under its pcall, so a throw in the render can
				-- no longer escape this listener.
				updateMenu()
			end)
		end
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
			open_init = function() hs.timer.doAfter(0, function() _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8; pcall(hs.execute, "open " .. text_utils.shell_quote(base_dir .. "init.lua")) end) end,
			open_personal_toml = function()
				hs.timer.doAfter(0, function()
					local personal_path = MenuPaths.get("PersonalTomlPath")
					pcall(hs.execute, "open " .. text_utils.shell_quote(personal_path))
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
			open_config = function() hs.timer.doAfter(0, function() _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8; pcall(hs.execute, "open " .. text_utils.shell_quote(MenuPaths.get("ConfigTomlPath"))) end) end,
			open_logs = function() hs.timer.doAfter(0, function() pcall(hs.execute, "open " .. text_utils.shell_quote(base_dir .. "logs")) end) end,
		})

		-- Wire the active-wrap-pairs getter eagerly at startup so the wrap-selection
		-- eventtap honours the user's persisted per-symbol state from the very first
		-- keystroke. The menubar menu is built lazily (only on click), so without this
		-- the getter stays nil after a fresh launch and bind_wrap_text_if_selected
		-- falls back to the full WRAP_PAIRS catalogue — re-wrapping a symbol the user
		-- had disabled in a previous session until they happened to open the menu once.
		-- The menu re-installs an identical closure when first built, so this is purely
		-- a startup head-start, not a competing source of truth.
		if type(core_mods.shortcuts_mod.set_wrap_pairs_getter) == "function" then
			local ok_txt, text_acts_mod = pcall(require, "modules.shortcuts.actions.text")
			if ok_txt and type(text_acts_mod.build_active_wrap_pairs) == "function" then
				pcall(core_mods.shortcuts_mod.set_wrap_pairs_getter, function()
					return text_acts_mod.build_active_wrap_pairs(
						state.wrap_symbol_states  or {},
						state.custom_wrap_symbols or {}
					)
				end)
			end
		end

		-- Restore the user-configured ChatGPT URL at boot the same way: without this,
		-- ctrl_g silently ignores config.toml and always opens the manifest default
		-- until the user happens to re-save the URL from the menu (shortcuts-ctrl-g-ignores-config).
		if type(core_mods.shortcuts_mod.set_chatgpt_url) == "function" then
			pcall(core_mods.shortcuts_mod.set_chatgpt_url, state.chatgpt_url)
		end
	end

	-- ctx and actions are built once and reused across menu opens.
	-- Fields that must reflect live state (paused) are read inside Builder.generate()
	-- from upvalues (state, core_mods) which are always current.
	local function logs_dir()
		local d = MenuPaths.get_config_dir() or ""
		if not d:match("[/\\]$") then d = d .. "/" end
		return d .. "hammerspoon/logs/"
	end

	local function open_path_via_menu(key)
		local p = MenuPaths.get(key)
		if type(p) == "string" and p ~= "" then
			pcall(hs.execute, "open " .. text_utils.shell_quote(p))
		end
	end

	local actions = {
		enable_all                = function() set_all_enabled(true) end,
		disable_all               = function() set_all_enabled(false) end,
		reset_defaults            = function() reset_all_defaults() end,
		open_paths                = function() hs.timer.doAfter(0.05, function() pcall(MenuPaths.open_editor) end) end,
		reload                    = function() do_reload("menu") end,
		quit                      = function()
			hs.timer.doAfter(0.05, function()
				-- Tear down Karabiner-Elements via karabiner.kill() — the SAME
				-- ownership-respecting path script_quit (modules/gestures/actions.lua)
				-- and hs.shutdownCallback (init.lua) already use. The previous
				-- run_total_reset_async() call bypassed kill()'s is_hs_owned_bridge()
				-- guard entirely, so it could tear down a user-managed KE install that
				-- Hammerspoon never started (F-MED-13).
				pcall(function()
					local ok_kb, karabiner = pcall(require, "modules.karabiner")
					if ok_kb and type(karabiner) == "table" and type(karabiner.kill) == "function" then
						karabiner.kill()
					end
				end)
				pcall(function() require("ui.menu.menu_llm").stop_mlx_server() end)
				-- Full orphan teardown before os.exit — os.exit() bypasses
				-- hs.shutdownCallback so terminate_helper_processes and
				-- terminate_orphan_mlx_server (called there) must be replicated here.
				-- Without this the detached mlx_lm.server + helper daemons survive
				-- indefinitely after a menubar-Quit (M-11 / F-MED-7 missed sibling).
				pcall(function()
					local mlm = require("ui.menu.menu_llm")
					if type(mlm.terminate_helper_processes) == "function" then mlm.terminate_helper_processes() end
					if type(mlm.terminate_orphan_mlx_server) == "function" then mlm.terminate_orphan_mlx_server() end
				end)
				-- Flush keylogger before os.exit() — it bypasses hs.shutdownCallback
				-- where the normal flush lives.
				pcall(function()
					local ok_kl, kl = pcall(require, "modules.keylogger")
					if ok_kl and type(kl) == "table" and type(kl.stop) == "function" then
						kl.stop()
					end
				end)
				os.exit(0)
			end)
		end,
		open_logs                 = function()
			local dir = logs_dir()
			pcall(hs.execute, "mkdir -p " .. text_utils.shell_quote(dir)
				.. " && open " .. text_utils.shell_quote(dir))
		end,
		open_console              = function() pcall(hs.openConsole) end,
		open_paths_editor         = function() hs.timer.doAfter(0.05, function() pcall(MenuPaths.open_editor) end) end,
		open_hotstrings_editor    = function()
			local ok, ed = pcall(require, "ui.hotstring_editor")
			if ok and type(ed.open) == "function" then pcall(ed.open) end
		end,
		-- Both overlays expose show(), never toggle(): the toggle guard below
		-- always failed its type check, so these two entries were silent no-ops.
		open_metrics_typing       = function()
			local ok, m = pcall(require, "ui.metrics_typing")
			if ok and type(m.show) == "function" then pcall(m.show) end
		end,
		open_metrics_apps         = function()
			local ok, m = pcall(require, "ui.metrics_apps")
			if ok and type(m.show) == "function" then pcall(m.show) end
		end,
		open_script_source        = function() pcall(hs.execute, "open " .. text_utils.shell_quote(base_dir .. "init.lua")) end,
		open_personal_shortcuts   = function()
			local ok, ps = pcall(require, "infra.personal_shortcuts")
			if ok and type(ps.open) == "function" then pcall(ps.open) end
		end,
		open_personal_hotstrings  = function() open_path_via_menu("PersonalTomlPath") end,
		open_personal_info        = function() open_path_via_menu("PersonalInfoTomlPath") end,
		open_config               = function() open_path_via_menu("ConfigTomlPath") end,
		open_logs_folder          = function()
			local dir = logs_dir()
			pcall(hs.execute, "mkdir -p " .. text_utils.shell_quote(dir)
				.. " && open " .. text_utils.shell_quote(dir))
		end,
		open_today_log            = function()
			local path = require("infra.logger").UNIFIED_LOG_FILE
			if type(path) ~= "string" or path == "" then
				path = logs_dir() .. "ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log"
			end
			pcall(hs.execute, "open " .. text_utils.shell_quote(path))
		end,
		open_error_log            = function()
			local path = require("infra.logger").ERRORS_LOG_FILE
			if type(path) ~= "string" or path == "" then
				path = logs_dir() .. "ErgoptiPlus_errors_" .. os.date("%Y-%m-%d") .. ".log"
			end
			pcall(hs.execute, "open " .. text_utils.shell_quote(path))
		end,
		show_setup_wizard         = function()
			local ok, ob = pcall(require, "ui.onboarding")
			if ok and type(ob.run_from_menu) == "function" then
				pcall(ob.run_from_menu, MenuPaths.get("ConfigTomlPath"))
			end
		end,
		set_log_level             = function(level)
			local L = require("infra.logger")
			L.set_level(level)
			pcall(function() hs.settings.set("ergopti.log_level", level) end)
			L.info("menu", "Log level set to %s.", level)
			-- The menubar tree is cached and only rebuilt when _menu_dirty is set.
			-- Without this the Debug submenu kept showing the previous level and
			-- its checkmark indefinitely — the menu asserting a setting the engine
			-- no longer has.
			_menu_dirty = true
			if type(schedule_menu_refresh) == "function" then schedule_menu_refresh() end
		end,
	}

	if type(core_mods.shortcuts_mod) == "table"
		and type(core_mods.shortcuts_mod.set_extras) == "function" then
		pcall(core_mods.shortcuts_mod.set_extras, actions)
	end

	-- ctx is a stable table of upvalue references — fields that are mutable at
	-- runtime (state, keymap, …) are already live pointers so the menu always
	-- reads current values without rebuilding the table on every click.
	local ctx = {
		base_dir                 = base_dir,
		state                    = state,
		save_prefs               = save_prefs,
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

	-- updateMenu refreshes the menubar icon and re-wires script_control extras,
	-- then marks the cached menu tree dirty so the NEXT open reflects the change.
	-- It does NOT rebuild synchronously — the rebuild happens lazily, once, on the
	-- next click via the setMenu callback below, keeping toggles lag-free.
	updateMenu = function()
		pcall(update_icon)
		if type(core_mods.shortcuts_mod) == "table"
			and type(core_mods.shortcuts_mod.set_extras) == "function" then
			pcall(core_mods.shortcuts_mod.set_extras, actions)
		end
		_menu_dirty = true
		-- After priming, the menu is static (no per-click callback to lazily
		-- rebuild), so a state change must actively re-push the tree. Coalesced so
		-- a burst of updateMenu() calls collapses into a single rebuild. Before
		-- priming the cold callback still rebuilds on the next open, so we skip.
		if _menu_primed and type(schedule_menu_refresh) == "function" then
			schedule_menu_refresh()
		end
	end

	ctx.updateMenu   = updateMenu
	ctx.refresh_icon = function() pcall(update_icon) end

	-- Rebuilds and caches the full menubar tree, timing the build so a slow menu
	-- is visible in the boot/runtime log (the macOS analog of the AHK menu-build
	-- profiling). ctx.paused is refreshed here because the cached tree bakes the
	-- master-toggle's checked/fn state from it.
	-- Switch the menubar to a STATIC prebuilt NSMenu (built once, reused by AppKit)
	-- so opening it is native-instant. Only meaningful once a tree exists.
	push_static_menu = function()
		if type(_cached_menu_items) ~= "table" then return end
		TrayMenu.setMenu(_cached_menu_items)
	end

	local function rebuild_menu_cache()
		local t0 = hs.timer.secondsSinceEpoch()
		local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)
		local elapsed_ms = (hs.timer.secondsSinceEpoch() - t0) * 1000
		if ok_b and type(items) == "table" then
			_cached_menu_items = items
			_cached_paused     = ctx.paused
			_menu_dirty        = false
			-- Push the freshly built tree as a static native menu once primed so
			-- subsequent opens skip the per-click native rebuild entirely.
			if _menu_primed then push_static_menu() end
			Logger.info(LOG, "Menu tree rebuilt in %.1f ms (%d top-level item(s)).", elapsed_ms, #items)
		else
			Logger.error(LOG, "Menu tree rebuild failed (%.1f ms): %s.", elapsed_ms, tostring(items))
		end
	end
	ctx.rebuild_menu_cache = rebuild_menu_cache

	-- Refresh the static menu now: re-read the live pause state into ctx (the tree
	-- bakes it) and rebuild. Coalesced by schedule_menu_refresh so bursts of state
	-- changes cost a single rebuild on the next tick instead of one per change.
	local function refresh_menu_now()
		ctx.paused = core_mods.shortcuts_mod
			and type(core_mods.shortcuts_mod.is_paused) == "function"
			and core_mods.shortcuts_mod.is_paused() or false
		rebuild_menu_cache()
	end
	schedule_menu_refresh = function()
		if _menu_refresh_timer then return end
		_menu_refresh_timer = hs.timer.doAfter(MENU_REFRESH_COALESCE_SEC, function()
			_menu_refresh_timer = nil
			pcall(refresh_menu_now)
		end)
	end

	-- COLD path only: until the prewarm build primes the static menu (~2 s after
	-- boot), use the dynamic callback so an early click still renders. It rebuilds
	-- on dirty/pause-flip and returns the cache otherwise. Once primed, the prewarm
	-- replaces this with a STATIC native menu (see below) and the callback is never
	-- consulted again — every open is then instant.
	pcall(function()
		TrayMenu.setMenu(function()
			local paused_now = core_mods.shortcuts_mod
				and type(core_mods.shortcuts_mod.is_paused) == "function"
				and core_mods.shortcuts_mod.is_paused() or false
			if _menu_dirty or not _cached_menu_items or paused_now ~= _cached_paused then
				Logger.debug(LOG, "Menu open → cold rebuild (dirty=%s, cache=%s, pause_flip=%s).",
					tostring(_menu_dirty), tostring(_cached_menu_items ~= nil),
					tostring(paused_now ~= _cached_paused))
				ctx.paused = paused_now
				rebuild_menu_cache()
			else
				Logger.debug(LOG, "Menu open → served from cache (cold path).")
			end
			return _cached_menu_items or {}
		end)
	end)

	updateMenu()

	-- Warm the expensive menu-discovery caches off the boot path so the FIRST
	-- click renders instantly. Without this, building the keyboard-layout and
	-- apps submenus on first open would synchronously spawn python3 plus several
	-- directory scans — the dominant cause of slow menubar opens.
	hs.timer.doAfter(MENU_CACHE_PRIME_DELAY_SEC, function()
		if menu_mods.keyboard_layout and type(menu_mods.keyboard_layout.prime) == "function" then
			pcall(menu_mods.keyboard_layout.prime, ctx)
		end
		if menu_mods.apps and type(menu_mods.apps.prime) == "function" then
			pcall(menu_mods.apps.prime, ctx)
		end
		if menu_mods.karabiner and type(menu_mods.karabiner.prime) == "function" then
			pcall(menu_mods.karabiner.prime, ctx)
		end
		-- Now that the expensive submenu caches are warm, build the menu tree once
		-- off the boot path and PRIME the static menu: rebuild_menu_cache() pushes
		-- it as a native NSMenu so the user's FIRST (and every) click opens
		-- instantly, never paying the per-click native rebuild of the callback form.
		ctx.paused = core_mods.shortcuts_mod
			and type(core_mods.shortcuts_mod.is_paused) == "function"
			and core_mods.shortcuts_mod.is_paused() or false
		_menu_primed = true
		rebuild_menu_cache()
	end)

	-- Background update poller — parity with AHK ErgoptiPlus.ahk boot path.
	local update_channel = (type(state.update_channel) == "string" and state.update_channel ~= "")
		and state.update_channel or "dev"
	local update_interval = tonumber(state.update_check_interval_seconds) or Updater.get_check_interval()
	Updater.start_background_checks(update_channel, update_interval, updateMenu)

	-- Load the user's personal_shortcuts.lua. Done after the menu is built
	-- so any hs.hotkey.bind defined in the user file finds the rest of the
	-- driver fully wired. Errors are caught inside the module so a broken
	-- user file logs to the console without preventing boot.
	pcall(function()
		local ok, ps = pcall(require, "infra.personal_shortcuts")
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

	-- The same exclusion list infra/file_watchers already receives. Two recursive
	-- watchers cover this tree and only that one was using it.
	local configWatcher = MenuWatchers.start_config_watcher(
		base_dir,
		function() do_reload("watcher") end,
		function() return _suppress_watcher_until end,
		ui_restore,
		{ (hs.configdir or ".") .. "/cache" },
		-- Resolved from MenuPaths, exactly as infra/file_watchers resolves the same
		-- two, so the watcher and the writers cannot disagree about where they are.
		-- Both files are rewritten by the driver itself — config.toml on every
		-- persisted preference change, the Karabiner config on every regenerate —
		-- and this is the second recursive watcher on the same tree. The other one
		-- has always been given this list; this one was not, so under a layout where
		-- the config directory sits inside base_dir a menu toggle read as a source
		-- edit and armed a reload.
		{
			MenuPaths.get("ConfigTomlPath"),
			MenuPaths.get("KarabinerConfigPath"),
		}
	)

	M._menu    = myMenu
	M._watcher = configWatcher

	M._theme_watcher = MenuWatchers.start_theme_watcher(function()
		-- updateMenu refreshes the icon itself, so the bare call was the same double
		-- render as the pause listener's. And the icon does not depend on the system
		-- theme in the first place: the variant is chosen from `paused` alone and it
		-- is pushed with setIcon(icon, false) — the non-template form, so macOS never
		-- re-tints it for light or dark either. What a theme change actually needs is
		-- the menu rebuild below.
		if type(updateMenu) == "function" then updateMenu() end
	end)

	-- No "script ready" notification: boot is now ~1 s (like the AHK driver), so a
	-- per-launch banner is pure noise. Notifications are reserved for things the
	-- user genuinely needs to act on or wait for — LLM and Karabiner.
	return myMenu, configWatcher
end

return M
