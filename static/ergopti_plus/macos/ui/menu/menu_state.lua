--- ui/menu/menu_state.lua

--- ==============================================================================
--- MODULE: Menu State
--- DESCRIPTION:
--- Manages the mutable UI context (ctx) consumed by the menu builder and all
--- sub-menu modules. Centralises ctx construction and update logic that was
--- previously scattered across init.lua.
---
--- FEATURES & RATIONALE:
--- 1. Single Responsibility: init.lua stays focused on lifecycle; state lives here.
--- 2. Testability: context assembly is isolated from OS callbacks.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("infra.logger")
local DeferredWork = require("infra.deferred_work")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local LOG    = "menu_state"

-- Delay before starting the keylogger engine. Its start (~1.3 s of SQLite +
-- log-rotation work) only feeds typing metrics, so it is deferred off the boot
-- critical path; a sub-second gap of unlogged keystrokes after boot is harmless.
local KEYLOGGER_START_DELAY_SEC = 0.5
local _keylogger_start_generation = 0






-- ==========================================
-- ==========================================
-- ======= 1/ Module State Sync Logic =======
-- ==========================================
-- ==========================================

--- Synchronises the loaded state table back into all engine modules.
--- Called once at startup after preferences are loaded, and after a reset.
--- @param state table The current mutable state table.
--- @param saved table The raw saved preferences table.
--- @param config_absent boolean True when no config file was found on disk.
--- @param deps table Dependency bag: { keymap, gestures, hotstring_editor, core_mods, save_prefs, apply_metrics_shortcut, apply_apps_time_shortcut, _metrics_hk_ref, _apps_time_hk_ref }.
function M.sync_state_to_modules(state, saved, config_absent, deps)
	local sync_failed = false

	--- Calls a runtime setter under pcall and records any raised failure.
	--- Successful setters may return nil; only a thrown error breaks the sync contract.
	--- @param label string Human-readable description for the warning.
	--- @param fn function|nil Function to call, or nil when the dependency is optional.
	--- @param ... any Arguments forwarded to fn.
	--- @return boolean completed True unless the setter raised.
	local function try(label, fn, ...)
		if type(fn) ~= "function" then return true end
		local ok, err = pcall(fn, ...)
		if not ok then
			sync_failed = true
			Logger.warn(LOG, "sync_state_to_modules: %s failed — %s", label, tostring(err))
		end
		return ok, err
	end

	--- Calls a lifecycle method whose contract requires an exact true result.
	--- @param label string Human-readable description for the warning.
	--- @param fn function|nil Required lifecycle method.
	--- @param ... any Arguments forwarded to fn.
	--- @return boolean committed True only after exact runtime commitment.
	local function try_exact(label, fn, ...)
		if type(fn) ~= "function" then
			sync_failed = true
			Logger.warn(LOG, "sync_state_to_modules: %s is unavailable.", label)
			return false
		end
		local ok, result_or_err = pcall(fn, ...)
		if not ok or result_or_err ~= true then
			sync_failed = true
			Logger.warn(LOG, "sync_state_to_modules: %s did not commit — %s",
				label, tostring(result_or_err))
			return false
		end
		return true
	end

	local keymap           = deps.keymap
	local gestures         = deps.gestures
	local hotstring_editor = deps.hotstring_editor
	local core_mods        = deps.core_mods
	local save_prefs       = deps.save_prefs
	local apply_llm_enabled = deps.apply_llm_enabled
	local apply_metrics_shortcut   = deps.apply_metrics_shortcut
	local apply_apps_time_shortcut = deps.apply_apps_time_shortcut

	-- Sync section states
	-- WHY explicit if/else: in Lua, both `false` and `nil` are falsy, so the
	-- `cond and false or nil` idiom evaluates to `nil` even when sec_enabled
	-- is `false` (silently re-enabling sections the user had disabled)
	if type(saved.section_states) == "table" then
		for group_name, secs in pairs(saved.section_states) do
			if type(secs) == "table" then
				for sec_name, sec_enabled in pairs(secs) do
					local key = "hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(sec_name)
					if sec_enabled == false then
						try("hs.settings.set " .. key, hs.settings.set, key, false)
					else
						try("hs.settings.set " .. key, hs.settings.set, key, nil)
					end
				end
			end
		end
	end

	-- Sync terminators
	if type(saved.terminator_states) == "table" then
		for key, enabled in pairs(saved.terminator_states) do
			if keymap and type(keymap.set_terminator_enabled) == "function" then try("keymap.set_terminator_enabled", keymap.set_terminator_enabled, key, enabled) end
		end
	end

	-- Re-register custom terminators created by the user (persisted in state)
	if keymap and type(keymap.add_custom_terminator) == "function" then
		local desired_custom = {}
		for _, ct in ipairs(type(state.custom_terminators) == "table" and state.custom_terminators or {}) do
			if type(ct) == "table" and type(ct.key) == "string" then desired_custom[ct.key] = true end
		end
		if type(keymap.get_terminator_defs) == "function"
			and type(keymap.remove_custom_terminator) == "function" then
			local defs = keymap.get_terminator_defs()
			for index = #(type(defs) == "table" and defs or {}), 1, -1 do
				local def = defs[index]
				if type(def) == "table" and def.custom == true and not desired_custom[def.key] then
					try("keymap.remove_custom_terminator", keymap.remove_custom_terminator, def.key)
				end
			end
		end
		for _, ct in ipairs(type(state.custom_terminators) == "table" and state.custom_terminators or {}) do
			if type(ct) == "table" and ct.key and ct.char then
				try("keymap.add_custom_terminator", keymap.add_custom_terminator, ct.key, ct.char, ct.label or ct.char, ct.consume or false)
				-- Resolved from the persisted states rather than read off an
				-- undefined global. `enabled_ct` was never assigned anywhere, so it
				-- was always nil and this branch never ran: a custom terminator the
				-- user had DISABLED came back enabled on every restart. It has to be
				-- re-applied here and not by the terminator_states loop above,
				-- because that loop runs before add_custom_terminator has created
				-- the key it would be setting.
				local enabled_ct = type(saved.terminator_states) == "table"
					and saved.terminator_states[ct.key] or nil
				if enabled_ct ~= nil and type(keymap.set_terminator_enabled) == "function" then
					try("keymap.set_terminator_enabled", keymap.set_terminator_enabled, ct.key, enabled_ct)
				end
			end
		end
	end

	-- Sync delays — resolution chain (highest priority first):
	--   1. legacy `state.delays[k]` (loaded from config.json) — kept for
	--      users upgrading from a version that wrote delays there.
	--   2. `hotstrings_config.resolve(category).delay` for TOML-backed keys —
	--      this is the new authoritative source (TOML metadata + user override).
	--   3. `keymap.DELAYS_DEFAULT[k]` — ultimate hardcoded fallback.
	if type(state.expansion_delay) == "number" then
		if keymap and type(keymap.set_base_delay) == "function" then try("keymap.set_base_delay", keymap.set_base_delay, state.expansion_delay) end
	end
	if keymap and type(keymap.set_delay) == "function" then
		local defs       = keymap.DELAYS_DEFAULT or {}
		local key_to_cat = keymap.DELAY_KEY_TO_CATEGORY or {}
		local ok_cfg, hs_cfg = pcall(require, "modules.hotstrings.hotstrings_config")
		if not ok_cfg then hs_cfg = nil end
		for k, default_val in pairs(defs) do
			local resolved = nil
			if hs_cfg and key_to_cat[k] then
				local r = hs_cfg.resolve(key_to_cat[k], nil)
				if r and type(r.delay) == "number" then resolved = r.delay end
			end
			try("keymap.set_delay " .. k, keymap.set_delay, k, state.delays[k] or resolved or default_val)
		end
	end

	-- Sync gestures
	if gestures and type(saved.gesture_actions) == "table" then
		for slot, action in pairs(saved.gesture_actions) do
			if type(gestures.set_action) == "function" then try("gestures.set_action", gestures.set_action, slot, action) end
		end
	end
	if gestures and type(saved.gesture_action_parameters) == "table"
		and type(gestures.set_action_parameter) == "function" then
		for key, value in pairs(saved.gesture_action_parameters) do
			local binding, action
			if type(gestures.split_action_parameter_key) == "function" then
				binding, action = gestures.split_action_parameter_key(key)
			end
			if binding and action then
				try("gestures.set_action_parameter", gestures.set_action_parameter, binding, action, value)
			end
		end
	end
	if gestures and type(gestures.apply_all_overrides) == "function" then try("gestures.apply_all_overrides", gestures.apply_all_overrides) end

	-- Restore the backend/profile/model identity before keymap LLM setters. Those
	-- setters may schedule warmup work immediately, so reversing this order would
	-- dispatch the acknowledged model through the just-rejected backend.
	local llm = core_mods and core_mods.llm
	local llm_identity_committed = true
	if llm then
		local identity_map = {
			{ fn = "set_backend",        val = state.llm_backend },
			{ fn = "set_user_profiles",  val = state.llm_user_profiles },
			{ fn = "set_active_profile", val = state.llm_active_profile },
			{ fn = "set_llm_model_ollama", val = state.llm_model_ollama },
			{ fn = "set_llm_model_mlx",    val = state.llm_model_mlx },
		}
		for _, item in ipairs(identity_map) do
			if not try_exact("llm." .. item.fn, llm[item.fn], item.val) then
				llm_identity_committed = false
				break
			end
		end
		if llm_identity_committed and type(llm.set_llm_streaming) == "function" then
			try("llm.set_llm_streaming", llm.set_llm_streaming, state.llm_streaming)
		end
	end

	-- Sync keymap options
	if keymap and llm_identity_committed then
		local keymap_identity_committed = try_exact(
			"keymap.set_llm_model", keymap.set_llm_model, state.llm_model)
		local llm_enabled_setter = type(apply_llm_enabled) == "function"
			and apply_llm_enabled or keymap.set_llm_enabled
		if keymap_identity_committed and type(llm_enabled_setter) == "function" then
			keymap_identity_committed = try_exact(
				"keymap.set_llm_enabled", llm_enabled_setter, state.llm_enabled)
		end
		if keymap_identity_committed then
			local backend_labels = { mlx = "MLX 🚀", ollama = "Ollama 🦙", api = "API 🌐" }
			local map = {
			{ fn = "set_preview_star_enabled",        val = state.preview_star_enabled },
			{ fn = "set_preview_autocorrect_enabled", val = state.preview_autocorrect_enabled },
			{ fn = "set_preview_ai_enabled",          val = state.preview_ai_enabled },
			{ fn = "set_preview_colored_tooltips",    val = state.preview_colored_tooltips },
			{ fn = "set_llm_after_hotstring",         val = state.llm_after_hotstring },
			{ fn = "set_llm_auto_raise_temp",         val = state.llm_auto_raise_temp },
			{ fn = "set_llm_debounce",                val = state.llm_debounce },
			{ fn = "set_llm_backend_name",            val = backend_labels[state.llm_backend] or state.llm_backend },
			{ fn = "set_llm_display_model_name",      val = state.llm_model },
			{ fn = "set_trigger_char",                val = state.trigger_char },
			{ fn = "set_llm_context_length",          val = state.llm_context_length },
			{ fn = "set_llm_reset_on_nav",            val = state.llm_reset_on_nav },
			{ fn = "set_llm_temperature",             val = state.llm_temperature },
			{ fn = "set_llm_max_words",               val = state.llm_max_words },
			{ fn = "set_llm_min_words",               val = state.llm_min_words },
			{ fn = "set_llm_num_predictions",         val = state.llm_num_predictions },
			{ fn = "set_llm_sequential_mode",         val = state.llm_sequential_mode },
			{ fn = "set_llm_streaming",               val = state.llm_streaming },
			{ fn = "set_llm_streaming_multi",         val = state.llm_streaming_multi },
			{ fn = "set_llm_arrow_nav_enabled",       val = state.llm_arrow_nav_enabled },
			{ fn = "set_llm_nav_modifiers",           val = state.llm_nav_modifiers },
			{ fn = "set_llm_show_info_bar",           val = state.llm_show_info_bar },
			{ fn = "set_llm_val_modifiers",           val = state.llm_val_modifiers },
			{ fn = "set_llm_pred_indent",             val = state.llm_pred_indent },
			{ fn = "set_llm_disabled_apps",           val = state.llm_disabled_apps },
			{ fn = "set_llm_url_bar_filter_enabled",      val = state.llm_url_bar_filter_enabled },
			{ fn = "set_llm_secure_field_filter_enabled", val = state.llm_secure_field_filter_enabled },
			{ fn = "set_llm_instant_on_word_end",         val = state.llm_instant_on_word_end },
			}
			for _, item in ipairs(map) do
				if type(keymap[item.fn]) == "function" then
					try("keymap." .. item.fn, keymap[item.fn], item.val)
				end
			end
		end
	end
	-- Several LLM editors also mirror these values in hs.settings. Restore that
	-- secondary runtime store from the same acknowledged snapshot so a failed
	-- config.toml publication cannot survive as a plist-only preference.
	for _, key in ipairs({
		"llm_debounce", "llm_max_words", "llm_min_words", "llm_temperature",
		"llm_context_length", "llm_pred_indent", "llm_nav_modifiers", "llm_val_modifiers",
	}) do
		if state[key] ~= nil then try("hs.settings.set " .. key, hs.settings.set, key, state[key]) end
	end

	-- Sync editor options
	if type(hotstring_editor.set_trigger_char) == "function"    then try("hotstring_editor.set_trigger_char", hotstring_editor.set_trigger_char, state.trigger_char) end
	if type(hotstring_editor.set_default_section) == "function" then try("hotstring_editor.set_default_section", hotstring_editor.set_default_section, state.custom_default_section) end
	if type(hotstring_editor.set_close_on_add) == "function"    then try("hotstring_editor.set_close_on_add", hotstring_editor.set_close_on_add, state.custom_close_on_add) end

	-- Sync the dynamic-hotstrings RulesEngine's trigger char too — without this
	-- it only ever sees the value captured once at boot, orphaning every
	-- date/prefix rule from a magic-key change made via the menu (F-HIGH-8 fix).
	local dyn_hot_mod = core_mods and core_mods.dyn_hot_mod
	if dyn_hot_mod and type(dyn_hot_mod.set_trigger_char) == "function" then
		try("dyn_hot_mod.set_trigger_char", dyn_hot_mod.set_trigger_char, state.trigger_char)
	end

	local sc = state.custom_editor_shortcut
	if sc == nil then
		local def = { mods = {"ctrl"}, key = state.trigger_char }
		state.custom_editor_shortcut = def
		if type(hotstring_editor.set_shortcut) == "function" then
			try_exact("hotstring_editor.set_shortcut", hotstring_editor.set_shortcut, def.mods, def.key)
		end
	elseif type(sc) == "table" and type(sc.mods) == "table" and type(sc.key) == "string" then
		if type(hotstring_editor.set_shortcut) == "function" then
			try_exact("hotstring_editor.set_shortcut", hotstring_editor.set_shortcut, sc.mods, sc.key)
		end
	elseif sc == false and type(hotstring_editor.clear_shortcut) == "function" then
		try_exact("hotstring_editor.clear_shortcut", hotstring_editor.clear_shortcut)
	end

	if type(apply_metrics_shortcut) == "function" then
		if type(state.metrics_shortcut) == "table" then
			apply_metrics_shortcut(state.metrics_shortcut.mods, state.metrics_shortcut.key, false)
		else
			apply_metrics_shortcut(nil, nil, false)
		end
	end
	if type(apply_apps_time_shortcut) == "function" then
		if type(state.apps_time_shortcut) == "table" then
			apply_apps_time_shortcut(state.apps_time_shortcut.mods, state.apps_time_shortcut.key, false)
		else
			apply_apps_time_shortcut(nil, nil, false)
		end
	end
	-- Re-enable after a brief warm-up delay: on the very first presses after
	-- a Hammerspoon restart the event tap may not be fully live, so the first
	-- call above registers the hotkey and this second enable() ensures it is
	-- active once the tap is stable. 0.1s is enough — the event tap is live
	-- well before 1s in practice; the original 1.0s was unnecessarily long.
	DeferredWork.after(0.1, function()
		if deps._metrics_hk and deps._metrics_hk[1] then try("metrics_hotkey:enable", function() deps._metrics_hk[1]:enable() end) end
		if deps._apps_time_hk and deps._apps_time_hk[1] then try("apps_time_hotkey:enable", function() deps._apps_time_hk[1]:enable() end) end
	end, "menu_state.hotkey_warmup")

	-- Sync keylogger engine
	local kl = core_mods.keylogger
	if kl then
		_keylogger_start_generation = _keylogger_start_generation + 1
		local keylogger_generation = _keylogger_start_generation
		if type(kl.set_options) == "function" then
			try("keylogger.set_options", kl.set_options, {
				encrypt     = state.keylogger_encrypt,
				menubar     = state.keylogger_menubar_wpm,
				float       = state.keylogger_float_wpm,
				float_graph = state.keylogger_float_graph,
			})
		end
		if type(kl.set_disabled_apps) == "function" then try("keylogger.set_disabled_apps", kl.set_disabled_apps, state.keylogger_disabled_apps or {}) end
		if type(kl.set_private_filter_enabled) == "function" then
			try("keylogger.set_private_filter_enabled", kl.set_private_filter_enabled,
				state.keylogger_private_filter_enabled)
		end
		if type(kl.set_secure_field_filter_enabled) == "function" then
			try("keylogger.set_secure_field_filter_enabled", kl.set_secure_field_filter_enabled,
				state.keylogger_secure_filter_enabled)
		end
		if type(kl.set_system_auth_filter_enabled) == "function" then
			try("keylogger.set_system_auth_filter_enabled", kl.set_system_auth_filter_enabled,
				state.keylogger_system_auth_filter_enabled)
		end
		if state.keylogger_enabled then
			-- Keylogger start is the single biggest boot cost (~1.3 s: SQLite open,
			-- log-rotation offset replay, export setup). It only feeds typing
			-- METRICS, so missing the first fraction of a second of keystrokes is
			-- harmless — defer it off the boot critical path so the menubar/UI become
			-- interactive ~1.3 s sooner. The shortcuts ref is captured for the closure.
			local _shortcuts_ref = core_mods.shortcuts_mod
			DeferredWork.after(KEYLOGGER_START_DELAY_SEC, function()
				if keylogger_generation ~= _keylogger_start_generation then return end
				if type(kl.start) ~= "function" then return end
				local _t_kl = hs.timer.secondsSinceEpoch()
				local start_ok, started = try("keylogger.start", kl.start, _shortcuts_ref)
				if not start_ok or started ~= true then
					state.keylogger_enabled = false
					sync_failed = true
					local persist_ok, persisted = pcall(save_prefs)
					if not persist_ok or persisted ~= true then
						Logger.error(LOG, "Deferred keylogger start failed and its disabled rollback could not be persisted.")
					end
					Logger.error(LOG, "Deferred keylogger start was rejected; Metrics remains disabled.")
				end
				Logger.info(LOG, "Keylogger engine start (deferred): %.1f ms.",
					(hs.timer.secondsSinceEpoch() - _t_kl) * 1000)
			end, "menu_state.keylogger_start")
		else
			if type(kl.stop) == "function" then
				local stop_ok, stopped = try("keylogger.stop", kl.stop)
				if not stop_ok or stopped ~= true then
					Logger.error(LOG, "Keylogger is disabled, but native lifecycle cleanup remains pending.")
				end
			end
		end
	end
	local cipher_ok, TextCipher = pcall(require, "modules.keylogger.text_cipher")
	if cipher_ok and type(TextCipher) == "table" and type(TextCipher.set_enabled) == "function" then
		try("keylogger.text_cipher.set_enabled", TextCipher.set_enabled, state.keylogger_encrypt)
	end

	-- Start/stop engines
	if keymap then
		if state.keymap then
			local _t_km = hs.timer.secondsSinceEpoch()
			if not KeymapLifecycle.ensure_started({ state = state, keymap = keymap },
				"synchronize menu state") then
				state.keymap = false
			end
			Logger.info(LOG, "Keymap engine start: %.1f ms.", (hs.timer.secondsSinceEpoch() - _t_km) * 1000)

			-- Recover from a stale paused state when script control is not paused
			local paused = core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.is_paused) == "function" and core_mods.shortcuts_mod.is_paused() or false
			if not paused and type(keymap.is_processing_paused) == "function" and keymap.is_processing_paused() then
				if type(keymap.resume_processing) == "function" then try("keymap.resume_processing", keymap.resume_processing) end
			end
		else
			if type(keymap.stop) == "function" then try("keymap.stop", keymap.stop) end
		end
	end
	if gestures then
		local desired_gestures = state.gestures == true
		local gesture_lifecycle = desired_gestures
			and gestures.enable_all or gestures.disable_all
		local gesture_committed = try_exact(
			desired_gestures and "gestures.enable_all" or "gestures.disable_all",
			gesture_lifecycle)
		if gesture_committed ~= true then
			-- Production enable_all()/disable_all() preserve their previous CoreState
			-- on refusal. Publish that exact runtime posture back into the mutable
			-- state and preferences so boot cannot report the rejected desired value.
			local query_ok, runtime_enabled = pcall(gestures.is_enabled)
			if query_ok and type(runtime_enabled) == "boolean" then
				state.gestures = runtime_enabled
				if type(save_prefs) == "function" then
					try_exact("save_prefs gesture lifecycle rollback", save_prefs)
				end
			else
				sync_failed = true
				Logger.warn(LOG,
					"sync_state_to_modules: gestures.is_enabled rollback query failed — %s",
					tostring(runtime_enabled))
			end
		end

		-- Sync granular settings
		if type(saved.gesture_modes) == "table" then
			for slot, mode in pairs(saved.gesture_modes) do
				if type(gestures.set_mode) == "function" then try("gestures.set_mode", gestures.set_mode, slot, mode) end
			end
		end
		if type(saved.gesture_sensitivities) == "table" then
			for slot, sens in pairs(saved.gesture_sensitivities) do
				if type(gestures.set_sensitivity) == "function" then try("gestures.set_sensitivity", gestures.set_sensitivity, slot, sens) end
			end
		end
		if saved.gesture_space_wrap ~= nil then
			if type(gestures.set_space_wrap) == "function" then try("gestures.set_space_wrap", gestures.set_space_wrap, saved.gesture_space_wrap) end
		end
	end
	-- Drive shortcuts with binding-only helpers so the script-control eventtap
	-- (AltGr+Enter/Backspace/Escape) is never destroyed mid-session.
	-- stop()/start() would kill the tap; pause_bindings/resume_bindings is safe.
	if core_mods.shortcuts_mod then
		if state.shortcuts then
			try_exact("shortcuts.resume_bindings", core_mods.shortcuts_mod.resume_bindings)
		else
			try_exact("shortcuts.pause_bindings", core_mods.shortcuts_mod.pause_bindings)
		end
	end
	if core_mods.shortcuts_mod and type(state.script_control_shortcuts) == "table"
		and type(core_mods.shortcuts_mod.set_shortcut_action) == "function" then
		for keyname, action in pairs(state.script_control_shortcuts) do
			try("shortcuts.set_shortcut_action", core_mods.shortcuts_mod.set_shortcut_action,
				keyname, action)
		end
	end
	if core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.set_chatgpt_url) == "function" then
		try("shortcuts.set_chatgpt_url", core_mods.shortcuts_mod.set_chatgpt_url, state.chatgpt_url)
	end
	if core_mods.dyn_hot_mod then
		if state.personal_info then
			if type(core_mods.dyn_hot_mod.enable) == "function" then try("dyn_hot.enable", core_mods.dyn_hot_mod.enable) end
		else
			if type(core_mods.dyn_hot_mod.disable) == "function" then try("dyn_hot.disable", core_mods.dyn_hot_mod.disable) end
		end
	end

	-- Sync hotstrings & shortcuts.
	-- IMPORTANT (perf): apply ONLY the delta. enable_group is a no-op when the
	-- group is already enabled (it early-returns), and disable_group is a no-op
	-- when already disabled — so calling just the one matching the desired state
	-- costs nothing for groups already in that state. The previous code did a
	-- blind disable_group + enable_group round-trip for every enabled group,
	-- which at boot (all groups enabled) re-parsed each category TOML from disk
	-- and re-sorted all ~5355 mappings ~16× for no change — the dominant ~2 s of
	-- the "Menu + UI + script control start" boot phase. Letting the registry's
	-- own early-return guards short-circuit the no-ops removes that entirely.
	if keymap then
		local _t_sync = hs.timer.secondsSinceEpoch()
		local _n_enable, _n_disable = 0, 0
		for name, enabled in pairs(state.hotstrings) do
			if enabled then
				if type(keymap.enable_group) == "function" then try("keymap.enable_group " .. name, keymap.enable_group, name); _n_enable = _n_enable + 1 end
			else
				if type(keymap.disable_group) == "function" then try("keymap.disable_group " .. name, keymap.disable_group, name); _n_disable = _n_disable + 1 end
			end
		end
		-- Timing surfaced so a regression to the disable+enable round-trip (which
		-- reloaded every TOML and re-sorted ~5355 mappings, ~2 s at boot) is
		-- immediately visible: a healthy delta-only sync should report ~0 ms.
		Logger.info(LOG, "Hotstring group sync: %d enable / %d disable in %.1f ms.",
			_n_enable, _n_disable, (hs.timer.secondsSinceEpoch() - _t_sync) * 1000)
	end
	if core_mods.shortcuts_mod and type(saved) == "table" and type(saved.shortcut_keys) == "table" then
		if type(core_mods.shortcuts_mod.enable) == "function" and type(core_mods.shortcuts_mod.disable) == "function" then
			for id, enabled in pairs(saved.shortcut_keys) do
				if enabled then try("shortcuts.enable", core_mods.shortcuts_mod.enable, id) else try("shortcuts.disable", core_mods.shortcuts_mod.disable, id) end
			end
		end
	end

	if config_absent and save_prefs() ~= true then return false end
	return not sync_failed
end

return M
