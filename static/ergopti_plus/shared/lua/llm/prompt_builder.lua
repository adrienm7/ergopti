--- shared/lua/llm/prompt_builder.lua

--- ==============================================================================
--- MODULE: PromptBuilder — Shared Lua Implementation
--- DESCRIPTION:
--- Canonical Lua implementation of the LLM request parameter builder, shared
--- between the Hammerspoon driver and any future Lua-based driver (Linux, etc.).
--- Derives all backend request parameters from the current buffer and a
--- configuration object. No OS calls; fully deterministic and unit-testable.
---
--- This module is the Lua counterpart of shared/domain/PromptBuilder.js.
--- All constants and algorithms MUST stay in sync with the JS reference.
---
--- CONSTANTS (canonical — all drivers MUST use these exact values):
---   CONTEXT_TAIL_WORDS      = 5
---   DEFAULT_MAX_TOKENS      = 150
---   MIN_MAX_TOKENS          = 15
---   WORDS_TO_TOKENS_RATIO   = 6
---   TOKEN_BUDGET_OVERHEAD   = 10
---   TEMP_DIVERSITY_CAP      = 1.0
---   TEMP_INCREMENT_PER_PRED = 0.1
---   GREEDY_TEMP_THRESHOLD   = 0.15
---   CONTEXT_CHARS_PER_WORD  = 40
---   CONTEXT_MIN_CHARS       = 100
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Number of words from the buffer tail kept as rolling context window
M.CONTEXT_TAIL_WORDS = 5

-- Token budget when max_words is uncapped (= 0)
M.DEFAULT_MAX_TOKENS = 150

-- Hard floor on the token budget regardless of word settings
M.MIN_MAX_TOKENS = 15

-- Conservative words-to-tokens multiplier for token budget estimation
M.WORDS_TO_TOKENS_RATIO = 6

-- Fixed overhead appended to the computed token budget
M.TOKEN_BUDGET_OVERHEAD = 10

-- Upper bound when auto_raise_temperature is active
M.TEMP_DIVERSITY_CAP = 1.0

-- Temperature step per extra prediction requested beyond 1
M.TEMP_INCREMENT_PER_PRED = 0.1

-- Greedy threshold: snap temperature to 0 when single prediction and temp <= this
M.GREEDY_TEMP_THRESHOLD = 0.15

-- Chars of context allocated per predicted output word
M.CONTEXT_CHARS_PER_WORD = 40

-- Hard floor: always forward at least this many context characters
M.CONTEXT_MIN_CHARS = 100




-- =============================================
-- =============================================
-- ======= 2/ Internal Helpers =================
-- =============================================
-- =============================================

--- Extracts the last CONTEXT_TAIL_WORDS words from the buffer.
--- Returns both the ordered word list and the concatenated tail string.
--- @param buffer string The current typing buffer.
--- @return table words Ordered list of whitespace-delimited tokens.
--- @return string tail Concatenated last-N-words string.
local function extract_tail(buffer)
	if not buffer or buffer:match("^%s*$") then
		return {}, ""
	end
	local words = {}
	for w in buffer:gmatch("%S+") do
		table.insert(words, w)
	end
	local start = math.max(1, #words - M.CONTEXT_TAIL_WORDS + 1)
	local tail_words = {}
	for i = start, #words do
		table.insert(tail_words, words[i])
	end
	return words, table.concat(tail_words, " ")
end

--- Computes the token budget from the max_words setting.
--- Returns DEFAULT_MAX_TOKENS when max_words is 0 (unlimited).
--- @param max_words number Maximum predicted words (0 = unlimited).
--- @return number max_tokens The computed token budget.
local function compute_max_tokens(max_words)
	if not max_words or max_words <= 0 then
		return M.DEFAULT_MAX_TOKENS
	end
	return math.max(M.MIN_MAX_TOKENS, max_words * M.WORDS_TO_TOKENS_RATIO + M.TOKEN_BUDGET_OVERHEAD)
end

--- Computes the effective temperature for a request.
--- Optionally raises temperature per extra prediction for diversity,
--- then snaps to 0 for single-prediction greedy decoding.
--- @param base_temperature number User-configured base temperature.
--- @param num_predictions number Number of predictions requested (1+).
--- @param auto_raise boolean True = raise temperature for diversity.
--- @return number The effective temperature to send to the backend.
local function compute_temperature(base_temperature, num_predictions, auto_raise)
	local t = base_temperature

	if auto_raise and num_predictions > 1 then
		t = math.min(
			M.TEMP_DIVERSITY_CAP,
			t + M.TEMP_INCREMENT_PER_PRED * (num_predictions - 1)
		)
	end

	-- Greedy decoding for single prediction and low temperature
	if num_predictions == 1 and t <= M.GREEDY_TEMP_THRESHOLD then
		t = 0
	end

	return t
end

--- Truncates the context to a character limit proportional to max_words.
--- Prevents oversized prefill tokens from driving up TTFT on short predictions.
--- @param buffer string The full context buffer.
--- @param max_words number Max predicted words (0 = unlimited, returns buffer unchanged).
--- @return string The possibly truncated context.
local function cap_context(buffer, max_words)
	if not max_words or max_words <= 0 then return buffer end
	local char_limit = math.max(M.CONTEXT_MIN_CHARS, max_words * M.CONTEXT_CHARS_PER_WORD)
	if #buffer <= char_limit then return buffer end
	return buffer:sub(-char_limit)
end




-- =============================================
-- =============================================
-- ======= 3/ Public API =======================
-- =============================================
-- =============================================

--- Derives all LLM request parameters from the buffer and configuration.
--- This is the Lua equivalent of PromptBuilder.js:buildParams().
---
--- @param buffer string The current typing buffer.
--- @param config table Fields: max_words, min_words, num_predictions, temperature,
---        auto_raise_temp, language.
--- @return table params Keys: context, context_tail, max_tokens, temperature,
---         min_words, max_words, language, num_predictions.
function M.build_params(buffer, config)
	config = config or {}
	local max_words       = config.max_words       or 0
	local min_words       = config.min_words       or 1
	local num_predictions = config.num_predictions or 1
	local temperature     = config.temperature     or 0.1
	local auto_raise      = config.auto_raise_temp or false
	local language        = config.language        or "fr"

	if temperature == nil then temperature = 0.1 end

	local _, tail   = extract_tail(buffer)
	local context   = cap_context(buffer, max_words)

	return {
		context          = context,
		context_tail     = tail,
		max_tokens       = compute_max_tokens(max_words),
		temperature      = compute_temperature(temperature, num_predictions, auto_raise),
		min_words        = min_words,
		max_words        = max_words,
		language         = language,
		num_predictions  = num_predictions,
	}
end

--- Returns cross-driver test vectors matching PromptBuilder.js:promptBuilderTestVectors().
--- Every assertion in the JS reference must hold when executed against M.build_params().
--- @return table vectors Array of test vector objects.
function M.test_vectors()
	return {
		{
			id = "default_config",
			description = "Default config: budget = DEFAULT_MAX_TOKENS, temperature = 0.",
			buffer = "hello world",
			config = { max_words = 0, num_predictions = 1, temperature = 0.1 },
			expected = {
				max_tokens      = M.DEFAULT_MAX_TOKENS,
				temperature     = 0,
				context_tail    = "hello world",
				min_words       = 1,
				num_predictions = 1,
			},
		},
		{
			id = "token_budget_from_max_words",
			description = "max_words=5: budget = max(15, 5*6+10) = 40.",
			buffer = "some context",
			config = { max_words = 5, num_predictions = 1, temperature = 0.5 },
			expected = { max_tokens = 40, temperature = 0.5 },
		},
		{
			id = "min_token_floor",
			description = "max_words=1: budget = max(15, 1*6+10) = 16.",
			buffer = "context",
			config = { max_words = 1, num_predictions = 1, temperature = 0.1 },
			expected = { max_tokens = 16 },
		},
		{
			id = "auto_raise_temperature",
			description = "auto_raise_temp with 3 predictions: t = min(1.0, 0.2 + 0.1*2) = 0.4.",
			buffer = "le chat",
			config = { max_words = 3, num_predictions = 3, temperature = 0.2, auto_raise_temp = true },
			expected = { temperature = 0.4 },
		},
		{
			id = "temperature_diversity_cap",
			description = "auto_raise_temp with high base: capped at TEMP_DIVERSITY_CAP = 1.0.",
			buffer = "le chat",
			config = { max_words = 5, num_predictions = 10, temperature = 0.9, auto_raise_temp = true },
			expected = { temperature = M.TEMP_DIVERSITY_CAP },
		},
		{
			id = "context_truncation",
			description = "Long buffer truncated to max(100, max_words*40) chars.",
			buffer = ("a "):rep(200),
			config = { max_words = 2, num_predictions = 1, temperature = 0.1 },
			expected = { context_length_max = 100 },
		},
		{
			id = "tail_extraction",
			description = "context_tail contains the last 5 words of the buffer.",
			buffer = "word1 word2 word3 word4 word5 word6 word7",
			config = { max_words = 0, num_predictions = 1, temperature = 0.1 },
			expected = { context_tail = "word3 word4 word5 word6 word7" },
		},
		{
			id = "language_passthrough",
			description = "Language from config is passed through unchanged.",
			buffer = "some text",
			config = { language = "en" },
			expected = { language = "en" },
		},
	}
end

return M
