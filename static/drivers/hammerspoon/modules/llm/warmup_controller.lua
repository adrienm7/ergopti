--- modules/llm/warmup_controller.lua

--- ==============================================================================
--- MODULE: LLM Warmup Controller
--- DESCRIPTION:
--- Schedules and retries backend warmup requests until the model is confirmed
--- ready to serve inference. The first request to a cold backend (e.g. an MLX
--- server still loading weights) returns immediately without generating tokens;
--- this module re-primes on a fixed interval so the prediction engine can start
--- serving suggestions as soon as the model is loaded, without manual intervention.
---
--- FEATURES & RATIONALE:
--- 1. Retry loop: re-schedules itself every WARMUP_RETRY_SEC until the backend
---    reports ready, so a 20-second model load does not silently strand the user.
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

-- Gap between retry attempts when the backend is still loading weights.
local WARMUP_RETRY_SEC = 5


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

--- Schedules a warmup attempt after a short delay and keeps retrying every
--- WARMUP_RETRY_SEC seconds until the backend reports ready.
---
--- The first request often hits a server that is still loading model weights
--- (10-30 s for a 2B model) and returns -1; this retry loop keeps re-priming
--- until the model is actually loaded. Model resolution is intentionally deferred
--- to each attempt so a backend swap mid-flight hits the correct model ID
--- (e.g. "gemma-4-e2b-it-mxfp4" rather than the display label "gemma-4-E2B-it").
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

	local function try_warmup()
		if not _get_llm_enabled() then
			Logger.warn(LOG, "[WARMUP-LOOP] try_warmup early-return: is_llm_enabled=false — chain ends here.")
			return
		end
		if _core_llm.is_backend_ready and _core_llm.is_backend_ready() then
			Logger.warn(LOG, "[WARMUP-LOOP] try_warmup early-return: backend already ready — chain ends here.")
			return
		end
		local current = _core_llm.get_current_model()
		if type(current) ~= "string" or current == "" then
			Logger.warn(LOG, "[WARMUP-LOOP] try_warmup early-return: get_current_model returned %s — re-scheduling in %ds.",
				tostring(current), WARMUP_RETRY_SEC)
			-- Do NOT terminate the retry chain when the model is momentarily missing
			-- (typical during a backend swap). Re-schedule so warmup eventually picks
			-- up once set_llm_model has run.
			hs.timer.doAfter(WARMUP_RETRY_SEC, try_warmup)
			return
		end
		Logger.warn(LOG, "[WARMUP-LOOP] Warmup attempt for '%s' (backend: %s).",
			current, tostring(_core_llm.get_backend()))
		pcall(_core_llm.warmup_model, current, _core_llm.get_active_profile())
		hs.timer.doAfter(WARMUP_RETRY_SEC, try_warmup)
	end
	hs.timer.doAfter(WARMUP_INITIAL_DELAY_SEC, try_warmup)
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
