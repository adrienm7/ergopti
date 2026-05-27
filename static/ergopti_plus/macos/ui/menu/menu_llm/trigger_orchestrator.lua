--- ui/menu/menu_llm/trigger_orchestrator.lua

--- ==============================================================================
--- MODULE: Menu LLM — Trigger Orchestrator
--- DESCRIPTION:
--- Manages hotkey binding, activation, and profile-triggered prediction for the
--- LLM menu. Extracted from menu_llm/init.lua to keep the orchestrator thin.
---
--- FEATURES & RATIONALE:
--- 1. Single Responsibility: owns all hs.hotkey lifecycle — create, enable,
---    delete — so init.lua never touches hotkey objects directly.
--- 2. Profile Triggering: encapsulates the profile-swap-and-restore dance
---    (set active profile → fire prediction → restore previous profile).
--- 3. Shortcut Application: normalises raw mods/key pairs via shortcut_ui,
---    tears down the old hotkey, and wires up the new one atomically.
--- 4. Getter/Setter Closures: exposes get_trigger_hk / get_profile_hks so
---    startup_controller can reattach hotkeys without holding stale refs.
--- ==============================================================================

local M = {}

local hs        = hs
local Logger    = require("lib.logger")
local llm_mod   = require("modules.llm")
local shortcut_ui = require("ui.menu.shortcut_utils")

local LOG = "menu_llm.trigger_orchestrator"




-- ======================================
-- ======================================
-- ======= 1/ Module Constructor =======
-- ======================================
-- ======================================

--- Creates a new trigger orchestrator bound to the given context.
--- @param ctx table Required fields: state, keymap, save_prefs, update_menu,
---   get_startup_silence, set_startup_silence, get_trigger_hk, get_profile_hks.
---   The last four are closures into init.lua's locals so the orchestrator
---   never holds stale references to the hotkey objects.
--- @return table Instance with: bind_hotkey, activate_hotkey,
---   trigger_prediction_with_profile, apply_llm_shortcut,
---   apply_llm_profile_shortcut.
function M.new(ctx)
	if type(ctx) ~= "table" then
		Logger.error(LOG, "M.new(): ctx must be a table — module non-functional.")
		return {}
	end

	local state              = ctx.state
	local keymap             = ctx.keymap
	local save_prefs         = ctx.save_prefs
	local update_menu        = ctx.update_menu
	local get_startup_silence = ctx.get_startup_silence
	local set_startup_silence = ctx.set_startup_silence   -- kept for symmetry / future use
	local get_trigger_hk     = ctx.get_trigger_hk
	local get_profile_hks    = ctx.get_profile_hks
	local set_trigger_hk     = ctx.set_trigger_hk
	local set_profile_hk     = ctx.set_profile_hk

	local inst = {}


	--- Safely creates a new hs.hotkey without enabling it yet.
	--- Returns the hotkey object or nil on failure.
	--- @param mods table Modifier list (e.g. {"ctrl"}).
	--- @param key string Key name.
	--- @param callback function Called on key press.
	--- @return table|nil The hs.hotkey object or nil.
	function inst.bind_hotkey(mods, key, callback)
		Logger.debug(LOG, "Attempting hotkey bind: mods=%s, key=%s",
			type(mods) == "table" and table.concat(mods, "+") or tostring(mods),
			key or "nil")
		local ok, hk = pcall(hs.hotkey.new, mods, key, callback)
		if ok and hk then
			Logger.debug(LOG, "Hotkey created successfully: %s+%s",
				type(mods) == "table" and table.concat(mods, "+") or "", key or "")
			return hk
		else
			Logger.error(LOG, "Hotkey binding failed: ok=%s, err=%s", tostring(ok), tostring(hk))
			return nil
		end
	end


	--- Enables a hotkey object if it supports :enable().
	--- Returns true on success, false otherwise.
	--- @param hk table|nil The hs.hotkey object.
	--- @return boolean
	function inst.activate_hotkey(hk)
		if hk and type(hk.enable) == "function" then
			pcall(function() hk:enable() end)
			return true
		end
		return false
	end


	--- Fires a one-shot prediction under a specific LLM profile, then restores
	--- the previously active profile. Designed for profile-shortcut triggers.
	--- @param profile_id string The profile to activate transiently.
	function inst.trigger_prediction_with_profile(profile_id)
		if type(profile_id) ~= "string" or profile_id == "" then
			Logger.warn(LOG, "trigger_prediction_with_profile: invalid profile_id: %s", tostring(profile_id))
			return
		end
		if not keymap or type(keymap.trigger_prediction) ~= "function" then
			Logger.error(LOG, "trigger_prediction_with_profile: keymap or trigger_prediction is unavailable.")
			return
		end

		Logger.debug(LOG, "Triggering prediction with profile '%s'", profile_id)

		if type(keymap.reset_predictions) == "function" then
			pcall(keymap.reset_predictions)
			Logger.debug(LOG, "Active predictions cancelled before profile trigger.")
		end

		local previous_profile = state.llm_active_profile or "basic"
		Logger.debug(LOG, "Changing profile: %s -> %s", previous_profile, profile_id)

		-- Resolve a human-readable label for the notification toast.
		local profile_label = profile_id
		for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
			if type(profile) == "table" and profile.id == profile_id and type(profile.label) == "string" then
				profile_label = profile.label
				break
			end
		end
		if profile_label == profile_id then
			for _, profile in ipairs(type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}) do
				if type(profile) == "table" and profile.id == profile_id and type(profile.label) == "string" then
					profile_label = profile.label
					break
				end
			end
		end

		llm_mod.set_active_profile(profile_id)
		pcall(keymap.trigger_prediction, true, profile_label)
		llm_mod.set_active_profile(previous_profile)

		Logger.debug(LOG, "Profile restored: %s", previous_profile)
	end


	--- Tears down the current LLM trigger hotkey and arms a new one for the
	--- given mods/key combination. Passing nil/empty mods disables the shortcut.
	--- Writes back to state.llm_trigger_shortcut and persists via save_prefs.
	--- @param mods table|nil Modifier list.
	--- @param key string|nil Key name.
	function inst.apply_llm_shortcut(mods, key)
		local current_hk = get_trigger_hk()
		if current_hk then
			pcall(function() current_hk:delete() end)
		end
		set_trigger_hk(nil)

		local normalized = shortcut_ui.normalize_shortcut(mods, key, {"ctrl"})
		if normalized then
			state.llm_trigger_shortcut = { mods = normalized.mods, key = normalized.key }
			local hk = inst.bind_hotkey(normalized.mods, normalized.key, function()
				if keymap and type(keymap.trigger_prediction) == "function" then
					pcall(keymap.trigger_prediction, true)
				end
			end)
			set_trigger_hk(hk)
			if hk and not get_startup_silence() then inst.activate_hotkey(hk) end
		else
			state.llm_trigger_shortcut = false
			set_trigger_hk(nil)
		end

		save_prefs(); update_menu()
	end


	--- Tears down the current profile shortcut for profile_id and arms a new
	--- one. Passing nil/empty mods disables the shortcut for that profile.
	--- Writes back to state.llm_profile_shortcuts and persists unless opts.silent.
	--- @param profile_id string The profile this shortcut belongs to.
	--- @param mods table|nil Modifier list.
	--- @param key string|nil Key name.
	--- @param opts table|nil Optional flags: opts.silent = true skips save_prefs/update_menu.
	function inst.apply_llm_profile_shortcut(profile_id, mods, key, opts)
		if type(profile_id) ~= "string" or profile_id == "" then return end

		local profile_hks = get_profile_hks()
		if profile_hks[profile_id] then
			pcall(function() profile_hks[profile_id]:delete() end)
			set_profile_hk(profile_id, nil)
		end

		if type(state.llm_profile_shortcuts) ~= "table" then state.llm_profile_shortcuts = {} end

		local normalized = shortcut_ui.normalize_shortcut(mods, key, {"ctrl"})
		Logger.debug(LOG, "apply_llm_profile_shortcut('%s', mods=%s, key=%s) -> normalized=%s",
			profile_id,
			type(mods) == "table" and table.concat(mods, "+") or tostring(mods),
			key or "nil",
			normalized and (table.concat(normalized.mods, "+") .. "+" .. normalized.key) or "nil")

		if normalized then
			state.llm_profile_shortcuts[profile_id] = { mods = normalized.mods, key = normalized.key }
			local hk = inst.bind_hotkey(normalized.mods, normalized.key, function()
				Logger.debug(LOG, "Profile shortcut triggered: '%s'", profile_id)
				inst.trigger_prediction_with_profile(profile_id)
			end)
			if hk and not (type(opts) == "table" and opts.silent == true) then
				inst.activate_hotkey(hk)
			end
			set_profile_hk(profile_id, hk)
			if hk then
				Logger.debug(LOG, "Shortcut bound successfully for profile '%s'", profile_id)
			else
				Logger.error(LOG, "Shortcut binding failed for profile '%s'", profile_id)
			end
		else
			state.llm_profile_shortcuts[profile_id] = nil
			set_profile_hk(profile_id, nil)
			Logger.debug(LOG, "Shortcut disabled for profile '%s'", profile_id)
		end

		if not (type(opts) == "table" and opts.silent == true) then
			save_prefs(); update_menu()
		end
	end

	return inst
end

return M
