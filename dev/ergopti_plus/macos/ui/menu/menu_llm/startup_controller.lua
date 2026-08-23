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
local TimerScheduler = require("adapters.timer_scheduler")
local PredictionLockRegistry = require("ui.menu.menu_llm.prediction_lock_registry")

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
	local prediction_locks = type(ctx.prediction_locks) == "table"
		and ctx.prediction_locks or PredictionLockRegistry.new({
			state = state,
			keymap = keymap,
		})
	local function pause_epoch()
		local control = deps and deps.script_control
		if not control or type(control.get_pause_epoch) ~= "function" then return 0 end
		local ok, epoch = xpcall(control.get_pause_epoch, debug.traceback)
		return ok and tonumber(epoch) or -1
	end
	local function runtime_current(epoch)
		local control = deps and deps.script_control
		if pause_epoch() ~= epoch then return false end
		if control and type(control.is_paused) == "function" then
			local ok, paused = xpcall(control.is_paused, debug.traceback)
			return ok and paused ~= true
		end
		return true
	end

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
	local _startup_timer_generation = 0
	local _startup_paused = false
	local _startup_cycle_active = false
	local _startup_requested = false
	local _startup_abort_pending = false
	local _startup_settlement_finalize = nil
	local _startup_callback_depth = 0
	local _startup_sync_in_progress = false
	local _restart_requirements_cycle = nil
	local _reattach_callback = nil
	local _reattach_callback_in_progress = false
	local _reattach_active = false
	local _reattach_dispatch_in_progress = false
	local _pause_snapshot = nil
	local _startup_prediction_lock = nil
	local _startup_prediction_lock_id = {}
	-- Unforgeable capability used only by this owner's transactional RESUME.
	-- ScriptControl intentionally keeps its public paused bit set until every
	-- owner has resumed, so the owner needs a narrowly-scoped way to stage its
	-- deferred timers without opening the public check_startup entry point.
	local _transactional_resume_authority = {}
	local script_control = deps and deps.script_control or nil
	local requirement_owner = nil
	if script_control then
		if type(models_mgr.create_requirement_owner) ~= "function" then
			Logger.error(LOG,
				"Startup requirement-owner factory is unavailable.")
		else
			local ok, owner = Logger.callback(LOG,
				"Startup requirement-owner creation",
				models_mgr.create_requirement_owner,
				"startup")
			if ok == true and type(owner) == "table" then
				requirement_owner = owner
			else
				Logger.error(LOG, "Startup requirement-owner creation was refused.")
			end
		end
	end
	local pause_owner_registered = script_control == nil
	local _timer_slots = {
		reattach = nil,
		primary = nil,
		backup = nil,
	}

	--- Cancels one exact startup timer. False, nil, and throw all retain the
	--- original capability for a later retry; its callback is separately fenced.
	--- @param slot string Timer-slot name.
	--- @return boolean settled
	local function cancel_startup_timer(slot)
		local owner = _timer_slots[slot]
		if owner == nil then return true end
		owner.authorized = false
		owner.committed = false
		if owner.handle == nil then
			if owner.installing == true then return false end
			if _timer_slots[slot] == owner then _timer_slots[slot] = nil end
			return true
		end
		local ok_cancel, settled_or_error = xpcall(function()
			return TimerScheduler.cancel(owner.handle)
		end, debug.traceback)
		if ok_cancel ~= true or settled_or_error ~= true then
			Logger.error(LOG,
				"Startup timer '%s' cancellation remains unsettled; exact owner retained: %s.",
				slot, tostring(settled_or_error))
			return false
		end
		if _timer_slots[slot] == owner then _timer_slots[slot] = nil end
		return true
	end

	--- Cancels every startup timer without short-circuiting sibling cleanup.
	--- @return boolean settled
	local function cancel_startup_timers()
		local settled = true
		for _, slot in ipairs({ "reattach", "primary", "backup" }) do
			if cancel_startup_timer(slot) ~= true then settled = false end
		end
		return settled
	end

	--- Arms one one-shot timer as an exact owned capability.
	--- @param slot string Timer-slot name.
	--- @param delay number Delay in seconds.
	--- @param callback function Deferred work.
	--- @return boolean committed
	local function arm_startup_timer(slot, delay, callback, on_callback_failure)
		if _startup_paused == true then return false end
		if cancel_startup_timer(slot) ~= true then return false end
		local generation = _startup_timer_generation
		local owner = {
			handle = nil,
			authorized = true,
			committed = false,
			installing = true,
			native_settled = false,
			callback_pending = false,
			callback_consumed = false,
		}
		-- Publish before TimerScheduler crosses native start(). Re-entrant PAUSE can
		-- fence this exact acquisition, and the return path compensates its handle.
		_timer_slots[slot] = owner

		local function deliver_callback()
			if owner.callback_pending ~= true or owner.callback_consumed == true
				or owner.native_settled ~= true or owner.committed ~= true then
				return false
			end
			owner.callback_consumed = true
			owner.callback_pending = false
			owner.committed = false
			if owner.authorized ~= true
				or generation ~= _startup_timer_generation
				or _startup_paused == true then
				return true
			end
			_startup_callback_depth = _startup_callback_depth + 1
			local ok_callback, callback_error = xpcall(callback, debug.traceback)
			if not ok_callback then
				Logger.error(LOG, "Startup timer '%s' callback failed: %s.",
					slot, tostring(callback_error))
				if type(on_callback_failure) == "function" then
					Logger.callback(LOG,
						"Startup timer failure compensation",
						on_callback_failure,
						slot,
						callback_error)
				end
			end
			_startup_callback_depth = _startup_callback_depth - 1
			return ok_callback == true
		end

		local function timer_callback()
			if owner.callback_consumed == true or owner.callback_pending == true then
				return false
			end
			owner.callback_pending = true
			if owner.installing == true then return true end
			deliver_callback()
			return true
		end

		local ok_timer, handle_or_error, timer_committed = xpcall(function()
			return TimerScheduler.after(delay, timer_callback)
		end, debug.traceback)
		owner.installing = false
		if ok_timer == true and type(handle_or_error) == "table" then
			owner.handle = handle_or_error
			local observed_ok, observed = xpcall(function()
				return TimerScheduler.onSettled(handle_or_error, function()
					owner.native_settled = true
					if _timer_slots[slot] == owner then _timer_slots[slot] = nil end
					deliver_callback()
				end)
			end, debug.traceback)
			if observed_ok ~= true or observed ~= true then
				owner.authorized = false
				owner.committed = false
				local cancel_ok, settled = xpcall(function()
					return TimerScheduler.cancel(handle_or_error)
				end, debug.traceback)
				if cancel_ok == true and settled == true
					and _timer_slots[slot] == owner then
					_timer_slots[slot] = nil
				end
				Logger.error(LOG,
					"Startup timer '%s' settlement observation failed: %s.",
					slot, tostring(observed))
				return false
			end
		end
		if ok_timer ~= true or type(handle_or_error) ~= "table"
			or timer_committed ~= true then
			owner.authorized = false
			owner.committed = false
			if owner.handle ~= nil then
				xpcall(function() return TimerScheduler.cancel(owner.handle) end,
					debug.traceback)
			elseif _timer_slots[slot] == owner then
				_timer_slots[slot] = nil
			end
			Logger.error(LOG, "Startup timer '%s' could not be armed: %s.",
				slot, tostring(ok_timer and timer_committed or handle_or_error))
			return false
		end
		if owner.authorized ~= true then
			local cancel_ok, settled = xpcall(function()
				return TimerScheduler.cancel(owner.handle)
			end, debug.traceback)
			if cancel_ok == true and settled == true
				and _timer_slots[slot] == owner then
				_timer_slots[slot] = nil
			end
			return false
		end
		owner.committed = true
		deliver_callback()
		return true
	end

	--- Acquires the MLX startup lock exactly once.
	--- @return boolean committed
	local function acquire_startup_prediction_lock()
		if state.llm_backend ~= "mlx" or state.llm_enabled ~= true then return true end
		_startup_prediction_lock = _startup_prediction_lock_id
		return prediction_locks.acquire(_startup_prediction_lock_id) == true
	end

	--- Reasserts a retained startup lock after a resume setter mutated the live
	--- gate before refusing or throwing. The exact owner remains unchanged.
	--- @return boolean settled
	local function reassert_startup_prediction_lock()
		_startup_prediction_lock = _startup_prediction_lock_id
		return prediction_locks.ensure_locked(_startup_prediction_lock_id) == true
	end

	--- Restores and consumes the exact startup prediction lock once. A disabled
	--- persisted preference consumes it without re-enabling the engine.
	--- @return boolean settled
	local function restore_startup_prediction_lock()
		local owner = _startup_prediction_lock
		if owner == nil then return true end
		if prediction_locks.release(_startup_prediction_lock_id) ~= true then return false end
		if _startup_prediction_lock == owner then _startup_prediction_lock = nil end
		return true
	end

	--- Fences and joins the exact MLX requirement tasks beneath startup callbacks.
	--- @return boolean settled True only after every retained task completed.
	local function pause_requirement_tasks()
		if requirement_owner == nil then
			-- Legacy standalone construction has no ScriptControl pause transaction.
			-- A registered production owner, however, must never lose provenance.
			return script_control == nil
		end
		if type(models_mgr.pause_requirements) ~= "function" then
			Logger.error(LOG,
				"Startup requirement pause primitive is unavailable.")
			return false
		end
		local ok, result = Logger.callback(LOG,
			"Startup requirement-task pause",
			models_mgr.pause_requirements,
			requirement_owner)
		return ok == true and result == true
	end

	--- Retries every exact capability retained by an aborted startup cycle. The
	--- prediction lock is intentionally released last: a still-live requirement
	--- task must never run below an unlocked engine after its dispatch refused.
	--- @return boolean settled
	local function settle_startup_abort()
		if _startup_abort_pending ~= true then return true end
		local timers_settled = cancel_startup_timers()
		local requirements_settled = pause_requirement_tasks()
		local prediction_settled = false
		if requirements_settled == true then
			prediction_settled = restore_startup_prediction_lock() == true
		end
		local native_settled = timers_settled == true
			and requirements_settled == true and prediction_settled == true
		local finalize_settled = _startup_settlement_finalize == nil
		if native_settled and type(_startup_settlement_finalize) == "function" then
			_startup_callback_depth = _startup_callback_depth + 1
			local ok, result = Logger.callback(LOG,
				"Startup terminal finalization", _startup_settlement_finalize)
			_startup_callback_depth = _startup_callback_depth - 1
			finalize_settled = ok == true and result == true
		end
		if native_settled and finalize_settled then
			_startup_abort_pending = false
			_startup_settlement_finalize = nil
			return true
		end
		return false
	end

	--- Quiesces one startup cycle before any terminal state is published. The same
	--- path handles failures and winning primary/backup terminals so a losing
	--- requirement child can never outlive prediction-lock release.
	--- @param reason string Terminal or failure boundary used for diagnostics.
	--- @param finalize function|nil Exact business terminal committed after joins.
	--- @return boolean settled
	local function quiesce_startup_cycle(reason, finalize)
		if finalize ~= nil then
			if _startup_settlement_finalize ~= nil
				and _startup_settlement_finalize ~= finalize then
				Logger.error(LOG,
					"Startup terminal '%s' refused behind a prior unsettled terminal.",
					tostring(reason))
				return false
			end
			_startup_settlement_finalize = finalize
		end
		_startup_cycle_active = false
		_startup_check_generation = _startup_check_generation + 1
		_startup_timer_generation = _startup_timer_generation + 1
		_startup_abort_pending = true
		if settle_startup_abort() ~= true then
			Logger.error(LOG,
				"Startup-cycle settlement remains unsettled after '%s'.",
				tostring(reason))
			return false
		end
		return true
	end

	--- Fences an abandoned startup cycle, releases every owned timer, and restores
	--- the prediction gate if this controller acquired it. Each capability stays
	--- in its ledger when native settlement is refused so a pause-owner retry can
	--- complete it later.
	--- @param reason string Failure boundary used for diagnostics.
	--- @return boolean settled
	local function abort_startup_cycle(reason)
		return quiesce_startup_cycle(reason)
	end

	--- Defers a synchronous manager terminal until its dispatch has returned a
	--- literal ownership commit. A callback fired before false/nil/throw must not
	--- publish success or consume the prediction lease.
	local function dispatch_requirements_exact(label, dispatch_fn, model_name,
		on_ok, on_fail, opts)
		local dispatching = true
		local terminal_sent = false
		local buffered = nil
		local function deliver(callback, ...)
			if terminal_sent then return false end
			terminal_sent = true
			_startup_callback_depth = _startup_callback_depth + 1
			local ok, result = Logger.callback(LOG, label .. " terminal", callback, ...)
			_startup_callback_depth = _startup_callback_depth - 1
			return ok == true and result == true
		end
		local function buffer_or_deliver(kind, callback, ...)
			if dispatching then
				if buffered ~= nil then return false end
				buffered = { kind = kind, callback = callback, args = table.pack(...) }
				return true
			end
			return deliver(callback, ...)
		end
		local dispatch_ok, dispatch_result = Logger.callback(LOG, label,
			dispatch_fn, model_name,
			function(...) return buffer_or_deliver("ok", on_ok, ...) end,
			function(...) return buffer_or_deliver("fail", on_fail, ...) end,
			opts)
		dispatching = false
		if dispatch_ok ~= true or dispatch_result ~= true then
			buffered = nil
			terminal_sent = true
			return false
		end
		if buffered ~= nil then
			local terminal = buffered
			buffered = nil
			return deliver(terminal.callback,
				table.unpack(terminal.args, 1, terminal.args.n)) == true
		end
		return true
	end


	-- =====================================================
	-- ===== 1.1) Startup sequence =====
	-- =====================================================

	--- Runs the full startup sequence: download reattachment, shortcut restoration,
	--- profile-shortcut binding, hotkey activation, and requirements check.
	local function check_startup_impl(resume_authority, resume_epoch)
		if pause_owner_registered ~= true then
			Logger.error(LOG, "LLM startup refused because its pause owner is not registered.")
			return false
		end
		local globally_paused = false
		if script_control and type(script_control.is_paused) == "function" then
			local ok_paused, paused = xpcall(script_control.is_paused, debug.traceback)
			globally_paused = ok_paused and paused == true
		end
		local transactional_resume = resume_authority == _transactional_resume_authority
			and _startup_paused ~= true
			and pause_epoch() == resume_epoch
		if _startup_paused == true or (globally_paused and not transactional_resume) then
			_startup_paused = true
			_startup_requested = true
			Logger.debug(LOG, "LLM startup deferred until script control resumes.")
			return true
		end
		if settle_startup_abort() ~= true then
			Logger.error(LOG,
				"LLM startup refused while prior abort cleanup remains unsettled.")
			return false
		end
		_startup_requested = false
		Logger.info(LOG, "═══════════════ Starting menu_llm ═══════════════")

		-- Reattach a model download that was still running before a Hammerspoon reload
		_reattach_callback = function()
			local callback_epoch = pause_epoch()
			_reattach_callback_in_progress = true
			local callback_ok, callback_result = xpcall(function()
				local sf = io.open("/tmp/hs_mlx_active_download.json", "r")
				if sf then
					local raw = sf:read("*a"); sf:close()
					local ok_j, sess = pcall(hs.json.decode, raw)
					if _startup_paused == true or not runtime_current(callback_epoch) then
						return false
					end
					if ok_j and type(sess) == "table" and type(sess.log_path) == "string" then
					Logger.info(LOG, "Active download session found after reload — reattaching.")
					if models_mgr and type(models_mgr.reattach_download) == "function" then
						local reattach_epoch = pause_epoch()
						local reattach_authorized = true
						local dispatch_in_progress = true
						local terminal_during_dispatch = false
						_reattach_active = true
						_reattach_dispatch_in_progress = true
						local opts = {
							is_current = function()
								return reattach_authorized == true
									and _startup_paused ~= true
									and runtime_current(reattach_epoch)
							end,
							on_terminal = function()
								if dispatch_in_progress then
									terminal_during_dispatch = true
								end
								_reattach_active = false
								return true
							end,
						}
						local dispatched, result = Logger.callback(LOG,
							"MLX download reattachment dispatch",
							models_mgr.reattach_download,
							sess,
							opts)
						dispatch_in_progress = false
						_reattach_dispatch_in_progress = false
						-- A dispatch that mutates before returning false/nil/throw may
						-- already own native download work. Keep that ambiguous owner
						-- until the manager probe or exact compensation proves otherwise;
						-- acceptance is not ownership evidence.
						_reattach_active = terminal_during_dispatch ~= true
						if type(models_mgr.has_reattached_download) == "function" then
							local active_ok, active = Logger.callback(LOG,
								"MLX reattachment ownership probe",
								models_mgr.has_reattached_download)
							-- Only a literal false is proof that the mutating dispatch did
							-- not retain work. A nil/non-boolean/throwing probe is itself
							-- unsettled and must preserve ambiguous ownership for cleanup.
							if active_ok == true and type(active) == "boolean" then
								_reattach_active = terminal_during_dispatch ~= true and active
							end
						end
						-- A PAUSE that re-entered this dispatch can fail and roll this owner
						-- back before the manager call returns. Adopt the resulting ACTIVE
						-- epoch only after both local and global pause gates prove reopened;
						-- a committed PAUSE must keep the original epoch stale.
						local resumed_epoch = pause_epoch()
						if _startup_paused ~= true and runtime_current(resumed_epoch) then
							reattach_epoch = resumed_epoch
						end
						local dispatch_current = opts.is_current()
						if dispatched ~= true or result ~= true or dispatch_current ~= true then
							reattach_authorized = false
							if _reattach_active
								and type(models_mgr.pause_reattached_download) == "function" then
								Logger.callback(LOG, "MLX reattachment refusal compensation",
									models_mgr.pause_reattached_download)
							end
							Logger.error(LOG,
								"MLX download reattachment was refused or superseded: %s.",
								tostring(result))
							return false
						end
						if dispatch_current
							and deps and type(deps.update_menu) == "function" then
							Logger.callback(LOG, "MLX reattachment menu refresh", deps.update_menu)
						end
						return true
					end
					end
				end
				return true
			end, debug.traceback)
			_reattach_callback_in_progress = false
			if callback_ok ~= true then
				Logger.error(LOG, "MLX reattachment callback failed: %s.",
					tostring(callback_result))
				return false
			end
			return callback_result == true
		end
		if arm_startup_timer("reattach", 0.5, _reattach_callback) ~= true then
			Logger.error(LOG, "Download reattachment timer could not be armed.")
		end
		if _startup_paused == true then return false end

		-- Silence save_prefs/update_menu during bulk shortcut restoration so the
		-- menu is not redrawn for every individual bind call. The whole restoration
		-- is wrapped in pcall: a failure here (e.g. a menu rebuild throwing while a
		-- profile/label change is mid-flight) must NOT abort the model-startup path
		-- below — the MLX server has to come up even if shortcut restoration
		-- hiccups. The error is logged loudly (and, via the runtime capture
		-- installed in init.lua, lands in the file log) instead of silently killing
		-- the entire LLM boot the way it did before this guard.
		set_startup_silence(true)
		if _startup_paused == true then
			set_startup_silence(false)
			return false
		end
		local ok_restore, restore_err = pcall(function()
			if type(state.llm_trigger_shortcut) == "table" then
				Logger.debug(LOG, string.format("Restoring trigger shortcut: %s+%s.",
					table.concat(state.llm_trigger_shortcut.mods or {}, "+"),
					state.llm_trigger_shortcut.key or "nil"))
				apply_llm_shortcut(state.llm_trigger_shortcut.mods, state.llm_trigger_shortcut.key)
				if _startup_paused == true then return false end
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
				if _startup_paused == true then return false end
			end

			Logger.debug(LOG, "Activating bound hotkeys…")
			local trigger_hk  = get_trigger_hk()
			local profile_hks = get_profile_hks()
			if trigger_hk then
				activate_hotkey(trigger_hk)
				if _startup_paused == true then return false end
			end
			for _, hk in pairs(profile_hks) do
				if hk then
					activate_hotkey(hk)
					if _startup_paused == true then return false end
				end
			end
			return true
		end)
		set_startup_silence(false)
		if _startup_paused == true then return false end
		if ok_restore == true and restore_err ~= true then
			Logger.error(LOG,
				"LLM shortcut/profile restoration was superseded by PAUSE.")
			return false
		end
		if not ok_restore then
			Logger.error(LOG, "LLM shortcut/profile restoration failed at startup — continuing to model startup so the server still launches: %s",
				tostring(restore_err))
		end

		if not state.llm_enabled then
			Logger.debug(LOG, "LLM disabled at startup.")
			return true
		end

		Logger.info(LOG, string.format("LLM enabled at startup, model: %s.", state.llm_model or "nil"))

		local function disable_llm()
			Logger.error(LOG, "Disabling LLM (requirements check failed).")
			state.llm_enabled = false
			local preference_applied = false
			local prefs_saved = false
			local menu_updated = false
			local function finalize_disable()
				if _startup_paused == true then return false end
				if not preference_applied then
					if type(prediction_locks.apply_preference) == "function"
						and prediction_locks.apply_preference(false) ~= true then
						return false
					end
					preference_applied = true
					if _startup_paused == true then return false end
				end
				if not prefs_saved then
					if save_prefs() ~= true then return false end
					prefs_saved = true
					if _startup_paused == true then return false end
				end
				if not menu_updated then
					local ok = Logger.callback(LOG,
						"Disabled startup menu refresh", update_menu)
					if ok ~= true then return false end
					menu_updated = true
					if _startup_paused == true then return false end
				end
				return true
			end
			return quiesce_startup_cycle(
				"failed requirements terminal", finalize_disable)
		end

		if not state.llm_model or state.llm_model == "" then
			Logger.warn(LOG, "No model configured at startup.")
			return true
		end

		-- Lock MLX predictions during server initialization — weights take 60–90 s to load
		if state.llm_backend == "mlx" then
			Logger.debug(LOG, "MLX mode: locking predictions during initialization.")
			if acquire_startup_prediction_lock() ~= true then
				Logger.error(LOG, "MLX startup prediction lock could not be acquired.")
				abort_startup_cycle("prediction lock acquisition")
				return false
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
		_restart_requirements_cycle = function()
			if _startup_paused == true or state.llm_enabled ~= true
				or not state.llm_model or state.llm_model == "" then
				return false
			end
			_startup_cycle_active = true
			_check_startup_attempts = nil
			local my_startup_gen = _startup_check_generation
			local my_pause_epoch = pause_epoch()
			local compensate_timer_callback

		-- Poll installed-models cache until populated — refresh_installed_async fires
		-- at doAfter(0), so the first tick may return an empty table.
		local function do_check_requirements()
			if not runtime_current(my_pause_epoch) then return end
			local installed = models_mgr.get_installed_models()
			if _startup_paused == true or not runtime_current(my_pause_epoch) then
				return false
			end
			local count = 0; for _ in pairs(installed) do count = count + 1 end
			Logger.debug(LOG, string.format("Startup installed-models cache count: %d.", count))
			if count == 0 then
				if not _check_startup_attempts then _check_startup_attempts = 0 end
				_check_startup_attempts = _check_startup_attempts + 1
				Logger.debug(LOG, string.format("Requirements deferred (attempt %d/10).", _check_startup_attempts))
				if _check_startup_attempts < 10 then
					if arm_startup_timer("primary", 1, do_check_requirements,
						compensate_timer_callback) ~= true then
						abort_startup_cycle("primary retry timer")
					end
					return
				end
				-- After 10 s, proceed anyway (Ollama may simply not be running yet)
			end
			_check_startup_attempts = nil

			local check_fn = function(model_name, on_ok, on_fail)
				return models_mgr.check_requirements(model_name, on_ok, on_fail, {
					silent_notifications = false,
					requirement_owner = requirement_owner,
					is_current = function()
						return my_startup_gen == _startup_check_generation
							and runtime_current(my_pause_epoch)
					end,
				})
			end
			if state.llm_backend == "mlx" and type(models_mgr.force_mlx_check) == "function" then
				Logger.debug(LOG, string.format("Startup MLX: forcing requirements check for %s.", state.llm_model))
				check_fn = function(model_name, on_ok, on_fail)
					return models_mgr.force_mlx_check(model_name, on_ok, on_fail, {
						silent_notifications = false,
						requirement_owner = requirement_owner,
						is_current = function()
							return my_startup_gen == _startup_check_generation
								and runtime_current(my_pause_epoch)
						end,
					})
				end
			end

			local dispatch_result = dispatch_requirements_exact(
				"Startup requirements dispatch", check_fn, state.llm_model, function()
				-- Discard if the OTHER (backup) check already reached a terminal
				-- outcome (e.g. disable_llm ran) since this chain started (F-MED-32).
				if my_startup_gen ~= _startup_check_generation or not runtime_current(my_pause_epoch) then
					Logger.debug(LOG, "Startup primary check: stale success discarded (gen %d != %d).",
						my_startup_gen, _startup_check_generation)
					return true
				end
				if quiesce_startup_cycle(
					"primary requirements success") ~= true then
					return false
				end
				Logger.info(LOG, string.format("Requirements verified for %s.", state.llm_model))
				if state.llm_backend == "mlx" then
					-- Re-read the LIVE flag: the user may have turned AI off during the
					-- seconds this check was in flight, and a late success that
					-- re-enables it silently reverts their choice.
					if state.llm_enabled then
						Logger.debug(LOG, "Reactivating MLX predictions.")
					else
						Logger.debug(LOG, "MLX check succeeded but AI was turned off meanwhile — not re-enabling.")
					end
				end
				return true
			end, function(...)
				if my_startup_gen ~= _startup_check_generation
					or not runtime_current(my_pause_epoch) then
					Logger.debug(LOG,
						"Startup primary failure terminal discarded after pause/supersession.")
					return false
				end
				return disable_llm(...)
			end)
			if dispatch_result ~= true then
				abort_startup_cycle("requirements dispatch")
			end
		end
		compensate_timer_callback = function(slot)
			abort_startup_cycle(slot .. " callback")
		end
		if arm_startup_timer("primary", 1, do_check_requirements,
			compensate_timer_callback) ~= true then
			abort_startup_cycle("primary timer")
			return false
		end

		-- Backup path: re-run the MLX boot check after 3 s in case the primary
		-- callback chain was skipped (edge case on very slow machines).
		if arm_startup_timer("backup", 3, function()
			-- The primary chain (or a prior disable_llm) may have already
			-- reached a terminal outcome by now — skip entirely rather than
			-- dispatching a redundant/racing force_mlx_check (F-MED-32).
			if my_startup_gen ~= _startup_check_generation or not runtime_current(my_pause_epoch) then
				Logger.debug(LOG, "Startup MLX backup check: primary chain already resolved (gen %d != %d) — skipping.",
					my_startup_gen, _startup_check_generation)
				return
			end
			if state.llm_backend == "mlx" and state.llm_enabled
				and state.llm_model and state.llm_model ~= ""
				and type(models_mgr.force_mlx_check) == "function" then
				Logger.debug(LOG, string.format("Startup MLX backup check fired for %s.", state.llm_model))
				local backup_result = dispatch_requirements_exact(
					"Startup backup requirements dispatch",
					models_mgr.force_mlx_check, state.llm_model, function()
					if my_startup_gen ~= _startup_check_generation
						or not runtime_current(my_pause_epoch) then
						Logger.debug(LOG, "Startup MLX backup check: stale success discarded (gen %d != %d).",
							my_startup_gen, _startup_check_generation)
						return true
					end
					if quiesce_startup_cycle(
						"backup requirements success") ~= true then
						return false
					end
					Logger.info(LOG, string.format("Startup MLX backup check succeeded for %s.", state.llm_model))
					-- Same live re-read as the primary path: the generation guard
					-- catches a terminal outcome, not a user toggle.
					if not state.llm_enabled then
						Logger.debug(LOG, "Backup check succeeded but AI was turned off meanwhile — not re-enabling.")
					else
						Logger.debug(LOG, "Reactivating MLX predictions from backup check.")
					end
					return true
				end, function()
					if my_startup_gen ~= _startup_check_generation
						or not runtime_current(my_pause_epoch) then
						Logger.debug(LOG,
							"Startup backup failure terminal discarded after pause/supersession.")
						return false
					end
					Logger.warn(LOG, string.format("Startup MLX backup check failed for %s.", state.llm_model))
					return true
				end, {
					silent_notifications = false,
					requirement_owner = requirement_owner,
					is_current = function()
						return my_startup_gen == _startup_check_generation
							and runtime_current(my_pause_epoch)
					end,
				})
				if backup_result ~= true then
					abort_startup_cycle("backup requirements dispatch")
				end
			end
		end, compensate_timer_callback) ~= true then
			abort_startup_cycle("backup timer")
			return false
		end
		return true
		end

		if _restart_requirements_cycle() ~= true then
			Logger.error(LOG, "LLM startup requirements cycle could not be armed.")
			abort_startup_cycle("requirements cycle")
			return false
		end

		Logger.info(LOG, "═══════════════ Startup completed for menu_llm ═══════════════")
		return true
	end

	local function check_startup(resume_authority, resume_epoch)
		if _startup_sync_in_progress == true then
			Logger.error(LOG, "Concurrent LLM startup entry was refused.")
			return false
		end
		_startup_sync_in_progress = true
		_startup_callback_depth = _startup_callback_depth + 1
		local ok, result = xpcall(function()
			return check_startup_impl(resume_authority, resume_epoch)
		end, debug.traceback)
		_startup_callback_depth = _startup_callback_depth - 1
		_startup_sync_in_progress = false
		if ok ~= true then
			Logger.error(LOG, "LLM startup transaction raised: %s.", tostring(result))
			-- The startup body may already have armed reattachment, acquired the
			-- prediction lock, or enabled the bulk-restore silence gate before an
			-- injected/native boundary raises. Fence and join those exact owners;
			-- returning directly would leave the timer free to run after failure.
			Logger.callback(LOG, "LLM startup silence exception rollback",
				set_startup_silence, false)
			local abort_ok, settled = xpcall(function()
				return abort_startup_cycle("startup transaction exception")
			end, debug.traceback)
			if abort_ok ~= true or settled ~= true then
				Logger.error(LOG,
					"LLM startup exception cleanup remains unsettled: %s.",
					tostring(settled))
			end
			return false
		end
		return result == true
	end

	local startup_pause_owner = {
		pause = function()
			local epoch = pause_epoch()
			if _startup_sync_in_progress == true then
				_startup_requested = true
			end
			if not _pause_snapshot
				or (_pause_snapshot.resume_committed == true
					and _pause_snapshot.epoch ~= epoch) then
				_pause_snapshot = {
					epoch = epoch,
					-- An acquisition published before native start is already the sole
					-- owner of this intent. If PAUSE re-enters at that boundary, its
					-- rollback must remain pending until the exact candidate settles and
					-- the same reattachment intent can be armed again.
					reattach_timer_pending = _timer_slots.reattach ~= nil
						or _reattach_callback_in_progress == true,
					reattach_active = _reattach_active == true,
					cycle_active = _startup_cycle_active == true,
					had_prediction_lock = _startup_prediction_lock ~= nil,
					deferred_start_committed = false,
					resume_committed = false,
				}
			else
				-- A later owner can fail after this owner resumed. ScriptControl then
				-- rolls us back in the same epoch, so retain the original pre-pause
				-- lock/work intent rather than snapshotting the briefly-enabled runtime.
				if _pause_snapshot.resume_committed == true
					and _pause_snapshot.epoch == epoch
					and _pause_snapshot.deferred_start_committed == true then
					_startup_requested = true
				end
				_pause_snapshot.resume_committed = false
				_pause_snapshot.epoch = epoch
			end
			-- Fence callbacks before crossing any fallible native stop. Manager
			-- continuations receive the same generation through `is_current`.
			_startup_paused = true
			_startup_timer_generation = _startup_timer_generation + 1
			_startup_check_generation = _startup_check_generation + 1
			local timers_settled = cancel_startup_timers()
			local requirements_settled = pause_requirement_tasks()
			local callbacks_settled = _startup_callback_depth == 0
			local reattach_settled = _reattach_dispatch_in_progress ~= true
				and _reattach_callback_in_progress ~= true
			if _pause_snapshot.reattach_active then
				if type(models_mgr.pause_reattached_download) ~= "function" then
					reattach_settled = false
				else
					local ok, result = Logger.callback(LOG,
						"MLX reattached monitor pause",
						models_mgr.pause_reattached_download)
					reattach_settled = ok == true and result == true
						and _reattach_dispatch_in_progress ~= true
				end
			end
			local prediction_settled = true
			if _pause_snapshot.had_prediction_lock
				or _startup_prediction_lock ~= nil then
				prediction_settled = reassert_startup_prediction_lock()
			end
			return timers_settled == true and requirements_settled == true
				and reattach_settled == true
				and callbacks_settled == true
				and prediction_settled == true
		end,
		resume = function()
			if _startup_callback_depth > 0 then
				Logger.error(LOG,
					"Startup resume refused while a prior callback remains on-stack.")
				return false
			end
			if _pause_snapshot and _pause_snapshot.resume_committed == true then
				return true
			end
			if cancel_startup_timers() ~= true then return false end
			if _pause_snapshot then _pause_snapshot.epoch = pause_epoch() end
			_startup_paused = false
			_startup_timer_generation = _startup_timer_generation + 1

			local committed = settle_startup_abort() == true
			local deferred_start = _startup_requested == true
			if deferred_start then
				local resume_epoch = pause_epoch()
				committed = check_startup(
					_transactional_resume_authority,
					resume_epoch) == true
			elseif _pause_snapshot and _pause_snapshot.reattach_active then
				if type(models_mgr.resume_reattached_download) ~= "function" then
					committed = false
				else
					local resume_epoch = pause_epoch()
					local ok, result = Logger.callback(LOG,
						"MLX reattached monitor resume",
						models_mgr.resume_reattached_download,
						{
							resume_is_current = function()
								return pause_epoch() == resume_epoch
									and _startup_paused ~= true
							end,
							is_current = function()
								return _startup_paused ~= true
									and runtime_current(resume_epoch)
							end,
							on_terminal = function()
								_reattach_active = false
								return true
							end,
						})
					committed = ok == true and result == true
				end
			elseif _pause_snapshot and _pause_snapshot.reattach_timer_pending then
				committed = type(_reattach_callback) == "function"
					and arm_startup_timer("reattach", 0.5, _reattach_callback) == true
			end
			if committed and _pause_snapshot and _pause_snapshot.cycle_active then
				committed = type(_restart_requirements_cycle) == "function"
					and _restart_requirements_cycle() == true
			elseif committed and _pause_snapshot
				and _pause_snapshot.had_prediction_lock then
				committed = restore_startup_prediction_lock() == true
			end
			if committed then
				if _pause_snapshot then
					_pause_snapshot.deferred_start_committed = deferred_start
					_pause_snapshot.resume_committed = true
				end
				return true
			end

			-- Roll an incomplete resume back to the same fenced startup state.
			if deferred_start then _startup_requested = true end
			_startup_paused = true
			_startup_timer_generation = _startup_timer_generation + 1
			_startup_check_generation = _startup_check_generation + 1
			cancel_startup_timers()
			if _pause_snapshot and _pause_snapshot.reattach_active
				and type(models_mgr.pause_reattached_download) == "function" then
				Logger.callback(LOG, "MLX reattached monitor resume rollback",
					models_mgr.pause_reattached_download)
			end
			if _pause_snapshot and (_pause_snapshot.had_prediction_lock
				or _startup_prediction_lock ~= nil) then
				reassert_startup_prediction_lock()
			end
			return false
		end,
	}

	if script_control then
		if requirement_owner == nil then
			Logger.error(LOG, "LLM startup has no exact requirement-task owner.")
			pause_owner_registered = false
		elseif type(script_control.register_pause_owner) ~= "function" then
			Logger.error(LOG,
				"Script-control pause-owner registration API is unavailable for LLM startup.")
			pause_owner_registered = false
		else
			local ok, registered = Logger.callback(LOG,
				"LLM-startup pause-owner registration",
				script_control.register_pause_owner,
				"llm_startup",
				startup_pause_owner)
			pause_owner_registered = ok == true and registered == true
			if not pause_owner_registered then
				Logger.error(LOG, "LLM-startup pause-owner registration was refused.")
			end
		end
	end

	return check_startup
end

return M
