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
local Manifest         = require("infra.manifest_reader")

local Preferences   = require("infra.preferences")
local Builder       = require("ui.menu.builder")
local HotCounter    = require("ui.menu.hotstring_counter")
local MenuPaths     = require("ui.menu.menu_paths")
local MenuState     = require("ui.menu.menu_state")
local MenuWatchers  = require("ui.menu.menu_watchers")
local TrayMenu      = require("adapters.tray_menu")
local Storage       = require("adapters.storage")
local TimerScheduler = require("adapters.timer_scheduler")
local DeferredWork = require("infra.deferred_work")
local TerminationCoordinator = require("infra.termination_coordinator")
local PreferencesTransaction = require("ui.menu.preferences_transaction")
local SessionDemotions = require("ui.menu.session_demotions")
local ProgramParameterTransaction = require("ui.menu.program_parameter_transaction")
local GlobalActionsTransaction = require("ui.menu.global_actions_transaction")
local RecoverableFileMoves = require("ui.menu.recoverable_file_moves")
local FactoryResetJournal = require("infra.factory_reset_journal")
local DiagnosticSnapshot = require("infra.diagnostic_snapshot")
local BootProfiler = require("infra.boot_profiler")
local ConfigPaths = require("infra.config_paths")
local LogOpeners = require("ui.log_openers")
local ShellRunner = require("adapters.shell_runner")

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

-- config.toml [ui] menubar_icon: its variants and its default are the
-- manifest's. v1 draws the simple glyph, v2 the detailed Ergopti logo.
local MENUBAR_ICON_DEFAULT = Manifest.default_for("ui.menubar_icon")
local MENUBAR_ICON_VARIANTS = {}
for _, variant in ipairs(Manifest.find_entry_by_path("ui.menubar_icon").enum_values) do
	MENUBAR_ICON_VARIANTS[variant] = true
end

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
	tap_holds       = safe_require("ui.menu.menu_tap_holds",    "tap-holds menu"),
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
	local function stop_owned(field, label)
		local watcher = M[field]
		if watcher == nil then return true end
		local ok, result = pcall(function() return watcher:stop() end)
		if not ok or result == false then
			Logger.error(LOG, "%s stop failed; exact capability retained for retry: %s",
				label, tostring(result))
			return false
		end
		M[field] = nil
		return true
	end

	local config_stopped = stop_owned("_watcher", "Menubar config watcher")
	local theme_stopped = stop_owned("_theme_watcher", "Menubar theme watcher")
	-- The automatic update checks own a timer and a wake watcher.
	local checks_stopped = stop_owned("_update_checks", "Automatic update checks")
	if config_stopped and theme_stopped and checks_stopped then
		Logger.debug(LOG, "Menubar watchers stopped.")
		return true
	end
	return false
end

--- Builds the menubar and wires its owners.
--- @param extension_packs table|nil The boot's extension discovery catalogue, whose
---   loaded packs the Hotstrings menu lists under their extension.
--- @param personal_files table|nil Actual boot-loaded personal source records.
--- @param personal_root string|nil Configured route that admitted those sources.
function M.start(base_dir, hotfiles, gestures, keymap, dynamic_hotstrings, module_sections, karabiner, hotfile_paths,
	extension_packs, personal_files, personal_root)
	base_dir = type(base_dir) == "string" and base_dir or (hs.configdir .. "/")
	-- init.lua initializes only the resolver. The editor owns its reload callback
	-- and must be initialized here even when ConfigPaths is already ready.
	if not MenuPaths.is_initialized() then
		MenuPaths.init(base_dir, function()
			return DeferredWork.after(0.25,
				function() pcall(hs.reload) end,
				"menu.reload_after_paths")
		end)
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
	-- group, builds the layout/apps/tap-holds submenus, renders the badge), and
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

	-- Inputs the menubar icon was last rendered for, and whether an unknown
	-- stored variant was already reported. Declared above update_icon: a local
	-- below the closure would bind the nil global instead.
	local _last_icon_key = nil
	local _unknown_icon_reported = false


	local function update_icon(custom_text)
		local shortcuts = core_mods.shortcuts_mod
		local paused    = shortcuts and type(shortcuts.is_paused) == "function" and shortcuts.is_paused() or false

		-- config.toml [ui] menubar_icon, merged into the menu state. A value the
		-- manifest does not list is reported once and drawn as its default.
		local variant = state.menubar_icon
		if not MENUBAR_ICON_VARIANTS[variant] then
			if not _unknown_icon_reported then
				_unknown_icon_reported = true
				Logger.error(LOG, "config.toml [ui] menubar_icon is '%s', not a known variant — drawing %s.",
					tostring(variant), MENUBAR_ICON_DEFAULT)
			end
			variant = MENUBAR_ICON_DEFAULT
		end

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
		if variant == "v1" then
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
			local TARGET = (variant == "v2") and TARGET_COMPLEX or TARGET_SIMPLE
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

	local run_global_exclusive
	local function do_reload(source)
		if type(run_global_exclusive) ~= "function" then return false end
		return run_global_exclusive(
			source == "watcher" and "Watcher reload" or "Reload",
			function()
				local msg = source == "watcher"
					and i18n.get("menu.reloading_files")
					or  i18n.get("menu.reloading")
				local notified, notify_err = pcall(notifications.notify, msg, nil, "info")
				if not notified then
					Logger.warn(LOG, "Reload notification failed: %s.", tostring(notify_err))
				end
				local request_ok, accepted = xpcall(function()
					return TerminationCoordinator.request_reload(source)
				end, debug.traceback)
				if not request_ok then
					Logger.error(LOG, "Reload request from '%s' raised: %s.", tostring(source), tostring(accepted))
				end
				return request_ok and accepted == true
			end)
	end

	local function notify_feature(label, is_enabled)
		-- Every menu feature toggle funnels through here; the toast was its only
		-- trace, so a user log could never say what had been switched and when.
		Logger.info(LOG, "Feature toggled from the menu: '%s' → %s.", tostring(label),
			is_enabled and "enabled" or "disabled")
		local notified, notify_err = pcall(notifications.notify, tostring(label), nil,
			is_enabled and "success" or "error")
		if not notified then
			Logger.warn(LOG, "Feature toggle notification failed: %s.", tostring(notify_err))
		end
	end

	-- Preference callbacks mutate shared tables and runtime engines before they
	-- publish config.toml. Keep the last acknowledged state so a returned or
	-- raised writer failure can reverse the whole user action in place.
	local sync_state_to_modules
	local transactional_save_prefs = nil
	local preference_checkpoint = nil
	local llm_handler = nil
	local base_delay_owner = nil
	local script_chords_owner = nil
	local apply_preference_scope
	local apply_global_scope
	-- Features whose runtime refused the saved value this session: their state
	-- shows the real posture while saves keep the value config.toml holds.
	local session_demotions = SessionDemotions.new()
	-- Set when this session only holds defaults in place of a present config.toml
	-- (corrupt file, or a boot rollback): saving would overwrite the user's file.
	local read_only_reason = nil

	local function save_prefs()
		if type(transactional_save_prefs) ~= "function" then
			Logger.error(LOG, "Preference transaction used before its boot snapshot was seeded.")
			return false
		end
		return run_global_exclusive("Preference save", transactional_save_prefs)
	end



	-- =======================================
	-- ===== 1.2) Module Synchronization =====
	-- =======================================

	--- Delegates an open dashboard close to the module that owns its full runtime.
	--- Only a dashboard the user is looking at is closed: a covered one answers
	--- nil, so the caller opens it and the module presents the open window.
	--- @param module_name string Canonical loaded-module name.
	--- @param label string Diagnostic dashboard label.
	--- @return boolean|nil settled False on refused close, nil when not open or covered.
	local function close_loaded_dashboard(module_name, label)
		local dashboard = package.loaded[module_name]
		if not dashboard or not dashboard._wv then return nil end
		if not require("ui.ui_builder").is_window_focused(dashboard._wv) then return nil end
		if type(dashboard.close) ~= "function" then
			Logger.error(LOG, "%s close transaction is unavailable; exact owner retained.", label)
			return false
		end
		local ok, result = xpcall(dashboard.close, debug.traceback)
		if not ok or result ~= true then
			Logger.error(LOG, "%s close did not commit; module-owned state retained: %s.",
				label, tostring(result))
			return false
		end
		return true
	end

	sync_state_to_modules = function(saved, config_absent, restoring, rollback_modules)
		local committed, report = MenuState.sync_state_to_modules(state, saved, config_absent, {
			keymap                   = keymap,
			apply_llm_enabled         = function(enabled)
				if type(llm_handler) == "table"
					and type(llm_handler.set_llm_preference_runtime) == "function" then
					return llm_handler.set_llm_preference_runtime(enabled) == true
				end
				if keymap and type(keymap.set_llm_enabled) == "function" then
					return keymap.set_llm_enabled(enabled) == true
				end
				return false
			end,
			gestures                 = gestures,
			hotstring_editor         = hotstring_editor,
			core_mods                = rollback_modules or core_mods,
			restoring                 = restoring == true,
			-- A deferred engine refusal (keylogger start) lands after this sync
			-- returned; it keeps the acknowledged value on disk like a boot one.
			on_runtime_demotion      = session_demotions.record,
		})
		-- A rollback re-applies what config.toml already holds, so a feature its
		-- runtime refused on the way back keeps that value on disk, exactly like a
		-- boot refusal. A candidate sync never records: its values are not saved.
		if restoring == true and type(report) == "table" and type(report.demotions) == "table" then
			for _, record in ipairs(report.demotions) do session_demotions.record(record) end
		end
		return committed, report
	end

	local gestures_core_mod = safe_require("modules.gestures", "gestures core")
	local file_mover = RecoverableFileMoves.create()
	local reset_journal_path = FactoryResetJournal.path_for(MenuPaths.get("ConfigTomlPath"))
	local reset_journal, reset_journal_detail = FactoryResetJournal.create(reset_journal_path)
	if type(reset_journal) ~= "table" then
		Logger.error(LOG, "Factory-reset journal owner is unavailable: %s.", tostring(reset_journal_detail))
		return nil
	end
	local script_defaults = core_mods.shortcuts_mod
		and core_mods.shortcuts_mod.DEFAULT_STATE
		and core_mods.shortcuts_mod.DEFAULT_STATE.script_control_shortcuts
	local global_gesture_slots = {}
	local global_gesture_slot_set = {}
	for _, slot in ipairs(gestures_core_mod and gestures_core_mod.SINGLE_SLOTS or {}) do
		global_gesture_slots[#global_gesture_slots + 1] = slot
		global_gesture_slot_set[slot] = true
	end
	for slot in pairs(gestures_core_mod and gestures_core_mod.DEFAULT_GESTURES or {}) do
		if not global_gesture_slot_set[slot] then
			global_gesture_slots[#global_gesture_slots + 1] = slot
			global_gesture_slot_set[slot] = true
		end
	end
	table.sort(global_gesture_slots)

	local global_actions_owner = GlobalActionsTransaction.create({
		state = state,
		capture_preferences = function()
			return Preferences.snapshot(state, hotfiles, core_mods)
		end,
		sync_runtime = function(snapshot, restoring)
			return sync_state_to_modules(snapshot, false, restoring == true) == true
		end,
		restore_state = PreferencesTransaction.restore_table,
		settings = {
			get = Storage.get,
			set = Storage.set,
			get_keys = Storage.keys,
		},
		file_mover = file_mover,
		reset_journal = reset_journal,
		reset_paths = {
			MenuPaths.get("ConfigTomlPath"),
			MenuPaths.get("KarabinerConfigPath"),
		},
		gestures = gestures,
		gesture_slots = global_gesture_slots,
		gesture_defaults = gestures_core_mod and gestures_core_mod.DEFAULT_GESTURES or {},
		shortcuts = core_mods.shortcuts_mod,
		script_defaults = script_defaults,
		karabiner = karabiner,
		request_reload = function(on_aborted)
			return TerminationCoordinator.request_reload_owned(
				"factory_reset", on_aborted)
		end,
		terminal_pending = function()
			return TerminationCoordinator.is_pending()
		end,
	})

	if gestures.configure_program_admission(function()
		return global_actions_owner ~= nil and global_actions_owner.is_pending() == false
	end) ~= true then
		error("Private program admission could not be registered")
	end

	-- The factory reset moves both configuration files aside and reloads. No
	-- menu row runs it since Configuration › « Restore recommended values »
	-- composes the category scopes (apply_global_scope); it stays exported as
	-- actions.factory_reset until it is retired or given an approved row.
	local function reset_all_defaults()
		if not global_actions_owner then
			Logger.error(LOG, "Factory reset transaction owner is unavailable.")
			return false
		end
		return global_actions_owner.reset_defaults()
	end

	run_global_exclusive = function(action_label, callback, retained_owner)
		if not global_actions_owner
			or type(global_actions_owner.run_exclusive) ~= "function" then
			Logger.error(LOG, "%s refused because the global action owner is unavailable.",
				tostring(action_label))
			return false
		end
		return global_actions_owner.run_exclusive(action_label, callback, retained_owner)
	end




	-- ====================================
	-- ===== 1.3) Final Orchestration =====
	-- ====================================

	pcall(update_icon)

	-- Expose a refresh hook so submenus can re-render the menubar icon after
	-- changing a persisted preference (e.g. the menubar icon variant)
	M.refresh_icon = function() pcall(update_icon) end

	-- Quitting applies the pause layout (one input-source setting for pause and
	-- quit). The root teardown awaits it through ui.menu.quit_layout.
	M.apply_quit_layout = function(on_done)
		local kbd_layout_mod = menu_mods.keyboard_layout
		if not kbd_layout_mod or type(kbd_layout_mod.apply_quit_layout) ~= "function" then
			Logger.error(LOG, "Quit layout unavailable: the keyboard-layout menu module is not loaded.")
			return "none"
		end
		return kbd_layout_mod.apply_quit_layout(state, on_done)
	end

	local saved, load_status = Preferences.load(MenuPaths.get("ConfigTomlPath"))
	-- A CORRUPT file must never be treated as absent. Both yield an empty table,
	-- but only "absent" means the user has no settings to lose: it seeds factory
	-- defaults and then saves them, which on a corrupt file overwrites settings
	-- that were still recoverable. Anything that is not positively absent is
	-- therefore treated as present-but-unusable - defaults in memory for this
	-- session, and nothing written back.
	local config_absent = (load_status == "absent") and (next(saved) == nil)
	if load_status == "corrupt" then
		read_only_reason = "config.toml could not be read or decoded at startup"
		Logger.error(LOG, "Preference saves are read-only for this session: %s.", read_only_reason)
	end

	if config_absent then
		for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
			local name = Preferences.get_group_name(f)
			local secs = keymap and type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
			if type(secs) == "table" then
				for _, sec in ipairs(secs) do
					if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
						Storage.delete("hotstrings_section_" .. name .. "_" .. sec.name)
					end
				end
			end
			if keymap then
				if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
				if type(keymap.enable_group) == "function"  then pcall(keymap.enable_group, name) end
			end
		end
	end

	-- Preserve the known-live pre-load posture. A persisted preference can cross
	-- several runtime owners (notably Bindings + KeyboardShortcuts); if one child
	-- refuses, continuing with the merged table would let the menu advertise OFF
	-- while a retained native hotkey remains ON.
	local pre_load_state = PreferencesTransaction.clone(state)
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
	-- Do not ask MenuState to seed config.toml yet: the transaction must first be
	-- initialized from the fully hydrated runtime. This is crucial for the first
	-- user click after boot, before any successful save has occurred.
	local initial_call_ok, initial_sync_ok, initial_report = xpcall(function()
		return sync_state_to_modules(saved, false)
	end, debug.traceback)
	-- A refused owner demotes only its own feature, in memory, and the rest of the
	-- saved configuration stays applied. Restoring every pre-load default for one
	-- refusal showed Gestures, Metrics and AI OFF and let the next toggle write
	-- those defaults over config.toml. Only a refusal whose runtime posture is
	-- unknown, or a sync that raised, still forces the whole rollback below.
	local unisolated_failure = nil
	if not initial_call_ok then
		unisolated_failure = "the synchronization raised: " .. tostring(initial_sync_ok)
	elseif initial_sync_ok ~= true then
		if type(initial_report) ~= "table" or type(initial_report.unsettled) ~= "table"
			or type(initial_report.demotions) ~= "table"
			or type(initial_report.failures) ~= "table" then
			unisolated_failure = "the synchronization returned no feature report"
		elseif #initial_report.unsettled > 0 then
			local features = {}
			for _, entry in ipairs(initial_report.unsettled) do
				features[#features + 1] = tostring(entry.feature)
			end
			unisolated_failure = "unknown runtime posture for " .. table.concat(features, ", ")
		end
	end
	if unisolated_failure then
		Logger.error(LOG,
			"Initial preference synchronization did not complete (%s); restoring pre-load runtime state.",
			unisolated_failure)
		local state_restored = PreferencesTransaction.restore_table(state, pre_load_state)
		local rollback_ok = false
		local rollback_result
		if state_restored == true then
			local rollback_call_ok
			rollback_call_ok, rollback_result = xpcall(function()
				return sync_state_to_modules(pre_load_state, false, true)
			end, debug.traceback)
			rollback_ok = rollback_call_ok and rollback_result == true
		end
		if not rollback_ok then
			Logger.error(LOG,
				"Initial preference rollback did not settle; menubar startup aborted: %s.",
				tostring(rollback_result))
			pcall(TrayMenu.destroy)
			return nil, nil
		end
		Logger.warn(LOG,
			"Persisted preferences were rejected; the pre-load runtime state was restored.")
		if not config_absent then
			read_only_reason = "the saved preferences could not be applied at startup"
			Logger.error(LOG, "Preference saves are read-only for this session: %s.", read_only_reason)
		end
	elseif initial_sync_ok ~= true then
		for _, record in ipairs(initial_report.demotions) do session_demotions.record(record) end
		Logger.warn(LOG,
			"Saved preferences applied except %d refused step(s), isolated to their feature.",
			#initial_report.failures)
	end
	local snapshot_ok, initial_preferences = pcall(Preferences.snapshot, state, hotfiles, core_mods)
	if not snapshot_ok or type(initial_preferences) ~= "table" then
		initial_preferences = PreferencesTransaction.clone(state)
		Logger.error(LOG, "Could not capture the initial runtime preference snapshot: %s.",
			tostring(initial_preferences))
	end
	transactional_save_prefs, preference_checkpoint = PreferencesTransaction.bind(Preferences, {
		path                = MenuPaths.get("ConfigTomlPath"),
		state               = state,
		hotfiles            = hotfiles,
		core_modules        = core_mods,
		builder             = Builder,
		hot_counter         = HotCounter,
		initial_state       = state,
		initial_preferences = initial_preferences,
		snapshot_view       = session_demotions.persisted_view,
		read_only_reason    = function() return read_only_reason end,
		restore_runtime     = function(snapshot)
			if base_delay_owner and base_delay_owner.pending()
				and base_delay_owner.restore_runtime() ~= true then return false end
			local rollback_modules = core_mods
			if script_chords_owner and script_chords_owner.pending() then
				if script_chords_owner.restore_runtime() ~= true then return false end
				rollback_modules = script_chords_owner.rollback_modules(core_mods)
				if type(rollback_modules) ~= "table" then return false end
			end
			if sync_state_to_modules(snapshot, false, true, rollback_modules) ~= true then return false end
			if script_chords_owner and script_chords_owner.pending()
				and script_chords_owner.restore_runtime() ~= true then return false end
			if type(llm_handler) == "table"
				and type(llm_handler.restore_preference_runtime) == "function" then
				return llm_handler.restore_preference_runtime(snapshot) == true
			end
			return true
		end,
		on_commit           = function(_, runtime_snapshot)
			_menu_dirty = true
			-- Only a written change ends a demotion; a refused write rolls it back.
			session_demotions.settle(runtime_snapshot)
		end,
		on_rollback         = function()
			_menu_dirty = true
			if type(schedule_menu_refresh) == "function" then schedule_menu_refresh() end
		end,
	})
	if config_absent and save_prefs() ~= true then
		Logger.error(LOG, "Could not seed the initial preference file.")
	end
	-- Repairs the sync made in memory (quarantined custom terminators) are only
	-- persisted now: the sync itself runs before this transaction exists.
	if not config_absent and not unisolated_failure and type(initial_report) == "table"
		and type(initial_report.repairs) == "table" and #initial_report.repairs > 0
		and save_prefs() ~= true then
		Logger.error(LOG, "Repaired preferences (%s) could not be saved.",
			table.concat(initial_report.repairs, ", "))
	end

	-- The update channel's one owner for this session writes through the same
	-- preferences transaction and tells the launcher's Sparkle feed; the menu
	-- follows its durable changes. The About menu reads it from ctx.channel_owner.
	local channel_owner = nil
	local ok_owner, owner_or_err = pcall(function()
		return require("modules.updater.channel").new({ state = state, save = save_prefs })
	end)
	if ok_owner then
		channel_owner = owner_or_err
		channel_owner.subscribe("menu", function()
			if type(updateMenu) == "function" then updateMenu() end
		end)
	else
		Logger.error(LOG, "The update channel owner could not start: %s.", tostring(owner_or_err))
	end

	-- The automatic update checks are this driver's: the launcher's Sparkle has
	-- no scheduled checks and installs only when the About row is clicked. A
	-- source run has no release to update from.
	local update_checks = nil
	if channel_owner then
		local ok_checks, checks_or_err = pcall(function()
			if require("modules.updater").is_local_source() then return nil end
			local AutoCheck = require("modules.updater.auto_check")
			return AutoCheck.start_session({
				state = state,
				save = save_prefs,
				channel = channel_owner.get,
				is_paused = function()
					local shortcuts_mod = core_mods.shortcuts_mod
					return type(shortcuts_mod) == "table" and type(shortcuts_mod.is_paused) == "function"
						and shortcuts_mod.is_paused() == true
				end,
				on_available = function(release)
					local accepted = AutoCheck.announce(release)
					if type(updateMenu) == "function" then updateMenu() end
					return accepted
				end,
			})
		end)
		if not ok_checks then
			Logger.error(LOG, "The automatic update checks could not start: %s.", tostring(checks_or_err))
		elseif checks_or_err ~= nil then
			update_checks = checks_or_err
			M._update_checks = update_checks
			channel_owner.subscribe("automatic_checks", update_checks.on_channel_changed)
		end
	end

	if menu_mods.llm and type(menu_mods.llm.create) == "function" then
		local ok_h, res = pcall(menu_mods.llm.create, {
			apply_preference_scope = function(scope, mode)
				return type(apply_preference_scope) == "function" and apply_preference_scope(scope, mode) == true
			end,
			state          = state,
			active_tasks   = M._active_tasks,
			update_icon    = update_icon,
			reset_menubar  = reset_menubar,
			-- updateMenu is a forward-declared upvalue assigned later in this file;
			-- the LLM startup path can call ctx.update_menu() during boot BEFORE that
			-- assignment runs, so guard it like every other updateMenu call site.
			-- Without the guard this threw "attempt to call a nil value (upvalue
			-- 'updateMenu')" and the swallowed error silently killed the LLM startup.
			update_menu    = function()
				if type(updateMenu) == "function" then updateMenu() end
				return true
			end,
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

	-- Honour the live pause state once KE's first deploy/prime has settled. The
	-- callback runs four seconds after this code, so capturing the boot-time
	-- `false` would let a pause in that window get overwritten by the resume layout.
	local _, startup_layout_timer_committed = TimerScheduler.after(
		STARTUP_LAYOUT_SWITCH_DELAY_SEC,
		function()
			local kbd_layout_mod = menu_mods.keyboard_layout
			if kbd_layout_mod
				and type(kbd_layout_mod.schedule_pause_layout_switch) == "function" then
				local live_paused = false
				local shortcuts_mod = core_mods.shortcuts_mod
				if shortcuts_mod and type(shortcuts_mod.is_paused) == "function" then
					local ok_pause, paused_or_err = pcall(shortcuts_mod.is_paused)
					if not ok_pause then
						Logger.error(LOG,
							"Startup layout callback could not read live pause state: %s.",
							tostring(paused_or_err))
						return
					end
					live_paused = paused_or_err == true
				end
				local ok_switch, switch_err = pcall(
					kbd_layout_mod.schedule_pause_layout_switch, live_paused, state)
				if not ok_switch then
					Logger.error(LOG, "Startup layout callback raised: %s.", tostring(switch_err))
				end
			end
		end)
	if startup_layout_timer_committed ~= true then
		Logger.error(LOG, "Startup layout switch timer did not commit.")
	end

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
		-- The script chords: every slot's action and the switch, which keeps the
		-- actions when off. Each setter asks Karabiner for the new plan's rules.
		for slot_id, action in pairs(state.script_control_shortcuts) do
			pcall(core_mods.shortcuts_mod.set_shortcut_action, slot_id, action)
		end
		pcall(core_mods.shortcuts_mod.set_script_chords_enabled, state.script_control_enabled == true)
		pcall(core_mods.shortcuts_mod.set_extras, {
			open_init = function()
				return DeferredWork.after(0, function()
					_suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8
					pcall(hs.execute, "open " .. text_utils.shell_quote(base_dir .. "init.lua"))
				end, "menu.open_init")
			end,
			open_personal_toml = function()
				return DeferredWork.after(0, function()
					local personal_path = MenuPaths.get("PersonalTomlPath")
					pcall(hs.execute, "open " .. text_utils.shell_quote(personal_path))
				end, "menu.open_personal_toml")
			end,
			add_hotstring = function()
				-- Toggle: close if open and focused, otherwise open or present it.
				-- A covered editor may hold typed text: bring it back, never close it.
				if hotstring_editor then
					if type(hotstring_editor.is_open) == "function" and hotstring_editor.is_open()
						and type(hotstring_editor.is_editor_focused) == "function"
						and hotstring_editor.is_editor_focused()
					then
						if type(hotstring_editor.close) == "function" then pcall(hotstring_editor.close) end
						return
					end
					if type(hotstring_editor.open) == "function" then pcall(hotstring_editor.open, "shortcut") end
				end
			end,
			show_metrics = function()
				-- Toggle: close if open and focused, otherwise open or present it
				local closed = close_loaded_dashboard(
					"ui.metrics_typing", "Typing dashboard")
				if closed ~= nil then return closed end
				if core_mods.keylogger and type(core_mods.keylogger.show_metrics) == "function" then pcall(core_mods.keylogger.show_metrics) end
			end,
			show_apps_time = function()
				-- Toggle: close if open and focused, otherwise open or present it
				local closed = close_loaded_dashboard(
					"ui.metrics_apps", "Apps dashboard")
				if closed ~= nil then return closed end
				local ok_at, at = pcall(require, "ui.metrics_apps"); if ok_at and type(at.show) == "function" then pcall(at.show, base_dir .. "logs") end
			end,
			open_config = function()
				return DeferredWork.after(0, function()
					_suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8
					pcall(hs.execute, "open " .. text_utils.shell_quote(MenuPaths.get("ConfigTomlPath")))
				end, "menu.open_config")
			end,
			open_logs = function()
				return LogOpeners.open_logs_folder(function(target) return (ShellRunner.open(target)) end)
			end,
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
	-- The Debug log rows open through one owner, shared with the gesture
	-- actions, with the asynchronous Launch Services opener: never a blocking
	-- hs.execute on the run loop that also services the typing event tap.
	local function open_async(target) return (ShellRunner.open(target)) end

	local function open_path_via_menu(key)
		local p = MenuPaths.get(key)
		if type(p) == "string" and p ~= "" then
			pcall(hs.execute, "open " .. text_utils.shell_quote(p))
		end
	end

	local actions = {
		start_at_login            = function()
			return require("ui.menu.start_at_login").request("toggle", function()
				if type(updateMenu) == "function" then updateMenu() end
			end)
		end,
		uninstall                 = function()
			return run_global_exclusive("Uninstall", function()
				return require("ui.menu.uninstall").run()
			end)
		end,
		-- Configuration › « Restore recommended values » and « Clear all »:
		-- every category's own scope owner, composed all or nothing
		-- (ui.menu.global_scope). Neither asks; each owner backs up first.
		reset_defaults            = function()
			return type(apply_global_scope) == "function" and apply_global_scope("recommended") == true
		end,
		clear_to_system           = function()
			return type(apply_global_scope) == "function" and apply_global_scope("clear") == true
		end,
		factory_reset             = function() return reset_all_defaults() end,
		clean_unused_keys         = function()
			return require("ui.menu.unused_keys_cleanup").run_from_menu()
		end,
		open_paths                = function()
			return DeferredWork.after(0.05, MenuPaths.open_editor, "menu.open_paths")
		end,
		reload                    = function()
			return do_reload("menu")
		end,
		quit                      = function()
			-- request_user_exit arms the bounded quit watchdog: once accepted, a stuck
			-- fence, input drain, or teardown force-exits instead of hanging the app.
			local accepted = run_global_exclusive("Quit", function()
				local request_ok, request_accepted = xpcall(function()
					return TerminationCoordinator.request_user_exit("menu_quit")
				end, debug.traceback)
				return request_ok and request_accepted == true
			end)
			if accepted ~= true then
				-- A refusal used to reach only the log, so the user saw Quit do nothing
				Logger.warn(LOG, "Menubar Quit was refused; the user is notified.")
				pcall(notifications.notify, i18n.get("notify.quit_refused"), nil, "error")
			end
			return accepted
		end,
		open_logs                 = function() return LogOpeners.open_logs_folder(open_async) end,
		open_console              = function() return require("ui.console_window").open() end,
		open_paths_editor         = function()
			return DeferredWork.after(0.05, MenuPaths.open_editor, "menu.open_paths_editor")
		end,
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
		open_logs_folder          = function() return LogOpeners.open_logs_folder(open_async) end,
		open_today_log            = function() return LogOpeners.open_today_log(open_async) end,
		open_error_log            = function() return LogOpeners.open_today_errors(open_async) end,
		show_setup_wizard         = function()
			local ok, ob = pcall(require, "ui.onboarding")
			if ok and type(ob.run_from_menu) == "function" then
				pcall(ob.run_from_menu, MenuPaths.get("ConfigTomlPath"))
			end
		end,
		set_log_level             = function(level)
			local L = require("infra.logger")
			local ok, committed = pcall(Storage.set, "log_level", level)
			if not ok or committed ~= true then
				L.warn("menu", "Log level %s was refused by settings; the live level was left unchanged.", level)
				return false
			end
			L.set_level(level)
			L.info("menu", "Log level set to %s.", level)
			-- The menubar tree is cached and only rebuilt when _menu_dirty is set.
			-- Without this the Debug submenu kept showing the previous level and
			-- its checkmark indefinitely — the menu asserting a setting the engine
			-- no longer has.
			_menu_dirty = true
			if type(schedule_menu_refresh) == "function" then schedule_menu_refresh() end
			return true
		end,
		toggle_error_dialog       = function()
			local ErrorDialog = require("ui.error_dialog")
			if not ErrorDialog.set_enabled(not ErrorDialog.is_enabled()) then return end
			-- The tick is part of the cached tree, like the log level's
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
	local gesture_scope = nil
	local scope_generation = 0
	local function gesture_scope_owner()
		if read_only_reason ~= nil or type(gestures) ~= "table" then return nil end
		if not gesture_scope then
			gesture_scope = require("ui.menu.gesture_scope").new({
				path = MenuPaths.get("ConfigTomlPath"), files = require("adapters.file_system"),
				state = state, gestures = gestures, preferences = Preferences, checkpoint = preference_checkpoint,
				demotions = session_demotions,
				capture_preferences = function() return Preferences.snapshot(state, hotfiles, core_mods) end,
				admission = run_global_exclusive,
				paused = function()
					if type(core_mods.shortcuts_mod) ~= "table"
						or type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
					return core_mods.shortcuts_mod.is_paused()
				end,
				backup_path = function()
					scope_generation = scope_generation + 1
					return MenuPaths.get("ConfigTomlPath") .. ".gestures-"
						.. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
				end,
			})
		end
		return gesture_scope
	end
	local function apply_gesture_scope(mode)
		local owner = gesture_scope_owner()
		if not owner then return false end
		local committed = owner.apply(mode)
		if committed == true then
			Builder.invalidate_cache()
			updateMenu()
		end
		return committed
	end
	local metrics_scope = nil
	local layout_scope = nil
	local llm_scope = nil
	local shortcuts_scope = nil
	local hotstrings_scope = nil
	--- The scoped owner of one config.toml category, created on first use, or
	--- nil when this session cannot own it (read-only, or its runtime absent).
	--- @param scope string Manifest scope id.
	--- @return table|nil owner
	local function preference_scope_owner(scope)
		if scope == "shortcuts" then
			if read_only_reason ~= nil or type(core_mods.shortcuts_mod) ~= "table"
				or type(menu_mods.shortcuts) ~= "table"
				or type(menu_mods.shortcuts.scope_idle) ~= "function" then return nil end
			if not shortcuts_scope then
				shortcuts_scope = require("ui.menu.shortcuts_scope").new({
					path = MenuPaths.get("ConfigTomlPath"), files = require("adapters.file_system"),
					state = state, preferences = Preferences, checkpoint = preference_checkpoint,
					demotions = session_demotions, shortcuts = core_mods.shortcuts_mod, gestures = gestures,
					bindings = require("modules.shortcuts.bindings"),
					keyboard = require("modules.shortcuts.keyboard_shortcuts"),
					tap_keys = require("modules.shortcuts.tap_keys"),
					script_control = require("modules.shortcuts.script_control"),
					idle = menu_mods.shortcuts.scope_idle,
					start_script_control = function()
						return core_mods.shortcuts_mod.start_script_control(keymap, core_mods.shortcuts_mod, gestures, karabiner)
					end,
					capture_preferences = function() return Preferences.snapshot(state, hotfiles, core_mods) end,
					admission = run_global_exclusive,
					paused = function()
						if type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
						return core_mods.shortcuts_mod.is_paused()
					end,
					backup_path = function()
						scope_generation = scope_generation + 1
						return MenuPaths.get("ConfigTomlPath") .. ".shortcuts-"
							.. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
					end,
				})
			end
			return shortcuts_scope
		end
		if scope == "llm" then
			if read_only_reason ~= nil or type(llm_handler) ~= "table" or type(llm_handler.scope_runtime) ~= "table" then return nil end
			if not llm_scope then
				llm_scope = require("ui.menu.llm_scope").new({
					path = MenuPaths.get("ConfigTomlPath"), files = require("adapters.file_system"),
					state = state, preferences = Preferences, checkpoint = preference_checkpoint,
					demotions = session_demotions, runtime = llm_handler.scope_runtime, profiles = llm_handler.scope_profiles,
					capture_preferences = function() return Preferences.snapshot(state, hotfiles, core_mods) end,
					admission = run_global_exclusive,
					paused = function()
						if type(core_mods.shortcuts_mod) ~= "table" or type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
						return core_mods.shortcuts_mod.is_paused()
					end,
					backup_path = function()
						scope_generation = scope_generation + 1
						return MenuPaths.get("ConfigTomlPath") .. ".llm-" .. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
					end,
				})
			end
			return llm_scope
		end
		if scope == "metrics" then
			if read_only_reason ~= nil then return nil end
			if not metrics_scope then
				metrics_scope = require("ui.menu.metrics_scope").new({
					path = MenuPaths.get("ConfigTomlPath"), files = require("adapters.file_system"),
					state = state, preferences = Preferences, checkpoint = preference_checkpoint,
					demotions = session_demotions, core = core_mods.keylogger,
					menubar = require("ui.wpm.wpm_menubar"), widget = require("ui.wpm.wpm_widget"),
					script_control = core_mods.shortcuts_mod,
					activation_pending = MenuState.metrics_start_pending,
					capture_preferences = function() return Preferences.snapshot(state, hotfiles, core_mods) end,
					admission = run_global_exclusive,
					paused = function()
						if type(core_mods.shortcuts_mod) ~= "table"
							or type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
						return core_mods.shortcuts_mod.is_paused()
					end,
					backup_path = function()
						scope_generation = scope_generation + 1
						return MenuPaths.get("ConfigTomlPath") .. ".metrics-"
							.. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
					end,
				})
			end
			return metrics_scope
		end
		if scope == "hotstrings" then
			-- The typing engine is the scope's runtime: without it no registry,
			-- delay inventory or scalar owner can acknowledge a candidate.
			if read_only_reason ~= nil or type(keymap) ~= "table" then return nil end
			if not hotstrings_scope then
				local HotstringsConfig = require("modules.hotstrings.hotstrings_config")
				local FileSystem = require("adapters.file_system")
				local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
				hotstrings_scope = require("ui.menu.hotstrings_scope").new({
					path = MenuPaths.get("ConfigTomlPath"), files = FileSystem,
					state = state, preferences = Preferences, checkpoint = preference_checkpoint,
					demotions = session_demotions, keymap = keymap, config = HotstringsConfig,
					dynamic = core_mods.dyn_hot_mod,
					-- The magic-key row updates the editor with the keymap; the scope does too.
					editor = hotstring_editor,
					is_personal = function(name)
						return require("infra.personal_hotstrings").is_personal_group(name)
					end,
					start_engine = function()
						return KeymapLifecycle.ensure_started({ state = state, keymap = keymap }, "hotstrings scope")
					end,
					stop_engine = function() return keymap.stop() == true end,
					remove = function(target) return FileSystem.remove_exact(target) == true end,
					capture_preferences = function() return Preferences.snapshot(state, hotfiles, core_mods) end,
					admission = run_global_exclusive,
					paused = function()
						if type(core_mods.shortcuts_mod) ~= "table"
							or type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
						return core_mods.shortcuts_mod.is_paused()
					end,
					backup_path = function()
						scope_generation = scope_generation + 1
						return MenuPaths.get("ConfigTomlPath") .. ".hotstrings-"
							.. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
					end,
					override_backup_path = function()
						scope_generation = scope_generation + 1
						return HotstringsConfig.get_override_path() .. ".hotstrings-"
							.. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
					end,
				})
			end
			return hotstrings_scope
		end
		if scope ~= "keyboard_layout" then return nil end
		if read_only_reason ~= nil then return nil end
		if not layout_scope then
			layout_scope = require("ui.menu.scoped_preferences").new({
				path = MenuPaths.get("ConfigTomlPath"), files = require("adapters.file_system"),
				scope = scope, state = state, preferences = Preferences, checkpoint = preference_checkpoint,
				runtime = {
					capture = function(_, source) return menu_mods.keyboard_layout.capture_scope(state, source) end,
					apply = function(_, rows) return menu_mods.keyboard_layout.apply_scope(state, rows) end,
					restore = function(snapshot) return menu_mods.keyboard_layout.restore_scope(state, snapshot) end,
				},
				capture_preferences = function() return Preferences.snapshot(state, hotfiles, core_mods) end,
				admission = run_global_exclusive,
				paused = function()
					if type(core_mods.shortcuts_mod) ~= "table"
						or type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
					return core_mods.shortcuts_mod.is_paused()
				end,
				backup_path = function()
					scope_generation = scope_generation + 1
					return MenuPaths.get("ConfigTomlPath") .. ".layout-"
						.. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
				end,
			})
		end
		return layout_scope
	end
	apply_preference_scope = function(scope, mode)
		local owner = preference_scope_owner(scope)
		if not owner then return false end
		local committed = owner.apply(mode)
		if committed == true then
			Builder.invalidate_cache()
			updateMenu()
		end
		return committed
	end
	--- « Restaurer » and « Tout effacer » of the script chords' submenu: the
	--- Shortcuts scope narrowed to the chords, at once and without a question
	--- (the maintainer's decision of 2026-09-30); the clear writes "none" in
	--- every slot, since an absent slot starts with its preset.
	--- @param mode string "recommended" or "clear".
	--- @return boolean committed
	local function apply_script_chords_scope(mode)
		local owner = preference_scope_owner("shortcuts")
		if not owner then return false end
		local committed = owner.apply(mode, require("ui.menu.shortcuts_scope").script_chord_rows)
		if committed == true then
			Builder.invalidate_cache()
			updateMenu()
		end
		return committed
	end
	local global_scope = nil
	apply_global_scope = function(mode)
		if read_only_reason ~= nil then return false end
		if not global_scope then
			local owners = { gestures = gesture_scope_owner }
			for _, scope in ipairs({ "shortcuts", "keyboard_layout", "hotstrings", "llm", "metrics" }) do
				owners[scope] = function() return preference_scope_owner(scope) end
			end
			-- The Hotstrings owner also needs its override file: one it cannot
			-- serve is skipped and named, like an owner this Mac lacks, instead of
			-- refusing every other category with it.
			owners.hotstrings = function()
				local owner = preference_scope_owner("hotstrings")
				if owner == nil then return nil end
				local reason = owner.unavailable()
				if reason ~= nil then
					Logger.warn(LOG, "Global scope skips hotstrings: %s.", tostring(reason))
					return nil
				end
				return owner
			end
			global_scope = require("ui.menu.global_scope").new({
				owners = owners,
				remap = karabiner,
				backup_path = function(scope)
					scope_generation = scope_generation + 1
					return MenuPaths.get("KarabinerConfigPath") .. ".global-" .. scope .. "-"
						.. tostring(hs.timer.absoluteTime()) .. "-" .. scope_generation .. ".bak"
				end,
				defer = function(continuation)
					return DeferredWork.after(0, continuation, "menu.global_scope") == true
				end,
				paused = function()
					if type(core_mods.shortcuts_mod) ~= "table"
						or type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
					return core_mods.shortcuts_mod.is_paused()
				end,
				refresh = function()
					Builder.invalidate_cache()
					updateMenu()
				end,
			})
		end
		return global_scope.apply(mode)
	end
	local function live_pause()
		if type(core_mods.shortcuts_mod) ~= "table"
			or type(core_mods.shortcuts_mod.is_paused) ~= "function" then return nil end
		return core_mods.shortcuts_mod.is_paused()
	end
	-- These owners enter the global writer fence before changing runtime state.
	-- Their save port is the ordinary transaction, avoiding nested admission.
	local preview_owner = require("ui.menu.preview_transaction").new({
		state = state, keymap = keymap, admission = run_global_exclusive,
		paused = live_pause, save_prefs = transactional_save_prefs,
	})
	base_delay_owner = require("ui.menu.base_delay_transaction").new({
		state = state, keymap = keymap, admission = run_global_exclusive,
		paused = live_pause, save_prefs = transactional_save_prefs,
	})
	script_chords_owner = require("ui.menu.script_chords_transaction").new({
		state = state, script_control = core_mods.shortcuts_mod, admission = run_global_exclusive,
		paused = live_pause, save_prefs = transactional_save_prefs,
	})
	local program_parameter_owner = ProgramParameterTransaction.new({
		gestures = gestures, preferences = Preferences, checkpoint = preference_checkpoint,
		path = MenuPaths.get("ConfigTomlPath"), files = require("adapters.file_system"),
		admission = run_global_exclusive, paused = live_pause, save_prefs = transactional_save_prefs,
		current_path = function() return MenuPaths.get("ConfigTomlPath") end,
		capture_checkpoint_candidate = function()
			return { state = PreferencesTransaction.clone(state),
				preferences = Preferences.snapshot(state, hotfiles, core_mods) }
		end,
	})
	local ctx = {
		physical_shortcuts_scope = function() return preference_scope_owner("shortcuts") end,
		physical_shortcuts_paused = live_pause,
		commit_program_parameter = program_parameter_owner.apply,
		apply_gesture_scope = apply_gesture_scope,
		apply_preference_scope = apply_preference_scope,
		apply_script_chords_scope = apply_script_chords_scope,
		base_dir                 = base_dir,
		state                    = state,
		save_prefs               = save_prefs,
		commit_preview           = preview_owner.toggle,
		commit_base_delay        = base_delay_owner.set,
		commit_script_chords     = script_chords_owner.toggle,
		notify_feature           = notify_feature,
		do_reload                = do_reload,
		applyTriggerChar         = applyTriggerChar,
		get_group_name           = Preferences.get_group_name,
		keymap                   = keymap,
		hotfiles                 = hotfiles,
		hotfile_paths            = type(hotfile_paths) == "table" and hotfile_paths or {},
		-- The packs this boot discovered and registered; the counter groups their
		-- loaded categories under each extension from it.
		extension_packs          = extension_packs,
		personal_files           = PreferencesTransaction.clone(personal_files or {}),
		personal_root            = personal_root,
		module_sections          = module_sections,
		hotstring_editor         = hotstring_editor,
		personal_info            = core_mods.dyn_hot_mod,
		gestures                 = gestures,
		shortcuts                = core_mods.shortcuts_mod,
		script_control           = core_mods.shortcuts_mod,
		llm_handler              = llm_handler,
		karabiner                = karabiner,
		channel_owner            = channel_owner,
		update_checks            = update_checks,
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
	push_static_menu = function(items)
		local candidate = items or _cached_menu_items
		if type(candidate) ~= "table" then return false end
		return TrayMenu.setMenu(candidate) == true
	end

	local function rebuild_menu_cache()
		require("ui.menu.start_at_login").request("status", function()
			if type(updateMenu) == "function" then updateMenu() end
		end)
		local t0 = hs.timer.secondsSinceEpoch()
		local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)
		local elapsed_ms = (hs.timer.secondsSinceEpoch() - t0) * 1000
		if ok_b and type(items) == "table" then
			-- The generated tree is only a candidate until AppKit accepts it. Keep
			-- the previous cache and dirty debt on refusal so the live dynamic menu
			-- retries instead of serving a tree the native tray never received.
			if _menu_primed and not push_static_menu(items) then
				_menu_dirty = true
				Logger.error(LOG,
					"Menu tree native push failed (%.1f ms); cache remains dirty.",
					elapsed_ms)
				return false
			end
			_cached_menu_items = items
			_cached_paused     = ctx.paused
			_menu_dirty        = false
			Logger.info(LOG, "Menu tree rebuilt in %.1f ms (%d top-level item(s)).", elapsed_ms, #items)
			return true
		else
			Logger.error(LOG, "Menu tree rebuild failed (%.1f ms): %s.", elapsed_ms, tostring(items))
			return false
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
	local function dynamic_menu_provider()
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
	end
	local installed, accepted_or_err = xpcall(function()
		return TrayMenu.setMenu(dynamic_menu_provider)
	end, debug.traceback)
	if not installed or accepted_or_err ~= true then
		Logger.error(LOG, "Initial native menu publication failed: %s.",
			tostring(accepted_or_err))
		pcall(TrayMenu.destroy)
		return nil, nil
	end

	updateMenu()

	-- Warm the expensive menu-discovery caches off the boot path so the FIRST
	-- click renders instantly. Without this, building the keyboard-layout and
	-- apps submenus on first open would synchronously spawn python3 plus several
	-- directory scans — the dominant cause of slow menubar opens.
	local _, cache_prime_timer_committed = TimerScheduler.after(
		MENU_CACHE_PRIME_DELAY_SEC,
		function()
			-- A failed prime only costs a slower first open, but it used to cost it
			-- silently; the submenu then looked empty with nothing in the log.
			for _prime_index, name in ipairs({ "keyboard_layout", "apps", "tap_holds" }) do
				local mod = menu_mods[name]
				if mod and type(mod.prime) == "function" then
					local primed, prime_err = pcall(mod.prime, ctx)
					if not primed then
						Logger.warn(LOG, "Menu cache prime '%s' failed: %s.", name, tostring(prime_err))
					end
				end
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
			-- The boot sequence is complete by now, and this runs once per session:
			-- the natural point for the one-line environment summary every driver
			-- logs after boot. A probe failure is reported, never allowed to unwind
			-- the menu prime that precedes it.
			local snapshot_ok, snapshot_err = pcall(function()
				local Updater = require("modules.updater")
				DiagnosticSnapshot.emit_once({
					version    = Updater.current_version(),
					boot_ms    = BootProfiler.boot_complete_ms(),
					locale     = i18n.get_locale(),
					config_dir = ConfigPaths.get_config_dir(),
					state      = state,
				})
			end)
			if not snapshot_ok then
				Logger.error(LOG, "Diagnostic snapshot could not be collected: %s.", tostring(snapshot_err))
			end
		end)
	if cache_prime_timer_committed ~= true then
		Logger.error(LOG, "Menu cache-prime timer did not commit.")
	end

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
		function() return do_reload("watcher") end,
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
