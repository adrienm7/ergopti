--- ui/menu/menu_llm/startup_controller.lua

--- ==============================================================================
--- MODULE: LLM Startup Controller
--- DESCRIPTION:
--- Handles the Hammerspoon startup sequence for the LLM menu: shortcut
--- restoration, profile-shortcut binding, installed-models cache polling,
--- and the MLX boot-lock flow.
---
--- FEATURES & RATIONALE:
--- 1. Isolated startup path: keeps the boot sequence separate from the
---    menu-building code in init.lua so each module has a single concern.
--- 2. MLX boot-lock: predictions are disabled until the server confirms
---    readiness so stale async callbacks never fire against a dead port.
--- 3. Retry loop: polls the installed-models cache at 1-second intervals
---    (max 10 attempts) before running the requirements check, preventing
---    false "not installed" dialogs on a fresh Hammerspoon load.
--- ==============================================================================

local M = {}

local hs      = hs
local llm_mod = require("modules.llm")
local Logger  = require("infra.logger")

local LOG = "startup_ctrl"





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Returns a check_startup closure bound to the given context.
--- Call the returned function once after all hotkeys and profile shortcuts
--- have been registered so the boot sequence can restore them safely.
--- @param ctx table Context with fields:
---   state                     table    Shared preference state.
---   keymap                    table    Keymap module (optional).
---   models_mgr                table    Models manager instance.
---   guarded_check_requirements function Wrapped check_requirements.
---   save_prefs                function Persists state to disk.
---   update_menu               function Redraws the tray menu.
---   apply_llm_shortcut        function Restores the on-demand trigger shortcut.
---   apply_llm_profile_shortcut function Binds a per-profile shortcut.
---   activate_hotkey           function Enables a hs.hotkey object.
---   mlx_deps_checker          table    MLX deps checker module.
---   deps                      table    Full deps table (for update_menu access after reload).
---   get_startup_silence       function Returns the current _startup_silence flag.
---   set_startup_silence       function Sets the _startup_silence flag.
---   get_trigger_hk            function Returns the current _llm_trigger_hk handle.
---   get_profile_hks           function Returns the current _llm_profile_hks map.
--- @return function check_startup The startup function to call once.
function M.new(ctx)
	local state                      = ctx.state
	local keymap                     = ctx.keymap
	local models_mgr                 = ctx.models_mgr
	local guarded_check_requirements = ctx.guarded_check_requirements
	local save_prefs                 = ctx.save_prefs
	local update_menu                = ctx.update_menu
	local apply_llm_shortcut         = ctx.apply_llm_shortcut
	local apply_llm_profile_shortcut = ctx.apply_llm_profile_shortcut
	local activate_hotkey            = ctx.activate_hotkey
	local mlx_deps_checker           = ctx.mlx_deps_checker
	local deps                       = ctx.deps
	local get_startup_silence        = ctx.get_startup_silence
	local set_startup_silence        = ctx.set_startup_silence
	local get_trigger_hk             = ctx.get_trigger_hk
	local get_profile_hks            = ctx.get_profile_hks

	local _check_startup_attempts = nil
	-- Shared guard between the self-rescheduling primary requirements chain
	-- (do_check_requirements) and the unrelated 3 s "backup" check below: both
	-- independently call keymap.set_llm_enabled(true) on success with no
	-- coordination, so if the primary chain's disable_llm() already ran
	-- (state.llm_enabled = false) the backup's later success could silently
	-- re-enable LLM against that decision, or the two checks could otherwise
	-- race with no defined winner (F-MED-32). Bumped whenever a chain
	-- reaches a terminal outcome (success or disable_llm); each chain
	-- captures its own generation up front and re-checks it before acting.
	local _startup_check_generation = 0


	-- =====================================================
	-- ===== 1.1) Startup sequence =====
	-- =====================================================

	--- Runs the full startup sequence: download reattachment, shortcut restoration,
	--- profile-shortcut binding, hotkey activation, and requirements check.
	local function check_startup()
		Logger.info(LOG, "═══════════════ Starting menu_llm ═══════════════")

		-- Reattach a model download that was still running before a Hammerspoon reload
		hs.timer.doAfter(0.5, function()
			local sf = io.open("/tmp/hs_mlx_active_download.json", "r")
			if sf then
				local raw = sf:read("*a"); sf:close()
				local ok_j, sess = pcall(hs.json.decode, raw)
				if ok_j and type(sess) == "table" and type(sess.log_path) == "string" then
					Logger.info(LOG, "Active download session found after reload — reattaching.")
					if models_mgr and type(models_mgr.reattach_download) == "function" then
						pcall(models_mgr.reattach_download, sess)
						if type(deps.update_menu) == "function" then pcall(deps.update_menu) end
					end
				end
			end
		end)

		-- Silence save_prefs/update_menu during bulk shortcut restoration so the
		-- menu is not redrawn for every individual bind call. The whole restoration
		-- is wrapped in pcall: a failure here (e.g. a menu rebuild throwing while a
		-- profile/label change is mid-flight) must NOT abort the model-startup path
		-- below — the MLX server has to come up even if shortcut restoration
		-- hiccups. The error is logged loudly (and, via the runtime capture
		-- installed in init.lua, lands in the file log) instead of silently killing
		-- the entire LLM boot the way it did before this guard.
		set_startup_silence(true)
		local ok_restore, restore_err = pcall(function()
			if type(state.llm_trigger_shortcut) == "table" then
				Logger.debug(LOG, string.format("Restoring trigger shortcut: %s+%s.",
					table.concat(state.llm_trigger_shortcut.mods or {}, "+"),
					state.llm_trigger_shortcut.key or "nil"))
				apply_llm_shortcut(state.llm_trigger_shortcut.mods, state.llm_trigger_shortcut.key)
			else
				Logger.debug(LOG, "No global trigger shortcut configured.")
			end

			-- Rebuild the set of valid profile ids from built-ins + user profiles
			local valid_profile_ids = {}
			local builtin_count = 0
			for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
				if type(profile) == "table" and type(profile.id) == "string" then
					valid_profile_ids[profile.id] = true
					builtin_count = builtin_count + 1
				end
			end
			Logger.debug(LOG, string.format("Built-in profiles loaded: %d.", builtin_count))

			local user_count = 0
			for _, profile in ipairs(type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}) do
				if type(profile) == "table" and type(profile.id) == "string" then
					valid_profile_ids[profile.id] = true
					user_count = user_count + 1
				end
			end
			Logger.debug(LOG, string.format("User profiles loaded: %d.", user_count))

			local profile_shortcuts = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts or {}
			local sc_count = 0
			for _ in pairs(profile_shortcuts) do sc_count = sc_count + 1 end
			Logger.info(LOG, string.format("Profile shortcuts loaded: %d entries.", sc_count))

			for profile_id, sc in pairs(profile_shortcuts) do
				local mods_str = (type(sc) == "table" and type(sc.mods) == "table") and table.concat(sc.mods, "+") or "nil"
				local key_str  = (type(sc) == "table" and type(sc.key) == "string") and sc.key or "nil"
				Logger.debug(LOG, string.format("Profile '%s': mods=%s, key=%s.", profile_id, mods_str, key_str))
				if valid_profile_ids[profile_id] and type(sc) == "table" then
					Logger.debug(LOG, string.format("Binding shortcut for profile '%s' on startup.", profile_id))
					apply_llm_profile_shortcut(profile_id, sc.mods, sc.key, { silent = true })
				else
					Logger.warn(LOG, string.format("Removing invalid shortcut for profile '%s'.", profile_id))
					apply_llm_profile_shortcut(profile_id, nil, nil, { silent = true })
				end
			end

			Logger.debug(LOG, "Activating bound hotkeys…")
			local trigger_hk  = get_trigger_hk()
			local profile_hks = get_profile_hks()
			if trigger_hk then activate_hotkey(trigger_hk) end
			for _, hk in pairs(profile_hks) do
				if hk then activate_hotkey(hk) end
			end
		end)
		set_startup_silence(false)
		if not ok_restore then
			Logger.error(LOG, "LLM shortcut/profile restoration failed at startup — continuing to model startup so the server still launches: %s",
				tostring(restore_err))
		end

		if not state.llm_enabled then
			Logger.debug(LOG, "LLM disabled at startup.")
			return
		end

		Logger.info(LOG, string.format("LLM enabled at startup, model: %s.", state.llm_model or "nil"))

		local function disable_llm()
			Logger.error(LOG, "Disabling LLM (requirements check failed).")
			state.llm_enabled = false
			-- Bump so a still-pending backup/primary check (whichever did not
			-- reach this terminal outcome) discards its own later success and
			-- does not silently re-enable LLM against this decision (F-MED-32).
			_startup_check_generation = _startup_check_generation + 1
			if keymap and type(keymap.set_llm_enabled) == "function" then
				pcall(keymap.set_llm_enabled, false)
			end
			if save_prefs() ~= true then return false end
			update_menu()
		end

		if not state.llm_model or state.llm_model == "" then
			Logger.warn(LOG, "No model configured at startup.")
			return
		end

		-- Lock MLX predictions during server initialization — weights take 60–90 s to load
		if state.llm_backend == "mlx" then
			Logger.debug(LOG, "MLX mode: locking predictions during initialization.")
			if keymap and type(keymap.set_llm_enabled) == "function" then
				pcall(keymap.set_llm_enabled, false)
			end
		end

		if keymap and type(keymap.set_llm_backend_name) == "function" then
			local backend_label = ""
			if state.llm_backend == "mlx"    then backend_label = "MLX 🚀"    end
			if state.llm_backend == "ollama" then backend_label = "Ollama 🦙" end
			pcall(keymap.set_llm_backend_name, backend_label)
		end

		Logger.debug(LOG, string.format("Checking model requirements: %s.", state.llm_model))

		-- Captured once for this boot's pair of independently-scheduled checks
		-- (the self-rescheduling primary chain and the unrelated 3 s "backup"
		-- check) so each can detect whether the OTHER already reached a
		-- terminal outcome and discard its own stale success (F-MED-32).
		local my_startup_gen = _startup_check_generation

		-- Poll installed-models cache until populated — refresh_installed_async fires
		-- at doAfter(0), so the first tick may return an empty table.
		local function do_check_requirements()
			local installed = models_mgr.get_installed_models()
			local count = 0; for _ in pairs(installed) do count = count + 1 end
			Logger.debug(LOG, string.format("Startup installed-models cache count: %d.", count))
			if count == 0 then
				if not _check_startup_attempts then _check_startup_attempts = 0 end
				_check_startup_attempts = _check_startup_attempts + 1
				Logger.debug(LOG, string.format("Requirements deferred (attempt %d/10).", _check_startup_attempts))
				if _check_startup_attempts < 10 then
					hs.timer.doAfter(1, do_check_requirements)
					return
				end
				-- After 10 s, proceed anyway (Ollama may simply not be running yet)
			end
			_check_startup_attempts = nil

			local check_fn = guarded_check_requirements
			if state.llm_backend == "mlx" and type(models_mgr.force_mlx_check) == "function" then
				Logger.debug(LOG, string.format("Startup MLX: forcing requirements check for %s.", state.llm_model))
				check_fn = function(model_name, on_ok, on_fail)
					models_mgr.force_mlx_check(model_name, on_ok, on_fail, { silent_notifications = false })
				end
			end

			check_fn(state.llm_model, function()
				-- Discard if the OTHER (backup) check already reached a terminal
				-- outcome (e.g. disable_llm ran) since this chain started (F-MED-32).
				if my_startup_gen ~= _startup_check_generation then
					Logger.debug(LOG, "Startup primary check: stale success discarded (gen %d != %d).",
						my_startup_gen, _startup_check_generation)
					return
				end
				_startup_check_generation = _startup_check_generation + 1
				Logger.info(LOG, string.format("Requirements verified for %s.", state.llm_model))
				if state.llm_backend == "mlx" and state.llm_enabled
					and keymap and type(keymap.set_llm_enabled) == "function" then
					-- Re-read the LIVE flag: the user may have turned AI off during the
					-- seconds this check was in flight, and a late success that
					-- re-enables it silently reverts their choice.
					if state.llm_enabled then
						Logger.debug(LOG, "Reactivating MLX predictions.")
						pcall(keymap.set_llm_enabled, true)
					else
						Logger.debug(LOG, "MLX check succeeded but AI was turned off meanwhile — not re-enabling.")
					end
				end
			end, disable_llm)
		end
		hs.timer.doAfter(1, do_check_requirements)

		-- Backup path: re-run the MLX boot check after 3 s in case the primary
		-- callback chain was skipped (edge case on very slow machines).
		hs.timer.doAfter(3, function()
			-- The primary chain (or a prior disable_llm) may have already
			-- reached a terminal outcome by now — skip entirely rather than
			-- dispatching a redundant/racing force_mlx_check (F-MED-32).
			if my_startup_gen ~= _startup_check_generation then
				Logger.debug(LOG, "Startup MLX backup check: primary chain already resolved (gen %d != %d) — skipping.",
					my_startup_gen, _startup_check_generation)
				return
			end
			if state.llm_backend == "mlx" and state.llm_enabled
				and state.llm_model and state.llm_model ~= ""
				and type(models_mgr.force_mlx_check) == "function" then
				Logger.debug(LOG, string.format("Startup MLX backup check fired for %s.", state.llm_model))
				models_mgr.force_mlx_check(state.llm_model, function()
					if my_startup_gen ~= _startup_check_generation then
						Logger.debug(LOG, "Startup MLX backup check: stale success discarded (gen %d != %d).",
							my_startup_gen, _startup_check_generation)
						return
					end
					_startup_check_generation = _startup_check_generation + 1
					Logger.info(LOG, string.format("Startup MLX backup check succeeded for %s.", state.llm_model))
					-- Same live re-read as the primary path: the generation guard
					-- catches a terminal outcome, not a user toggle.
					if not state.llm_enabled then
						Logger.debug(LOG, "Backup check succeeded but AI was turned off meanwhile — not re-enabling.")
					elseif keymap and type(keymap.set_llm_enabled) == "function" then
						pcall(keymap.set_llm_enabled, true)
					end
				end, function()
					Logger.warn(LOG, string.format("Startup MLX backup check failed for %s.", state.llm_model))
				end, { silent_notifications = false })
			end
		end)

		Logger.info(LOG, "═══════════════ Startup completed for menu_llm ═══════════════")
	end

	return check_startup
end

return M
