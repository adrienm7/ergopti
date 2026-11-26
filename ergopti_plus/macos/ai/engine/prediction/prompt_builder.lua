--- ai/engine/prediction/prompt_builder.lua

--- ==============================================================================
--- MODULE: LLM Prompt Builder (Hammerspoon shim)
--- DESCRIPTION:
--- Thin adapter over the shared pure-Lua implementation located at
--- ``_shared/ai/engine/prediction/prompt_builder_core.lua``. Delegates all deterministic
--- computation (token budget, temperature, context truncation, tail extraction)
--- to the shared module and adds only the Hammerspoon-specific concerns that
--- cannot live in the shared layer:
---
---   1. Freshness guard — skips requests when the buffer content did not change
---      since the last dispatched call (signature comparison).
---   2. Field-name mapping — translates the shared module's return keys
---      (context, context_tail, temperature) to the legacy keys consumed by
---      engine.lua (context_buffer, tail, req_temperature, num_preds).
---
--- FEATURES & RATIONALE:
--- 1. Zero duplication: all math lives in the shared module; this file is ~30 LOC.
--- 2. Backward compat: engine.lua is unchanged — it still calls
---    M.build(buffer, config, last_signature, force_trigger).
--- ==============================================================================

local M = {}

local Shared = require("ai.engine.prediction.prompt_builder_core")
local Utf8   = require("core.lifecycle.engine.compat.utf8")
local Logger = require("core.logger.engine.logger")

local LOG = "ai.engine.prediction.prompt_builder_core"




-- =============================================================================
-- =============================================================================
-- ======= 1/ Public API =======================================================
-- =============================================================================
-- =============================================================================

--- Builds all backend request parameters from the current buffer and configuration.
---
--- Wraps SharedPromptBuilder.build_params(), adding a freshness guard so callers
--- do not have to manage the signature themselves. Returns three values to
--- preserve the legacy contract expected by engine.lua.
---
--- @param buffer string The current tracked context buffer.
--- @param config table Must contain: temperature, max_words, min_words,
---        num_predictions, auto_raise_temperature. Optional: context_window_chars.
--- @param last_signature string|nil Signature of the last dispatched request.
--- @param force_trigger boolean When true, bypasses freshness and length guards.
--- @return table|nil params Built request params in HS field shape, or nil on skip.
--- @return string|nil skip_reason Human-readable skip reason, or nil on success.
--- @return string|nil signature Freshness signature for this request.
function M.build(buffer, config, last_signature, force_trigger)
	-- Delegate pure computation to the shared module
	local p = Shared.build_params(buffer, {
		max_words            = config.max_words,
		min_words            = config.min_words,
		num_predictions      = config.num_predictions,
		temperature          = config.temperature,
		auto_raise_temp      = config.auto_raise_temperature,
		language             = config.language,
		context_window_chars = config.context_window_chars,
	})

	local sig = buffer .. "\n" .. p.context_tail

	-- Freshness and length guards (HS-specific: shared module is stateless)
	if not force_trigger then
		if #p.context_tail == 0 then
			return nil, "empty buffer", nil
		end
		local tail_length = Utf8.len(p.context_tail)
		if tail_length == nil then return nil, "context is not valid UTF-8", nil end
		if tail_length < 2 then
			return nil, string.format("context too short (%d chars)", tail_length), nil
		end
		if last_signature == sig then
			return nil, "buffer unchanged (freshness)", nil
		end
		Logger.debug(LOG, "Request signature accepted.")
	else
		Logger.debug(LOG, "Force-trigger: freshness guard bypassed.")
	end

	-- Map shared fields to the legacy shape expected by engine.lua
	return {
		tail             = p.context_tail,
		context_buffer   = p.context,
		max_tokens       = p.max_tokens,
		req_temperature  = p.temperature,
		num_preds        = p.num_predictions,
	}, nil, sig
end

return M
