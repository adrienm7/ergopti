--- modules/llm/warmup_controller.lua

--- ==============================================================================
--- MODULE: LLM Warmup Controller
--- DESCRIPTION:
--- Schedules and retries backend warmup requests until the model is confirmed
--- ready to serve inference. The first request to a cold backend (e.g. an MLX
--- server still loading weights) returns immediately without generating tokens;
--- this module re-primes with exponential backoff so the prediction engine can
--- start serving suggestions as soon as the model is loaded, without manual
--- intervention.
---
--- FEATURES & RATIONALE:
--- 1. Exponential backoff: retry interval doubles on each attempt (from
---    WARMUP_RETRY_BASE_SEC) up to WARMUP_RETRY_CAP_SEC, preventing busy-waiting
---    against a slow-loading backend while still converging quickly.
--- 2. Lazy model resolution: always calls core_llm.get_current_model() at attempt
---    time rather than capturing the name at schedule time, so a backend swap
---    mid-flight hits the correct model ID.
--- 3. Exact timer ownership: one generation-scoped scheduler handle is retained
---    until native cancellation commits, and cleanup debt blocks its successor.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local Timings        = require("infra.timings")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.warmup_controller"


-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Delay before the first warmup attempt fires after schedule_warmup is called.
-- A short delay gives the menu time to finish calling set_llm_model before the
-- warmup fires, so the resolved model name is always correct.
local WARMUP_INITIAL_DELAY_SEC = Timings.sec("llm", "warmup_initial_delay_ms")

-- Starting retry interval; doubles on each failed attempt up to WARMUP_RETRY_CAP_SEC.
-- A fast-loading backend (< 10 s) is caught within 1–2 attempts; a slow one
-- (30+ s) is polled progressively less aggressively rather than every 5 seconds.
local WARMUP_RETRY_BASE_SEC = Timings.sec("llm", "warmup_retry_base_ms")

-- Maximum retry interval — prevents the backoff from growing unbounded.
local WARMUP_RETRY_CAP_SEC  = Timings.sec("llm", "warmup_retry_cap_ms")


-- =====================================
-- =====================================
-- ======= 2/ Mutable State ============
-- =====================================
-- =====================================

-- Injected dependencies — set via M.init()
local _core_llm        = nil
local _get_llm_enabled = nil

-- Monotonic generation counter. Incremented each time a new retry chain is
-- started (or M.stop() is called). Closures capture their own my_gen and
-- bail out when they discover the global has moved on, ensuring at most one
-- live retry chain at any given time.
local _warmup_gen = 0

-- The exact one-shot capability remains owned until native cancellation is
-- proven; a fenced timer whose stop was refused is cleanup debt, not a free slot
local _warmup_timer = nil
local _warmup_settlement_observers = {}
-- ScriptControl may synchronously re-enter while native start/running or a
-- business callback is still on-stack.  These depths keep PAUSE from claiming
-- quiescence before the outer frame has either committed or rolled back.
local _warmup_acquisition_depth = 0
local _warmup_callback_depth = 0
-- Exact pre-pause scheduling intent. A quiescent controller must remain
-- quiescent after resume; a refused native cancellation retains this debt.
local _pause_resume_pending = false


-- =====================================
-- =====================================
-- ======= 3/ Private Helpers ==========
-- =====================================
-- =====================================

--- Guards public functions that require initialized dependencies.
--- @param func_name string Name of the calling function (for the error log).
--- @return boolean True if dependencies are ready, false otherwise.
local function require_state(func_name)
	if not _core_llm or not _get_llm_enabled then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end

--- Cancels the exact warmup timer without losing a refused native handle.
--- @param context string Operation requesting cancellation.
--- @return boolean settled True only when no native timer can remain.
local function cancel_warmup_timer(context, allow_callback_owner)
	if _warmup_acquisition_depth > 0
		or (_warmup_callback_depth > 0 and allow_callback_owner ~= true) then
		Logger.error(LOG, "%s: warmup ownership boundary is still in flight.", context)
		return false
	end
	if not _warmup_timer then return true end
	local owned = _warmup_timer
	local ok, result = xpcall(function()
		return TimerScheduler.cancel(owned)
	end, debug.traceback)
	if ok and result == true then
		-- stop()/running() may synchronously install a successor.  Proving the
		-- captured owner settled does not prove that successor settled too.
		if _warmup_timer ~= nil and _warmup_timer ~= owned then return false end
		if _warmup_timer == owned then _warmup_timer = nil end
		return true
	end
	Logger.error(LOG, "%s: warmup timer cleanup remains pending — %s.",
		context, tostring(result))
	return false
end

--- Keeps a business/settlement continuation visible to ScriptControl until its
--- complete Lua frame has unwound, including thrown dependency callbacks.
--- @param context string Callback label for diagnostics.
--- @param fn function Continuation.
local function run_warmup_callback(context, fn)
	_warmup_callback_depth = _warmup_callback_depth + 1
	local ok, err = xpcall(fn, debug.traceback)
	_warmup_callback_depth = _warmup_callback_depth - 1
	if not ok then
		Logger.error(LOG, "%s failed — %s.", context, tostring(err))
	end
end

--- Continues a retry chain after a fired timer's native stop eventually settles.
--- @param owned table Exact TimerScheduler handle.
--- @param my_gen integer Retry-chain generation.
--- @param continuation function Continuation to run after settlement.
--- @return boolean registered
local function observe_warmup_timer_settlement(owned, my_gen, continuation)
	if type(owned) ~= "table" or type(continuation) ~= "function" then return false end
	if _warmup_settlement_observers[owned] == true then return true end
	if type(TimerScheduler.onSettled) ~= "function" then return false end
	_warmup_settlement_observers[owned] = true
	local ok, registered_or_err = xpcall(function()
		return TimerScheduler.onSettled(owned, function()
			_warmup_settlement_observers[owned] = nil
			if _warmup_timer == owned then _warmup_timer = nil end
			run_warmup_callback("Warmup timer settlement continuation", function()
				if my_gen == _warmup_gen then continuation() end
			end)
		end)
	end, debug.traceback)
	if not ok or registered_or_err ~= true then
		_warmup_settlement_observers[owned] = nil
		Logger.error(LOG, "Warmup timer settlement observer failed â€” %s.",
			tostring(registered_or_err))
		return false
	end
	return true
end

--- Reads the live LLM enable gate without letting a dependency throw escape.
--- @param context string Operation reading the gate.
--- @return boolean|nil enabled Nil means the read failed.
local function read_llm_enabled(context)
	local ok, enabled = xpcall(_get_llm_enabled, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s: live LLM gate read failed — %s.", context, tostring(enabled))
		return nil
	end
	return enabled == true
end


-- ============================================
-- ============================================
-- ======= 4/ Warmup Scheduling ===============
-- ============================================
-- ============================================

--- Schedules a warmup attempt after a short delay and keeps retrying with
--- exponential backoff until the backend reports ready.
---
--- The first request often hits a server that is still loading model weights
--- (10–30 s for a 2B model) and returns -1; this retry loop keeps re-priming
--- until the model is actually loaded. The interval doubles after each attempt
--- (capped at WARMUP_RETRY_CAP_SEC) to avoid busy-waiting against a slow backend.
--- Model resolution is intentionally deferred to each attempt so a backend swap
--- mid-flight hits the correct model ID (e.g. "gemma-4-e2b-it-mxfp4" rather
--- than the display label "gemma-4-E2B-it").
---
--- @param reason string Human-readable label for the log entry (who triggered warmup).
--- @return boolean committed True for an intentional no-op or an owned timer.
function M.schedule_warmup_with_retry(reason)
	if not require_state("schedule_warmup_with_retry") then return false end
	local entry_gen = _warmup_gen
	local enabled = read_llm_enabled("schedule_warmup_with_retry")
	if entry_gen ~= _warmup_gen then return false end
	if enabled == nil then return false end
	if enabled ~= true then
		_warmup_gen = _warmup_gen + 1
		Logger.debug(LOG, "%s: warmup skipped — live LLM gate is disabled.", reason)
		return cancel_warmup_timer("disabled warmup schedule")
	end

	local resolved_ok, resolved = xpcall(_core_llm.get_current_model, debug.traceback)
	if entry_gen ~= _warmup_gen then return false end
	if not resolved_ok then
		Logger.error(LOG, "%s: backend model resolution failed — %s.", reason, tostring(resolved))
		return false
	end
	if type(resolved) ~= "string" or resolved == "" then
		Logger.debug(LOG, "%s: warmup skipped — backend model not resolved yet.", reason)
		return true
	end
	-- Bump the generation counter to cancel any in-flight retry chain from a
	-- previous call (e.g. a toggle or model switch that arrived before ready).
	_warmup_gen = _warmup_gen + 1
	local my_gen = _warmup_gen
	if cancel_warmup_timer("schedule_warmup_with_retry") ~= true then return false end
	Logger.debug(LOG, "Scheduling warmup for '%s' in %.0fs (from %s, gen=%d).",
		resolved, WARMUP_INITIAL_DELAY_SEC, reason, my_gen)

	local try_warmup

	--- Arms one exact attempt without acquiring a sibling over cleanup debt.
	--- @param delay number Delay before the attempt.
	--- @param current_interval number Retry interval passed to the attempt.
	--- @return boolean committed True only when the native timer was armed.
	local function arm_attempt(delay, current_interval)
		if my_gen ~= _warmup_gen then return false end
		if cancel_warmup_timer("warmup retry acquisition", true) ~= true then return false end

		local candidate
		local authorized = false
		local delivery_attempted = false
		_warmup_acquisition_depth = _warmup_acquisition_depth + 1
		local schedule_ok, handle_or_err, committed = xpcall(function()
			return TimerScheduler.after(delay, function()
				delivery_attempted = true
				if authorized ~= true or my_gen ~= _warmup_gen
					or _warmup_timer ~= candidate then return end
				run_warmup_callback("Warmup timer delivery", function()
					-- The adapter fences a fired one-shot before delivery, but the native
					-- stop may still refuse. Never acquire its successor over that debt.
					if cancel_warmup_timer("warmup timer completion", true) ~= true then
						observe_warmup_timer_settlement(candidate, my_gen, function()
							try_warmup(current_interval)
						end)
					else
						try_warmup(current_interval)
					end
				end)
			end)
		end, debug.traceback)
		_warmup_acquisition_depth = _warmup_acquisition_depth - 1
		candidate = handle_or_err
		local acquisition_current = my_gen == _warmup_gen and _warmup_timer == nil
		if type(candidate) == "table" and acquisition_current then
			_warmup_timer = candidate
		end

		if not schedule_ok or committed ~= true or type(candidate) ~= "table"
			or delivery_attempted == true or acquisition_current ~= true then
			if type(candidate) == "table" and _warmup_timer == nil then
				-- Retain the exact partial/stale candidate while its native rollback
				-- is attempted; refusal leaves it visible as the sole cleanup debt.
				_warmup_timer = candidate
			end
			if _warmup_timer == candidate then
				cancel_warmup_timer("warmup timer acquisition rollback")
			end
			Logger.error(LOG, "Warmup timer acquisition failed — %s.", tostring(handle_or_err))
			return false
		end
		authorized = true
		return true
	end

	try_warmup = function(current_interval)
		-- Stale chain — a newer schedule_warmup_with_retry or M.stop() arrived
		if my_gen ~= _warmup_gen then return end
		local still_enabled = read_llm_enabled("warmup retry")
		if my_gen ~= _warmup_gen then return end
		if still_enabled == nil then return end
		if still_enabled ~= true then
			Logger.debug(LOG, "[WARMUP-LOOP] LLM disabled — stopping retry chain.")
			return
		end
		if _core_llm.is_backend_ready and _core_llm.is_backend_ready() then
			Logger.debug(LOG, "[WARMUP-LOOP] Backend ready — stopping retry chain.")
			return
		end
		if my_gen ~= _warmup_gen then return end
		-- A failed load is a permanent terminal state; retrying would be pointless
		-- and would produce an infinite timer chain that never resolves
		if _core_llm.is_backend_load_failed and _core_llm.is_backend_load_failed() then
			Logger.debug(LOG, "[WARMUP-LOOP] Backend load failed — stopping retry chain.")
			return
		end
		if my_gen ~= _warmup_gen then return end
		local model_ok, current = xpcall(_core_llm.get_current_model, debug.traceback)
		if my_gen ~= _warmup_gen then return end
		if not model_ok then
			Logger.error(LOG, "[WARMUP-LOOP] Model resolution failed — %s.", tostring(current))
			return
		end
		-- Compute next interval before the attempt so it is available in all branches.
		local next_interval = math.min(current_interval * 2, WARMUP_RETRY_CAP_SEC)
		if type(current) ~= "string" or current == "" then
			-- Model momentarily missing during a backend swap — keep the chain alive.
			Logger.debug(LOG, "[WARMUP-LOOP] Model not resolved yet — retrying in %.0fs.", next_interval)
			arm_attempt(next_interval, next_interval)
			return
		end
		local backend_ok, backend = xpcall(_core_llm.get_backend, debug.traceback)
		if my_gen ~= _warmup_gen then return end
		if not backend_ok then backend = "unknown" end
		Logger.debug(LOG, "[WARMUP-LOOP] Warmup attempt for '%s' (backend: %s, next retry: %.0fs).",
			current, tostring(backend), next_interval)
		local profile_ok, profile = xpcall(_core_llm.get_active_profile, debug.traceback)
		if my_gen ~= _warmup_gen then return end
		if not profile_ok then
			Logger.error(LOG, "[WARMUP-LOOP] Active profile resolution failed — %s.", tostring(profile))
			return
		end
		local warmup_ok, warmup_err = xpcall(function()
			_core_llm.warmup_model(current, profile)
		end, debug.traceback)
		if my_gen ~= _warmup_gen then return end
		if not warmup_ok then
			Logger.error(LOG, "[WARMUP-LOOP] Warmup attempt failed — %s.", tostring(warmup_err))
		end
		arm_attempt(next_interval, next_interval)
	end
	return arm_attempt(WARMUP_INITIAL_DELAY_SEC, WARMUP_RETRY_BASE_SEC)
end


-- ============================================
-- ============================================
-- ======= 5/ Module Lifecycle ================
-- ============================================
-- ============================================

--- Cancels the currently active retry chain, if any.
--- Safe to call before M.init() or when no chain is running.
--- @return boolean settled True only when no native warmup timer can remain.
function M.stop()
	_warmup_gen = _warmup_gen + 1
	Logger.debug(LOG, "Warmup retry chain cancelled (gen bumped to %d).", _warmup_gen)
	return cancel_warmup_timer("M.stop")
end

--- Quiesces the retry controller while snapshotting only an actually-owned timer.
--- @return boolean settled
function M.pause_warmup()
	if _pause_resume_pending ~= true then
		_pause_resume_pending = _warmup_timer ~= nil
			or _warmup_acquisition_depth > 0
			or _warmup_callback_depth > 0
	end
	return M.stop()
end

--- Restores the retry intent captured by pause_warmup exactly once.
--- @return boolean committed
function M.resume_warmup()
	if _pause_resume_pending ~= true then return true end
	if M.schedule_warmup_with_retry("script-control resume") ~= true then return false end
	_pause_resume_pending = false
	return true
end

--- Initializes the warmup controller with its required dependencies.
--- Must be called exactly once before schedule_warmup_with_retry.
--- @param deps table Must contain: core_llm (table), get_llm_enabled (function).
--- @return boolean committed True only when every dependency is ready.
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table" then
		Logger.error(LOG, "M.init(): deps must be a table — module non-functional.")
		return false
	end
	if _core_llm then
		if _core_llm == deps.core_llm and _get_llm_enabled == deps.get_llm_enabled then
			Logger.warn(LOG, "M.init() called more than once with the active dependencies — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.init(): different dependencies are already active — replacement refused.")
		return false
	end
	if type(deps.core_llm) ~= "table" then
		Logger.error(LOG, "M.init(): deps.core_llm must be a table — module non-functional.")
		return false
	end
	if type(deps.get_llm_enabled) ~= "function" then
		Logger.error(LOG, "M.init(): deps.get_llm_enabled must be a function — module non-functional.")
		return false
	end
	_core_llm        = deps.core_llm
	_get_llm_enabled = deps.get_llm_enabled
	Logger.success(LOG, "Initialized.")
	return true
end

return M
