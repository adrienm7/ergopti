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
local Logger = require("lib.logger")
local LOG    = "menu_state"




-- =========================================
--- ==========================================
-- ======= 1/ Module State Sync Logic =======
--- ==========================================
-- =========================================

--- Synchronises the loaded state table back into all engine modules.
--- Called once at startup after preferences are loaded, and after a reset.
--- @param state table The current mutable state table.
--- @param saved table The raw saved preferences table.
--- @param config_absent boolean True when no config file was found on disk.
--- @param deps table Dependency bag: { keymap, gestures, hotstring_editor, core_mods, save_prefs, apply_metrics_shortcut, apply_apps_time_shortcut, _metrics_hk_ref, _apps_time_hk_ref }.
function M.sync_state_to_modules(state, saved, config_absent, deps)
	local keymap           = deps.keymap
	local gestures         = deps.gestures
	local hotstring_editor = deps.hotstring_editor
	local core_mods        = deps.core_mods
	local save_prefs       = deps.save_prefs
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
						pcall(hs.settings.set, key, false)
					else
						pcall(hs.settings.set, key, nil)
					end
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

	-- Sync delays — resolution chain (highest priority first):
	--   1. legacy `state.delays[k]` (loaded from config.json) — kept for
	--      users upgrading from a version that wrote delays there.
	--   2. `hotstrings_config.resolve(category).delay` for TOML-backed keys —
	--      this is the new authoritative source (TOML metadata + user override).
	--   3. `keymap.DELAYS_DEFAULT[k]` — ultimate hardcoded fallback.
	if type(state.expansion_delay) == "number" then
		if keymap and type(keymap.set_base_delay) == "function" then pcall(keymap.set_base_delay, state.expansion_delay) end
	end
	if keymap and type(keymap.set_delay) == "function" then
		local defs       = keymap.DELAYS_DEFAULT or {}
		local key_to_cat = keymap.DELAY_KEY_TO_CATEGORY or {}
		local ok_cfg, hs_cfg = pcall(require, "modules.hotstrings_config")
		if not ok_cfg then hs_cfg = nil end
		for k, default_val in pairs(defs) do
			local resolved = nil
			if hs_cfg and key_to_cat[k] then
				local r = hs_cfg.resolve(key_to_cat[k], nil)
				if r and type(r.delay) == "number" then resolved = r.delay end
			end
			pcall(keymap.set_delay, k, state.delays[k] or resolved or default_val)
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
			{ fn = "set_llm_auto_raise_temp",         val = state.llm_auto_raise_temp },
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
			{ fn = "set_llm_url_bar_filter_enabled",      val = state.llm_url_bar_filter_enabled },
			{ fn = "set_llm_secure_field_filter_enabled", val = state.llm_secure_field_filter_enabled },
			{ fn = "set_llm_instant_on_word_end",         val = state.llm_instant_on_word_end },
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
	if type(state.apps_time_shortcut) == "table" then
		apply_apps_time_shortcut(state.apps_time_shortcut.mods, state.apps_time_shortcut.key)
	end
	-- Re-enable after a brief warm-up delay: on the very first presses after
	-- a Hammerspoon restart the event tap may not be fully live, so the first
	-- call above registers the hotkey and this second enable() ensures it is
	-- active once the tap is stable
	hs.timer.doAfter(1.0, function()
		if deps._metrics_hk and deps._metrics_hk[1] then pcall(function() deps._metrics_hk[1]:enable() end) end
		if deps._apps_time_hk and deps._apps_time_hk[1] then pcall(function() deps._apps_time_hk[1]:enable() end) end
	end)

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
		if state.gestures then
			if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end
		else
			if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end
		end

		-- Sync granular settings
		if type(state.gesture_modes) == "table" then
			for slot, mode in pairs(state.gesture_modes) do
				if type(gestures.set_mode) == "function" then pcall(gestures.set_mode, slot, mode) end
			end
		end
		if type(state.gesture_sensitivities) == "table" then
			for slot, sens in pairs(state.gesture_sensitivities) do
				if type(gestures.set_sensitivity) == "function" then pcall(gestures.set_sensitivity, slot, sens) end
			end
		end
		if state.gesture_space_wrap ~= nil then
			if type(gestures.set_space_wrap) == "function" then pcall(gestures.set_space_wrap, state.gesture_space_wrap) end
		end
	end
	if core_mods.shortcuts_mod then
		if state.shortcuts then
			if type(core_mods.shortcuts_mod.start) == "function" then pcall(core_mods.shortcuts_mod.start) end
		else
			if type(core_mods.shortcuts_mod.stop) == "function" then pcall(core_mods.shortcuts_mod.stop) end
		end
	end
	if core_mods.dyn_hot_mod then
		if state.personal_info then
			if type(core_mods.dyn_hot_mod.enable) == "function" then pcall(core_mods.dyn_hot_mod.enable) end
		else
			if type(core_mods.dyn_hot_mod.disable) == "function" then pcall(core_mods.dyn_hot_mod.disable) end
		end
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

return M
