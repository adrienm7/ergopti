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
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "llm.warmup_controller"


-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Delay before the first warmup attempt fires after schedule_warmup is called.
-- A short delay gives the menu time to finish calling set_llm_model before the
-- warmup fires, so the resolved model name is always correct.
local WARMUP_INITIAL_DELAY_SEC = 2

-- Starting retry interval; doubles on each failed attempt up to WARMUP_RETRY_CAP_SEC.
-- A fast-loading backend (< 10 s) is caught within 1–2 attempts; a slow one
-- (30+ s) is polled progressively less aggressively rather than every 5 seconds.
local WARMUP_RETRY_BASE_SEC = 5

-- Maximum retry interval — prevents the backoff from growing unbounded.
local WARMUP_RETRY_CAP_SEC  = 60


-- =====================================
-- =====================================
-- ======= 2/ Mutable State ============
-- =====================================
-- =====================================

-- Injected dependencies — set via M.init()
local _core_llm        = nil
local _get_llm_enabled = nil


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
function M.schedule_warmup_with_retry(reason)
	if not require_state("schedule_warmup_with_retry") then return end

	local resolved = _core_llm.get_current_model()
	if type(resolved) ~= "string" or resolved == "" then
		Logger.debug(LOG, "%s: warmup skipped — backend model not resolved yet.", reason)
		return
	end
	Logger.debug(LOG, "Scheduling warmup for '%s' in %.0fs (from %s).",
		resolved, WARMUP_INITIAL_DELAY_SEC, reason)

	local function try_warmup(current_interval)
		if not _get_llm_enabled() then
			Logger.debug(LOG, "[WARMUP-LOOP] LLM disabled — stopping retry chain.")
			return
		end
		if _core_llm.is_backend_ready and _core_llm.is_backend_ready() then
			Logger.debug(LOG, "[WARMUP-LOOP] Backend ready — stopping retry chain.")
			return
		end
		local current = _core_llm.get_current_model()
		-- Compute next interval before the attempt so it is available in all branches.
		local next_interval = math.min(current_interval * 2, WARMUP_RETRY_CAP_SEC)
		if type(current) ~= "string" or current == "" then
			-- Model momentarily missing during a backend swap — keep the chain alive.
			Logger.debug(LOG, "[WARMUP-LOOP] Model not resolved yet — retrying in %.0fs.", next_interval)
			hs.timer.doAfter(next_interval, function() try_warmup(next_interval) end)
			return
		end
		Logger.debug(LOG, "[WARMUP-LOOP] Warmup attempt for '%s' (backend: %s, next retry: %.0fs).",
			current, tostring(_core_llm.get_backend()), next_interval)
		pcall(_core_llm.warmup_model, current, _core_llm.get_active_profile())
		hs.timer.doAfter(next_interval, function() try_warmup(next_interval) end)
	end
	hs.timer.doAfter(WARMUP_INITIAL_DELAY_SEC, function() try_warmup(WARMUP_RETRY_BASE_SEC) end)
end


-- ============================================
-- ============================================
-- ======= 5/ Module Lifecycle ================
-- ============================================
-- ============================================

--- Initializes the warmup controller with its required dependencies.
--- Must be called exactly once before schedule_warmup_with_retry.
--- @param deps table Must contain: core_llm (table), get_llm_enabled (function).
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table" then
		Logger.error(LOG, "M.init(): deps must be a table — module non-functional.")
		return
	end
	if _core_llm then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	if type(deps.core_llm) ~= "table" then
		Logger.error(LOG, "M.init(): deps.core_llm must be a table — module non-functional.")
		return
	end
	if type(deps.get_llm_enabled) ~= "function" then
		Logger.error(LOG, "M.init(): deps.get_llm_enabled must be a function — module non-functional.")
		return
	end
	_core_llm        = deps.core_llm
	_get_llm_enabled = deps.get_llm_enabled
	Logger.success(LOG, "Initialized.")
end

return M
