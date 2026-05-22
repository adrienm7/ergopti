--- modules/llm/prompt_builder.lua

--- ==============================================================================
--- MODULE: LLM Prompt Builder
--- DESCRIPTION:
--- Pure domain module that derives all backend request parameters from the
--- current buffer state and user configuration. No Hammerspoon API calls; every
--- function is deterministic given its inputs so it can be unit-tested in
--- isolation without a running Hammerspoon environment.
---
--- FEATURES & RATIONALE:
--- 1. Token budget: computes max_tokens from the max_words setting using a
---    conservative words-to-tokens ratio plus a fixed overhead, with a hard floor
---    so very short predictions still get a meaningful budget.
--- 2. Adaptive temperature: optionally raises temperature per extra prediction to
---    encourage diversity, then snaps to 0 for single-prediction greedy decoding.
--- 3. Context truncation: limits the context forwarded to the LLM proportionally
---    to the predicted output length so prefill tokens (and TTFT) scale with need.
--- 4. Tail extraction: extracts the last N words as a rolling context tail used
---    for change-detection (freshness guard) and as the backend's reference window.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "llm.prompt_builder"


-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Words from buffer tail forwarded as rolling LLM context
local CONTEXT_TAIL_WORDS = 5

-- Token budget formula: max_tokens = max(MIN_MAX_TOKENS, effective_max_words * RATIO + OVERHEAD)
local DEFAULT_MAX_TOKENS    = 150  -- Token budget when max_words is uncapped (= 0)
local MIN_MAX_TOKENS        = 15   -- Hard floor on the token budget regardless of word settings
local WORDS_TO_TOKENS_RATIO = 6    -- Conservative words-to-tokens multiplier for budget estimation
local TOKEN_BUDGET_OVERHEAD = 10   -- Fixed overhead appended to the computed token budget

-- Upper bound when auto_raise_temperature is active
local TEMP_DIVERSITY_CAP = 1.0

-- Temperature step per extra prediction requested (+0.1 each)
local TEMP_INCREMENT_PER_PRED = 0.1

-- Greedy threshold: if num_predictions == 1 and temperature is at or below this value,
-- force temperature to 0 (pure greedy). Avoids sampling noise with no diversity benefit.
local GREEDY_TEMP_THRESHOLD = 0.15

-- Dynamic context cap: limit the context forwarded to the LLM proportionally to the
-- max prediction length. Short predictions don't need 500 chars of history; reducing
-- the context shrinks the prefill token count and cuts TTFT proportionally.
local CONTEXT_CHARS_PER_WORD = 40   -- Chars of context allocated per predicted output word
local CONTEXT_MIN_CHARS      = 100  -- Hard floor: always keep at least this many chars






--- =============================================
--- ======= 2/ Request Parameter Building =======
--- =============================================

--- Extracts the tail context (last CONTEXT_TAIL_WORDS words) from the buffer.
--- Returns both the word list and the concatenated tail string for use in the
--- freshness guard and as the backend's reference window.
--- @param buffer string The current tracked context buffer.
--- @return table words Ordered list of whitespace-delimited token strings.
--- @return string tail Concatenated last-N words string.
local function extract_tail(buffer)
	local words = {}
	for w in buffer:gmatch("%S+%s*") do table.insert(words, w) end
	local tail = table.concat(words, "", math.max(1, #words - (CONTEXT_TAIL_WORDS - 1)))
	return words, tail
end

--- Computes the token budget for a request given the max_words setting.
--- Returns DEFAULT_MAX_TOKENS when max_words is 0 (unlimited), otherwise
--- applies the words-to-tokens ratio with a fixed overhead and hard floor.
--- @param max_words number Maximum predicted words (0 = unlimited).
--- @param min_words number Minimum predicted words (floor applied to effective_max).
--- @return number max_tokens The computed token budget.
local function compute_max_tokens(max_words, min_words)
	local effective_max = (max_words > 0 and max_words < min_words) and min_words or max_words
	if effective_max <= 0 then return DEFAULT_MAX_TOKENS end
	return math.max(MIN_MAX_TOKENS, math.floor(effective_max * WORDS_TO_TOKENS_RATIO + TOKEN_BUDGET_OVERHEAD))
end

--- Computes the effective temperature for a request, optionally raised for
--- multi-prediction diversity or snapped to 0 for single-prediction greedy decoding.
--- @param base_temp number The user-configured base temperature.
--- @param num_preds number Number of predictions requested.
--- @param auto_raise boolean Whether to auto-raise temperature for diversity.
--- @return number req_temperature The effective temperature to send to the backend.
local function compute_temperature(base_temp, num_preds, auto_raise)
	local req_temperature = base_temp

	-- Optionally add +TEMP_INCREMENT_PER_PRED per extra prediction to encourage diversity.
	-- Example: 3 predictions -> +0.2 ; 5 predictions -> +0.4
	if auto_raise and num_preds > 1 then
		local increment = (num_preds - 1) * TEMP_INCREMENT_PER_PRED
		req_temperature = math.min(req_temperature + increment, TEMP_DIVERSITY_CAP)
		Logger.debug(LOG, "Temperature raised to %.2f for %d predictions.", req_temperature, num_preds)
	end

	-- Greedy decoding for single prediction: with only one variant requested, sampling
	-- adds noise without any diversity benefit — forcing temp=0 enables deterministic
	-- greedy decoding and avoids the softmax+sample step on the backend
	if num_preds == 1 and not auto_raise and req_temperature <= GREEDY_TEMP_THRESHOLD then
		req_temperature = 0
		Logger.debug(LOG, "Single prediction: greedy decoding applied (temp -> 0).")
	end

	return req_temperature
end

--- Applies the dynamic context cap to the buffer, keeping only as many
--- trailing characters as needed for the requested output length.
--- @param buffer string The full context buffer.
--- @param max_words number Max predicted words (0 = unlimited, use full buffer).
--- @return string context_buffer The (possibly truncated) context to send.
local function cap_context(buffer, max_words)
	if max_words <= 0 then return buffer end
	local effective_context_chars = math.min(
		#buffer,
		math.max(CONTEXT_MIN_CHARS, max_words * CONTEXT_CHARS_PER_WORD)
	)
	return buffer:sub(-effective_context_chars)
end


-- =============================================
-- =============================================
-- ======= 3/ Public API =======================
-- =============================================
-- =============================================

--- Builds all backend request parameters from the current buffer and configuration.
---
--- Returns a params table used by perform_check to fire the async LLM call,
--- or nil with a reason string when a precondition is not met (empty buffer,
--- context too short, unchanged input).
---
--- @param buffer string The current tracked context buffer.
--- @param config table Must contain: temperature, max_words, min_words, num_predictions, auto_raise_temperature.
--- @param last_signature string|nil The signature of the last dispatched request.
--- @param force_trigger boolean When true, bypasses freshness and word-count guards.
--- @return table|nil params Built request params, or nil on skip.
--- @return string|nil skip_reason Human-readable skip reason, or nil on success.
--- @return string|nil signature The freshness signature for this request.
function M.build(buffer, config, last_signature, force_trigger)
	local words, tail = extract_tail(buffer)

	if #words == 0 and not force_trigger then
		return nil, "empty buffer", nil
	end

	if #tail < 2 and not force_trigger then
		return nil, string.format("context too short (%d chars)", #tail), nil
	end

	local signature = buffer .. "\n" .. tail
	if not force_trigger and last_signature == signature then
		return nil, "buffer unchanged (freshness)", nil
	end

	local max_words   = config.max_words   or 0
	local min_words   = config.min_words   or 0
	local num_preds   = config.num_predictions
	local auto_raise  = config.auto_raise_temperature

	local max_tokens      = compute_max_tokens(max_words, min_words)
	local req_temperature = compute_temperature(config.temperature, num_preds, auto_raise)
	local context_buffer  = cap_context(buffer, max_words)

	return {
		tail             = tail,
		context_buffer   = context_buffer,
		max_tokens       = max_tokens,
		req_temperature  = req_temperature,
		num_preds        = num_preds,
	}, nil, signature
end

return M
