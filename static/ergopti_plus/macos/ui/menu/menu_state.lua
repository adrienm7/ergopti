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
local Storage = require("adapters.storage")
local DeferredWork = require("infra.deferred_work")
local KeymapLifecycle = require("ui.menu.keymap_lifecycle")
local LOG    = "menu_state"

-- Delay before starting the keylogger engine. Its start (~1.3 s of SQLite +
-- log-rotation work) only feeds typing metrics, so it is deferred off the boot
-- critical path; a sub-second gap of unlogged keystrokes after boot is harmless.
local KEYLOGGER_START_DELAY_SEC = 0.5
local _keylogger_start_generation = 0
local _keylogger_start_pending = false

--- Reports boot activation that has not reached the native lifecycle owner.
--- @return boolean pending True until the current deferred start settles.
function M.metrics_start_pending() return _keylogger_start_pending end






-- ==========================================
-- ==========================================
-- ======= 1/ Module State Sync Logic =======
-- ==========================================
-- ==========================================

--- Deep-copies plain Lua data so a demotion record cannot alias live state.
--- @param value any Value to copy.
--- @return any copy
local function clone_value(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[clone_value(key)] = clone_value(child) end
	return copy
end

--- Synchronises the loaded state table back into all engine modules.
--- Called once at startup after preferences are loaded, after a failed save
--- (rollback) and by the global actions.
---
--- Failures are isolated per feature. A refused lifecycle whose runtime posture
--- can be read back demotes only that feature's state flag, in memory, and is
--- reported in `report.demotions`; the sync never persists anything, so a boot
--- refusal can neither save before the caller's transaction exists nor rewrite
--- config.toml. A refusal whose posture cannot be proved lands in
--- `report.unsettled`, the only case in which the caller must roll back whole.
--- @param state table The current mutable state table.
--- @param saved table The raw saved preferences table.
--- @param config_absent boolean Must be false: the caller seeds config.toml once
--- its save transaction exists, never this sync.
--- @param deps table Dependency bag: { keymap, gestures, hotstring_editor, core_mods, apply_llm_enabled, on_runtime_demotion }.
--- @return boolean committed True only when every feature applied.
--- @return table report { failures, demotions, unsettled, repairs } per feature.
function M.sync_state_to_modules(state, saved, config_absent, deps)
	if config_absent then
		error("sync_state_to_modules never persists; seed config.toml after the save transaction exists", 2)
	end
	local report = { failures = {}, demotions = {}, unsettled = {}, repairs = {} }

	--- Records one refused step of a feature and names both in an ERROR.
	--- @param feature string Feature the refused owner belongs to.
	--- @param label string Refused runtime step.
	--- @param detail any Refusal result or raised error.
	local function record_failure(feature, label, detail)
		report.failures[#report.failures + 1] = {
			feature = feature, step = label, detail = tostring(detail),
		}
		Logger.error(LOG, "sync_state_to_modules: feature '%s' was not fully applied: %s did not commit — %s.",
			feature, label, tostring(detail))
	end

	--- Calls a runtime setter under pcall and records any raised failure.
	--- Successful setters may return nil; only a thrown error breaks the sync contract.
	--- @param feature string Feature the setter belongs to.
	--- @param label string Human-readable description for the error.
	--- @param fn function|nil Function to call, or nil when the dependency is optional.
	--- @param ... any Arguments forwarded to fn.
	--- @return boolean completed True unless the setter raised.
	local function try(feature, label, fn, ...)
		if type(fn) ~= "function" then return true end
		local ok, err = pcall(fn, ...)
		if not ok then record_failure(feature, label, err) end
		return ok, err
	end

	--- Calls a lifecycle method whose contract requires an exact true result.
	--- @param feature string Feature the lifecycle belongs to.
	--- @param label string Human-readable description for the error.
	--- @param fn function|nil Required lifecycle method.
	--- @param ... any Arguments forwarded to fn.
	--- @return boolean committed True only after exact runtime commitment.
	local function try_exact(feature, label, fn, ...)
		if type(fn) ~= "function" then
			record_failure(feature, label, "unavailable")
			return false
		end
		local ok, result_or_err = pcall(fn, ...)
		if not ok or result_or_err ~= true then
			record_failure(feature, label, result_or_err)
			return false
		end
		return true
	end

	--- Shows one feature flag at the posture its runtime really has, in memory
	--- only. The record keeps the saved value so the caller can keep it on disk.
	--- @param feature string Demoted feature.
	--- @param key string State key of its switch.
	--- @param runtime_value any Posture the runtime actually has.
	--- @param reason string Why the saved value could not apply.
	--- @return table record { feature, key, persisted, demoted }.
	local function demote(feature, key, runtime_value, reason)
		local record = {
			feature = feature,
			key = key,
			persisted = clone_value(state[key]),
			demoted = clone_value(runtime_value),
		}
		state[key] = runtime_value
		report.demotions[#report.demotions + 1] = record
		Logger.error(LOG, "Feature '%s' is %s for this session because %s; config.toml keeps its saved value.",
			feature, runtime_value and "ON" or "OFF", reason)
		return record
	end

	--- Records a refusal whose runtime posture cannot be proved.
	--- @param feature string Feature left in an unknown posture.
	--- @param label string Step whose outcome is unknown.
	--- @param detail any Query failure or refusal.
	local function unsettled(feature, label, detail)
		report.unsettled[#report.unsettled + 1] = {
			feature = feature, step = label, detail = tostring(detail),
		}
		Logger.error(LOG, "Feature '%s' runtime posture is unknown after %s — %s.",
			feature, label, tostring(detail))
	end

	local keymap           = deps.keymap
	local gestures         = deps.gestures
	local hotstring_editor = deps.hotstring_editor
	local core_mods        = deps.core_mods
	local apply_llm_enabled = deps.apply_llm_enabled

	-- Canonical absence replaces stale derived section settings as well as groups.
	if keymap and type(keymap.apply_hotstring_preferences) == "function" then
		try_exact("hotstrings", "keymap.apply_hotstring_preferences", keymap.apply_hotstring_preferences, saved)
	elseif type(saved.section_states) == "table" then
		record_failure("hotstrings", "keymap.apply_hotstring_preferences", "owner unavailable")
	end

	-- Sync the built-in terminators only. A custom terminator's state is
	-- re-applied below, once add_custom_terminator has re-created its key:
	-- replaying it here first made the registry log an ERROR for every valid
	-- custom terminator at each boot. Keys no owner knows never get here, the
	-- loader drops them as outdated configuration.
	if type(saved.terminator_states) == "table" and keymap
		and type(keymap.set_terminator_enabled) == "function"
		and type(keymap.get_terminator_defs) == "function" then
		local builtin = {}
		local defs = keymap.get_terminator_defs()
		for _, def in ipairs(type(defs) == "table" and defs or {}) do
			if type(def) == "table" and type(def.key) == "string" and def.custom ~= true then
				builtin[def.key] = true
			end
		end
		for key, enabled in pairs(saved.terminator_states) do
			if builtin[key] then
				try("hotstrings", "keymap.set_terminator_enabled", keymap.set_terminator_enabled, key, enabled)
			end
		end
	end

	-- Re-register custom terminators created by the user (persisted in state)
	if keymap and type(keymap.add_custom_terminator) == "function" then
		local custom_runtime_failed = false
		if type(keymap.get_terminator_defs) == "function"
			and type(keymap.remove_custom_terminator) == "function" then
			local defs = keymap.get_terminator_defs()
			for index = #(type(defs) == "table" and defs or {}), 1, -1 do
				local def = defs[index]
				if type(def) == "table" and def.custom == true then
					if not try_exact("hotstrings", "keymap.remove_custom_terminator",
						keymap.remove_custom_terminator, def.key) then
						custom_runtime_failed = true
					end
				end
			end
		end
		local accepted_custom = {}
		local accepted_keys = {}
		local rejected_keys = {}
		local custom_repaired = false
		local persisted_custom = type(state.custom_terminators) == "table"
			and state.custom_terminators or {}
		for _, ct in ipairs(not custom_runtime_failed and persisted_custom or {}) do
			if type(ct) == "table" and type(ct.key) == "string" and not accepted_keys[ct.key] then
				local consume = ct.consume
				if consume == nil then consume = false end
				local label = ct.label or ct.char
				local validation_ok, candidate_valid = xpcall(function()
					return type(keymap.validate_custom_terminator) == "function"
						and keymap.validate_custom_terminator(
							ct.key, ct.char, label, consume) == true
				end, debug.traceback)
				if not validation_ok then
					custom_runtime_failed = true
					record_failure("hotstrings", "keymap.validate_custom_terminator", candidate_valid)
					break
				end
				if candidate_valid then
					local ok_add, added = xpcall(keymap.add_custom_terminator,
						debug.traceback, ct.key, ct.char, label, consume)
					if not ok_add or added ~= true then
						custom_runtime_failed = true
						record_failure("hotstrings", "keymap.add_custom_terminator", added)
						break
					end
					accepted_keys[ct.key] = true
					-- Runtime admission validates owned fields; it does not own future
					-- record metadata that an ordinary preference save must retain.
					local accepted = clone_value(ct)
					accepted.label, accepted.consume = label, consume
					accepted_custom[#accepted_custom + 1] = accepted
					-- Resolved from the persisted states rather than read off an
					-- undefined global. `enabled_ct` was never assigned anywhere, so it
					-- was always nil and this branch never ran: a custom terminator the
					-- user had DISABLED came back enabled on every restart. It has to be
					-- re-applied here and not by the terminator_states loop above,
					-- because that loop runs before add_custom_terminator has created
					-- the key it would be setting.
					local enabled_ct
					if type(saved.terminator_states) == "table" then
						enabled_ct = saved.terminator_states[ct.key]
					end
					if enabled_ct ~= nil and not try_exact("hotstrings", "keymap.set_terminator_enabled",
						keymap.set_terminator_enabled, ct.key, enabled_ct) then
						custom_runtime_failed = true
						break
					end
				else
					custom_repaired = true
					rejected_keys[ct.key] = true
					Logger.warn(LOG, "sync_state_to_modules: rejected one invalid custom terminator.")
				end
			else
				custom_repaired = true
				if type(ct) == "table" and type(ct.key) == "string" then
					rejected_keys[ct.key] = true
				end
			end
		end
		if not custom_runtime_failed then
			state.custom_terminators = accepted_custom
			if type(state.terminator_states) == "table" then
				for key in pairs(rejected_keys) do
					if not accepted_keys[key] then state.terminator_states[key] = nil end
				end
			end
			-- The caller persists the repair once its save transaction exists; saving
			-- from here ran before that transaction was seeded at boot and failed.
			if custom_repaired then report.repairs[#report.repairs + 1] = "custom_terminators" end
		end
	end

	-- Sync delays — resolution chain (highest priority first):
	--   1. legacy `state.delays[k]` (loaded from config.json) — kept for
	--      users upgrading from a version that wrote delays there.
	--   2. `hotstrings_config.resolve(category).delay` for TOML-backed keys —
	--      this is the new authoritative source (TOML metadata + user override).
	--   3. `keymap.DELAYS_DEFAULT[k]` — ultimate hardcoded fallback.
	if type(state.expansion_delay) == "number" then
		if keymap and type(keymap.set_base_delay) == "function" then try("hotstrings", "keymap.set_base_delay", keymap.set_base_delay, state.expansion_delay) end
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
			try("hotstrings", "keymap.set_delay " .. k, keymap.set_delay, k, state.delays[k] or resolved or default_val)
		end
	end

	-- Sync gestures
	if gestures and type(saved.gesture_actions) == "table" then
		for slot, action in pairs(saved.gesture_actions) do
			if type(gestures.set_action) == "function" then try("gestures", "gestures.set_action", gestures.set_action, slot, action) end
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
				try("gestures", "gestures.set_action_parameter", gestures.set_action_parameter, binding, action, value)
			end
		end
	end
	if gestures and type(gestures.apply_all_overrides) == "function" then try("gestures", "gestures.apply_all_overrides", gestures.apply_all_overrides) end

	-- Hotstring preview and magic-key options belong to the text engine, not to
	-- the AI, so a refused AI identity below must not keep them unapplied.
	if keymap then
		for _, item in ipairs({
			{ fn = "set_repeat_feature_enabled",      val = state.repeat_key_enabled },
			{ fn = "set_preview_star_enabled",        val = state.preview_star_enabled },
			{ fn = "set_preview_autocorrect_enabled", val = state.preview_autocorrect_enabled },
			{ fn = "set_preview_colored_tooltips",    val = state.preview_colored_tooltips },
			{ fn = "set_trigger_char",                val = state.trigger_char },
			{ fn = "set_magic_key_source",            val = state.magic_key_source },
		}) do
			if type(keymap[item.fn]) == "function" then
				try("hotstrings", "keymap." .. item.fn, keymap[item.fn], item.val)
			end
		end
	end

	-- Restore the backend/profile/model identity before keymap LLM setters. Those
	-- setters may schedule warmup work immediately, so reversing this order would
	-- dispatch the acknowledged model through the just-rejected backend.
	local llm = core_mods and core_mods.llm
	local llm_committed = true
	local llm_refusal = nil
	if llm then
		local identity_map = {
			{ fn = "set_backend",        val = state.llm_backend },
			{ fn = "set_user_profiles",  val = state.llm_user_profiles },
			{ fn = "set_active_profile", val = state.llm_active_profile },
			{ fn = "set_llm_model_ollama", val = state.llm_model_ollama },
			{ fn = "set_llm_model_mlx",    val = state.llm_model_mlx },
		}
		for _, item in ipairs(identity_map) do
			if not try_exact("ai", "llm." .. item.fn, llm[item.fn], item.val) then
				llm_committed = false
				llm_refusal = "llm." .. item.fn .. " was refused"
				break
			end
		end
		if llm_committed and type(llm.set_llm_streaming) == "function" then
			try("ai", "llm.set_llm_streaming", llm.set_llm_streaming, state.llm_streaming)
		end
	end

	-- Sync keymap AI options
	if keymap then
		local llm_enabled_setter = type(apply_llm_enabled) == "function"
			and apply_llm_enabled or keymap.set_llm_enabled
		if llm_committed then
			llm_committed = try_exact("ai", "keymap.set_llm_model", keymap.set_llm_model, state.llm_model)
			if not llm_committed then llm_refusal = "keymap.set_llm_model was refused" end
		end
		if llm_committed and type(llm_enabled_setter) == "function" then
			llm_committed = try_exact("ai", "keymap.set_llm_enabled", llm_enabled_setter, state.llm_enabled)
			if not llm_committed then llm_refusal = "keymap.set_llm_enabled was refused" end
		end
		if not llm_committed then
			-- A partial identity must not serve predictions, so the AI stays off for
			-- this session; the next boot retries the saved configuration. A keymap
			-- without an AI switch has no prediction runtime to turn off.
			local off_ok, off_result = true, true
			if type(llm_enabled_setter) == "function" then
				off_ok, off_result = pcall(llm_enabled_setter, false)
			end
			if off_ok and off_result == true then
				if state.llm_enabled then demote("ai", "llm_enabled", false, llm_refusal) end
			else
				unsettled("ai", "AI disable after " .. tostring(llm_refusal), off_result)
			end
		end
		if llm_committed then
			local backend_labels = { mlx = "MLX 🚀", ollama = "Ollama 🦙", api = "API 🌐" }
			local map = {
			{ fn = "set_preview_ai_enabled",          val = state.preview_ai_enabled },
			{ fn = "set_llm_after_hotstring",         val = state.llm_after_hotstring },
			{ fn = "set_llm_auto_raise_temp",         val = state.llm_auto_raise_temp },
			{ fn = "set_llm_debounce",                val = state.llm_debounce },
			{ fn = "set_llm_backend_name",            val = backend_labels[state.llm_backend] or state.llm_backend },
			{ fn = "set_llm_display_model_name",      val = state.llm_model },
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
			{ fn = "set_llm_agent_system1",               val = state.llm_agent_system1 },
			{ fn = "set_llm_agent_system2",               val = state.llm_agent_system2 },
			{ fn = "set_llm_agent_mode",                  val = state.llm_agent_mode },
			{ fn = "set_llm_agent_disabled_apps",         val = state.llm_agent_disabled_apps },
			}
			for _, item in ipairs(map) do
				if type(keymap[item.fn]) == "function" then
					try("ai", "keymap." .. item.fn, keymap[item.fn], item.val)
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
		if state[key] ~= nil then try("ai", "Storage.set " .. key, Storage.set, key, state[key]) end
	end

	-- Sync editor options
	if type(hotstring_editor.set_trigger_char) == "function"    then try("hotstring_editor", "hotstring_editor.set_trigger_char", hotstring_editor.set_trigger_char, state.trigger_char) end
	if type(hotstring_editor.set_default_section) == "function" then try("hotstring_editor", "hotstring_editor.set_default_section", hotstring_editor.set_default_section, state.custom_default_section) end
	if type(hotstring_editor.set_close_on_add) == "function"    then try("hotstring_editor", "hotstring_editor.set_close_on_add", hotstring_editor.set_close_on_add, state.custom_close_on_add) end

	-- Sync the dynamic-hotstrings RulesEngine's trigger char too — without this
	-- it only ever sees the value captured once at boot, orphaning every
	-- date/prefix rule from a magic-key change made via the menu (F-HIGH-8 fix).
	local dyn_hot_mod = core_mods and core_mods.dyn_hot_mod
	if dyn_hot_mod and type(dyn_hot_mod.set_trigger_char) == "function" then
		try("hotstrings", "dyn_hot_mod.set_trigger_char", dyn_hot_mod.set_trigger_char, state.trigger_char)
	end

	local sc = state.custom_editor_shortcut
	local editor_handoff_committed = true
	if sc == nil then
		-- Canonical absence belongs to the ordinary contextual slot. Retire an
		-- acknowledged legacy owner before that slot may acquire a replacement.
		if type(hotstring_editor.clear_shortcut) == "function" then
			editor_handoff_committed = try_exact("hotstring_editor", "hotstring_editor.clear_shortcut", hotstring_editor.clear_shortcut)
		end
	elseif type(sc) == "table" and type(sc.mods) == "table" and type(sc.key) == "string" then
		if type(hotstring_editor.set_shortcut) == "function" then
			try_exact("hotstring_editor", "hotstring_editor.set_shortcut", hotstring_editor.set_shortcut, sc.mods, sc.key)
		end
	elseif sc == false and type(hotstring_editor.clear_shortcut) == "function" then
		try_exact("hotstring_editor", "hotstring_editor.clear_shortcut", hotstring_editor.clear_shortcut)
	end


	local kl = core_mods.keylogger
	if kl then
		_keylogger_start_generation = _keylogger_start_generation + 1
		local keylogger_generation = _keylogger_start_generation
		_keylogger_start_pending = false
		if type(kl.set_options) == "function" then
			try("metrics", "keylogger.set_options", kl.set_options, {
				encrypt     = state.keylogger_encrypt,
				menubar     = state.keylogger_menubar_wpm,
				float       = state.keylogger_float_wpm,
				float_graph = state.keylogger_float_graph,
			})
		end
		if type(kl.set_disabled_apps) == "function" then try("metrics", "keylogger.set_disabled_apps", kl.set_disabled_apps, state.keylogger_disabled_apps or {}) end
		if type(kl.set_private_filter_enabled) == "function" then
			try("metrics", "keylogger.set_private_filter_enabled", kl.set_private_filter_enabled,
				state.keylogger_private_filter_enabled)
		end
		if type(kl.set_secure_field_filter_enabled) == "function" then
			try("metrics", "keylogger.set_secure_field_filter_enabled", kl.set_secure_field_filter_enabled,
				state.keylogger_secure_filter_enabled)
		end
		if type(kl.set_system_auth_filter_enabled) == "function" then
			try("metrics", "keylogger.set_system_auth_filter_enabled", kl.set_system_auth_filter_enabled,
				state.keylogger_system_auth_filter_enabled)
		end
		local physical_source_admitted = true
		if type(kl.set_physical_source) == "function" then
			local physical_source = state.keylogger_physical_source
			if physical_source == nil and type(kl.DEFAULT_STATE) == "table" then
				physical_source = kl.DEFAULT_STATE.keylogger_physical_source
			end
			physical_source_admitted = try_exact("metrics", "keylogger.set_physical_source",
				kl.set_physical_source, physical_source)
		end
		if state.keylogger_enabled and physical_source_admitted then
			-- Keylogger start is the single biggest boot cost (~1.3 s: SQLite open,
			-- log-rotation offset replay, export setup). It only feeds typing
			-- METRICS, so missing the first fraction of a second of keystrokes is
			-- harmless — defer it off the boot critical path so the menubar/UI become
			-- interactive ~1.3 s sooner. The shortcuts ref is captured for the closure.
			local _shortcuts_ref = core_mods.shortcuts_mod
			_keylogger_start_pending = true
			local scheduling, fired = true, false
			local function activate()
				if keylogger_generation ~= _keylogger_start_generation then return end
				if scheduling then fired = true; return end
				if type(kl.start) ~= "function" then return end
				local _t_kl = hs.timer.secondsSinceEpoch()
				local start_ok, started = try("metrics", "keylogger.start", kl.start, _shortcuts_ref)
				if start_ok and started ~= true then
					record_failure("metrics", "keylogger.start", started)
				end
				if not start_ok or started ~= true then
					-- In memory only: persisting OFF here rewrote config.toml whenever
					-- the engine lacked a permission, so Metrics stayed off for good.
					local record = demote("metrics", "keylogger_enabled", false,
						"the deferred keylogger start was refused")
					if type(deps.on_runtime_demotion) == "function" then
						local notified, notify_err = pcall(deps.on_runtime_demotion, record)
						if not notified then
							Logger.error(LOG, "Deferred Metrics demotion could not be recorded: %s.",
								tostring(notify_err))
						end
					end
				end
				_keylogger_start_pending = false
				Logger.info(LOG, "Keylogger engine start (deferred): %.1f ms.",
					(hs.timer.secondsSinceEpoch() - _t_kl) * 1000)
			end
			local scheduled = DeferredWork.after(KEYLOGGER_START_DELAY_SEC, activate, "menu_state.keylogger_start")
			scheduling = false
			if scheduled ~= true then
				_keylogger_start_generation = _keylogger_start_generation + 1
				_keylogger_start_pending = false
			elseif fired then activate() end
		else
			if type(kl.stop) == "function" then
				local stop_ok, stopped = try("metrics", "keylogger.stop", kl.stop)
				if not stop_ok or stopped ~= true then
					Logger.error(LOG, "Keylogger is disabled, but native lifecycle cleanup remains pending.")
				end
			end
		end
	end
	local cipher_ok, TextCipher = pcall(require, "modules.keylogger.text_cipher")
	if cipher_ok and type(TextCipher) == "table" and type(TextCipher.set_enabled) == "function" then
		try("metrics", "keylogger.text_cipher.set_enabled", TextCipher.set_enabled, state.keylogger_encrypt)
	end

	-- Start/stop engines
	if keymap then
		if state.keymap then
			local _t_km = hs.timer.secondsSinceEpoch()
			-- ensure_started() clears state.keymap itself on refusal; restore the
			-- saved ON first so the demotion records what config.toml holds.
			local saved_keymap = state.keymap
			if not KeymapLifecycle.ensure_started({ state = state, keymap = keymap },
				"synchronize menu state") then
				record_failure("hotstrings", "keymap.start", "refused")
				state.keymap = saved_keymap
				demote("hotstrings", "keymap", false, "the typing engine did not start")
			end
			Logger.info(LOG, "Keymap engine start: %.1f ms.", (hs.timer.secondsSinceEpoch() - _t_km) * 1000)

			-- Recover from a stale paused state when script control is not paused
			local paused = core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.is_paused) == "function" and core_mods.shortcuts_mod.is_paused() or false
			if not paused and type(keymap.is_processing_paused) == "function" and keymap.is_processing_paused() then
				if type(keymap.resume_processing) == "function" then try("hotstrings", "keymap.resume_processing", keymap.resume_processing) end
			end
		elseif type(keymap.stop) == "function" and not try_exact("hotstrings", "keymap.stop", keymap.stop) then
			-- Boot starts the taps before this sync: a refused stop may leave them
			-- typing, and the Hotstrings tick reads this switch. It shows ON, and
			-- clicking it retries the stop, rather than claiming a silence the
			-- engine never reached.
			demote("hotstrings", "keymap", true, "the typing engine did not stop")
		end
	end
	if gestures then
		local desired_gestures = state.gestures == true
		local gesture_lifecycle = desired_gestures
			and gestures.enable_all or gestures.disable_all
		local gesture_label = desired_gestures and "gestures.enable_all" or "gestures.disable_all"
		local gesture_committed = try_exact("gestures", gesture_label, gesture_lifecycle)
		if gesture_committed ~= true then
			-- Production enable_all()/disable_all() preserve their previous CoreState
			-- on refusal. Show that exact runtime posture in memory only: saving it
			-- here ran before the boot save transaction existed, and would have
			-- replaced the user's config.toml value with a runtime refusal.
			local query_ok, runtime_enabled = pcall(gestures.is_enabled)
			if query_ok and type(runtime_enabled) == "boolean" then
				if runtime_enabled ~= desired_gestures then
					demote("gestures", "gestures", runtime_enabled, gesture_label .. " was refused")
				end
			else
				unsettled("gestures", "gestures.is_enabled", runtime_enabled)
			end
		end

		-- Sync granular settings
		if type(saved.gesture_modes) == "table" then
			for slot, mode in pairs(saved.gesture_modes) do
				if type(gestures.set_mode) == "function" then try("gestures", "gestures.set_mode", gestures.set_mode, slot, mode) end
			end
		end
		if type(saved.gesture_sensitivities) == "table" then
			for slot, sens in pairs(saved.gesture_sensitivities) do
				if type(gestures.set_sensitivity) == "function" then try("gestures", "gestures.set_sensitivity", gestures.set_sensitivity, slot, sens) end
			end
		end
	end
	-- Drive shortcuts with binding-only helpers so the script-control eventtap
	-- (AltGr+Enter/Backspace/Escape) is never destroyed mid-session.
	-- stop()/start() would kill the tap; pause_bindings/resume_bindings is safe.
	-- A refused pause or resume can leave one child of the layer live (native
	-- hotkeys vs keyboard shortcuts), so its posture is never provable here.
	if core_mods.shortcuts_mod then
		local shortcut_label = state.shortcuts and "shortcuts.resume_bindings"
			or "shortcuts.pause_bindings"
		local shortcut_lifecycle = state.shortcuts and core_mods.shortcuts_mod.resume_bindings
			or core_mods.shortcuts_mod.pause_bindings
		if not try_exact("shortcuts", shortcut_label, shortcut_lifecycle) then
			unsettled("shortcuts", shortcut_label, "the layer may be partially applied")
		end
	end
	if core_mods.shortcuts_mod and type(state.script_control_shortcuts) == "table"
		and type(core_mods.shortcuts_mod.set_shortcut_action) == "function" then
		for keyname, action in pairs(state.script_control_shortcuts) do
			try("shortcuts", "shortcuts.set_shortcut_action", core_mods.shortcuts_mod.set_shortcut_action,
				keyname, action)
		end
	end
	if core_mods.shortcuts_mod and type(state.script_control_enabled) == "boolean"
		and type(core_mods.shortcuts_mod.set_script_chords_enabled) == "function" then
		try("shortcuts", "shortcuts.set_script_chords_enabled", core_mods.shortcuts_mod.set_script_chords_enabled,
			state.script_control_enabled)
	end
	if core_mods.shortcuts_mod and type(core_mods.shortcuts_mod.set_chatgpt_url) == "function" then
		try("shortcuts", "shortcuts.set_chatgpt_url", core_mods.shortcuts_mod.set_chatgpt_url, state.chatgpt_url)
	end
	if core_mods.dyn_hot_mod then
		if state.dynamichotstrings_user_code_time_activation_seconds ~= nil then
			try_exact("programmable hotstrings", "dyn_hot.set_user_code_time_activation",
				core_mods.dyn_hot_mod.set_user_code_time_activation,
				state.dynamichotstrings_user_code_time_activation_seconds)
		end
		if type(state.dynamichotstrings_user_code_enabled) == "boolean" then
			try_exact("programmable hotstrings", "dyn_hot.set_user_code_enabled",
				core_mods.dyn_hot_mod.set_user_code_enabled, state.dynamichotstrings_user_code_enabled)
		end
		if state.personal_info then
			if type(core_mods.dyn_hot_mod.enable) == "function" then try("personal_info", "dyn_hot.enable", core_mods.dyn_hot_mod.enable) end
		else
			if type(core_mods.dyn_hot_mod.disable) == "function" then try("personal_info", "dyn_hot.disable", core_mods.dyn_hot_mod.disable) end
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
				if type(keymap.enable_group) == "function" then try("hotstrings", "keymap.enable_group " .. name, keymap.enable_group, name); _n_enable = _n_enable + 1 end
			else
				if type(keymap.disable_group) == "function" then try("hotstrings", "keymap.disable_group " .. name, keymap.disable_group, name); _n_disable = _n_disable + 1 end
			end
		end
		-- Timing surfaced so a regression to the disable+enable round-trip (which
		-- reloaded every TOML and re-sorted ~5355 mappings, ~2 s at boot) is
		-- immediately visible: a healthy delta-only sync should report ~0 ms.
		Logger.info(LOG, "Hotstring group sync: %d enable / %d disable in %.1f ms.",
			_n_enable, _n_disable, (hs.timer.secondsSinceEpoch() - _t_sync) * 1000)
	end
	if core_mods.shortcuts_mod and type(saved) == "table" and type(saved.shortcut_keys) == "table" then
		local shortcuts = core_mods.shortcuts_mod
		for id, enabled in pairs(saved.shortcut_keys) do
			local apply = enabled and shortcuts.enable or shortcuts.disable
			local label = (enabled and "shortcuts.enable " or "shortcuts.disable ") .. id
			if not try_exact("shortcuts", label, apply, id) then
				local query_ok, actual = pcall(shortcuts.is_enabled, id)
				if query_ok and type(actual) == "boolean" then
					if actual ~= enabled then
						report.demotions[#report.demotions + 1] = {
							feature = "shortcuts", key = "shortcut_keys", subkey = id,
							persisted = enabled, demoted = actual,
						}
					end
				else
					unsettled("shortcuts", "shortcuts.is_enabled " .. id, actual)
				end
			end
		end
	end

	local shortcut_owner = core_mods and core_mods.shortcuts_mod
	if shortcut_owner and type(shortcut_owner.configure_magic_editor) == "function" then
		try_exact("shortcuts", "shortcuts.configure_magic_editor", shortcut_owner.configure_magic_editor, {
			legacy_present = sc ~= nil or not editor_handoff_committed,
			trigger = function() return keymap.get_trigger_char() end,
			magic_source = function() return keymap.get_magic_key_source() end,
			replace_active = function()
				if type(keymap.is_magic_key_replacement_effective) ~= "function" then return nil end
				return keymap.is_magic_key_replacement_effective()
			end,
			paused = function() return shortcut_owner.is_paused() == true end,
			inhibited = function() return shortcut_owner.has_bindings_pause_debt() == true end,
		})
	end
	return #report.failures == 0 and #report.unsettled == 0, report
end

return M
