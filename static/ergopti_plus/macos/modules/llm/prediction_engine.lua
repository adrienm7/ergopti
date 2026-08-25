--- modules/llm/prediction_engine.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine
--- DESCRIPTION:
--- Owns the full lifecycle of AI-assisted text predictions: request dispatch,
--- streaming ingestion, deduplication, display, and state management. Extracted
--- from modules/keymap/llm_bridge so all LLM-specific logic is consolidated
--- under modules/llm/ and the keymap bridge can focus on hotstring preview and
--- keystroke routing. App exclusion logic is also handled here as a private
--- helper, keeping it alongside the prediction pipeline that consumes it.
---
--- KEY RESPONSIBILITIES:
--- 1. State ownership: pending predictions, visibility flag, request counters,
---    inactivity / chain / watchdog timers, and all LLM configuration.
--- 2. LLM pipeline: sends async requests, streams results progressively,
---    deduplicates candidates, and manages the auto-dismiss countdown.
--- 3. Chain trigger: after a prediction is accepted, arms F16 detection so the
---    next LLM request fires as soon as the HID queue drains.
--- 4. Public API surface: exposed to the keymap bridge and menu modules via
---    typed setters and query helpers; no shared mutable globals.
--- ==============================================================================

local M = {}

local hs = hs

local core_llm         = require("modules.llm")
local WarmupController = require("modules.llm.warmup_controller")
local PromptBuilder    = require("modules.llm.prompt_builder")
local StreamingHandler = require("modules.llm.streaming_handler")
local AppFilter        = require("modules.llm.app_filter")
local Logger           = require("infra.logger")
local Timings          = require("infra.timings")
local TimerScheduler   = require("adapters.timer_scheduler")
local i18n             = require("infra.i18n")
local Keycodes         = require("infra.keycodes")
local tooltip          = require("ui.tooltip")
local keylogger        = require("modules.keylogger")

local LOG    = "llm.prediction_engine"
local _state = nil  -- Shared keymap core state; injected via M.init()
local _runtime_guard = function() return true end
local _ollama_daemon_recovery_pending = false
local _ollama_daemon_recovery_inflight = false
local _ollama_daemon_recovery_generation = 0
local _ollama_daemon_recovery_timer = nil
local recover_ollama_daemon


local function runtime_guard_available()
	local ok, available = pcall(_runtime_guard)
	return ok and available == true
end

local function runtime_available()
	local available = runtime_guard_available()
	if available and _ollama_daemon_recovery_pending
		and type(recover_ollama_daemon) == "function"
		and recover_ollama_daemon() ~= true then
		return false
	end
	return available
end






--- ===================================
--- ===================================
--- ======= 1/ Module Constants =======
--- ===================================
--- ===================================

-- ── macOS key code ────────────────────────────────────────────────────────────

-- Synthetic "typing complete" signal sent by apply_prediction after all HID events.
-- Uses F16 — distinct from the F15 script-control kill-switch, so manually pressing
-- F15 cannot accidentally fire an LLM chain. Exported so the keymap bridge can
-- detect it without duplicating the constant.
local KEYCODE_LLM_CHAIN = Keycodes.F16_LLM_CHAIN_SIGNAL

local SPINNER_FPS = 6  -- Frames per second for the streaming progress spinner

-- Hard floor on the requested prediction count. A configured 0 (or a fraction that
-- floors to 0) would ask the backend for nothing at all and make the shared
-- prompt_builder's diversity/greedy branches meaningless.
local MIN_NUM_PREDICTIONS = 1

-- ── Adaptive debounce ─────────────────────────────────────────────────────────
-- Adjust the inactivity delay based on live WPM so the timer fires sooner
-- when the user is thinking and later when they are actively typing.

local FAST_TYPING_WPM    = 55   -- Above this WPM, extend debounce (user still mid-burst)
local SLOW_TYPING_WPM    = 20   -- Below this WPM, shorten debounce (user paused to think)
local DEBOUNCE_FAST_MULT = 1.5  -- Multiplier applied when WPM is above FAST_TYPING_WPM
local DEBOUNCE_SLOW_MULT = 0.5  -- Multiplier applied when WPM is below SLOW_TYPING_WPM
-- Hard floor / ceiling so extreme WPM values don't produce unusable delays.
-- Sourced from the shared cross-driver registry so AHK and macOS stay in sync.
local DEBOUNCE_MIN_SEC   = Timings.sec("llm", "prediction_debounce_min_ms")
local DEBOUNCE_MAX_SEC   = Timings.sec("llm", "prediction_debounce_max_ms")

-- ── Timing constants ──────────────────────────────────────────────────────────

local CHAIN_FALLBACK_SEC  = Timings.sec("llm", "chain_fallback_ms")   -- Fire chain LLM if the F16 signal is somehow missed
local OLLAMA_RECOVERY_RETRY_SEC = Timings.sec("llm", "warmup_retry_base_ms")

-- Reference to the LLM engine defaults, used once at module load to seed Section 2
local LLM_DEFAULTS = core_llm.DEFAULT_STATE






--- ================================
--- ================================
--- ======= 2/ Mutable State =======
--- ================================
--- ================================

-- ── Prediction pipeline ───────────────────────────────────────────────────────

-- Predictions currently loaded in the tooltip (empty when nothing is shown)
local pending_predictions = {}

-- True while predictions are on screen and waiting for user interaction
local predictions_visible = false

-- Incremented each time a new LLM request is triggered; stale async callbacks
-- capture this value at request time and discard themselves when it changes
local llm_request_counter = 0

-- Tracks the currently active streaming fetch; finer-grained than llm_request_counter
-- because it resets on every individual fetch call, not only on new user input
local fetch_request_counter = 0

-- The last buffer+tail string sent to the LLM; prevents re-sending unchanged input
local last_buffer_signature = nil

-- Length of the buffer at the time of the last LLM request; used by the adaptive
-- debounce to detect ongoing corrections (shrinking buffer = user still deleting)
local _last_request_buffer_len = 0

-- ── Timers ────────────────────────────────────────────────────────────────────

-- Fires perform_check() after inactivity_debounce_sec of silence
local _inactivity_timer = nil
local timer_running
local stop_inactivity_timer
local _inactivity_generation = 0

-- Holds the profile name to forward when the rate-limit deferral re-arms the
-- inactivity timer; cleared by the timer callback after each deferred fire
local _deferred_profile_name = nil

-- Fallback: fires perform_check() if the F16 chain signal is somehow missed
local _chain_trigger_timer = nil
-- Next-runloop dispatch created after the owned F16 signal arrives.
local _chain_dispatch_timer = nil
-- Fences fallback and dispatch callbacks across reset/re-arm transitions.
local _chain_generation = 0

-- Deferred dismissal telemetry is a native capability too. It is normally
-- best-effort, but a global PAUSE must fence and settle every predecessor.
local _deferred_telemetry_generation = 0
local _deferred_telemetry_handles = {}

-- True between an accepted prediction and the F16 chain trigger that follows it
local chain_pending = false

-- Minimum gap between consecutive backend calls — protects paid APIs from per-keystroke
-- bursts and caps energy on local backends. Sourced from _shared/modules/llm/inference.json
-- so the AHK twin (modules/llm/api_common.ahk) reads the same floor.
local ApiCommon = require("modules.llm.api_common")
local _last_request_at_s = 0

-- ── LLM engine configuration ─────────────────────────────────────────────────
-- Stub values that prevent crashes during the brief startup window before the
-- menu loads and calls the set_* setters. NOT the user-configured values.

local is_llm_enabled          = LLM_DEFAULTS.llm_enabled
local active_model            = core_llm.get_current_model()  -- Backend-aware; overridden by set_llm_model
local llm_display_name        = core_llm.get_current_model()  -- Human-readable label shown in the info bar
local llm_backend_label       = nil                           -- "Ollama 🦙", "MLX 🚀", or a custom label
local _model_transition_generation = 0
local temperature             = LLM_DEFAULTS.llm_temperature
local context_window_chars    = LLM_DEFAULTS.llm_context_length
local min_words               = tonumber(hs.settings.get("llm_min_words")) or LLM_DEFAULTS.llm_min_words
local max_words               = tonumber(hs.settings.get("llm_max_words")) or LLM_DEFAULTS.llm_max_words
local num_predictions         = LLM_DEFAULTS.llm_num_predictions
local prediction_indent       = LLM_DEFAULTS.llm_pred_indent
local validation_mods         = LLM_DEFAULTS.llm_val_modifiers
local navigation_mods         = LLM_DEFAULTS.llm_nav_modifiers
local show_info_bar           = LLM_DEFAULTS.llm_show_info_bar
local sequential_mode         = LLM_DEFAULTS.llm_sequential_mode
local inactivity_debounce_sec = LLM_DEFAULTS.llm_debounce
local excluded_apps              = {}
local is_ai_preview_enabled      = true
-- Privacy gates, sourced from defaults.json like every other shared scalar. These
-- were hardcoded to true here while the shared value said false and Windows read
-- the shared value, so the same setting shipped with opposite defaults on the two
-- drivers. Canonical posture: password/secure fields blocked, URL bars allowed —
-- a credential is not a URL.
local url_bar_filter_enabled      = LLM_DEFAULTS.llm_disable_url_bars
local secure_field_filter_enabled = LLM_DEFAULTS.llm_disable_password_fields
local auto_raise_temperature  = LLM_DEFAULTS.llm_auto_raise_temp
local is_streaming_enabled       = LLM_DEFAULTS.llm_streaming
local is_streaming_multi_enabled = LLM_DEFAULTS.llm_streaming_multi  -- Show each variant as it streams in
local instant_on_word_end        = LLM_DEFAULTS.llm_instant_on_word_end  -- Bypass debounce at word boundaries


--- Schedules one dismissal-telemetry callback behind an exact lifecycle fence.
--- @param callback function Deferred telemetry callback.
--- @return table handle Scheduler handle.
--- @return boolean committed True only when the native timer committed.
local function schedule_deferred_telemetry(callback)
	local generation = _deferred_telemetry_generation
	local owner = {
		handle = nil,
		authorized = true,
		committed = false,
		installing = true,
		native_settled = false,
		callback_pending = false,
		callback_running = false,
		callback_consumed = false,
	}
	_deferred_telemetry_handles[owner] = true

	local function release_owner()
		if owner.installing == true or owner.native_settled ~= true
			or owner.callback_running == true then
			return false
		end
		if owner.authorized == true and owner.committed == true
			and owner.callback_consumed ~= true then
			return false
		end
		_deferred_telemetry_handles[owner] = nil
		return true
	end

	local function deliver_callback()
		if owner.callback_pending ~= true or owner.callback_consumed == true
			or owner.native_settled ~= true then
			return false
		end
		if owner.committed ~= true then return false end
		if owner.authorized ~= true
			or generation ~= _deferred_telemetry_generation then
			release_owner()
			return false
		end
		owner.callback_consumed = true
		owner.callback_pending = false
		owner.callback_running = true
		local ok, detail = xpcall(callback, debug.traceback)
		owner.callback_running = false
		if not ok then
			Logger.error(LOG, "Prediction telemetry callback raised: %s", tostring(detail))
		end
		release_owner()
		return ok == true
	end

	local function timer_callback()
		if owner.callback_pending == true or owner.callback_consumed == true then
			return false
		end
		owner.callback_pending = true
		if owner.installing == true then return true end
		return deliver_callback()
	end

	local schedule_ok, handle_or_error, committed = xpcall(function()
		return TimerScheduler.after(0, timer_callback)
	end, debug.traceback)
	owner.installing = false
	if schedule_ok == true and type(handle_or_error) == "table" then
		owner.handle = handle_or_error
		local observer_ok, observer_result = xpcall(function()
			return TimerScheduler.onSettled(handle_or_error, function()
				owner.native_settled = true
				deliver_callback()
				release_owner()
			end)
		end, debug.traceback)
		if not observer_ok or observer_result ~= true then
			owner.authorized = false
			owner.committed = false
			local cancel_ok, settled = xpcall(function()
				return TimerScheduler.cancel(handle_or_error)
			end, debug.traceback)
			if cancel_ok == true and settled == true then
				owner.native_settled = true
				release_owner()
			end
			Logger.error(LOG,
				"Prediction telemetry settlement observer was not accepted: %s",
				tostring(observer_result))
			return handle_or_error, false
		end
	end
	if schedule_ok ~= true or type(handle_or_error) ~= "table"
		or committed ~= true or owner.authorized ~= true then
		owner.authorized = false
		owner.committed = false
		if owner.handle ~= nil then
			local cancel_ok, settled = xpcall(function()
				return TimerScheduler.cancel(owner.handle)
			end, debug.traceback)
			if cancel_ok == true and settled == true then
				owner.native_settled = true
				release_owner()
			end
		else
			owner.native_settled = true
			release_owner()
		end
		return handle_or_error, false
	end
	owner.committed = true
	deliver_callback()
	return owner.handle, true
end


--- Fences and settles every deferred telemetry timer without replay.
--- @return boolean settled True only after every exact timer settled.
local function settle_deferred_telemetry()
	_deferred_telemetry_generation = _deferred_telemetry_generation + 1
	local snapshot = {}
	for owner in pairs(_deferred_telemetry_handles) do
		snapshot[#snapshot + 1] = owner
	end
	local all_settled = true
	for _, owner in ipairs(snapshot) do
		owner.authorized = false
		owner.committed = false
		if owner.installing == true or owner.callback_running == true then
			all_settled = false
		elseif owner.native_settled == true then
			_deferred_telemetry_handles[owner] = nil
		elseif owner.handle == nil then
			owner.native_settled = true
			_deferred_telemetry_handles[owner] = nil
		else
			local ok, result = xpcall(function()
				return TimerScheduler.cancel(owner.handle)
			end, debug.traceback)
			if ok and result == true then
				owner.native_settled = true
				_deferred_telemetry_handles[owner] = nil
			else
				all_settled = false
				Logger.error(LOG,
					"Prediction telemetry timer remains owned: %s", tostring(result))
			end
		end
	end
	-- A native stop/running probe may synchronously re-enter an ordinary reset
	-- and publish a fresh telemetry owner. Preserve that successor and make the
	-- outer PAUSE retry instead of certifying a snapshot that is already stale.
	if next(_deferred_telemetry_handles) ~= nil then all_settled = false end
	return all_settled
end

--- Stable dependency identity for WarmupController. A retry after a later child
--- refuses must present the same function object, not a fresh closure that the
--- controller correctly treats as an ownership replacement attempt.
--- @return boolean enabled
local function get_runtime_llm_enabled()
	return is_llm_enabled
end

--- Returns whether Ollama still owns the enabled runtime identity.
--- @return boolean|nil active Nil means the identity could not be read safely.
--- @return string reason Stable diagnostic reason.
local function ollama_runtime_active()
	if is_llm_enabled ~= true then return false, "prediction runtime disabled" end
	if type(core_llm.get_runtime_llm_enabled) == "function" then
		local gate_ok, gate = xpcall(core_llm.get_runtime_llm_enabled, debug.traceback)
		if not gate_ok or type(gate) ~= "boolean" then
			return nil, "runtime LLM gate unreadable: " .. tostring(gate)
		end
		if gate ~= true then return false, "runtime LLM gate disabled" end
	end
	local backend_ok, backend = xpcall(core_llm.get_backend, debug.traceback)
	if not backend_ok or type(backend) ~= "string" then
		return nil, "backend identity unreadable: " .. tostring(backend)
	end
	if backend ~= "ollama" then return false, "backend is " .. backend end
	return true, "active Ollama runtime"
end

--- Cancels the exact daemon-recovery retry owner.
--- @return boolean settled
local function cancel_ollama_recovery_timer()
	local owned = _ollama_daemon_recovery_timer
	if type(owned) ~= "table" or owned.timer == nil then
		_ollama_daemon_recovery_timer = nil
		return true
	end
	local ok, settled = xpcall(function()
		return TimerScheduler.cancel(owned)
	end, debug.traceback)
	if _ollama_daemon_recovery_timer ~= owned then return true end
	if not ok or settled ~= true then
		Logger.error(LOG, "Ollama recovery retry timer remains owned: %s.", tostring(settled))
		return false
	end
	_ollama_daemon_recovery_timer = nil
	return true
end

--- Retires logical recovery after disable or backend supersession.
--- @param reason string Stable diagnostic reason.
--- @return boolean settled
local function retire_ollama_daemon_recovery(reason)
	_ollama_daemon_recovery_generation = _ollama_daemon_recovery_generation + 1
	_ollama_daemon_recovery_pending = false
	_ollama_daemon_recovery_inflight = false
	if cancel_ollama_recovery_timer() ~= true then return false end
	Logger.debug(LOG, "Ollama daemon recovery superseded: %s.", tostring(reason))
	return true
end

--- Arms one exact bounded-delay retry without overlapping native startup.
--- @param generation number Recovery generation.
--- @param reason string Failure reason that caused the retry.
--- @return boolean committed
local function arm_ollama_recovery_retry(generation, reason)
	if generation ~= _ollama_daemon_recovery_generation
		or _ollama_daemon_recovery_pending ~= true then return true end
	if type(_ollama_daemon_recovery_timer) == "table"
		and _ollama_daemon_recovery_timer.timer ~= nil then return true end
	local candidate
	local authorized = false
	local delivery_attempted = false
	local ok, handle, committed = xpcall(function()
		return TimerScheduler.after(OLLAMA_RECOVERY_RETRY_SEC, function()
			delivery_attempted = true
			if authorized ~= true or generation ~= _ollama_daemon_recovery_generation
				or _ollama_daemon_recovery_timer ~= candidate then return end
			_ollama_daemon_recovery_timer = nil
			recover_ollama_daemon()
		end)
	end, debug.traceback)
	candidate = handle
	if type(candidate) == "table" and candidate.timer ~= nil
		and _ollama_daemon_recovery_timer == nil then
		_ollama_daemon_recovery_timer = candidate
	end
	if not ok or committed ~= true or type(candidate) ~= "table"
		or candidate.timer == nil or delivery_attempted == true
		or _ollama_daemon_recovery_timer ~= candidate then
		if _ollama_daemon_recovery_timer == candidate then
			cancel_ollama_recovery_timer()
		end
		Logger.error(LOG, "Ollama recovery retry timer did not commit after %s: %s.",
			tostring(reason), tostring(handle))
		return false
	end
	authorized = true
	Logger.warn(LOG, "Ollama daemon restart failed (%s); retrying in %.0f seconds.",
		tostring(reason), OLLAMA_RECOVERY_RETRY_SEC)
	return true
end

--- Settles a daemon-exit recovery only after the native daemon is published.
--- A global pause retains the intent; disable/backend replacement retires it.
--- @return boolean committed True when recovery is owned, parked or superseded.
recover_ollama_daemon = function()
	if _ollama_daemon_recovery_pending ~= true then return true end
	if runtime_guard_available() ~= true then return true end
	if _ollama_daemon_recovery_inflight == true then return true end
	if type(_ollama_daemon_recovery_timer) == "table"
		and _ollama_daemon_recovery_timer.timer ~= nil then return true end
	local active, reason = ollama_runtime_active()
	if active == nil then
		Logger.error(LOG, "Ollama daemon recovery identity check failed: %s.", tostring(reason))
		return false
	end
	if active ~= true then return retire_ollama_daemon_recovery(reason) end

	local api = package.loaded["modules.llm.api_ollama"]
	if type(api) ~= "table" or type(api.ensure_running) ~= "function" then
		Logger.error(LOG, "Ollama daemon recovery owner is unavailable.")
		return false
	end
	local generation = _ollama_daemon_recovery_generation
	_ollama_daemon_recovery_inflight = true
	local callback_ran = false
	local terminal_owned = false
	local function is_authorized()
		if generation ~= _ollama_daemon_recovery_generation
			or _ollama_daemon_recovery_pending ~= true
			or runtime_guard_available() ~= true then return false end
		local current = ollama_runtime_active()
		return current == true
	end
	local function on_settled(committed, detail)
		if callback_ran then return end
		callback_ran = true
		if generation ~= _ollama_daemon_recovery_generation then return end
		_ollama_daemon_recovery_inflight = false
		if runtime_guard_available() ~= true then
			Logger.debug(LOG, "Ollama daemon recovery parked after startup settlement.")
			terminal_owned = true
			return
		end
		local current, current_reason = ollama_runtime_active()
		if current == nil then
			Logger.error(LOG, "Ollama daemon recovery settlement identity is unreadable: %s.",
				tostring(current_reason))
			terminal_owned = arm_ollama_recovery_retry(generation, tostring(current_reason))
			return
		end
		if current == false then
			terminal_owned = retire_ollama_daemon_recovery(current_reason)
			return
		end
		if committed ~= true then
			terminal_owned = arm_ollama_recovery_retry(generation, tostring(detail))
			return
		end
		local warmup_ok, scheduled = xpcall(function()
			return WarmupController.schedule_warmup_with_retry("ollama daemon exit")
		end, debug.traceback)
		if not warmup_ok or scheduled ~= true then
			Logger.error(LOG, "Ollama daemon recovery warmup did not commit: %s.", tostring(scheduled))
			terminal_owned = arm_ollama_recovery_retry(generation, "warmup scheduling refused")
			return
		end
		_ollama_daemon_recovery_pending = false
		terminal_owned = true
		Logger.warn(LOG, "Ollama daemon recovery committed; readiness warmup scheduled.")
	end
	local start_ok, accepted = xpcall(function()
		return api.ensure_running({
			is_authorized = is_authorized,
			on_settled = on_settled,
		})
	end, debug.traceback)
	if not start_ok or accepted ~= true then
		_ollama_daemon_recovery_inflight = false
		if callback_ran == true then return terminal_owned end
		return arm_ollama_recovery_retry(generation, tostring(accepted))
	end
	return true
end




-- ==========================================
-- ==========================================
-- ======= 3/ Configuration Setters =========
-- ==========================================
-- ==========================================


-- ==============================
-- ===== 3.1) AI Preview ========
-- ==============================

--- @param v boolean
function M.set_preview_ai_enabled(v)
	is_ai_preview_enabled = (v == true)
	Logger.debug(LOG, "AI preview: %s.", is_ai_preview_enabled and "on" or "off")
	-- Disabling is a state TEARDOWN, not a UI hide. A bare tooltip.hide() clears
	-- the canvas and nothing else: predictions_visible stayed true, the pending
	-- set stayed populated, and neither request counter moved — so an in-flight
	-- stream still passed its own generation check and repainted the bubble the
	-- user had just switched off. M.reset() is the contract that actually holds:
	-- it clears the state, bumps both counters so late callbacks discard
	-- themselves, stops the chain timer and hides forcibly.
	if not v then M.reset() end
end

--- @param color table|nil RGBA table, or nil to restore the module default.
function M.set_preview_ai_color(color)
	tooltip.set_accent_color("ai_prediction", color)
end



--- ===========================
--- ===== 3.2) LLM Config =====
--- ===========================

--- @return boolean committed True after the runtime prediction gate is applied.
function M.set_llm_enabled(enabled)
	is_llm_enabled = (enabled == true)
	local committed = true

	local function settle(label, fn, ...)
		if type(fn) ~= "function" then
			Logger.error(LOG, "LLM settlement '%s' is unavailable.", tostring(label))
			committed = false
			return false
		end
		local args = { ... }
		local ok, result = xpcall(function()
			return fn(table.unpack(args))
		end, debug.traceback)
		if not ok or result ~= true then
			Logger.error(LOG, "LLM settlement '%s' did not commit (result: %s).",
				tostring(label), tostring(result))
			committed = false
			return false
		end
		return true
	end

	settle("runtime gate", core_llm.set_runtime_llm_enabled, is_llm_enabled)
	Logger.info(LOG, "LLM %s.", is_llm_enabled and "enabled" or "disabled")
	if not is_llm_enabled then
		settle("Ollama daemon recovery retirement", retire_ollama_daemon_recovery,
			"prediction runtime disabled")
		settle("prediction reset", M.reset)
		-- Stop BOTH warmup drivers, exactly as script_control.pause_all() does.
		-- M.reset() only stops the prediction timers and cancels streaming; it never
		-- touches warmup. WarmupController's chain self-guards on _get_llm_enabled(),
		-- but api_mlx's own 2s self-retry is gated solely on _warmup_stopped — so
		-- without stop_warmup() it keeps POSTing after the user turned AI off and
		-- fires the "server ready" notification while AI is disabled (M-3).
		settle("warmup-controller stop", WarmupController.stop)
		local ok_api, api = pcall(require, "modules.llm.api_mlx")
		if ok_api and api and type(api.stop_warmup) == "function" then
			settle("MLX warmup stop", api.stop_warmup)
		else
			committed = false
		end
		-- Ollama needs the same invalidation: its warmup POST triggers the model load
		-- and can stay in flight for tens of seconds, so without this the response
		-- lands after the gate closed, flips _is_ready and fires the "server ready"
		-- notification while AI is off. Only the MLX leg was stopped (M-3's sibling).
		local ok_ol, ollama = pcall(require, "modules.llm.api_ollama")
		if ok_ol and ollama and type(ollama.stop_warmup) == "function" then
			settle("Ollama warmup stop", ollama.stop_warmup)
		else
			committed = false
		end
		-- Remote warmup may still own a Keychain token read before it owns an HTTP
		-- request. Disable must revoke that waiter too and consume any pause-resume
		-- intent, otherwise leaving PAUSED resurrects a provider the user disabled.
		local ok_remote, remote = pcall(require, "modules.llm.api_remote")
		if ok_remote and remote and type(remote.stop_warmup) == "function" then
			settle("Remote warmup stop", remote.stop_warmup)
		else
			committed = false
		end
		return committed
	end
	-- _warmup_stopped is owned by script_control.pause_all(); resume_all() clears it
	-- and re-arms both drivers itself. Clearing it here would revive the 2 s POST loop
	-- MID-PAUSE and fire the "server ready" notification while the driver is
	-- suspended — the same violation this function fixes on the disable side. Read
	-- through package.loaded rather than require() to avoid a circular dependency,
	-- exactly as perform_check does.
	local sc = package.loaded["modules.shortcuts.script_control"]
	if sc and type(sc.is_paused) == "function" and sc.is_paused() then
		Logger.debug(LOG, "set_llm_enabled(true) while paused — warmup stays parked until resume.")
		return committed
	end
	if not committed then return false end

	-- Symmetric to the disable-side pair: resume_warmup() clears the
	-- _warmup_stopped short-circuit BEFORE the controller re-arms, otherwise the
	-- scheduled warmup would immediately self-discard in M.warmup()'s guard
	local ok_api, api = pcall(require, "modules.llm.api_mlx")
	if ok_api and api and type(api.resume_warmup) == "function" then
		settle("MLX warmup resume", api.resume_warmup)
	else
		committed = false
	end
	settle("warmup-controller schedule", WarmupController.schedule_warmup_with_retry,
		"set_llm_enabled")
	return committed
end

--- @return boolean
function M.get_llm_enabled() return is_llm_enabled end

function M.set_llm_model(model_name)
	_model_transition_generation = _model_transition_generation + 1
	local my_transition_generation = _model_transition_generation
	local changed = active_model ~= model_name
	if changed then
		-- Model identity owns every pending debounce, watchdog and backend request.
		-- Tear those down before publishing the new identity so a completion from
		-- the old model cannot appear under the new menu selection.
		if M.reset() ~= true then return false end
		if _model_transition_generation ~= my_transition_generation then return false end
	end
	local backend = core_llm.get_backend()
	if _model_transition_generation ~= my_transition_generation then return false end
	local setter = backend == "mlx" and core_llm.set_llm_model_mlx
		or core_llm.set_llm_model_ollama
	local setter_ok, committed = xpcall(setter, debug.traceback, model_name)
	if setter_ok ~= true or committed ~= true then
		Logger.error(LOG, "Model setter refused '%s' for backend %s: %s.",
			tostring(model_name), tostring(backend), tostring(committed))
		return false
	end
	if _model_transition_generation ~= my_transition_generation then return false end
	active_model = model_name
	Logger.info(LOG, "Model set: '%s' (backend: %s).", tostring(model_name), tostring(backend))
	-- Trigger a warmup only when LLM is already enabled (avoids spurious requests
	-- during startup when set_llm_model fires before set_llm_enabled(true))
	if is_llm_enabled and type(model_name) == "string" and model_name ~= "" then
		local warmup_ok, accepted = xpcall(
			WarmupController.schedule_warmup_with_retry, debug.traceback,
			"set_llm_model")
		if _model_transition_generation ~= my_transition_generation then return false end
		if warmup_ok ~= true or accepted ~= true then
			Logger.error(LOG, "Model warmup scheduling was refused: %s.",
				tostring(accepted))
			return false
		end
	end
	return true
end

function M.set_llm_display_model_name(name)
	llm_display_name = name
	Logger.debug(LOG, "Model display name: '%s'.", tostring(name))
end

function M.set_llm_backend_name(label)
	llm_backend_label = label
	Logger.debug(LOG, "Backend label: '%s'.", tostring(label))
end

function M.set_llm_context_length(l)
	-- Same coercion contract as set_llm_min_words below: this value reaches
	-- `context_window_chars > 0` in the shared prompt_builder, which throws on a
	-- string. config.toml / a half-written plist can deliver one, and neither
	-- preferences.lua nor menu_state.lua coerces on the way in.
	context_window_chars = tonumber(l) or LLM_DEFAULTS.llm_context_length
	Logger.debug(LOG, "Context window: %s chars.", tostring(context_window_chars))
end

function M.set_llm_temperature(t)
	-- Reaches `temperature <= GREEDY_TEMP_THRESHOLD` in the shared prompt_builder
	-- on the single-prediction path, which throws on a string
	temperature = tonumber(t) or LLM_DEFAULTS.llm_temperature
	Logger.debug(LOG, "Temperature: %s.", tostring(temperature))
end

function M.set_llm_num_predictions(n)
	-- Reaches `num_predictions > 1` in the shared prompt_builder — on the DEFAULT
	-- path, since llm_auto_raise_temp ships enabled — which throws on a string.
	-- Floor + clamp because a fractional or zero count would also make
	-- compute_temperature and the streaming batch logic behave nonsensically.
	local coerced = tonumber(n) or LLM_DEFAULTS.llm_num_predictions
	num_predictions = math.max(MIN_NUM_PREDICTIONS, math.floor(coerced))
	Logger.debug(LOG, "Prediction count: %s.", tostring(num_predictions))
end

function M.set_llm_pred_indent(v)
	prediction_indent = v
	Logger.debug(LOG, "Prediction indent: %s.", tostring(v))
end

function M.set_llm_show_info_bar(v)
	show_info_bar = (v == true)
	Logger.debug(LOG, "Info bar: %s.", show_info_bar and "visible" or "hidden")
end

function M.set_llm_sequential_mode(v)
	sequential_mode = (v == true)
	Logger.debug(LOG, "Sequential mode: %s.", sequential_mode and "on" or "off")
end

function M.set_llm_auto_raise_temp(v)
	auto_raise_temperature = (v == true)
	Logger.debug(LOG, "Auto temperature raise: %s.", auto_raise_temperature and "on" or "off")
end

function M.set_llm_streaming(v)
	is_streaming_enabled = (v == true)
	core_llm.set_llm_streaming(v)
	Logger.debug(LOG, "Streaming: %s.", is_streaming_enabled and "on" or "off")
end

function M.set_llm_streaming_multi(v)
	is_streaming_multi_enabled = (v == true)
	Logger.debug(LOG, "Streaming multi: %s.", is_streaming_multi_enabled and "on" or "off")
end

function M.set_llm_instant_on_word_end(v)
	instant_on_word_end = (v == true)
	Logger.debug(LOG, "Instant on word end: %s.", instant_on_word_end and "on" or "off")
end

function M.set_llm_disabled_apps(apps)
	excluded_apps = apps
	Logger.debug(LOG, "Excluded apps: %d configured.", type(apps) == "table" and #apps or 0)
end

function M.set_llm_url_bar_filter_enabled(v)
	url_bar_filter_enabled = (v ~= false)
	Logger.debug(LOG, "URL bar filter: %s.", url_bar_filter_enabled and "on" or "off")
end

function M.set_llm_secure_field_filter_enabled(v)
	secure_field_filter_enabled = (v ~= false)
	Logger.debug(LOG, "Secure field filter: %s.", secure_field_filter_enabled and "on" or "off")
end

--- Accepts either a string ("alt") or a table ({"alt", "cmd"}) for convenience,
--- since the menu may pass either form depending on the number of modifiers configured.
function M.set_llm_val_modifiers(mods)
	validation_mods = type(mods) == "string" and { mods } or mods or {}
	Logger.debug(LOG, "Validation modifiers: [%s].", table.concat(validation_mods, ", "))
end

function M.set_llm_nav_modifiers(mods)
	navigation_mods = type(mods) == "string" and { mods } or mods or {}
	Logger.debug(LOG, "Navigation modifiers: [%s].", table.concat(navigation_mods, ", "))
end

function M.set_llm_min_words(w)
	-- Coerce + fail closed: a value from config.toml / a half-written plist can be a
	-- string, which later reaches `<=`/`>` comparisons in the shared prompt_builder
	-- and `> 0` in the menu — both crash on a non-number. SettingsManager remains
	-- the sole native plist publisher; this setter owns runtime state only.
	min_words = tonumber(w) or LLM_DEFAULTS.llm_min_words
	Logger.debug(LOG, "Min words: %s.", tostring(min_words))
end

function M.set_llm_max_words(w)
	max_words = tonumber(w) or LLM_DEFAULTS.llm_max_words
	Logger.debug(LOG, "Max words: %s (0 = unlimited).", tostring(max_words))
end

--- Reads the actual engine-owned runtime value for one transactional menu key.
--- The boolean discriminator keeps a valid false value distinct from an unknown key.
--- @param key string Canonical preference key.
--- @return boolean found True when this engine owns the requested runtime value.
--- @return any value Current runtime value.
function M.get_llm_runtime_setting(key)
	if key == "llm_debounce" then return true, inactivity_debounce_sec end
	if key == "llm_max_words" then return true, max_words end
	if key == "llm_min_words" then return true, min_words end
	if key == "llm_temperature" then return true, temperature end
	if key == "llm_context_length" then return true, context_window_chars end
	if key == "llm_num_predictions" then return true, num_predictions end
	if key == "llm_show_info_bar" then return true, show_info_bar end
	if key == "llm_sequential_mode" then return true, sequential_mode end
	if key == "llm_auto_raise_temp" then return true, auto_raise_temperature end
	if key == "llm_streaming" then return true, is_streaming_enabled end
	if key == "llm_streaming_multi" then return true, is_streaming_multi_enabled end
	if key == "llm_pred_indent" then return true, prediction_indent end
	if key == "llm_nav_modifiers" then return true, navigation_mods end
	if key == "llm_val_modifiers" then return true, validation_mods end
	if key == "llm_instant_on_word_end" then return true, instant_on_word_end end
	if key == "llm_url_bar_filter_enabled" then return true, url_bar_filter_enabled end
	if key == "llm_secure_field_filter_enabled" then
		return true, secure_field_filter_enabled
	end
	if key == "llm_disabled_apps" then return true, excluded_apps end
	return false, nil
end


-- =====================================
-- ===== 3.3) Debounce / Timer =========
-- =====================================

--- Updates the inactivity debounce interval after settling any active one-shot.
function M.set_llm_debounce(seconds)
	-- Coerce for the same reason as the other numeric setters: the value is fed
	-- straight to setDelay() and to the adaptive-debounce arithmetic, and a string
	-- from config.toml would blow up inside the timer callback where nothing logs
	inactivity_debounce_sec = tonumber(seconds) or LLM_DEFAULTS.llm_debounce
	if _inactivity_timer then
		if stop_inactivity_timer() ~= true then
			Logger.error(LOG, "Debounce update rejected because the active timer could not be stopped.")
			return false
		end
	end
	Logger.debug(LOG, "Inactivity timer delay updated: %.3fs.", inactivity_debounce_sec)
	return true
end






--- ==================================
--- ==================================
--- ======= 4/ Private Helpers =======
--- ==================================
--- ==================================

--- Guards functions that require _state. Logs an error and returns false if it is nil.
--- @param func_name string Name of the calling function (for the error log).
--- @return boolean True if _state is ready, false if it is nil.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- Normalizes a modifier input (string or table) to a plain array of strings.
--- @param mod_input string|table The raw modifier value from the configuration.
--- @return table A flat array of modifier name strings.
local function normalize_mods(mod_input)
	if type(mod_input) == "string" then return { mod_input } end
	return mod_input or {}
end

--- Builds the short backend label shown in the info bar.
--- Falls back to a generic emoji name if no custom label is configured.
--- @return string The display label, or an empty string.
local function resolve_backend_label()
	if llm_backend_label and llm_backend_label ~= "" then return llm_backend_label end
	local backend = core_llm.get_backend()
	if backend == "mlx"    then return "MLX 🚀" end
	if backend == "ollama" then return "Ollama 🦙" end
	return ""
end

--- Formats the validation modifier shortcut for tooltip display.
--- Returns "none" to suppress the hint, or a zero-width space to hide it invisibly.
--- @param mods table The normalized validation modifier array.
--- @return string Formatted shortcut string (e.g. "alt", "cmd+shift", or invisible).
local function format_validation_shortcut(mods)
	if #mods == 1 and mods[1] == "none" then return "none" end
	-- Zero-width space: renders as invisible but keeps the slot present in the layout
	if #mods == 0 then return "\226\128\139" end
	return table.concat(mods, "+")
end

--- Strips the em-dash suffix from a profile label for compact info-bar display.
--- "Mon profil — texte long" → "Mon profil"
--- @param label string|nil The raw profile label.
--- @return string|nil The trimmed label, or nil if it was blank.
local function trim_profile_label(label)
	if type(label) ~= "string" then return nil end
	local clean = label:match("^%s*(.-)%s*$")
	if clean == "" then return nil end
	local head = clean:match("^(.-)%s*—")
	-- head:match("%S") guards against a bare "— foo" where head="" falling through to clean
	local picked = (head and head:match("%S")) and head or clean
	picked = picked:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s*—%s*$", "")
	if picked == "" then return nil end
	return picked
end

--- Assembles the info-bar text displayed beneath the prediction list.
--- Returns nil when model_name is absent, which hides the info bar entirely.
--- @param model_name string Display name of the active model.
--- @param elapsed_ms number|nil Round-trip latency in milliseconds, or nil.
--- @param backend string|nil Short backend label (e.g. "MLX 🚀"), or nil.
--- @param profile_name string|nil Active profile label, or nil.
--- @return string|nil The formatted info string, or nil.
local function build_info_bar_text(model_name, elapsed_ms, backend, profile_name)
	if not model_name or model_name == "" then return nil end

	local pieces = { model_name }
	if type(backend) == "string" and backend ~= "" then pieces[#pieces + 1] = backend end
	local short_profile = trim_profile_label(profile_name)
	if short_profile and short_profile ~= "" then pieces[#pieces + 1] = short_profile end
	local text = table.concat(pieces, " — ")
	-- elapsed_ms intentionally discarded — tooltip_llm owns the timing zone to avoid duplication
	local _ = elapsed_ms
	return text
end

--- Syncs the user-configured dismiss delay into the tooltip engine and resets the countdown.
--- Called after the final prediction batch arrives so the timer starts with the correct duration.
--- A delay of 0 keeps the tooltip on screen indefinitely.
local function reset_llm_dismiss_timer()
	if not runtime_available() then return false end
	local delay = (_state and _state.DELAYS and _state.DELAYS.llm_prediction) or 0
	local timeout_ok, timeout_err = pcall(tooltip.set_llm_timeout, delay)
	if not timeout_ok then
		Logger.error(LOG, "LLM dismiss timeout update raised — timer not committed: %s", tostring(timeout_err))
		return false
	end
	local reset_ok, reset_result = pcall(tooltip.reset_llm_timer)
	if not reset_ok then
		Logger.error(LOG, "LLM dismiss timer reset raised — timer not committed: %s", tostring(reset_result))
		return false
	end
	if reset_result ~= true then
		Logger.error(LOG, "LLM dismiss timer reset did not commit (result: %s).", tostring(reset_result))
		return false
	end
	Logger.debug(LOG, "LLM dismiss timer reset (delay: %gs).", delay)
	return true
end

--- Computes an adaptive debounce delay based on the user's current typing speed.
--- Fast typing → extend delay (prediction would be stale before it arrives).
--- Slow/paused → shorten delay (user is thinking, fire sooner).
--- If the buffer shrank since the last request, the user is still correcting —
--- keep the full configured delay to avoid sending a broken intermediate state.
--- @return number The debounce delay in seconds to use for this timer start.
local function compute_adaptive_debounce()
	-- Correction guard: never reduce delay while the user is still deleting
	local active_buffer = _state and _state.llm_buffer
	if type(active_buffer) ~= "string" and _state then active_buffer = _state.buffer end
	local cur_len = type(active_buffer) == "string" and #active_buffer or 0
	if cur_len < _last_request_buffer_len then
		return inactivity_debounce_sec
	end

	local ok, stats = pcall(keylogger.get_live_stats)
	local wpm = (ok and type(stats) == "table") and (tonumber(stats.wpm_physical) or 0) or 0

	if wpm > FAST_TYPING_WPM then
		return math.min(inactivity_debounce_sec * DEBOUNCE_FAST_MULT, DEBOUNCE_MAX_SEC)
	elseif wpm > 0 and wpm < SLOW_TYPING_WPM then
		return math.max(inactivity_debounce_sec * DEBOUNCE_SLOW_MULT, DEBOUNCE_MIN_SEC)
	end
	return inactivity_debounce_sec
end

--- Arms the inactivity debounce timer to fire perform_check() after silence.
--- @param delay_override number|nil Override in seconds; uses adaptive debounce if nil.
local function start_inactivity_timer(delay_override)
	if not runtime_available() then return false end
	if not is_llm_enabled or inactivity_debounce_sec < 0 then return false end
	if stop_inactivity_timer() ~= true then return false end
	local delay = delay_override
	if delay == nil then delay = compute_adaptive_debounce() end
	local generation = _inactivity_generation + 1
	_inactivity_generation = generation
	local descriptor = {
		acquiring = true,
		authorized = false,
		callback_running = false,
		delivered = false,
		generation = generation,
		handle = nil,
		settled = false,
	}
	_inactivity_timer = descriptor

	--- Releases this descriptor only after both native and business settlement.
	--- @return boolean released True when this exact owner left the live slot.
	local function release_descriptor()
		if descriptor.acquiring == true or descriptor.callback_running == true
			or descriptor.settled ~= true then
			return false
		end
		if descriptor.authorized == true and descriptor.delivered ~= true then
			return false
		end
		if _inactivity_timer == descriptor then _inactivity_timer = nil end
		return true
	end

	--- Reports whether callback business may still publish after a dependency boundary.
	--- @return boolean current True only for this exact callback generation.
	local function callback_is_current()
		return descriptor.callback_running == true
			and descriptor.authorized == true
			and descriptor.generation == _inactivity_generation
			and _inactivity_timer == descriptor
	end

	local handle, committed = TimerScheduler.after(delay, function()
		if descriptor.authorized ~= true or descriptor.delivered == true
			or descriptor.generation ~= _inactivity_generation then
			descriptor.authorized = false
			release_descriptor()
			return false
		end
		descriptor.delivered = true
		descriptor.callback_running = true
		local profile = _deferred_profile_name
		_deferred_profile_name = nil
		local ok, err = xpcall(function()
			return M.perform_check(false, profile, callback_is_current)
		end, debug.traceback)
		local callback_remained_current = callback_is_current()
		local rearm_delay = callback_remained_current and descriptor.rearm_delay or nil
		local rearm_profile = descriptor.rearm_profile
		descriptor.rearm_delay = nil
		descriptor.rearm_profile = nil
		descriptor.callback_running = false
		if not ok then
			Logger.error(LOG, "Inactivity debounce check raised: %s. This prediction is abandoned — "
				.. "nothing retries it, so the user simply never sees one.", tostring(err))
		end
		release_descriptor()
		if ok and callback_remained_current and rearm_delay ~= nil then
			_deferred_profile_name = rearm_profile
			if start_inactivity_timer(rearm_delay) ~= true then
				_deferred_profile_name = nil
				Logger.error(LOG, "Rate-limit deferral timer did not commit; request abandoned.")
				return false
			end
		end
		return ok and callback_remained_current
	end)
	descriptor.handle = handle
	descriptor.acquiring = false
	local observer_ok, observer_result = xpcall(function()
		return TimerScheduler.onSettled(handle, function()
			descriptor.settled = true
			release_descriptor()
		end)
	end, debug.traceback)
	if not observer_ok or observer_result ~= true then
		descriptor.authorized = false
		TimerScheduler.cancel(handle)
		Logger.error(LOG, "Inactivity timer settlement observer was not accepted: %s",
			tostring(observer_result))
		return false
	end
	if committed ~= true or generation ~= _inactivity_generation
		or _inactivity_timer ~= descriptor then
		descriptor.authorized = false
		TimerScheduler.cancel(handle)
		if handle.timer == nil and _inactivity_timer == descriptor then _inactivity_timer = nil end
		Logger.error(LOG, "Cannot commit inactivity timer start; exact cleanup is retained.")
		return false
	end
	descriptor.authorized = true
	if delay_override ~= nil then
		Logger.trace(LOG, "Inactivity timer started (override: %.3fs).", delay)
	else
		Logger.trace(LOG, "Inactivity timer started (adaptive: %.3fs).", delay)
	end
	return true
end
--- Reads a timer's native running state.
--- @param timer table|userdata Timer candidate.
--- @return boolean readable True when the probe completed.
--- @return boolean|string running_or_error Running state, or a diagnostic.
timer_running = function(timer)
	local timer_type = type(timer)
	if timer_type ~= "table" and timer_type ~= "userdata" then
		return false, "invalid timer"
	end
	local probe = timer.running
	if type(probe) == "function" then
		local ok, running_or_err = pcall(probe, timer)
		if not ok then return false, tostring(running_or_err) end
		return true, running_or_err == true
	end
	if type(probe) == "boolean" then return true, probe end
	return false, "running-state probe unavailable"
end


--- Cancels the exact inactivity timer without firing the LLM check.
--- A failed native stop remains retryable through the same descriptor.
--- @return boolean stopped True only when no native capability remains.
stop_inactivity_timer = function()
	local descriptor = _inactivity_timer
	if not descriptor then return true end
	descriptor.authorized = false
	_inactivity_generation = _inactivity_generation + 1
	if descriptor.callback_running == true then
		Logger.error(LOG, "Inactivity timer callback is still running.")
		return false
	end
	if descriptor.acquiring == true then
		Logger.error(LOG, "Inactivity timer acquisition is still unresolved.")
		return false
	end
	local handle = descriptor.handle
	if type(handle) ~= "table" or handle.timer == nil then
		if _inactivity_timer == descriptor then _inactivity_timer = nil end
		return true
	end
	local stop_ok, stop_result = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not stop_ok or stop_result ~= true then
		Logger.error(LOG, "Cannot stop inactivity timer: %s", tostring(stop_result))
		return false
	end
	if _inactivity_timer ~= nil and _inactivity_timer ~= descriptor then
		Logger.error(LOG,
			"Inactivity timer cleanup was superseded during native settlement.")
		return false
	end
	if _inactivity_timer == descriptor then _inactivity_timer = nil end
	Logger.done(LOG, "Inactivity timer stopped.")
	return true
end


--- Verifies ownership of a newly created one-shot timer.
--- @param timer table|userdata Timer candidate.
--- @param label string Diagnostic label.
--- @return boolean committed True only when the timer is running.
local function verify_started_timer(timer, label)
	local timer_type = type(timer)
	if timer_type ~= "table" and timer_type ~= "userdata" then
		Logger.error(LOG, "%s timer creation returned %s.", tostring(label), timer_type)
		return false
	end
	local status_ok, running_or_err = timer_running(timer)
	if not status_ok then
		Logger.error(LOG, "Cannot verify started %s timer: %s", tostring(label), tostring(running_or_err))
		return false
	end
	if not running_or_err then
		Logger.error(LOG, "%s timer was created stopped.", tostring(label))
		return false
	end
	return true
end


--- Stops one owned timer and preserves its handle until native state commits.
--- @param timer table|userdata|nil Timer handle.
--- @param label string Diagnostic label.
--- @return boolean stopped True only when no live callback remains.
local function stop_timer_handle(timer, label)
	if timer == nil then return true end
	local timer_type = type(timer)
	if (timer_type ~= "table" and timer_type ~= "userdata") or type(timer.stop) ~= "function" then
		Logger.error(LOG, "Cannot stop %s timer: stop() is unavailable.", tostring(label))
		return false
	end
	local stop_ok, stop_err = xpcall(function() timer:stop() end, debug.traceback)
	if not stop_ok then
		Logger.error(LOG, "Cannot stop %s timer: %s", tostring(label), tostring(stop_err))
		return false
	end
	local status_ok, running_or_err = timer_running(timer)
	if not status_ok then
		Logger.error(LOG, "Cannot verify stopped %s timer: %s", tostring(label), tostring(running_or_err))
		return false
	end
	if running_or_err then
		Logger.error(LOG, "%s timer remained running after stop().", tostring(label))
		return false
	end
	return true
end


--- Returns one chain-timer descriptor slot.
--- @param kind string "fallback" or "dispatch".
--- @return table|nil descriptor
local function get_chain_timer(kind)
	if kind == "fallback" then return _chain_trigger_timer end
	return _chain_dispatch_timer
end


--- Publishes one chain-timer descriptor slot.
--- @param kind string "fallback" or "dispatch".
--- @param descriptor table|nil
local function set_chain_timer(kind, descriptor)
	if kind == "fallback" then
		_chain_trigger_timer = descriptor
	else
		_chain_dispatch_timer = descriptor
	end
end


--- Fences and settles one exact TimerScheduler-owned chain capability.
--- @param kind string "fallback" or "dispatch".
--- @param label string Diagnostic label.
--- @return boolean settled
local function settle_chain_timer(kind, label)
	local descriptor = get_chain_timer(kind)
	if descriptor == nil then return true end
	descriptor.authorized = false
	if descriptor.callback_running == true then
		Logger.error(LOG, "%s timer callback is still running.", tostring(label))
		return false
	end
	if descriptor.acquiring == true then
		Logger.error(LOG, "%s timer acquisition is still unresolved.", tostring(label))
		return false
	end
	local handle = descriptor.handle
	if type(handle) ~= "table" or handle.timer == nil then
		if get_chain_timer(kind) == descriptor then set_chain_timer(kind, nil) end
		return true
	end
	local cancel_ok, cancel_result = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not cancel_ok or cancel_result ~= true then
		Logger.error(LOG, "%s timer remains owned: %s", tostring(label), tostring(cancel_result))
		return false
	end
	if get_chain_timer(kind) ~= nil and get_chain_timer(kind) ~= descriptor then
		Logger.error(LOG,
			"%s timer cleanup was superseded during native settlement.", tostring(label))
		return false
	end
	if get_chain_timer(kind) == descriptor then set_chain_timer(kind, nil) end
	return true
end


--- Acquires one exact one-shot chain timer behind a publish-before-start marker.
--- TimerScheduler buffers synchronous delivery and retains mutate-then-refuse debt.
--- @param kind string "fallback" or "dispatch".
--- @param delay number Delay in seconds.
--- @param generation number Chain generation authorized to receive delivery.
--- @param callback function Business callback.
--- @return table descriptor
--- @return boolean committed
local function acquire_chain_timer(kind, delay, generation, callback)
	local descriptor = {
		acquiring = true,
		authorized = false,
		callback_running = false,
		delivered = false,
		delivery_attempted = false,
		generation = generation,
		handle = nil,
		settled = false,
	}
	set_chain_timer(kind, descriptor)

	--- Releases this chain owner only after native settlement and callback return.
	--- @return boolean released True when the exact descriptor left its slot.
	local function release_descriptor()
		if descriptor.acquiring == true or descriptor.callback_running == true
			or descriptor.settled ~= true then
			return false
		end
		if descriptor.authorized == true and descriptor.delivered ~= true then
			return false
		end
		if get_chain_timer(kind) == descriptor then set_chain_timer(kind, nil) end
		return true
	end

	--- Reports whether business still belongs to this exact chain generation.
	--- @return boolean current True only while this callback retains authority.
	local function callback_is_current()
		return descriptor.callback_running == true
			and descriptor.authorized == true
			and descriptor.generation == _chain_generation
			and get_chain_timer(kind) == descriptor
	end

	local handle, committed = TimerScheduler.after(delay, function()
		descriptor.delivery_attempted = true
		if descriptor.authorized ~= true or descriptor.delivered == true
			or descriptor.generation ~= _chain_generation then
			descriptor.authorized = false
			release_descriptor()
			return false
		end
		descriptor.delivered = true
		descriptor.callback_running = true
		local callback_ok, callback_result = xpcall(function()
			return callback(callback_is_current)
		end, debug.traceback)
		local callback_remained_current = callback_is_current()
		descriptor.callback_running = false
		if not callback_ok then
			Logger.error(LOG, "%s timer business callback raised: %s.",
				tostring(kind), tostring(callback_result))
		end
		release_descriptor()
		return callback_ok and callback_remained_current
	end)
	descriptor.handle = handle
	descriptor.acquiring = false

	local observer_ok, observer_result = xpcall(function()
		return TimerScheduler.onSettled(handle, function()
			descriptor.settled = true
			release_descriptor()
		end)
	end, debug.traceback)
	if not observer_ok or observer_result ~= true then
		descriptor.authorized = false
		TimerScheduler.cancel(handle)
		Logger.error(LOG, "%s timer settlement observer was not accepted: %s",
			tostring(kind), tostring(observer_result))
		return descriptor, false
	end

	if committed ~= true or descriptor.generation ~= _chain_generation
		or get_chain_timer(kind) ~= descriptor then
		descriptor.authorized = false
		TimerScheduler.cancel(handle)
		if handle.timer == nil and get_chain_timer(kind) == descriptor then
			set_chain_timer(kind, nil)
		end
		return descriptor, false
	end
	descriptor.authorized = true
	return descriptor, true
end




-- ============================================
-- ============================================
-- ======= 5/ LLM Prediction Pipeline =========
-- ============================================
-- ============================================


--- Runs the full LLM prediction pipeline against the current buffer state.
---
--- Execution flow:
---   1. Validates preconditions: initialized, LLM enabled, not in an excluded app.
---   2. Syncs the dismiss delay into the tooltip engine BEFORE showing predictions,
---      so the auto-dismiss timer is created with the correct duration immediately.
---   3. Shows a loading indicator for immediate visual feedback.
---   4. Fires the async LLM request with streaming enabled.
---   5. Progressively renders predictions as they arrive, deduplicating on the fly.
---   6. Starts the auto-dismiss countdown once the final batch is confirmed.
---
--- @param force_trigger boolean If true, bypasses the freshness and word-count guards.
--- @param profile_name string|nil Optional profile label override shown in the info bar.
--- @param continuation_guard function|nil Internal exact-owner predicate for timer delivery.
function M.perform_check(force_trigger, profile_name, continuation_guard)
	if not runtime_available() then return end
	if not require_state("perform_check") then return end
	local entry_request_counter = llm_request_counter
	local entry_fetch_counter = fetch_request_counter

	--- Revalidates an optional timer owner after crossing a dependency boundary.
	--- @return boolean current True while the initiating owner remains authorized.
	local function owner_is_current()
		if type(continuation_guard) ~= "function" then return true end
		local ok, current = xpcall(continuation_guard, debug.traceback)
		if not ok then
			Logger.error(LOG, "Prediction continuation guard raised: %s.", tostring(current))
			return false
		end
		return current == true
	end

	--- Detects reset or supersession before this check publishes its request ID.
	--- @return boolean current True while no re-entrant boundary invalidated the check.
	local function predispatch_is_current()
		return owner_is_current()
			and llm_request_counter == entry_request_counter
			and fetch_request_counter == entry_fetch_counter
	end

	-- Defence-in-depth: a debounce/chain timer armed in the moment before the
	-- user paused must not fire an HTTP request or paint a prediction. pause_all
	-- already calls reset_predictions() to stop these timers, but this closes the
	-- race window. Read script_control via package.loaded to avoid a circular
	-- require. Mirrors the AHK LLM_Engine_FirePrediction A_IsSuspended guard.
	local sc = package.loaded["modules.shortcuts.script_control"]
	if sc and type(sc.is_paused) == "function" and sc.is_paused() then
		Logger.debug(LOG, "Paused — LLM request skipped.")
		return
	end

	force_trigger = force_trigger == true

	if not is_llm_enabled then
		Logger.debug(LOG, "LLM disabled — request skipped.")
		return
	end
	-- Preview-off is an intentional no-surface state, not a failed render. Do not
	-- spend prompt/backend work on a result that cannot be published or accepted.
	if not is_ai_preview_enabled then
		Logger.debug(LOG, "AI preview disabled — request skipped.")
		return
	end
	local model_ok, model_to_use = xpcall(function()
		return core_llm.get_current_model()
	end, debug.traceback)
	if not model_ok then
		Logger.error(LOG, "Current model lookup raised — request aborted: %s", tostring(model_to_use))
		return
	end
	if not predispatch_is_current() then return end
	if type(model_to_use) ~= "string" or model_to_use == "" then
		Logger.debug(LOG, "No active model — request skipped.")
		return
	end
	-- Backend readiness gate: until the warmup has confirmed the model is loaded
	-- and serving inference, dispatching a request would show the loading tooltip
	-- against a server that simply cannot answer in time. Skip silently so the
	-- user sees no spinner while the backend warms up.
	if type(core_llm.is_backend_ready) == "function" and not core_llm.is_backend_ready() then
		Logger.debug(LOG, "Backend not ready yet — request skipped (model warming up).")
		return
	end
	if not predispatch_is_current() then return end
	if AppFilter.is_blocked(_state, excluded_apps, url_bar_filter_enabled, secure_field_filter_enabled) then
		Logger.debug(LOG, "App excluded — LLM request skipped.")
		return
	end
	if not predispatch_is_current() then return end

	-- Sync dismiss delay before the first show call so the timer is created with the correct duration
	local dismiss_delay = (_state.DELAYS and _state.DELAYS.llm_prediction) or 0
	local timeout_ok, timeout_err = pcall(tooltip.set_llm_timeout, dismiss_delay)
	if not timeout_ok then
		Logger.error(LOG, "LLM dismiss timeout update raised — request aborted: %s", tostring(timeout_err))
		M.reset()
		return
	end
	if not predispatch_is_current() then return end

	local buffer = _state.llm_buffer
	if type(buffer) ~= "string" then buffer = _state.buffer end
	if type(buffer) ~= "string" then buffer = "" end

	-- Delegate prompt parameter building to PromptBuilder.
	-- Guarded: perform_check is the body of the module-level debounce timer, and
	-- hs.timer callbacks are pcall'd by Hammerspoon — a throw here would be routed
	-- to the Hammerspoon Console and never reach infra/logger. The failure mode is
	-- invisible and permanent: the health dot stays green, the backend stays
	-- ready, and no prediction ever appears again for the session. Surfacing the
	-- error through Logger.error makes it diagnosable from the unified log.
	local build_ok, params, skip_reason, signature = pcall(PromptBuilder.build, buffer, {
		temperature             = temperature,
		max_words               = max_words,
		min_words               = min_words,
		num_predictions         = num_predictions,
		auto_raise_temperature  = auto_raise_temperature,
		context_window_chars    = context_window_chars,
	}, last_buffer_signature, force_trigger)

	if not build_ok then
		-- On failure pcall returns (false, err); the error lands in `params`
		Logger.error(LOG, "PromptBuilder.build raised — request aborted: %s", tostring(params))
		return
	end
	if not predispatch_is_current() then return end

	if not params then
		Logger.debug(LOG, "%s — LLM request skipped.", skip_reason or "unknown reason")
		return
	end

	-- Backend-aware request floor — re-arm the debounce timer for the
	-- remaining gap instead of firing immediately. force_trigger (the
	-- manual hotkey path) bypasses the floor because it is an explicit user
	-- request, not a per-keystroke burst.
	if not force_trigger then
		local now_s        = hs.timer.secondsSinceEpoch()
		local backend_id   = core_llm.get_backend and core_llm.get_backend() or "ollama"
		local min_interval = ApiCommon.get_rate_limit_min_interval_s(backend_id)
		local elapsed      = now_s - _last_request_at_s
		if not predispatch_is_current() then return end
		if _last_request_at_s > 0 and elapsed < min_interval then
			local remaining = min_interval - elapsed
			Logger.debug(LOG, "Backend '%s' floor (%dms) — deferring %dms.",
				backend_id, math.floor(min_interval * 1000), math.floor(remaining * 1000))
			-- Reuse the single canonical timer instead of creating an orphan;
			-- store profile_name so the callback can forward it when it fires
			local callback_owner = _inactivity_timer
			if callback_owner and callback_owner.callback_running == true
				and owner_is_current() then
				-- A natural one-shot remains the logical owner until its business
				-- callback returns, so publish its successor only after that boundary
				callback_owner.rearm_delay = remaining
				callback_owner.rearm_profile = profile_name
			else
				_deferred_profile_name = profile_name
				if stop_inactivity_timer() ~= true or start_inactivity_timer(remaining) ~= true then
					_deferred_profile_name = nil
					Logger.error(LOG, "Rate-limit deferral timer did not commit; request abandoned.")
				end
			end
			return
		end
	end

	-- Pre-build the info bar for streaming frames; on_success replaces it with the latency-aware version
	local active_profile_now   = core_llm.get_active_profile()
	local display_profile_now  = profile_name or (active_profile_now and active_profile_now.label)
	local streaming_info_bar   = show_info_bar
		and build_info_bar_text(llm_display_name or core_llm.get_current_model(), nil, resolve_backend_label(), display_profile_now)
		or nil
	if not predispatch_is_current() then return end

	local num_preds       = params.num_preds

	llm_request_counter   = llm_request_counter + 1
	fetch_request_counter = fetch_request_counter + 1
	local my_fetch_id     = fetch_request_counter

	--- Reports whether this exact request still owns the pipeline.
	--- @return boolean current True while no reset or newer dispatch superseded it.
	local function is_current_fetch()
		return owner_is_current()
			and runtime_available()
			and fetch_request_counter == my_fetch_id
	end

	--- Fails closed only while this request still owns the surface.
	--- @param stage string UI stage that failed to commit.
	--- @param detail any Returned value or raised error.
	--- @return boolean reset True when this request performed the reset.
	local function close_current_request(stage, detail)
		if not is_current_fetch() then return false end
		Logger.error(LOG, "LLM request stage '%s' did not commit — request abandoned (result: %s).",
			tostring(stage), tostring(detail))
		local reset_ok, reset_result = xpcall(M.reset, debug.traceback)
		if not reset_ok or reset_result ~= true then
			Logger.error(LOG, "LLM request cleanup did not commit after '%s' (result: %s).",
				tostring(stage), tostring(reset_result))
			return false
		end
		return true
	end

	-- An empty surface needs an explicit loading commit before any backend work.
	-- Existing predictions were themselves committed by StreamingHandler, so they
	-- may remain visible while the replacement request is dispatched.
	if not predictions_visible then
		-- Keep argument construction inside the protected boundary: tint() and the
		-- locale lookup are native/dependency calls too, and a throw before pcall's
		-- function argument otherwise bypasses the file logger and leaves no surface.
		local loading_ok, loading_result = xpcall(function()
			return tooltip.show_loading(
				i18n.get("llm.generating"),
				is_ai_preview_enabled,
				tooltip.tint("ai_loading")
			)
		end, debug.traceback)
		if not loading_ok or loading_result ~= true then
			close_current_request("loading render", loading_result)
			return
		end
		if not is_current_fetch() then return end
	end

	local chain_ok, chain_result = xpcall(function()
		return tooltip.set_chain_start(hs.timer.secondsSinceEpoch())
	end, debug.traceback)
	if not chain_ok or chain_result ~= true then
		close_current_request("chain timing", chain_result)
		return
	end
	if not is_current_fetch() then return end

	-- Only after the current surface is proven usable may prior rows become
	-- placeholders and the backend lifecycle become externally observable.
	if predictions_visible then
		for _, p in ipairs(pending_predictions) do p._is_stream_placeholder = true end
	end

	-- Shared noise gate — must be consistent between partial and final paths
	local function is_noise_pred(to_type)
		if not to_type or to_type:gsub("[%s%.…]", "") == "" then return true end
		local text_lower = to_type:lower()
		-- Anchor to the end of the buffer ((%S)%s*$) instead of a greedy .*
		-- scan from position 1, which is O(N) on a large context buffer.
		local prev_char  = buffer:match("(%S)%s*$")
		local first_ch   = to_type:match("^%s*(.)") or ""
		local ends_sent  = (prev_char == nil) or (prev_char:match("[%.%!%?…:;\n]") ~= nil)
		-- Cache buffer:lower() once — repeated calls on a 10 k-word context are
		-- each O(N) allocations on this hot streaming path.
		local buffer_low = buffer:lower()
		return (text_lower:match("^%s*suite%s+finale") ~= nil)
			or (text_lower:match("^%s*</") ~= nil)
			or (text_lower:match("^%s*vous avez besoin de plus") ~= nil)
			or (text_lower:match("^%s*vous etes les plus") ~= nil)
			or (text_lower:match("^%s*vous%s") ~= nil and buffer_low:match("vous") == nil)
			or (first_ch:match("[A-Z]") ~= nil and not ends_sent)
			or (to_type:find(":", 1, true) ~= nil)
	end

	-- Mutable references for shared access between the engine and streaming callbacks
	local pending_ref = { value = pending_predictions }
	local visible_ref = { value = predictions_visible }

	-- Keep local state in sync when the refs are updated by callbacks
	local function sync_refs()
		pending_predictions = pending_ref.value
		predictions_visible = visible_ref.value
	end

	-- Callback construction happens after the loading surface is live. Keep both
	-- the context builders and the factory inside the same boundary: a throw here
	-- otherwise strands a spinner with no watchdog and no backend callback able to
	-- dismiss it.
	local callbacks_ok, on_partial_cb, on_success_cb, on_fail_cb = xpcall(function()
		return StreamingHandler.build_callbacks({
			buffer                  = buffer,
			tail                    = params.tail,
			my_fetch_id             = my_fetch_id,
			get_fetch_id            = function() return fetch_request_counter end,
			is_streaming_enabled    = is_streaming_enabled,
			is_streaming_multi_enabled = is_streaming_multi_enabled,
			num_predictions         = num_preds,
			show_info_bar           = show_info_bar,
			streaming_info_bar      = streaming_info_bar,
			prediction_indent       = prediction_indent,
			validation_mods         = normalize_mods(validation_mods),
			navigation_mods         = normalize_mods(navigation_mods),
			model_to_use            = model_to_use,
			llm_display_name        = llm_display_name,
			profile_name            = profile_name,
			build_info_bar_text     = build_info_bar_text,
			resolve_backend_label   = resolve_backend_label,
			is_noise_pred           = is_noise_pred,
			reset_llm_dismiss_timer = reset_llm_dismiss_timer,
			is_ai_preview_enabled   = is_ai_preview_enabled,
			pending_predictions_ref = pending_ref,
			predictions_visible_ref = visible_ref,
			runtime_available       = runtime_available,
			on_ui_unavailable       = close_current_request,
		})
	end, debug.traceback)
	if not callbacks_ok or type(on_success_cb) ~= "function" or type(on_fail_cb) ~= "function" then
		close_current_request("callback construction", callbacks_ok and "invalid callback set" or on_partial_cb)
		return
	end
	if not is_current_fetch() then return end

	-- Wrap callbacks to keep local state in sync after each call.
	--
	-- STALENESS-AWARE, and it must stay that way. The StreamingHandler callbacks
	-- already discard a superseded response on their own fetch-id guard, but the
	-- refs still hold the PREVIOUS response's populated values — so a bare
	-- sync_refs() copied them back into module state and resurrected a
	-- prediction that reset() had just cleared. Nothing changed on screen at
	-- that moment; the damage surfaced on the next Tab or Enter, which gates
	-- only on engine.is_visible() and therefore typed a completion the user
	-- never saw. Any other keystroke healed it, so it read as a one-off ghost
	-- insertion rather than a bug.
	--
	-- The handler-level guard cannot cover this: the clobber happens one level
	-- above it, in these two-line wrappers.
	local function run_async_callback(stage, callback, ...)
		if not is_current_fetch() then return end
		local args = table.pack(...)
		local callback_ok, callback_err = xpcall(function()
			return callback(table.unpack(args, 1, args.n))
		end, debug.traceback)
		if not callback_ok then
			close_current_request(stage, callback_err)
			return
		end
		if is_current_fetch() then sync_refs() end
	end

	local function on_success(raw_predictions, elapsed_ms, is_final, is_batch_progressive)
		run_async_callback("success callback", on_success_cb,
			raw_predictions, elapsed_ms, is_final, is_batch_progressive)
	end
	local function on_fail()
		run_async_callback("failure callback", on_fail_cb)
	end
	local on_partial = on_partial_cb and function(partial_raw)
		run_async_callback("partial callback", on_partial_cb, partial_raw)
	end or nil

	-- A request without a live watchdog can strand the loading surface forever.
	-- Treat timer construction and start verification as part of dispatch commit.
	local watchdog_ok, watchdog_result = xpcall(function()
		return StreamingHandler.arm_watchdog({
			my_fetch_id             = my_fetch_id,
			get_fetch_id            = function() return fetch_request_counter end,
			pending_predictions_ref = pending_ref,
			predictions_visible_ref = visible_ref,
			validation_mods         = normalize_mods(validation_mods),
			navigation_mods         = normalize_mods(navigation_mods),
			show_info_bar           = show_info_bar,
			llm_display_name        = llm_display_name,
			prediction_indent       = prediction_indent,
			is_ai_preview_enabled   = is_ai_preview_enabled,
			build_info_bar_text     = build_info_bar_text,
			resolve_backend_label   = resolve_backend_label,
			runtime_available       = runtime_available,
			on_ui_unavailable       = close_current_request,
		})
	end, debug.traceback)
	if not watchdog_ok or watchdog_result ~= true then
		close_current_request("watchdog arm", watchdog_result)
		return
	end
	if not is_current_fetch() then return end

	Logger.start(LOG, "LLM request — model: '%s' | temp: %.2f | %d pred(s) | max tokens: %d.",
		tostring(model_to_use), params.req_temperature, num_preds, params.max_tokens)

	local fetch_ok, fetch_err = xpcall(function()
		core_llm.fetch_llm_prediction(
			params.context_buffer, params.tail, model_to_use, params.req_temperature,
			params.max_tokens, num_preds,
			on_success,
			on_fail,
			sequential_mode, force_trigger, function() return fetch_request_counter end,
			on_partial
		)
	end, debug.traceback)
	if not fetch_ok then
		close_current_request("backend dispatch", fetch_err)
		return
	end
	if not is_current_fetch() then return end

	-- Rate-limit and duplicate-suppression state describes real backend calls,
	-- never a loading paint or failed watchdog construction.
	last_buffer_signature    = signature
	_last_request_buffer_len = #buffer
	_last_request_at_s       = hs.timer.secondsSinceEpoch()
end

--- Clears all active predictions and fully resets the prediction pipeline state.
--- Emits a keylogger dismissal event when predictions were visible before the reset,
--- except at a global pause boundary where no deferred capability may survive.
--- The keymap bridge wraps this to also handle hotstring dismissal telemetry.
--- @param options table|nil Optional { suppress_telemetry = boolean }.
function M.reset(options)
	local suppress_telemetry = type(options) == "table"
		and options.suppress_telemetry == true
	local was_visible = predictions_visible and #pending_predictions > 0
	local dismissed_predictions = was_visible and pending_predictions or nil
	local cleanup_committed = true

	--- Runs one cleanup stage without preventing its siblings from executing.
	--- @param stage string Diagnostic stage label.
	--- @param fn function Cleanup operation.
	--- @param require_true boolean Whether the operation has a strict commit result.
	--- @return boolean committed True when this stage completed as required.
	local function cleanup_stage(stage, fn, require_true)
		local ok, result = xpcall(fn, debug.traceback)
		if not ok or (require_true and result ~= true) then
			cleanup_committed = false
			Logger.error(LOG, "Prediction reset stage '%s' did not commit (result: %s).",
				tostring(stage), tostring(result))
			return false
		end
		return true
	end

	if suppress_telemetry then
		cleanup_stage("deferred telemetry stop", settle_deferred_telemetry, true)
		cleanup_stage("deferred profile warmup stop",
			core_llm.pause_deferred_profile_warmup, true)
	end

	-- Finalise chain timing before tearing down state so the tooltip can
	-- compute TTLT against the last update and render the full line one last
	-- time. Safe to call unconditionally — tooltip ignores it if no chain
	-- was armed (e.g. reset fired before any backend dispatch).
	cleanup_stage("chain timing", tooltip.mark_chain_complete, false)

	pending_predictions        = {}
	predictions_visible        = false
	last_buffer_signature      = nil
	llm_request_counter        = llm_request_counter + 1
	fetch_request_counter      = fetch_request_counter + 1
	-- Clear the rate-limit deferral's profile label. It is otherwise cleared ONLY by
	-- the inactivity-timer callback that consumes it; a reset that tears down that
	-- timer before it fires would leave the stale label to mis-attribute the NEXT,
	-- unrelated prediction's info bar (F-L12).
	_deferred_profile_name     = nil

	-- Clear chain state before tearing down other resources so any fallback
	-- timer callback that fires between now and its cancellation sees
	-- chain_pending = false and refuses to launch a fetch (D3 audit fix).
	chain_pending = false
	_chain_generation = _chain_generation + 1
	if _chain_trigger_timer then
		cleanup_stage("chain fallback timer stop", function()
			return settle_chain_timer("fallback", "chain fallback")
		end, true)
	end
	if _chain_dispatch_timer then
		cleanup_stage("chain dispatch timer stop", function()
			return settle_chain_timer("dispatch", "chain dispatch")
		end, true)
	end

	cleanup_stage("failure counter reset", StreamingHandler.reset_failure_count, false)

	-- A false/throwing silent hide must not abort the remaining cancellation
	-- stages. Try each stronger public fallback before admitting that pixels could
	-- not be revoked, while avoiding duplicate calls to the same function value.
	local hidden = false
	local attempted_hides = {}
	local hide_candidates = {}
	for _, candidate_name in ipairs({ "hide_forced_silent", "hide_forced", "hide" }) do
		local candidate = tooltip[candidate_name]
		if type(candidate) == "function" then hide_candidates[#hide_candidates + 1] = candidate end
	end
	for _, hide_fn in ipairs(hide_candidates) do
		if not attempted_hides[hide_fn] then
			attempted_hides[hide_fn] = true
			local hide_ok, hide_result = xpcall(hide_fn, debug.traceback)
			if hide_ok and hide_result == true then
				hidden = true
				break
			end
			Logger.error(LOG, "Prediction reset hide attempt did not commit (result: %s).", tostring(hide_result))
		end
	end
	if not hidden then cleanup_committed = false end

	cleanup_stage("inactivity timer stop", stop_inactivity_timer, true)
	cleanup_stage("stream watchdog stop", StreamingHandler.stop_watchdog, true)
	-- Cancel any in-flight streaming curl UNCONDITIONALLY — not gated on the current
	-- is_streaming_enabled. A stream dispatched while streaming was ON can still be in
	-- flight after the user toggles streaming OFF; gating on the live flag would skip
	-- the cancel and leak the curl task (and on MLX, the single-request connection it
	-- holds blocks the next prediction). cancel_streaming is a null-safe idempotent
	-- no-op when nothing is streaming, mirroring stop_timer()'s unconditional cancel (F-L11).
	cleanup_stage("backend stream cancel", core_llm.cancel_streaming, true)

	if dismissed_predictions and not suppress_telemetry then
		-- Persistence performs an open/write/flush in the keylogger. reset() is
		-- reached from the keyDown eventtap, so telemetry must run only after that
		-- callback returns. Capture the immutable pool before clearing module state.
		local schedule_ok, handle_or_err, telemetry_committed = xpcall(function()
			return schedule_deferred_telemetry(function()
				pcall(keylogger.log_llm_dismissed, nil, dismissed_predictions)
				Logger.debug(LOG, "Predictions cleared (were visible).")
			end)
		end, debug.traceback)
		if not schedule_ok or telemetry_committed ~= true then
			cleanup_committed = false
			Logger.error(LOG, "Prediction dismissal telemetry could not be scheduled (result: %s).",
				tostring(handle_or_err))
		end
	end
	return cleanup_committed
end

--- Captures the prediction at the given index for an apply operation and
--- atomically fences every older async callback before external cleanup begins.
--- The bridge logs acceptance, so the following reset must not emit dismissal.
--- @param idx number The 1-based prediction index to consume.
--- @return table|nil pred The prediction entry, or nil if the index is invalid.
--- @return table|nil all_preds The full prediction pool at the time of consumption, or nil.
function M.consume(idx)
	if not runtime_available() then return nil, nil end
	local pred = pending_predictions[idx]
	if not pred then
		Logger.warn(LOG, "consume(%d): invalid index (pool of %d prediction(s)).", idx, #pending_predictions)
		return nil, nil
	end
	local all_preds = pending_predictions
	-- Commit the logical half of acceptance before any timer/task/canvas teardown.
	-- Even if native cleanup later fails, an old stream can no longer repaint over
	-- the text the user accepted.
	predictions_visible = false
	pending_predictions = {}
	last_buffer_signature = nil
	llm_request_counter = llm_request_counter + 1
	fetch_request_counter = fetch_request_counter + 1
	return pred, all_preds
end

--- Arms the chain trigger after a prediction is accepted.
--- Sets chain_pending and starts a fallback timer in case the F16 signal is missed.
--- Must be called BEFORE hs.eventtap.keyStroke({}, "f16", 0) is sent by the bridge.
function M.arm_chain()
	if not runtime_available() then return false end
	if not require_state("arm_chain") then return false end
	if stop_inactivity_timer() ~= true then return false end
	-- A replacement attempt supersedes the logical intent before it crosses any
	-- native cleanup/start boundary.  If exact cleanup or the replacement start
	-- refuses, no stale chain_pending flag may survive without a business owner.
	local next_generation = _chain_generation + 1
	_chain_generation = next_generation
	chain_pending = false
	if settle_chain_timer("fallback", "prior chain fallback") ~= true then return false end
	if settle_chain_timer("dispatch", "prior chain dispatch") ~= true then return false end

	local descriptor, timer_committed = acquire_chain_timer("fallback", CHAIN_FALLBACK_SEC,
		next_generation, function(continuation_guard)
			if not chain_pending or not runtime_available() then
				chain_pending = false
				return
			end
			chain_pending = false
			Logger.warn(LOG, "Fallback chain triggered — F16 signal was missed.")
			M.perform_check(true, nil, continuation_guard)
		end)
	if timer_committed ~= true then
		Logger.error(LOG, "Chain fallback timer did not commit; exact cleanup is retained.")
		return false
	end
	-- The fallback belongs to the whole arm transaction, not merely to its native
	-- start.  Publish the logical intent before crossing the rescan boundary, but
	-- keep callback delivery fenced until that boundary commits.  A synchronous
	-- delivery can then only settle this exact candidate; it can never consume an
	-- unpublished intent and leave chain_pending=true without a fallback.
	descriptor.authorized = false
	chain_pending = true

	--- Rolls back only this arm attempt; a re-entrant successor owns the globals.
	--- @param label string Cleanup label.
	local function rollback_arm(label)
		descriptor.authorized = false
		if descriptor.generation ~= _chain_generation then return true end
		chain_pending = false
		_chain_generation = _chain_generation + 1
		if get_chain_timer("fallback") ~= descriptor then return true end
		return settle_chain_timer("fallback", label)
	end

	local suppress_ok, suppress_result = xpcall(function()
		return _state.suppress_rescan_keep_buffer(CHAIN_FALLBACK_SEC)
	end, debug.traceback)
	if not suppress_ok or suppress_result ~= true then
		rollback_arm("uncommitted chain fallback")
		Logger.error(LOG, "Chain rescan suppression did not commit: %s", tostring(suppress_result))
		return false
	end
	if descriptor.generation ~= _chain_generation
		or get_chain_timer("fallback") ~= descriptor
		or descriptor.delivery_attempted == true
		or descriptor.delivered == true
		or descriptor.settled == true then
		rollback_arm("superseded chain fallback")
		return false
	end

	descriptor.authorized = true
	return true
end






--- =============================
--- =============================
--- ======= 6/ Public API =======
--- =============================
--- =============================

--- Installs the live action-epoch predicate used by timers, fetches and actions.
--- @param fn function|nil Zero-arity predicate.
function M.set_runtime_guard(fn)
	_runtime_guard = type(fn) == "function" and fn or function() return true end
end

--- Accepts recovery ownership after the current Ollama daemon exits.
--- The API module has already invalidated readiness before calling this method.
--- @return boolean committed True when recovery ran, parked or was superseded.
function M.on_ollama_daemon_exit()
	_ollama_daemon_recovery_generation = _ollama_daemon_recovery_generation + 1
	_ollama_daemon_recovery_pending = true
	_ollama_daemon_recovery_inflight = false
	if cancel_ollama_recovery_timer() ~= true then return false end
	if runtime_guard_available() ~= true then
		Logger.debug(LOG, "Ollama daemon recovery parked behind the runtime guard.")
		return true
	end
	return recover_ollama_daemon()
end


--- Initializes the engine by injecting the shared keymap core state.
--- Must be called exactly once before any other engine function in this module.
--- @param core_state table The shared state object from modules/keymap/init.lua.
--- @return boolean committed True only when every dependency is ready.
function M.init(core_state)
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): invalid core_state (expected table, got %s).", type(core_state))
		return false
	end
	if _state then
		if _state == core_state then
			Logger.warn(LOG, "M.init() called more than once with the active state — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.init(): a different state is already active — replacement refused.")
		return false
	end

	-- A parent may only publish this engine after every child reports an exact
	-- commitment. Children treat a duplicate with the same retained binding as
	-- success, so a retry can converge after a later child refused.
	if WarmupController.init({
		core_llm        = core_llm,
		get_llm_enabled = get_runtime_llm_enabled,
	}) ~= true then
		Logger.error(LOG, "M.init(): warmup-controller dependency initialization refused.")
		return false
	end
	if StreamingHandler.init({
		core_llm  = core_llm,
		tooltip   = tooltip,
		keylogger = keylogger,
	}) ~= true then
		Logger.error(LOG, "M.init(): streaming-handler dependency initialization refused.")
		return false
	end

	_state = core_state
	Logger.debug(LOG, "Prediction engine state injected (%d mapping(s)).", #(core_state.mappings or {}))
	return true
end

--- Public alias so the expander can re-arm the LLM timer after a text replacement.
--- Without this, the expander's _llm.start_timer() call would throw a nil-function error,
--- causing onKeyDown to return false instead of true, which lets the trigger character
--- through to the app — resulting in one extra character on screen before the expansion.
--- @param delay_override number|nil Optional timer override in seconds.
function M.start_timer(delay_override)
	if not runtime_available() then return false end
	return start_inactivity_timer(delay_override) == true
end

--- Arms the inactivity timer after a completed word (buffer ends with whitespace).
--- When instant_on_word_end is enabled, bypasses the debounce entirely (delay = 0)
--- so the prediction fires as soon as the word boundary is detected.
function M.start_timer_word_end()
	if not runtime_available() then return false end
	if instant_on_word_end then
		return start_inactivity_timer(0) == true
	else
		return start_inactivity_timer() == true
	end
end

--- Cancels the inactivity timer without firing the LLM check.
--- Also terminates any in-flight streaming task: the GPU should not keep generating
--- tokens for a request that is now stale. Without this, a new request queues behind
--- the old curl process and the perceived TTFT is (old generation remaining) + (new TTFT).
function M.stop_timer()
	local committed = true
	local timer_ok, timer_result = xpcall(stop_inactivity_timer, debug.traceback)
	if not timer_ok or timer_result ~= true then
		committed = false
		Logger.error(LOG, "Inactivity timer cancellation did not commit (result: %s).",
			tostring(timer_result))
	end
	local stream_ok, stream_result = xpcall(core_llm.cancel_streaming, debug.traceback)
	if not stream_ok or stream_result ~= true then
		committed = false
		Logger.error(LOG, "Active stream cancellation did not commit (result: %s).", tostring(stream_result))
	end
	return committed
end

--- Consumes the F16 chain signal if a chain is pending.
--- Called from the keymap bridge's keystroke handler before any other routing.
--- @param keyCode number The macOS key code of the pressed key.
--- @return boolean True if the F16 event was consumed and the chain was triggered.
function M.handle_chain_signal(keyCode)
	if not runtime_available() then return false end
	if keyCode ~= KEYCODE_LLM_CHAIN or not chain_pending then return false end
	local fallback = get_chain_timer("fallback")
	if type(fallback) ~= "table" or fallback.authorized ~= true
		or fallback.generation ~= _chain_generation then
		-- arm_chain publishes the logical intent before crossing its suppression
		-- boundary, but the F16 consumer may only replace a fully committed fallback.
		return false
	end
	-- Never run perform_check inline: this function is reached from the keymap
	-- CGEventTap callback (llm_bridge.handle_llm_keys), and perform_check calls
	-- AppFilter.is_blocked, which issues uncached cross-process Accessibility
	-- queries. Stalling the tap risks kCGEventTapDisabledByTimeout, which kills
	-- the keyboard until the tap is re-armed. Deferring by one run-loop tick makes
	-- this path structurally identical to the CHAIN_FALLBACK_SEC timer that calls
	-- the same function.
	if settle_chain_timer("dispatch", "prior chain dispatch") ~= true then
		return true
	end
	local generation = _chain_generation
	local descriptor, dispatch_committed = acquire_chain_timer("dispatch", 0, generation,
		function(continuation_guard)
			if runtime_available() then M.perform_check(true, nil, continuation_guard) end
		end)
	if dispatch_committed ~= true then
		Logger.error(LOG, "F16 dispatch deferral did not commit; fallback retained.")
		-- F16 is an internal owned signal. Consume it while the already-armed
		-- fallback remains the sole path to the chained request.
		return true
	end

	chain_pending = false
	if _chain_trigger_timer then
		if settle_chain_timer("fallback", "superseded chain fallback") ~= true then
			-- TimerScheduler fenced fallback business delivery before the native
			-- stop attempt. Keep its exact cleanup debt, but do not revoke the one
			-- committed dispatch or the chain would have no remaining business path.
			Logger.error(LOG, "Superseded chain fallback remains exact cleanup debt.")
		end
	end
	Logger.debug(LOG, "F16 received — chained LLM dispatch committed.")
	return true
end

--- @return boolean True while predictions are displayed and awaiting user interaction.
function M.is_visible() return runtime_available() and predictions_visible end

--- @return boolean True between an accepted prediction and the incoming F16 chain signal.
function M.is_chain_pending() return runtime_available() and chain_pending end

--- @return table The current pending predictions array.
function M.get_predictions()
	if not runtime_available() then return {} end
	return pending_predictions
end

--- @return number|nil The currently selected prediction index, or nil.
function M.get_current_index()
	if not runtime_available() then return nil end
	return tooltip.get_current_index()
end

--- Navigates the prediction selection by the given delta.
--- @param delta number Positive moves down the list, negative moves up.
function M.navigate(delta)
	if not runtime_available() then return false end
	return tooltip.navigate(delta)
end

--- Normalizes a modifier input (string or table) to a plain array of strings.
--- Exported so the keymap bridge can use it when routing modifier+key combos.
--- @param mod_input string|table
--- @return table
function M.normalize_mods(mod_input) return normalize_mods(mod_input) end

--- @return table Normalized navigation modifier array.
function M.get_navigation_mods() return normalize_mods(navigation_mods) end

--- @return table Normalized validation modifier array.
function M.get_validation_mods() return normalize_mods(validation_mods) end

-- Export constants needed by external callers
M.KEYCODE_LLM_CHAIN  = KEYCODE_LLM_CHAIN   -- Bridge uses this to detect the chain signal
M.CHAIN_FALLBACK_SEC = CHAIN_FALLBACK_SEC  -- Bridge passes this to suppress_rescan_keep_buffer


-- Enable Enter-to-accept only after the user has explicitly navigated at least once;
-- without this guard, pressing Enter on the very first shown prediction would type a newline.
tooltip.set_navigate_callback(function()
	tooltip.set_enter_validates(true)
	return true
end)

return M
