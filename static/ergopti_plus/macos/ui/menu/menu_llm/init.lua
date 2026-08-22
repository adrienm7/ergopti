--- ui/menu/menu_llm/init.lua

--- ==============================================================================
--- MODULE: Menu LLM
--- DESCRIPTION:
--- Builds and manages the LLM system tray menu and logic bindings.
---
--- FEATURES & RATIONALE:
--- 1. Backend Agnostic: Switches gracefully between MLX and Ollama.
--- 2. Dynamic UI: Reads models from JSON configuration to build menus.
--- ==============================================================================

local M = {}

local hs            = hs
local llm_mod       = require("modules.llm")
local shortcut_ui   = require("ui.menu.shortcut_utils")
local Logger        = require("infra.logger")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")
local Models        = require("ui.menu.menu_llm.models_manager")
local Profiles      = require("ui.menu.menu_llm.profiles_manager")
local Settings      = require("ui.menu.menu_llm.settings_manager")
local TempPanel        = require("ui.menu.menu_llm.temperature_panel")
local StreamPanel      = require("ui.menu.menu_llm.streaming_panel")
local WarmupCtrl       = require("ui.menu.menu_llm.warmup_controller")
local BackendPanel     = require("ui.menu.menu_llm.backend_panel")
local TriggerPanel     = require("ui.menu.menu_llm.trigger_panel")
local ApiPanel         = require("ui.menu.menu_llm.api_panel")
local ModelsSelector   = require("ui.menu.menu_llm.models_selector")
local ModelSwitcher    = require("ui.menu.menu_llm.model_switcher")
local PredictionLockRegistry = require("ui.menu.menu_llm.prediction_lock_registry")
local ActivationPauseOwner = require("ui.menu.menu_llm.activation_pause_owner")
-- Single source of truth for the MLX server address — the health probe reads the
-- configured port from here rather than hardcoding it.
local ApiMlx           = require("modules.llm.api_mlx")
local StartupCtrl      = require("ui.menu.menu_llm.startup_controller")
local TriggerOrch      = require("ui.menu.menu_llm.trigger_orchestrator")
-- Shared cross-platform layout spec (the menu manifest's llm_menu key): the
-- single source of truth for which rows grey out while the feature is OFF, consumed
-- identically by the Windows renderer so the two menus can never drift again.
local MenuLayout       = require("ui.menu.menu_llm.menu_layout")
local ManifestMenu     = require("infra.manifest_menu")

-- Deps checkers — kicked off on backend switch and on first menu activation
-- so a fresh-out-of-the-box Mac auto-bootstraps the engine without any
-- manual user action. Both checkers are idempotent and exit silently when
-- nothing needs doing, so the menu opens instantly in the nominal case.
local mlx_deps_checker    = require("modules.llm.mlx_deps_checker")
local ollama_deps_checker = require("modules.llm.ollama_deps_checker")

local LOG = "menu_llm"

--- Wraps pcall and logs Logger.error when the wrapped call fails, so we
--- never swallow exceptions silently (violates project rule 5.3). Pass
--- the call-site label as ``name`` so the log carries enough context to
--- find the failing call. Returns the same ``ok, …`` tuple as pcall.
--- @param name string Short label identifying the call site.
--- @param fn function The function to call.
--- @vararg any Arguments forwarded to ``fn``.
local function pcall_log(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		Logger.error(LOG, "pcall '%s' failed: %s", tostring(name), tostring(err))
	end
	return ok, err
end

--- Triggers the deps checker matching the given backend name. Designed to
--- be safe to call repeatedly: each underlying script is hash-gated /
--- liveness-gated and exits in milliseconds when the backend is already
--- ready, so this is effectively a no-op on a working system.
--- @param backend string Either "mlx" or "ollama".
--- @return boolean completed True when dispatch returned without raising.
local function check_backend_deps(backend)
	if backend == "mlx" then
		local ok, accepted = pcall_log("mlx_deps_checker.check_and_install_deps",
			mlx_deps_checker.check_and_install_deps)
		return ok == true and accepted == true
	elseif backend == "ollama" then
		local ok, accepted = pcall_log("ollama_deps_checker.check_and_install_deps",
			ollama_deps_checker.check_and_install_deps)
		return ok == true and accepted == true
	end
	return true
end

-- Holds the active models manager so M.stop_mlx_server() can reach it from any context
-- (e.g., the Hammerspoon shutdown callback) without requiring a reference chain.
local _active_models_mgr = nil
-- Startup identity publication crosses opaque Core/runtime callbacks. A callback
-- may synchronously rebuild the menu and then resume its predecessor's tail, so
-- the whole factory is one non-reentrant boundary rather than a collection of
-- post-call freshness checks that cannot undo an opaque writer's stale tail.
local _startup_identity_boundary_depth = 0

--- Compensates one startup identity only while the refused caller's candidate
--- is still current. A different observed value belongs to a direct Core
--- successor and must never be overwritten by the predecessor's stale tail.
--- @return boolean settled
--- @return boolean successor_active
local function compensate_startup_identity(label, getter, setter, target, previous)
		if type(getter) ~= "function" or type(setter) ~= "function" then
				Logger.error(LOG, "%s compensation is unavailable.", tostring(label))
				return false, false
		end
		local observed_ok, observed = xpcall(getter, debug.traceback)
		if not observed_ok or type(observed) ~= "string" then
				Logger.error(LOG, "%s compensation could not observe its live identity.",
					tostring(label))
				return false, false
		end
		if observed == previous then return true, false end
		if observed ~= target then
				Logger.warn(LOG, "%s compensation yielded to direct successor '%s'.",
					tostring(label), tostring(observed))
				return true, true
		end
		local rollback_ok, rollback_result = xpcall(
				setter, debug.traceback, previous)
		if not rollback_ok or rollback_result ~= true then
				Logger.error(LOG, "%s compensation did not commit: %s.",
					tostring(label), tostring(rollback_result))
				return false, false
		end
		return true, false
end

-- Single source of truth for Apple-Silicon detection (F-MED-4): delegates to
-- BackendPanel.is_apple_silicon(), which uses `uname -m` — NOT a filesystem
-- existence check on /opt/homebrew. The old heuristic ("Homebrew on ARM
-- installs to /opt/homebrew") is wrong on a fresh arm64 Mac that has not
-- installed Homebrew yet, causing a first-run to seed llm_backend as
-- "ollama" on Apple Silicon instead of "mlx".
local is_apple_silicon = BackendPanel.is_apple_silicon()

M.DEFAULT_STATE = {
		llm_enabled           = llm_mod.DEFAULT_STATE.llm_enabled,
		llm_backend           = is_apple_silicon and "mlx" or "ollama",
		llm_debounce          = llm_mod.DEFAULT_STATE.llm_debounce,
		llm_model             = is_apple_silicon and llm_mod.DEFAULT_STATE.llm_model_mlx or llm_mod.DEFAULT_STATE.llm_model_ollama,
		llm_model_ollama      = llm_mod.DEFAULT_STATE.llm_model_ollama,
		llm_model_mlx         = llm_mod.DEFAULT_STATE.llm_model_mlx,
		llm_context_length    = llm_mod.DEFAULT_STATE.llm_context_length,
		llm_reset_on_nav      = llm_mod.DEFAULT_STATE.llm_reset_on_nav,
		llm_temperature       = llm_mod.DEFAULT_STATE.llm_temperature,
		llm_num_predictions   = llm_mod.DEFAULT_STATE.llm_num_predictions,
		llm_arrow_nav_enabled = llm_mod.DEFAULT_STATE.llm_arrow_nav_enabled,
		llm_nav_modifiers     = llm_mod.DEFAULT_STATE.llm_nav_modifiers,
		llm_show_info_bar     = llm_mod.DEFAULT_STATE.llm_show_info_bar,
		llm_val_modifiers     = llm_mod.DEFAULT_STATE.llm_val_modifiers,
		llm_pred_indent       = llm_mod.DEFAULT_STATE.llm_pred_indent,
		llm_active_profile    = llm_mod.DEFAULT_STATE.llm_active_profile,
		llm_user_models       = {},
		llm_disabled_apps          = {},
		llm_url_bar_filter_enabled        = true,
		llm_secure_field_filter_enabled   = true,
		llm_user_profiles     = {},
		llm_profile_shortcuts = {},
		-- On-demand prediction shortcut. Defaults to Ctrl+Space (real Ctrl,
		-- not Cmd — on macOS the Cmd+Space slot is owned by Spotlight and
		-- system-wide search, so it's a poor default for an editor cue).
		-- The user can rebind it from the trigger settings submenu or set
		-- the value to false to disable.
		llm_trigger_shortcut  = { mods = { "ctrl" }, key = "space" },
		llm_after_hotstring   = llm_mod.DEFAULT_STATE.llm_after_hotstring,
		llm_auto_raise_temp   = llm_mod.DEFAULT_STATE.llm_auto_raise_temp,
		llm_min_words         = llm_mod.DEFAULT_STATE.llm_min_words,
		llm_streaming           = llm_mod.DEFAULT_STATE.llm_streaming,
		llm_streaming_multi     = llm_mod.DEFAULT_STATE.llm_streaming_multi,
		llm_instant_on_word_end = llm_mod.DEFAULT_STATE.llm_instant_on_word_end,
}



-- Cached result of the last async server health check.
-- nil = not yet checked, true = server responded, false = server unreachable.
local _llm_health_status = nil
local _llm_health_generation = 0

--- Revokes every pending health writer and clears the shared display value.
local function invalidate_llm_health()
	_llm_health_generation = _llm_health_generation + 1
	_llm_health_status = nil
end

--- Revokes pending health callbacks and resets the display to not-yet-checked.
--- Call this after backend or enable-state commits and before teardown.
function M.reset_llm_health_status()
	invalidate_llm_health()
	Logger.debug(LOG, "Invalidated LLM health status.")
	return true
end

--- Fires an async health probe against the active backend.
--- Updates _llm_health_status and calls refresh_fn() when the result arrives.
--- @param state table The authoritative live LLM state.
--- @param refresh_fn function Called with no args after the result is stored.
local function probe_llm_health(state, refresh_fn)
	local backend = type(state) == "table" and state.llm_backend or nil
	-- In API backend mode there is no local server to probe. Skip the health
	-- check entirely to avoid lighting the orange "warming" indicator based on
	-- a residual MLX server that happens to be listening on the same port.
	if backend == "api" then return end
	if backend ~= "mlx" and backend ~= "ollama" then
		Logger.error(LOG, "Cannot probe LLM health for invalid backend '%s'.", tostring(backend))
		return
	end
	_llm_health_generation = _llm_health_generation + 1
	local generation = _llm_health_generation
	local backend_at_dispatch = backend
	local url
	if backend == "ollama" then
		url = "http://127.0.0.1:11434/api/version"
	else
		-- The MLX health probe follows the configured port via api_mlx.get_base_url()
		-- (the single source of truth) — no hardcoded port literal.
		url = ApiMlx.get_base_url() .. "/v1/models"
	end

	hs.http.asyncGet(url, {}, function(status)
		if generation ~= _llm_health_generation then return end
		if state.llm_backend ~= backend_at_dispatch or state.llm_enabled ~= true then return end
		-- Any HTTP response (even 4xx) means the server is reachable
		_llm_health_status = (type(status) == "number" and status > 0)
		if type(refresh_fn) == "function" then pcall(refresh_fn) end
	end)
end


--- Stops the MLX server process if one is currently running.
--- Safe to call even when no server is active or before M.create() has been called.
--- Intended for the Hammerspoon shutdown callback to prevent orphaned Python processes.
--- @param on_settled function|nil Called exactly once with the shutdown terminal.
--- @return boolean accepted True when synchronous settlement or callback ownership commits.
function M.stop_mlx_server(on_settled)
	if on_settled ~= nil and type(on_settled) ~= "function" then
		Logger.error(LOG, "MLX shutdown refused: settlement callback is not callable.")
		return false
	end
	local callback_claimed = false
	local callback_result = false
	local function settle_shutdown(settled, detail)
		if callback_claimed then return callback_result end
		callback_claimed = true
		callback_result = settled == true
		if callback_result then M.reset_llm_health_status() end
		if type(on_settled) == "function" then
			local callback_ok, callback_error = xpcall(function()
				on_settled(callback_result,
					detail or (callback_result and "mlx-listener-absent" or "mlx-listener-cleanup-refused"))
			end, debug.traceback)
			if not callback_ok then
				callback_result = false
				Logger.error(LOG, "MLX shutdown settlement callback failed: %s.",
					tostring(callback_error))
			end
		end
		return callback_result
	end

	if not _active_models_mgr then
		return settle_shutdown(true, "mlx-manager-inactive")
	end
	if type(_active_models_mgr.stop_mlx_server_if_needed) ~= "function" then
		Logger.error(LOG, "MLX shutdown refused: exact stop primitive is unavailable.")
		return false
	end
	local ok, accepted = xpcall(function()
		return _active_models_mgr.stop_mlx_server_if_needed(function(detail)
			return settle_shutdown(true, detail)
		end, {
			kind = "shutdown",
			on_cancel = function(reason)
				return settle_shutdown(false, reason)
			end,
		})
	end, debug.traceback)
	-- A faithful or test-native task may complete from inside terminate(); exact
	-- completion then outranks any contradictory return from the signal request
	if callback_claimed then return callback_result end
	if not ok or accepted ~= true then
		Logger.error(LOG, "MLX shutdown stop was refused: %s.",
			tostring(ok and accepted or accepted))
		return false
	end
	-- Callback callers own an awaitable terminal. Legacy synchronous callers still
	-- receive false until exact settlement rather than confusing signal with stop
	return type(on_settled) == "function"
end

--- Kills the orphan helper processes spawned for the local LLM backends (the
--- expander + http server). Shared by the genuine-quit shutdown callback AND the
--- script_quit action: script_quit exits via os.exit(0), which bypasses
--- hs.shutdownCallback, so it must perform the identical teardown. Centralising it
--- here means the two quit paths can never drift (the bug was that script_quit
--- revoked the exact remap lease + flushed the keylogger but left the MLX server
--- + helpers alive). Stock Karabiner processes are never owned by Ergopti.
function M.terminate_helper_processes()
	M.reset_llm_health_status()
	pcall(hs.execute, "pkill -f 'ergopti_plus_expander'", true)
	pcall(hs.execute, "pkill -f 'ergopti_plus_http_server'", true)
	-- The `ollama serve` wrapper this driver launches is a third helper and was
	-- not on this list. It is spawned through a /bin/sh pipeline, so terminating
	-- the hs.task only reaps the shell — the server itself survived every quit
	-- path and kept appending to the Ergopti log after Hammerspoon was gone.
	-- Matched on the same shape api_ollama uses to kill a stale one at launch, so
	-- the two agree on what "our ollama serve" means.
	pcall(hs.execute, "pkill -f '[o]llama serve'", true)
end

--- Kills any orphan mlx_lm.server and frees its listening port when no current
--- lifecycle owner can be reached. The exact stop primitive already proves its
--- captured port absent; this remains the previous-session/crash fallback shared
--- by BOTH the hs.shutdownCallback genuine-quit branch and
--- the script_quit (os.exit) action so the two quit paths can never drift — without
--- this, script_quit left the GPU-resident server holding the port (F-M7). The port
--- is read from the single source api_mlx.get_port().
function M.terminate_orphan_mlx_server()
	M.reset_llm_health_status()
	pcall(function()
		local ok_m, am = pcall(require, "modules.llm.api_mlx")
		local raw_port = (ok_m and type(am.get_port) == "function" and am.get_port())
		             or  (ok_m and am.DEFAULT_PORT)
		             or  3460
		local p = tostring(raw_port)
		hs.execute(
			"pgrep -f 'mlx_lm.*server' | xargs kill -9 2>/dev/null; " ..
			"lsof -tiTCP:" .. p .. " -sTCP:LISTEN | xargs kill -9 2>/dev/null", true)
	end)
end





-- =================================
-- =================================
-- ======= 1/ Helper Methods =======
-- =================================
-- =================================

local function format_mod_string(m_str)
		if type(m_str) ~= "string" then return "⌃" end
		local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
		local res = ""
		for p in m_str:gmatch("[^+]+") do res = res .. (dict[p] or p) end
		return res == "" and "⌃" or res
end



-- ==========================================
-- ===== 1.1) Shortcut Title Formatting =====
-- ==========================================

--- Returns true when the mods table contains the sentinel "none" value
--- (regardless of position), indicating the shortcut is disabled.
local function mods_has_none(mods)
		if not mods then return false end
		for _, m in ipairs(mods) do if m == "none" then return true end end
		return false
end

local function format_shortcut_title(action, mods, none_label, mod_label)
		-- Fail closed on a wrong-typed value: a corrupt or AHK-migrated hs.settings
		-- entry can hold a STRING where a table is expected, and table.concat(string)
		-- raises. Because the whole AI submenu builder runs inside a pcall, that throw
		-- silently blanked the entire LLM submenu from the menubar. Treat any non-table
		-- as "disabled" before the concat can ever run.
		if type(mods) ~= "table" then
				return action .. " : " .. i18n.get("common.disabled")
		end
		if not mods or mods_has_none(mods) then
				return action .. " : " .. i18n.get("common.disabled")
		elseif #mods == 0 then
				return action .. " : " .. none_label
		else
				local sym = format_mod_string(table.concat(mods, "+"))
				return action .. " : " .. sym .. " " .. mod_label
		end
end





-- ===============================
-- ===============================
-- ======= 2/ Main Factory =======
-- ===============================
-- ===============================

local function create_menu(deps)
		if type(deps) ~= "table" then return {} end
		
		deps.active_tasks = deps.active_tasks or {}
		local state       = deps.state
		
		-- Migration logic for older configs
		if state.llm_use_mlx ~= nil then
				state.llm_backend = state.llm_use_mlx and "mlx" or "ollama"
				state.llm_use_mlx = nil
		end
		if state.llm_backend == nil then 
				state.llm_backend = M.DEFAULT_STATE.llm_backend 
		end
		if type(llm_mod.get_backend) ~= "function" then
				Logger.error(LOG,
					"LLM menu creation refused: current backend identity getter is unavailable.")
				return {}
		end
		local getter_ok, previous_runtime_backend = xpcall(
				llm_mod.get_backend, debug.traceback)
		if not getter_ok or type(previous_runtime_backend) ~= "string" then
				Logger.error(LOG,
					"LLM menu creation refused: current backend identity could not be captured.")
				return {}
		end
		local backend_ok, backend_result = xpcall(
				llm_mod.set_backend, debug.traceback, state.llm_backend)
		if not backend_ok or backend_result ~= true then
				local rollback_result = compensate_startup_identity(
					"LLM backend startup", llm_mod.get_backend, llm_mod.set_backend,
					state.llm_backend, previous_runtime_backend)
				Logger.error(LOG, "LLM menu creation refused: backend identity did not commit (%s).",
					tostring(backend_result))
				if rollback_result ~= true then
						Logger.error(LOG, "LLM backend startup rollback did not commit.")
				end
				return {}
		end
		M.reset_llm_health_status()
		local function compensate_startup_backend()
				return compensate_startup_identity(
					"LLM backend startup", llm_mod.get_backend, llm_mod.set_backend,
					state.llm_backend, previous_runtime_backend)
		end

		local keymap       = deps.keymap
		local save_prefs   = deps.save_prefs
		local update_menu  = deps.update_menu
		local previous_runtime_model = nil
		if type(state.llm_model) == "string" then
				if type(llm_mod.get_current_model) ~= "function" then
						Logger.error(LOG,
							"LLM menu creation refused: current model identity getter is unavailable.")
						compensate_startup_backend()
						return {}
				end
				local getter_ok, observed_model = xpcall(
						llm_mod.get_current_model, debug.traceback)
				if not getter_ok or type(observed_model) ~= "string" then
						Logger.error(LOG,
							"LLM menu creation refused: current model identity could not be captured.")
						compensate_startup_backend()
						return {}
				end
				previous_runtime_model = observed_model
		end
		local models_mgr   = Models.new(deps)
		local startup_model_plan = nil
		if type(state.llm_model) == "string" and state.llm_model ~= "" then
				local configured_model = state.llm_model
				local presets_startup = models_mgr.get_presets()
				local display_name = configured_model
				if type(presets_startup) == "table" then
						for _, provider in ipairs(presets_startup) do
								for _, family in ipairs(provider.families or {}) do
										for _, model in ipairs(family.models or {}) do
												local candidate = model.name or model.repo
												if type(candidate) == "string"
														and models_mgr.get_actual_model_name(candidate) == configured_model
														and candidate ~= configured_model then
														display_name = candidate
												end
										end
								end
						end
				end
				local actual_name = models_mgr.get_actual_model_name(display_name)
				local model_setter = state.llm_backend == "mlx"
						and llm_mod.set_llm_model_mlx or llm_mod.set_llm_model_ollama
				if type(model_setter) ~= "function" then
						Logger.error(LOG, "LLM menu creation refused: model identity setter is unavailable.")
						compensate_startup_backend()
						return {}
				end
				local model_ok, model_result = xpcall(
						model_setter, debug.traceback, actual_name)
				if not model_ok or model_result ~= true then
						local rollback_result, successor_active = compensate_startup_identity(
							"LLM model startup", llm_mod.get_current_model, model_setter,
							actual_name, previous_runtime_model)
						if successor_active ~= true then compensate_startup_backend() end
						Logger.error(LOG,
								"LLM menu creation refused: model identity did not commit (%s); rollback=%s.",
								tostring(model_result),
								tostring(rollback_result))
						return {}
				end
				startup_model_plan = {
						actual_name = actual_name,
						display_name = display_name,
						previous_model = configured_model,
						setter = model_setter,
						target = actual_name,
				}
		elseif state.llm_model == "" then
				if not keymap or type(keymap.set_llm_model) ~= "function" then
						Logger.error(LOG, "LLM menu creation refused: No Model setter is unavailable.")
						compensate_startup_backend()
						return {}
				end
				local no_model_ok, no_model_result = xpcall(
						keymap.set_llm_model, debug.traceback, "")
				if not no_model_ok or no_model_result ~= true then
						local rollback_result, successor_active = compensate_startup_identity(
							"No Model startup", llm_mod.get_current_model,
							keymap.set_llm_model, "", previous_runtime_model)
						if successor_active ~= true then compensate_startup_backend() end
						Logger.error(LOG,
							"LLM menu creation refused: No Model identity did not commit (%s); rollback=%s.",
							tostring(no_model_result),
							tostring(rollback_result))
						return {}
				end
				startup_model_plan = {
					disabled = true,
					setter = keymap.set_llm_model,
					target = "",
				}
		end
		local function compensate_startup_model()
				if type(startup_model_plan) ~= "table"
						or type(startup_model_plan.setter) ~= "function"
						or type(startup_model_plan.target) ~= "string" then
						return true, false
				end
				return compensate_startup_identity(
					"LLM model startup", llm_mod.get_current_model,
					startup_model_plan.setter, startup_model_plan.target,
					previous_runtime_model)
		end
		-- profiles_mgr is re-created after apply_llm_profile_shortcut is bound into deps
		local profiles_mgr = nil
		local settings_mgr = Settings.new(deps)
		local prediction_locks = PredictionLockRegistry.new({
				state = state,
				keymap = keymap,
		})
		local mlx_port_transition_generation = 0
		local switcher

		local function restart_mlx_for_current_port(new_port, commit_port)
				if type(commit_port) ~= "function" then
						Logger.error(LOG, "MLX port transition refused: commit callback is unavailable.")
						return false
				end
				mlx_port_transition_generation = mlx_port_transition_generation + 1
				local generation = mlx_port_transition_generation
				if state.llm_backend ~= "mlx" then return commit_port() == true end
				if type(models_mgr.stop_mlx_server_if_needed) ~= "function" then
						Logger.error(LOG, "MLX port transition refused: exact stop primitive is unavailable.")
						return false
				end
				local ok_stop, accepted = xpcall(function()
						return models_mgr.stop_mlx_server_if_needed(function()
								if generation ~= mlx_port_transition_generation then return false end
								if not commit_port() then return false end
								if state.llm_backend == "mlx"
										and state.llm_enabled
										and state.llm_model
										and state.llm_model ~= "" then
										-- Silent: a port change is not a model change, so don't pop the
										-- recommended-profile dialog. Pin the committed port into this
										-- successor identity so a later preference edit cannot retarget it.
										local ok_start, started = xpcall(function()
												if type(switcher) ~= "table"
														or type(switcher.dispatch_resumable_requirements) ~= "function" then
														Logger.error(LOG,
															"MLX port relaunch owner is unavailable.")
														return false
												end
												return switcher.dispatch_resumable_requirements(
														state.llm_model, nil, nil, {
															silent_notifications = true,
															_mlx_port = new_port,
														})
										end, debug.traceback)
										if not ok_start or started ~= true then
												Logger.error(LOG, "MLX server relaunch on port %s was refused: %s.",
														tostring(new_port), tostring(started))
												return false
										end
								end
								return true
						end, { kind = "port" })
				end, debug.traceback)
				if not ok_stop or accepted ~= true then
						Logger.error(LOG, "MLX port transition stop was refused: %s.",
								tostring(ok_stop and accepted or accepted))
						return false
				end
				return true
		end

		switcher = ModelSwitcher.new({
				state       = state,
				models_mgr  = models_mgr,
				keymap      = keymap,
				script_control = deps.script_control,
				prediction_locks = prediction_locks,
				save_prefs  = save_prefs,
				update_menu = update_menu,
				profile_mutation_gate = function(switcher_recovery_capability)
						local delete_gate = deps.settle_profile_delete_recovery
						if delete_gate ~= nil then
								if type(delete_gate) ~= "function"
										or delete_gate() ~= true then
										return false
								end
						end
						local candidate_gate = deps.settle_profile_candidate_recovery
						if candidate_gate ~= nil then
								if type(candidate_gate) ~= "function"
										or candidate_gate(switcher_recovery_capability) ~= true then
										return false
								end
						end
						local edit_gate = deps.settle_profile_edit_recovery
						if edit_gate ~= nil then
								if type(edit_gate) ~= "function"
										or edit_gate() ~= true then
										return false
								end
						end
						return true
				end,
				runtime_gate = function()
						local script_control = deps.script_control
						if not script_control or type(script_control.is_paused) ~= "function" then return true end
						local ok, paused = xpcall(script_control.is_paused, debug.traceback)
						if not ok then
								Logger.error(LOG, "Cannot read pause state during model switch: %s", tostring(paused))
								return false
						end
						return paused ~= true
				end,
				pause_epoch = function()
						local script_control = deps.script_control
						if not script_control or type(script_control.get_pause_epoch) ~= "function" then return 0 end
						local ok, epoch = xpcall(script_control.get_pause_epoch, debug.traceback)
						return ok and tonumber(epoch) or -1
				end,
		})
		local switch_model                     = switcher.switch_model
		local disable_model                    = switcher.disable_model
		local get_display_model_name           = switcher.get_display_model_name
		local get_model_power_level            = switcher.get_model_power_level
		local apply_recommended_prompt_profile = switcher.apply_recommended_prompt_profile
		local guarded_check_requirements       = switcher.guarded_check_requirements

		deps.set_llm_profile = switcher.set_llm_profile
		deps.settle_llm_switcher_recovery = switcher.settle_recovery_debts
		deps.apply_recommended_prompt_profile = function(opts)
				return apply_recommended_prompt_profile(state.llm_model, opts)
		end

		-- The exact Core identity is acquired before Settings/ModelSwitcher, but
		-- display publication remains staged until the initial profile owner commits.
		local function publish_startup_display()
				if startup_model_plan and startup_model_plan.disabled ~= true then
						local display_name = startup_model_plan.display_name
						if display_name ~= startup_model_plan.previous_model then
								Logger.debug(LOG, string.format(
										"Correcting model name on startup (backend->display): '%s' -> '%s'.",
										startup_model_plan.previous_model, display_name))
						end
						Logger.debug(LOG, string.format("Resolving model name on startup: '%s' -> '%s'.",
								display_name, startup_model_plan.actual_name))
						state.llm_model = display_name
						if state.llm_backend == "mlx" then
								state.llm_model_mlx = display_name
						else
								state.llm_model_ollama = display_name
						end
						if type(deps.keymap) == "table"
								and type(deps.keymap.set_llm_display_model_name) == "function" then
								pcall(deps.keymap.set_llm_display_model_name, display_name)
						end
						state.llm_model_power = get_model_power_level(display_name)
						Logger.debug(LOG, string.format(
								"Model power on startup: %d.", state.llm_model_power))
				elseif startup_model_plan and startup_model_plan.disabled == true then
						if keymap and type(keymap.set_llm_display_model_name) == "function" then
								pcall_log("keymap.set_llm_display_model_name(No Model)",
									keymap.set_llm_display_model_name, "")
						end
						state.llm_model_power = nil
				end
		end

		if state.llm_num_predictions ~= nil and keymap and type(keymap.set_llm_num_predictions) == "function" then
				pcall(keymap.set_llm_num_predictions, state.llm_num_predictions)
		end
		if state.llm_max_words ~= nil and keymap and type(keymap.set_llm_max_words) == "function" then
				pcall(keymap.set_llm_max_words, state.llm_max_words)
		end
		if state.llm_min_words ~= nil and keymap and type(keymap.set_llm_min_words) == "function" then
				pcall(keymap.set_llm_min_words, state.llm_min_words)
		end
		if state.llm_streaming ~= nil and keymap and type(keymap.set_llm_streaming) == "function" then
				pcall(keymap.set_llm_streaming, state.llm_streaming)
		end
		if state.llm_streaming_multi ~= nil and keymap and type(keymap.set_llm_streaming_multi) == "function" then
				pcall(keymap.set_llm_streaming_multi, state.llm_streaming_multi)
		end



		-- ======================================
		-- ===== 2.2) Dynamic Menu Builders =====
		-- ======================================

		local function build_num_pred_menu()
				Logger.debug(LOG, "Building prediction count menu…")
				local rows = {}
				for i = 1, 10 do
						table.insert(rows, {
								label   = string.format(i18n.get("menu.llm.prediction_count_label"), i, i > 1 and "s" or ""),
								checked = (state.llm_num_predictions == i),
								action  = function()
										Logger.info(LOG, string.format("Changing number of predictions -> %d", i))
										return settings_mgr.apply_setting_transaction({
												key = "llm_num_predictions",
												value = i,
												runtime_fn = "set_llm_num_predictions",
												publish_setting = false,
										})
								end
						})
				end
				return ManifestMenu.render_rows(rows, "llm_num_predictions")
		end



		-- =====================================
		-- ===== 2.3) Hotkeys & Triggers =======
		-- =====================================

		local _llm_trigger_hk  = nil
		local _llm_profile_hks = {}
		local _startup_silence = false
		local function get_startup_silence() return _startup_silence end
		local function set_startup_silence(v) _startup_silence = v end
		local function get_trigger_hk() return _llm_trigger_hk end
		local function set_trigger_hk(v) _llm_trigger_hk = v end
		local function get_profile_hks() return _llm_profile_hks end
		local function set_profile_hk(id, v) _llm_profile_hks[id] = v end

		local trigger_orch = TriggerOrch.new({
				state              = state,
				keymap             = keymap,
				save_prefs         = save_prefs,
				update_menu        = update_menu,
				get_startup_silence = get_startup_silence,
				set_startup_silence = set_startup_silence,
				get_trigger_hk     = get_trigger_hk,
				set_trigger_hk     = set_trigger_hk,
				get_profile_hks    = get_profile_hks,
				set_profile_hk     = set_profile_hk,
		})
		local bind_hotkey                  = trigger_orch.bind_hotkey
		local activate_hotkey              = trigger_orch.activate_hotkey
		local apply_llm_shortcut           = trigger_orch.apply_llm_shortcut
		local apply_llm_profile_shortcut   = trigger_orch.apply_llm_profile_shortcut

		deps.apply_llm_profile_shortcut = apply_llm_profile_shortcut

		local profiles_ok, profiles_result = xpcall(
			Profiles.new, debug.traceback, deps, models_mgr)
		profiles_mgr = profiles_result
		if not profiles_ok or type(profiles_mgr) ~= "table"
				or type(profiles_mgr.get_menu_item) ~= "function" then
				local _, model_successor = compensate_startup_model()
				if model_successor ~= true then compensate_startup_backend() end
				Logger.error(LOG,
					"LLM menu creation refused: initial profile identities did not commit.")
				return {}
		end
		publish_startup_display()
		-- Register only the manager whose backend, model, and initial profile
		-- acquisitions completed. A refused factory must not replace the last
		-- reachable shutdown owner.
		_active_models_mgr = models_mgr



		-- =========================================
		-- ===== 2.4) Lifecycle & Main Build =======
		-- =========================================

		local check_startup
		local activation_generation = 0
		local activation_requirement_owner = nil
		if deps.script_control
				and type(models_mgr.create_requirement_owner) == "function" then
				local owner_ok, owner = pcall_log(
					"models_mgr.create_requirement_owner(llm_activation)",
					models_mgr.create_requirement_owner,
					"llm_activation")
				if owner_ok == true and type(owner) == "table" then
						activation_requirement_owner = owner
				else
						Logger.error(LOG,
							"LLM activation requirement-owner creation was refused.")
				end
		end
		local activation_controller = ActivationPauseOwner.new({
			script_control = deps.script_control,
			pause_join = function()
				if activation_requirement_owner == nil then return true, false end
				if type(models_mgr.pause_requirements) ~= "function" then
					return false, false
				end
				local results = table.pack(xpcall(function()
					return models_mgr.pause_requirements(
						activation_requirement_owner)
				end, debug.traceback))
				if results[1] ~= true then
					Logger.error(LOG,
						"LLM activation requirement-task join raised: %s.",
						tostring(results[2]))
				end
				return results[1] == true and results[2] == true,
					results[3] == true
			end,
		})
		local function build_item()
				Logger.debug(LOG, "Building LLM menu item (build_item)…")
				local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
				local is_disabled = (not state.llm_enabled) or paused
				Logger.debug(LOG, string.format("Menu state: paused=%s, llm_enabled=%s, is_disabled=%s", tostring(paused), tostring(state.llm_enabled), tostring(is_disabled)))
				-- Rows are collected under the id the manifest declares them with, and
				-- the SHARED renderer places them. The order was the one thing the
				-- shared spec always claimed to own and only Windows honoured: this
				-- menu inserted its rows as it built them, so the model row sat ninth
				-- here and second there, from one description.
				local rows_by_id = {}
				local function row_for(id, row)
						local bucket = rows_by_id[id]
						if not bucket then
								bucket = {}
								rows_by_id[id] = bucket
						end
						bucket[#bucket + 1] = row
				end


				local backend_title, backend_menu = BackendPanel.build({
						state                = state,
						keymap               = keymap,
						paused               = paused,
						models_mgr           = models_mgr,
						get_display_model_name = get_display_model_name,
						switch_model         = switch_model,
						disable_model        = disable_model,
						save_prefs           = save_prefs,
						update_menu          = update_menu,
						WarmupCtrl           = WarmupCtrl,
						-- So the API-backend switch can clear a stale MLX/Ollama health
						-- reading instead of leaking it into the API backend's status
						-- dot display (F-LOW-6).
						reset_llm_health_status = M.reset_llm_health_status,
				})

				row_for("llm_backend", {
						title    = backend_title,
						disabled = MenuLayout.row_disabled("llm_backend", is_disabled, paused),
						menu     = backend_menu
				})

				-- API entries CRUD — delegates entirely to ApiPanel.
				do
						local api_title, api_menu = ApiPanel.build({
								state       = state,
								paused      = paused,
								keymap      = keymap,
								update_menu = update_menu,
								WarmupCtrl  = WarmupCtrl,
						})
						if api_title and api_menu then
								-- Anchored to the backend row: it configures the backend the row
								-- above selects, and the manifest declares no row of its own for
								-- it because Windows has no API-entry CRUD to declare.
								row_for("llm_backend", {
										title    = api_title,
										disabled = paused or nil,
										menu     = api_menu,
								})
						end
				end
				local active_display_model = get_display_model_name(state.llm_model)
				local info = models_mgr.get_model_info(active_display_model) or {}
				local ram = models_mgr.get_model_ram(active_display_model) or 0
				local type_str = " [" .. i18n.get((info.type == "completion")
						and "menu.llm.model_type_completion"
						or  "menu.llm.model_type_chat") .. "]"
				local params_ram_str = (info.params and info.params > 0)
						and string.format(" (%gB params, ~%d Go RAM)", info.params, math.ceil(ram))
						or string.format(" (~%d Go RAM)", math.ceil(ram))
				
				-- Trigger a fresh async probe on every menu open so the indicator stays accurate.
				-- The result arrives after the menu is shown; the next open will display it.
				-- Pass a guarded callback that only calls update_menu when _llm_health_status
				-- actually changes: passing update_menu directly causes a build → probe →
				-- update_menu → build loop at ~10-20 rebuilds/second with live HTTP requests.
				if state.llm_enabled and not paused then
						local probe_snapshot = _llm_health_status
						probe_llm_health(state, function()
								if _llm_health_status ~= probe_snapshot then
										pcall(update_menu)
								end
						end)
				end

				-- Health indicator — must be HONEST about whether predictions actually fire:
				-- 🟢 = backend confirmed ready (warmup POST returned 200 + tokens) → the
				--      prediction readiness gate is open, so suggestions will appear.
				-- 🟡 = server reachable (HTTP probe ok) but the model is still warming up;
				--      the prediction engine skips requests until warmup confirms, so a
				--      green dot here would be a lie ("vert mais aucune prédiction").
				-- 🔴 = server unreachable, OR the model was given up on (incompatible /
				--      never loaded). The second case overrides orange so a broken model is
				--      never shown as an eternal "still loading" spinner.
				-- is_backend_ready() is synchronous and reflects the warmup state accurately
				-- even on the first menu open after a model swap.
				local health_dot
				-- Which row carries the dot is the manifest's call, not this file's:
				-- the same declaration drives the Windows renderer, so the two cannot
				-- end up dotting different rows.
				if not MenuLayout.has_health_dot("llm_model") or not state.llm_enabled or paused then
						health_dot = ""
				else
						local backend_ready = false
						if type(llm_mod.is_backend_ready) == "function" then
								local ok, ready = pcall(llm_mod.is_backend_ready)
								backend_ready = ok and ready == true
						end
						-- A model given up on (incompatible / never loaded) must show RED even
						-- though the HTTP server may still answer /v1/models — otherwise the dot
						-- would stay stuck orange forever with no error the user can see.
						local load_failed = false
						if type(llm_mod.is_backend_load_failed) == "function" then
								local ok, failed = pcall(llm_mod.is_backend_load_failed)
								load_failed = ok and failed == true
						end
						if backend_ready then
								health_dot = "🟢 "
						elseif load_failed then
								health_dot = "🔴 "
						elseif _llm_health_status == true then
								health_dot = "🟡 "
						else
								health_dot = "🔴 "
						end
				end

				local rich_model_title = health_dot .. i18n.get("menu.llm.active_model_label")
				if not state.llm_model or state.llm_model == "" then
						rich_model_title = rich_model_title .. i18n.get("menu.llm.no_model_none")
				else
						rich_model_title = rich_model_title .. string.format("%s%s%s", active_display_model, type_str, params_ram_str)
				end

				local model_submenu
				if state.llm_backend == "api" then
						model_submenu = ApiPanel.build_model_picker({
								state       = state,
								paused      = paused,
								keymap      = keymap,
								update_menu = update_menu,
								WarmupCtrl  = WarmupCtrl,
						})
				else
						model_submenu = ModelsSelector.build({
								state         = state,
								models_mgr    = models_mgr,
								switch_model  = switch_model,
								disable_model = disable_model,
								save_prefs    = save_prefs,
								update_menu   = update_menu,
								DEFAULT_STATE = M.DEFAULT_STATE,
								paused        = paused,   -- gate model rows while paused (M-16)
						})

						-- MLX server port — Ergopti's own server, so let the user move it off
						-- the default if it collides with another local server they run. Changing
						-- it persists (api_mlx → hs.settings), then relaunches the server on the
						-- new port for the current model so the change takes effect immediately.
						local ok_api, ApiMlx = pcall(require, "modules.llm.api_mlx")
						if ok_api and type(ApiMlx.get_port) == "function" then
								-- Row DATA appended to the selector's finished tree: the rows
								-- above it are ModelsSelector's, these three are this file's,
								-- and the renderer materialises this file's.
								local port_rows = {
										{ separator = true },
										{
												label    = string.format(i18n.get("menu.llm.mlx_port_label"), tostring(ApiMlx.get_port())),
										disabled = paused or nil,
										action   = not paused and function()
												return settings_mgr.set_mlx_port(restart_mlx_for_current_port)
										end or nil,
								},
								}
								if type(ApiMlx.get_default_port) == "function" and ApiMlx.get_port() ~= ApiMlx.get_default_port() then
										port_rows[#port_rows + 1] = {
												label    = string.format(i18n.get("menu.llm.reset_label"), tostring(ApiMlx.get_default_port())),
											disabled = paused or nil,
											action   = not paused and function()
													return settings_mgr.reset_mlx_port(restart_mlx_for_current_port)
											end or nil,
										}
								end
								for _, row in ipairs(ManifestMenu.render_rows(port_rows, "llm_model")) do
										table.insert(model_submenu, row)
								end
						end
				end

				row_for("llm_model", {
						title    = rich_model_title,
						disabled = MenuLayout.row_disabled("llm_model", is_disabled, paused),
						menu     = model_submenu,
				})

				-- Anchored to the model row it describes. It used to be inserted BEFORE
				-- that row, because the row itself was placed further down.
				if info and info.emojis and info.emojis:find("🧠💭") then
						row_for("llm_model", { title = i18n.get("menu.llm.thinking_model_info"), disabled = true })
				end

				row_for("llm_model", { title = "-" })

				local profiles_item = profiles_mgr.get_menu_item()
				profiles_item.disabled = MenuLayout.row_disabled("llm_profile", is_disabled, paused)
				row_for("llm_profile", profiles_item)

				row_for("llm_num_predictions", { title = string.format(i18n.get("menu.llm.num_predictions_label"), tostring(state.llm_num_predictions or llm_mod.DEFAULT_STATE.llm_num_predictions)), disabled = MenuLayout.row_disabled("llm_num_predictions", is_disabled, paused), menu = build_num_pred_menu() })
				if state.llm_num_predictions ~= llm_mod.DEFAULT_STATE.llm_num_predictions then
						row_for("llm_num_predictions", {
								title    = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_num_predictions)),
								disabled = MenuLayout.row_disabled("llm_num_predictions", is_disabled, paused),
								fn       = function()
										return settings_mgr.apply_setting_transaction({
												key = "llm_num_predictions",
												value = llm_mod.DEFAULT_STATE.llm_num_predictions,
												runtime_fn = "set_llm_num_predictions",
												publish_setting = false,
										})
								end
						})
				end

				row_for("llm_num_predictions", { title = "-" })


				-- ===== Trigger submenu =====

				local trigger_menu = TriggerPanel.build({
						state              = state,
						keymap             = keymap,
						is_disabled        = is_disabled,
						save_prefs         = save_prefs,
						update_menu        = update_menu,
						settings_mgr       = settings_mgr,
						apply_llm_shortcut = apply_llm_shortcut,
				})

				row_for("llm_trigger", { title = i18n.get("menu.llm.trigger_menu_title"), disabled = MenuLayout.row_disabled("llm_trigger", is_disabled, paused), menu = trigger_menu })


				-- ===== Generation settings submenu =====

				local generation_rows = {}

				table.insert(generation_rows, { label = string.format(i18n.get("menu.llm.context_length_label"), tostring(state.llm_context_length)), disabled = is_disabled or nil, action = settings_mgr.set_context_length })
				if state.llm_context_length ~= llm_mod.DEFAULT_STATE.llm_context_length then
						table.insert(generation_rows, { label = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_context_length)), disabled = is_disabled or nil, action = settings_mgr.reset_context_length })
				end

				table.insert(generation_rows, {
						label    = i18n.get("menu.llm.reset_on_nav"),
						checked  = state.llm_reset_on_nav,
						disabled = is_disabled or nil,
						action   = function()
								return settings_mgr.apply_setting_transaction({
										key = "llm_reset_on_nav",
										value = not state.llm_reset_on_nav,
										runtime_fn = "set_llm_reset_on_nav",
										publish_setting = false,
								})
						end
				})

				local mw_min = tonumber(state.llm_min_words)
				local min_words_display = (mw_min and mw_min > 0) and tostring(mw_min) or "1"
				table.insert(generation_rows, { label = string.format(i18n.get("menu.llm.min_words_label"), min_words_display), disabled = is_disabled or nil, action = settings_mgr.set_min_words })
				if state.llm_min_words ~= llm_mod.DEFAULT_STATE.llm_min_words then
						table.insert(generation_rows, { label = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_min_words)), disabled = is_disabled or nil, action = settings_mgr.reset_min_words })
				end

				local mw_max = tonumber(state.llm_max_words)
				local max_words_display = (mw_max and mw_max > 0) and tostring(mw_max) or i18n.get("menu.llm.unlimited")
				table.insert(generation_rows, { label = string.format(i18n.get("menu.llm.max_words_label"), max_words_display), disabled = is_disabled or nil, action = settings_mgr.set_max_words })
				if state.llm_max_words ~= llm_mod.DEFAULT_STATE.llm_max_words then
						local def_w_disp = (llm_mod.DEFAULT_STATE.llm_max_words and llm_mod.DEFAULT_STATE.llm_max_words > 0) and tostring(llm_mod.DEFAULT_STATE.llm_max_words) or i18n.get("menu.llm.unlimited")
						table.insert(generation_rows, { label = string.format(i18n.get("menu.llm.reset_label"), def_w_disp), disabled = is_disabled or nil, action = settings_mgr.reset_max_words })
				end

				TempPanel.build({
						state        = state,
						keymap       = keymap,
						is_disabled  = is_disabled,
						save_prefs   = save_prefs,
						update_menu  = update_menu,
						settings_mgr = settings_mgr,
				}, generation_rows)

				row_for("llm_generation_settings", {
						title    = i18n.get("menu.llm.generation_menu_title"),
						disabled = MenuLayout.row_disabled("llm_generation_settings", is_disabled, paused),
						menu     = ManifestMenu.render_rows(generation_rows, "llm_generation_settings"),
				})


				-- ===== Display submenu =====

				local display_menu = StreamPanel.build({
						state        = state,
						keymap       = keymap,
						is_disabled  = is_disabled,
						save_prefs   = save_prefs,
						update_menu  = update_menu,
						settings_mgr = settings_mgr,
				})

				row_for("llm_display", { title = i18n.get("menu.llm.display_menu_title"), disabled = MenuLayout.row_disabled("llm_display", is_disabled, paused), menu = display_menu })


				-- ===== Navigation submenu =====

				local nav_rows = {}

				local nav_mods = state.llm_nav_modifiers
				-- Rendering observes canonical state only. Runtime synchronization belongs
				-- to SettingsManager's transaction and must never be repeated by a rebuild.
				if type(nav_mods) ~= "table" then nav_mods = llm_mod.DEFAULT_STATE.llm_nav_modifiers end

				local val_mods = state.llm_val_modifiers
				if type(val_mods) ~= "table" then val_mods = llm_mod.DEFAULT_STATE.llm_val_modifiers end

				local num_preds_safe = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
				local nav_title = format_shortcut_title(i18n.get("menu.llm.nav_label"), nav_mods, i18n.get("menu.llm.arrows_only"), i18n.get("menu.llm.arrows"))
				table.insert(nav_rows, {
						label    = nav_title,
						disabled = (is_disabled or num_preds_safe < 2) or nil,
						-- The modifier picker is settings_mgr's tree, handed over whole.
						submenu  = settings_mgr.build_nav_modifier_menu()
				})

				local val_title = format_shortcut_title(string.format(i18n.get("menu.llm.val_label"), (num_preds_safe == 10) and "1-0" or ("1-" .. num_preds_safe)), val_mods, i18n.get("menu.llm.digits_only"), i18n.get("menu.llm.digits"))
				table.insert(nav_rows, {
						label    = val_title,
						disabled = (is_disabled or num_preds_safe < 2) or nil,
						submenu  = settings_mgr.build_val_modifier_menu()
				})

				row_for("llm_navigation", { title = i18n.get("menu.llm.nav_menu_title"), disabled = MenuLayout.row_disabled("llm_navigation", is_disabled, paused), menu = ManifestMenu.render_rows(nav_rows, "llm_navigation") })

				-- One handler per declared row, each appending what was collected for
				-- it. A row the manifest declares and this table does not answer is
				-- logged and dropped by the renderer, which is what makes the
				-- handler-bijection gate able to see it.
				local main_menu = {}
				do
						local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
						if ok_mm and type(ManifestMenu.build) == "function" then
								local handlers = {}
								for _, id in ipairs(MenuLayout.row_ids()) do
										handlers[id] = function(items)
												local bucket = rows_by_id[id] or {}
												-- A declared row nothing filled would render as nothing at
												-- all, and the renderer would count it as handled — the one
												-- failure the bijection gate cannot see from outside.
												if #bucket == 0 then
														Logger.warn(LOG, "Declared row '%s' has no content — nothing to place.", id)
												end
												for _, row in ipairs(bucket) do
														items[#items + 1] = row
												end
										end
								end
								main_menu = ManifestMenu.build("llm_menu", "LLM", handlers, nil, ctx, {}) or {}
						else
								Logger.error(LOG, "Manifest renderer unavailable — the IA submenu has no settings row.")
						end
				end

				return {
						label   = i18n.get("menu.llm.title"),
						checked = state.llm_enabled or nil,
						action  = not paused
							and activation_requirement_owner ~= nil
							and type(models_mgr.pause_requirements) == "function"
							and activation_controller.is_registered() and function()
								activation_generation = activation_generation + 1
								local my_generation = activation_generation
								local activation_backend = state.llm_backend
								local target_enabled = not state.llm_enabled
								local activation_terminal = false
								local activation_published = false
								local attempt = { phase = nil, bootstrap_result = nil }
								local token

								local function commit_enabled(enabled)
										local previous_enabled = state.llm_enabled
										Logger.info(LOG, string.format("Toggling LLM: %s -> %s",
												tostring(state.llm_enabled), tostring(enabled)))
										state.llm_enabled = enabled
										if type(prediction_locks.apply_preference) == "function" then
												local ok, settled = xpcall(function()
														return prediction_locks.apply_preference(state.llm_enabled)
												end, debug.traceback)
												Logger.debug(LOG, string.format(
														"Prediction preference %s settlement -> %s",
														tostring(state.llm_enabled), tostring(ok and settled == true)))
												if not ok or settled ~= true then
														state.llm_enabled = previous_enabled
														xpcall(function()
																return prediction_locks.apply_preference(previous_enabled)
														end, debug.traceback)
														return false
												end
										else
												Logger.warn(LOG, "Prediction preference settlement is unavailable.")
												state.llm_enabled = previous_enabled
												return false
										end
										if save_prefs() ~= true then return false end
										if enabled ~= true then M.reset_llm_health_status() end
										return true
								end

								local function publish_toggle()
										pcall_log("update_menu", update_menu)
										pcall_log("notifications.notify", function()
											notifications.notify(
												state.llm_enabled and i18n.get("notify.llm_enabled")
													or i18n.get("notify.llm_disabled"),
												i18n.get("notify.llm_suggestions"))
										end)
								end

								local function compensate_activation(reason)
										if activation_terminal then return false end
										activation_terminal = true
										if token ~= nil then activation_controller.complete(token) end
										Logger.error(LOG, "LLM activation failed (%s); restoring disabled state.",
											tostring(reason))
										if commit_enabled(false) ~= true then
												Logger.error(LOG,
													"Could not persist the compensating LLM disable after activation failure.")
												return false
										end
										pcall_log("update_menu after activation compensation", update_menu)
										return false
								end

								local function activation_is_current(authorization)
										return activation_terminal ~= true
											and my_generation == activation_generation
											and state.llm_backend == activation_backend
											and state.llm_enabled == true
											and activation_controller.is_current(token, authorization)
								end

								local function publish_activation_once()
										if activation_published then return true end
										activation_published = true
										publish_toggle()
										return true
								end

								local function dispatch_requirements()
										local authorization = activation_controller.capture(token)
										if authorization == nil or not activation_is_current(authorization) then
												return false
										end
										attempt.phase = "requirements"
										attempt.requirements_stale = false
										attempt.requirements_generation =
												(attempt.requirements_generation or 0) + 1
										local requirements_generation = attempt.requirements_generation
										attempt.requirements_terminal = nil
										local terminal = false
										local terminal_success = false
										local terminal_cancel_reason = nil
										local dispatching = true
										local function on_success()
												if terminal or attempt.requirements_generation ~= requirements_generation then
														return false
												end
												terminal = true
												terminal_success = true
												attempt.requirements_terminal = {
														generation = requirements_generation,
														success = true,
												}
												if dispatching then return true end
												if not activation_is_current(authorization) then return true end
												activation_terminal = true
												activation_controller.complete(token)
												publish_activation_once()
												return true
										end
										local function on_cancel(reason)
												if terminal or attempt.requirements_generation ~= requirements_generation then
														return false
												end
												terminal = true
												terminal_cancel_reason = reason
												attempt.requirements_terminal = {
														generation = requirements_generation,
														success = false,
														reason = reason,
												}
												if dispatching then return true end
												if reason == "stale" or not activation_is_current(authorization) then
														attempt.requirements_stale = true
														return true
												end
												activation_terminal = true
												activation_controller.complete(token)
												return true
										end
										local requirements_ok, accepted = pcall_log(
											"models_mgr.check_requirements",
											models_mgr.check_requirements, state.llm_model,
											on_success, on_cancel, {
												requirement_owner = activation_requirement_owner,
												is_current = function()
													return activation_is_current(authorization)
												end,
											})
										dispatching = false
										if requirements_ok ~= true or accepted ~= true then
												-- A synchronous terminal from a dispatch that subsequently
												-- refuses is not authoritative.  Nothing may be published
												-- until the acquisition itself returns literal true.
												attempt.requirements_terminal = nil
												if not activation_is_current(authorization) then
														attempt.requirements_stale = true
														return true
												end
												return compensate_activation("requirements dispatch refused")
										end
										if terminal_success then
												activation_terminal = true
												activation_controller.complete(token)
												return publish_activation_once()
										end
										if terminal then
												if terminal_cancel_reason == "stale"
													or not activation_is_current(authorization) then
														attempt.requirements_stale = true
														return true
												end
												activation_terminal = true
												activation_controller.complete(token)
												return true
										end
										return publish_activation_once()
								end

								local function finish_activation(skip_deps_check)
										local authorization = activation_controller.capture(token)
										if authorization == nil or not activation_is_current(authorization) then
												Logger.debug(LOG, "Discarding stale LLM activation completion.")
												return false
										end
										if not skip_deps_check
											and check_backend_deps(state.llm_backend) ~= true then
												return compensate_activation("dependency bootstrap refused")
										end
										if state.llm_model and state.llm_model ~= "" then
												return dispatch_requirements()
										end
										activation_terminal = true
										activation_controller.complete(token)
										return publish_activation_once()
								end

								local function resume_attempt(_, resumed_from_pause)
										if activation_terminal then return true end
										if my_generation ~= activation_generation
											or state.llm_backend ~= activation_backend
											or state.llm_enabled ~= true then
												-- A shared preference action (notably Disable All) may
												-- supersede this activation without going through this
												-- menu closure.  Settle the stale token so it cannot block
												-- a later explicit enable or a pause rollback.
												activation_terminal = true
												return activation_controller.complete(token) == true
										end
										if attempt.phase == "bootstrap" then
												if attempt.bootstrap_result == nil then return true end
												if attempt.bootstrap_result ~= true then
														return compensate_activation("MLX bootstrap reported failure")
												end
												attempt.phase = "requirements"
												return finish_activation(true)
										end
										if attempt.phase == "requirements" then
												local requirements_terminal = attempt.requirements_terminal
												if type(requirements_terminal) == "table" then
														attempt.requirements_terminal = nil
														if requirements_terminal.success == true then
																activation_terminal = true
																if activation_controller.complete(token) ~= true then return false end
																return publish_activation_once()
														end
														if requirements_terminal.reason ~= "stale" then
																activation_terminal = true
																return activation_controller.complete(token) == true
														end
														attempt.requirements_stale = true
												end
												if resumed_from_pause == true or attempt.requirements_stale == true then
														attempt.requirements_stale = false
														return dispatch_requirements()
												end
										end
										return true
								end

								if target_enabled then
										-- Global Disable All mutates the shared preference outside
										-- this closure.  Its old token is already fenced by state,
										-- but must settle exactly before a new enable can own work.
										if activation_controller.cancel() ~= true then return false end
										token = activation_controller.begin(resume_attempt)
										if token == nil then return false end
										-- No backend process starts until the candidate is durable.
										if commit_enabled(true) ~= true then
												activation_controller.cancel()
												return false
										end

										if state.llm_backend == "mlx" then
												attempt.phase = "bootstrap"
												Logger.info(LOG, "Activating LLM — running MLX bootstrap check first.")
												local bootstrap_dispatching = true
												local bootstrap_terminal = false
												local bootstrap_ok, bootstrap_accepted = pcall_log(
													"mlx_deps_checker.check_and_install_deps",
													mlx_deps_checker.check_and_install_deps, function(ok)
															if bootstrap_terminal then return false end
															bootstrap_terminal = true
															attempt.bootstrap_result = ok == true
															if bootstrap_dispatching then return true end
															local authorization = activation_controller.capture(token)
															if authorization ~= nil and activation_is_current(authorization) then
																	return resume_attempt(token, false)
															end
															return true
													end)
												bootstrap_dispatching = false
												if bootstrap_ok ~= true or bootstrap_accepted ~= true then
														return compensate_activation("MLX bootstrap dispatch refused")
												end
												if bootstrap_terminal then
														return resume_attempt(token, false)
												end
												return true
										else
												return finish_activation(false)
										end
								end

								if activation_controller.cancel() ~= true then return false end
								if commit_enabled(false) ~= true then return false end
								publish_toggle()
								return true
						end or nil,
						submenu = main_menu
				}
		end

		check_startup = StartupCtrl.new({
				state                      = state,
				keymap                     = keymap,
				models_mgr                 = models_mgr,
				guarded_check_requirements = guarded_check_requirements,
				save_prefs                 = save_prefs,
				update_menu                = update_menu,
				apply_llm_shortcut         = apply_llm_shortcut,
				apply_llm_profile_shortcut = apply_llm_profile_shortcut,
				activate_hotkey            = activate_hotkey,
				mlx_deps_checker           = mlx_deps_checker,
				deps                       = deps,
				prediction_locks           = prediction_locks,
				get_startup_silence        = get_startup_silence,
				set_startup_silence        = set_startup_silence,
				get_trigger_hk             = get_trigger_hk,
				get_profile_hks            = get_profile_hks,
		})

		--- Returns a menu item for the active download progress shortcut, or nil if no download is running.
		--- @return table|nil The menu item, or nil.
		local function build_download_item()
				local is_active = deps.active_tasks and (
						deps.active_tasks["download"] or
						deps.active_tasks["download_tail"] or
						deps.active_tasks["install"]
				)
				if not is_active then return nil end
				local _dw = package.loaded["ui.download_window"]
				return {
						title = i18n.get("menu.llm.show_download_window"),
						fn = function()
								if _dw and type(_dw.focus) == "function" then
										pcall(_dw.focus)
								elseif _dw and type(_dw.is_active) == "function" and not _dw.is_active() then
										-- Window was closed without cancelling — download still runs in background
										pcall(notifications.notify, i18n.get("menu.llm.download_window_lost"), i18n.get("menu.llm.download_window_lost_body"), "info")
								end
						end
				}
		end

		return {
				build_item          = build_item,
				build_download_item = build_download_item,
				check_startup       = check_startup,
				set_llm_preference_runtime = prediction_locks.apply_preference,
				restore_preference_runtime = trigger_orch.restore_shortcuts,
		}
end

function M.create(deps)
		if _startup_identity_boundary_depth > 0 then
				Logger.warn(LOG,
					"LLM menu creation refused inside an active startup identity boundary.")
				return {}
		end
		_startup_identity_boundary_depth = _startup_identity_boundary_depth + 1
		local ok, result = xpcall(create_menu, debug.traceback, deps)
		_startup_identity_boundary_depth = math.max(0, _startup_identity_boundary_depth - 1)
		if not ok then
				Logger.error(LOG, "LLM menu creation failed inside its identity boundary: %s.",
					tostring(result))
				return {}
		end
		return type(result) == "table" and result or {}
end

return M
