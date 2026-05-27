--- modules/llm/prompt_builder.lua

--- ==============================================================================
--- MODULE: LLM Prompt Builder (Hammerspoon shim)
--- DESCRIPTION:
--- Thin adapter over the shared pure-Lua implementation located at
--- ``shared/lua/llm/prompt_builder.lua``. Delegates all deterministic
--- computation (token budget, temperature, context truncation, tail extraction)
--- to the shared module and adds only the Hammerspoon-specific concerns that
--- cannot live in the shared layer:
---
---   1. Freshness guard — skips requests when the buffer content did not change
---      since the last dispatched call (signature comparison).
---   2. Field-name mapping — translates the shared module's return keys
---      (context, context_tail, temperature) to the legacy keys consumed by
---      prediction_engine.lua (context_buffer, tail, req_temperature, num_preds).
---
--- FEATURES & RATIONALE:
--- 1. Zero duplication: all math lives in the shared module; this file is ~30 LOC.
--- 2. Backward compat: prediction_engine.lua is unchanged — it still calls
---    M.build(buffer, config, last_signature, force_trigger).
--- ==============================================================================

local M = {}

local Shared = require("llm.prompt_builder")
local Logger = require("lib.logger")

local LOG = "llm.prompt_builder"




-- =============================================================================
-- =============================================================================
-- ======= 1/ Public API =======================================================
-- =============================================================================
-- =============================================================================

--- Builds all backend request parameters from the current buffer and configuration.
---
--- Wraps SharedPromptBuilder.build_params(), adding a freshness guard so callers
--- do not have to manage the signature themselves. Returns three values to
--- preserve the legacy contract expected by prediction_engine.lua.
---
--- @param buffer string The current tracked context buffer.
--- @param config table Must contain: temperature, max_words, min_words,
---        num_predictions, auto_raise_temperature.
--- @param last_signature string|nil Signature of the last dispatched request.
--- @param force_trigger boolean When true, bypasses freshness and length guards.
--- @return table|nil params Built request params in HS field shape, or nil on skip.
--- @return string|nil skip_reason Human-readable skip reason, or nil on success.
--- @return string|nil signature Freshness signature for this request.
function M.build(buffer, config, last_signature, force_trigger)
	-- Delegate pure computation to the shared module
	local p = Shared.build_params(buffer, {
		max_words           = config.max_words,
		min_words           = config.min_words,
		num_predictions     = config.num_predictions,
		temperature         = config.temperature,
		auto_raise_temp     = config.auto_raise_temperature,
		language            = config.language,
	})

	local sig = buffer .. "\n" .. p.context_tail

	-- Freshness and length guards (HS-specific: shared module is stateless)
	if not force_trigger then
		if #p.context_tail == 0 then
			return nil, "empty buffer", nil
		end
		if #p.context_tail < 2 then
			return nil, string.format("context too short (%d chars)", #p.context_tail), nil
		end
		if last_signature == sig then
			return nil, "buffer unchanged (freshness)", nil
		end
		Logger.debug(LOG, "Request signature accepted.")
	else
		Logger.debug(LOG, "Force-trigger: freshness guard bypassed.")
	end

	-- Map shared fields to the legacy shape expected by prediction_engine.lua
	return {
		tail             = p.context_tail,
		context_buffer   = p.context,
		max_tokens       = p.max_tokens,
		req_temperature  = p.temperature,
		num_preds        = p.num_predictions,
	}, nil, sig
end

return M
