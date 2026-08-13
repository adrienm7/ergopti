--- modules/llm/api_mlx_fetch.lua

--- ==============================================================================
--- MODULE: LLM API Fetch Strategies (Apple MLX)
--- DESCRIPTION:
--- The dispatch layer of the MLX controller: turns a single prediction request
--- into the right number of HTTP inferences and aggregates the results. It owns
--- the "how many requests, in what order, with what retry policy" strategy; the
--- request/response mechanics (post_and_parse / post_and_parse_streaming) live in
--- api_mlx_inference.lua and are injected here through M.init().
---
--- FEATURES & RATIONALE:
--- 1. batch / parallel / sequential strategies share one public signature so the
---    prediction engine can swap them without caring about the dispatch shape.
--- 2. State-free: every cross-cutting dependency (the post functions, the dedup
---    flag) is injected through M.init(), so this module owns no MLX state of its
---    own and re-declares no default — the single source of truth is the request
---    engine in api_mlx_inference.lua.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local ApiCommon      = require("modules.llm.api_common")
local Profiles       = require("modules.llm.profiles")
local TimerScheduler = require("adapters.timer_scheduler")
local ProgressiveReveal = require("modules.llm.progressive_reveal")
-- MLX log channel; every MLX line lands in ErgoptiPlus_mlx.log.
local LOG            = "llm.api_mlx"

-- Retry policy comes from _shared/modules/llm/inference.json (see api_common.lua),
-- read from the canonical source so the fan-out retry budget is never hardcoded
-- or duplicated.
local _RETRY_MAX_MULT, _RETRY_TEMP_STEP, _RETRY_EXTRA_TOKENS = ApiCommon.get_retry_policy()
local RETRY_FAILED_PREDICTION_ENABLED        = (_RETRY_MAX_MULT or 0) > 1
local RETRY_FAILED_PREDICTION_MAX_MULTIPLIER = _RETRY_MAX_MULT

-- Request mechanics injected by api_mlx through M.init(); nil until then.
local _post_and_parse           = nil
local _post_and_parse_streaming = nil
local _dedup_enabled            = false

--- Guard: every public fetch entry point depends on the injected post functions.
--- Logs an ERROR and bails when called before M.init() so a wiring regression is
--- loud instead of a nil-call crash deep inside a callback.
--- @param func_name string The caller, for the log line.
--- @return boolean True when the injected mechanics are available.
local function require_ctx(func_name)
	if not _post_and_parse or not _post_and_parse_streaming then
		Logger.error(LOG, "'%s' called before ApiMlxFetch.init() — request mechanics not injected.", func_name)
		return false
	end
	return true
end

--- Injects the request-mechanics functions and config owned by api_mlx.
--- @param ctx table { post_and_parse, post_and_parse_streaming, dedup_enabled }.
function M.init(ctx)
	if type(ctx) ~= "table" then
		Logger.error(LOG, "ApiMlxFetch.init(): ctx must be a table — module non-functional.")
		return
	end
	_post_and_parse           = ctx.post_and_parse
	_post_and_parse_streaming = ctx.post_and_parse_streaming
	_dedup_enabled            = ctx.dedup_enabled and true or false
	Logger.debug(LOG, "ApiMlxFetch initialized (dedup=%s).", tostring(_dedup_enabled))
end





--- ===================================
--- ===================================
--- ======= 1/ Fetch Strategies =======
--- ===================================
--- ===================================

--- Dispatches a single API request asking for N clustered predictions.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming (controlled by init.lua).
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_batch(full_text, tail_text, model_name, temperature,
                       max_predict, num_predictions, profile,
                       on_success, on_fail, request_id_provider, streaming, on_partial)
	if not require_ctx("fetch_batch") then
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	local effective_temp = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE
	local system_prompt  = Profiles.resolve_system_prompt(profile, num_predictions)
	local tokens         = tonumber(max_predict) * num_predictions + (num_predictions * 5)
	local is_batch       = profile.batch
	local dedup_stats    = ApiCommon.new_dedup_stats()
	local post_fn        = streaming and _post_and_parse_streaming or _post_and_parse
	local initial_request_id = type(request_id_provider) == "function" and request_id_provider() or nil
	local function request_is_current()
		return type(request_id_provider) ~= "function"
			or initial_request_id == nil
			or request_id_provider() == initial_request_id
	end

	local t0 = TimerScheduler.now()
	post_fn(model_name, system_prompt, full_text, tail_text,
		effective_temp, tokens, num_predictions, is_batch,
		function(results)
			if not request_is_current() then return end
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			ApiCommon.log_prediction_summary(Logger, LOG, "batch", num_predictions, dedup_stats, #results)
			-- With streaming OFF: reveal each prediction one by one (complete, no animation) so
			-- the user sees slot 1 fill, then slot 2, etc. rather than all appearing at once.
			-- Each doAfter(0) yields to the event loop so the tooltip renders between reveals.
			-- With streaming ON: on_partial_cb already showed each pred token by token;
			-- emit the final call directly to replace stream placeholders with diff colors.
			if not streaming and #results > 1 then
				ProgressiveReveal.deliver(results, on_success, ms, request_is_current)
			else
				if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, true) end
			end
		end,
		on_fail,
		dedup_stats,
		streaming and on_partial or nil)
end

--- Dispatches multiple parallel API requests incrementing the temperature to aggregate predictions.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_parallel(full_text, tail_text, model_name, temperature,
                          max_predict, num_predictions, profile,
                          on_success, on_fail, request_id_provider, streaming, on_partial)
	-- MLX can produce unstable outputs under parallel fan-out with some models
	-- Force sequential dispatch for reliability while keeping the same public API
	return M.fetch_sequential(full_text, tail_text, model_name, temperature,
		max_predict, num_predictions, profile,
		on_success, on_fail, request_id_provider, streaming, on_partial)
end

--- Dispatches multiple sequential API requests to avoid parallel connection dropping.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_sequential(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail, request_id_provider, streaming, on_partial)
	if not require_ctx("fetch_sequential") then
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	local system_prompt = Profiles.resolve_system_prompt(profile, 1)
	local t0            = TimerScheduler.now()
	local results       = {}
	local base_temp     = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE
	local requested_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local max_attempts = requested_predictions
	if RETRY_FAILED_PREDICTION_ENABLED == true then
		max_attempts = math.max(requested_predictions, requested_predictions * math.max(1, math.floor(tonumber(RETRY_FAILED_PREDICTION_MAX_MULTIPLIER))))
	end
	local attempt_index = 1
	local dedup_stats   = ApiCommon.new_dedup_stats()
	local initial_request_id = type(request_id_provider) == "function" and request_id_provider() or nil

	local function do_next()
		-- Check if this request batch was cancelled dynamically
		if type(request_id_provider) == "function" then
			local current_request_id = request_id_provider()
			if initial_request_id ~= nil and current_request_id ~= initial_request_id then
				Logger.debug(LOG, "Request batch cancelled: ID changed from %s to %s at step %d/%d",
					tostring(initial_request_id), tostring(current_request_id), attempt_index, max_attempts)
				return
			end
		end

		if #results >= requested_predictions or attempt_index > max_attempts then
			if #results == 0 then if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end return end
			ApiCommon.log_prediction_summary(Logger, LOG, "sequential", requested_predictions, dedup_stats, #results)
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, true) end
			return
		end

		local variant_index  = attempt_index
		attempt_index        = attempt_index + 1
		local variant_temp   = ApiCommon.get_diversity_temperature(base_temp, variant_index, 0.30)
		local primary_tokens = tonumber(max_predict)
		-- Each variant streams its tokens via on_partial so the tooltip shows each
		-- prediction building in its own slot; prediction_engine.lua keeps the cursor
		-- at slot 1 (or wherever the user navigated) regardless of which slot streams
		local variant_partial = on_partial

		local function request_variant(attempt, tokens, temp)
			local post_fn = streaming and _post_and_parse_streaming or _post_and_parse
			post_fn(model_name, system_prompt, full_text, tail_text,
				temp, tokens, 1, false,
				function(preds)
					if type(preds) == "table" and type(preds[1]) == "table" then
						if #results < requested_predictions then
							ApiCommon.insert_prediction(results, preds[1], dedup_stats, _dedup_enabled, Logger, LOG)
							local ms = math.floor((TimerScheduler.now() - t0) * 1000)
							if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, false) end
						end
					end
					do_next()
				end,
				function()
					if attempt < 2 then
						-- Same retry policy as api_ollama and api_remote: the step and the
						-- extra-token budget come from the shared inference manifest rather
						-- than from literals here, and the ceiling matches theirs. The old
						-- hardcoded 0.60 cap meant a profile configured above it could never
						-- raise temperature on a retry at all, so the retry re-sent an
						-- effectively identical request and failed the same way.
						local retry_tokens = tokens + _RETRY_EXTRA_TOKENS
						local retry_temp   = math.min(1.30, (tonumber(temp) or ApiCommon.DEFAULT_TEMPERATURE) + _RETRY_TEMP_STEP)
						Logger.debug(LOG, "[%s] Variant %d/%d quick chat retry: tokens=%d temp=%.2f",
							model_name, variant_index, max_attempts, retry_tokens, retry_temp)
						-- Retry does not stream partial updates (would overwrite the growing preview)
						request_variant(attempt + 1, retry_tokens, retry_temp)
						return
					end
					do_next()
				end,
				dedup_stats,
				streaming and variant_partial or nil)
		end

		request_variant(1, primary_tokens, variant_temp)
	end

	do_next()
end

return M
