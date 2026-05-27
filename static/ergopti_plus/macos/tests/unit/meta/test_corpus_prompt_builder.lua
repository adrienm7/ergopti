--- tests/unit/meta/test_corpus_prompt_builder.lua

--- ==============================================================================
--- MODULE: PromptBuilder Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver corpus from
--- shared/tests/corpus/prompt_builder/vectors.json and validates each vector
--- against the shared Lua implementation at shared/lua/llm/prompt_builder.lua.
---
--- COVERAGE:
--- 1. Corpus integrity — JSON file is readable and every vector has required
---    fields (id, buffer, config, expected).
--- 2. Token budget — computeMaxTokens() matches expected max_tokens.
--- 3. Temperature — greedy snap, diversity raise, and cap are correct.
--- 4. Context tail — last CONTEXT_TAIL_WORDS words match expected context_tail.
--- 5. Context truncation — context length never exceeds context_length_max.
--- 6. Language passthrough — language field is forwarded unchanged.
--- 7. Direct string match — context field is exact when expected.context provided.
---
--- This file exercises the shared shared/lua/llm/prompt_builder.lua module,
--- ensuring the Lua implementation stays in sync with the JS reference.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================
--- ============================================
-- ======= 1/ Corpus + Module Bootstrap =======
--- ============================================
-- ============================================

-- Inject the shared/lua/ path so prompt_builder can be required directly.
local _driver_root = helpers.driver_root()
local _shared_lua  = _driver_root .. "../shared/lua"
local _entry       = _shared_lua .. "/?.lua"
if not package.path:find(_entry, 1, true) then
	package.path = _entry .. ";" .. package.path
end

local corpus_path = _driver_root .. "../shared/tests/corpus/prompt_builder/vectors.json"

--- Reads and parses the corpus JSON file.
--- @return table|nil corpus, string|nil err
local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	-- Use hs.json via the stub loader
	helpers.load_with_stubs("lib.logger")
	local ok, corpus = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(corpus) end
	return corpus, nil
end

local corpus, corpus_err = read_corpus()

-- Load the shared prompt_builder module
local ok_pb, prompt_builder = pcall(require, "llm.prompt_builder")
if not ok_pb then
	-- Fallback: resolve relative to shared/lua
	ok_pb, prompt_builder = pcall(require, "prompt_builder")
end




-- ============================================
-- ============================================
-- ======= 2/ Corpus Integrity =================
-- ============================================
-- ============================================

helpers.describe("prompt_builder corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus ~= nil,
			"corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus.vectors > 0,
			"corpus must contain at least one vector")
	end)

	helpers.it("prompt_builder module is loadable", function()
		helpers.assert_true(ok_pb,
			"prompt_builder load failed: " .. tostring(prompt_builder))
		helpers.assert_true(type(prompt_builder.build_params) == "function",
			"prompt_builder must expose build_params()")
	end)

	helpers.it("every vector has required fields: id, buffer, config, expected", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id")
			helpers.assert_true(type(v.buffer) == "string",
				"vector '" .. tostring(v.id) .. "' missing buffer")
			helpers.assert_true(type(v.config) == "table",
				"vector '" .. tostring(v.id) .. "' missing config")
			helpers.assert_true(type(v.expected) == "table",
				"vector '" .. tostring(v.id) .. "' missing expected")
		end
	end)

	helpers.it("corpus constants match prompt_builder constants", function()
		if not corpus or not ok_pb then return end
		local c = corpus.constants
		helpers.assert_eq(c.DEFAULT_MAX_TOKENS,      prompt_builder.DEFAULT_MAX_TOKENS,
			"DEFAULT_MAX_TOKENS mismatch")
		helpers.assert_eq(c.MIN_MAX_TOKENS,          prompt_builder.MIN_MAX_TOKENS,
			"MIN_MAX_TOKENS mismatch")
		helpers.assert_eq(c.CONTEXT_TAIL_WORDS,      prompt_builder.CONTEXT_TAIL_WORDS,
			"CONTEXT_TAIL_WORDS mismatch")
		helpers.assert_eq(c.TEMP_DIVERSITY_CAP,      prompt_builder.TEMP_DIVERSITY_CAP,
			"TEMP_DIVERSITY_CAP mismatch")
		helpers.assert_eq(c.GREEDY_TEMP_THRESHOLD,   prompt_builder.GREEDY_TEMP_THRESHOLD,
			"GREEDY_TEMP_THRESHOLD mismatch")
	end)
end)




-- ============================================
-- ============================================
-- ======= 3/ Corpus Vector Execution ==========
-- ============================================
-- ============================================

helpers.describe("prompt_builder corpus — vector execution", function()
	helpers.it("all corpus vectors pass build_params()", function()
		if not corpus or not ok_pb then return end

		local failures = {}

		for _, v in ipairs(corpus.vectors) do
			local result = prompt_builder.build_params(v.buffer, v.config)
			local exp    = v.expected

			-- max_tokens check
			if exp.max_tokens ~= nil and result.max_tokens ~= exp.max_tokens then
				table.insert(failures, string.format(
					"[%s] max_tokens: expected %s, got %s",
					v.id, tostring(exp.max_tokens), tostring(result.max_tokens)))
			end

			-- temperature check (approximate: allow floating-point epsilon)
			if exp.temperature ~= nil then
				local diff = math.abs(result.temperature - exp.temperature)
				if diff > 1e-9 then
					table.insert(failures, string.format(
						"[%s] temperature: expected %.4f, got %.4f",
						v.id, exp.temperature, result.temperature))
				end
			end

			-- context_tail check
			if exp.context_tail ~= nil and result.context_tail ~= exp.context_tail then
				table.insert(failures, string.format(
					"[%s] context_tail: expected '%s', got '%s'",
					v.id, exp.context_tail, result.context_tail))
			end

			-- context_length_max check (truncation test)
			if exp.context_length_max ~= nil then
				if #result.context > exp.context_length_max then
					table.insert(failures, string.format(
						"[%s] context too long: got %d chars, max %d",
						v.id, #result.context, exp.context_length_max))
				end
			end

			-- exact context check
			if exp.context ~= nil and result.context ~= exp.context then
				table.insert(failures, string.format(
					"[%s] context: expected '%s', got '%s'",
					v.id, exp.context, result.context))
			end

			-- language check
			if exp.language ~= nil and result.language ~= exp.language then
				table.insert(failures, string.format(
					"[%s] language: expected '%s', got '%s'",
					v.id, exp.language, result.language))
			end

			-- min_words passthrough
			if exp.min_words ~= nil and result.min_words ~= exp.min_words then
				table.insert(failures, string.format(
					"[%s] min_words: expected %s, got %s",
					v.id, tostring(exp.min_words), tostring(result.min_words)))
			end

			-- num_predictions passthrough
			if exp.num_predictions ~= nil and result.num_predictions ~= exp.num_predictions then
				table.insert(failures, string.format(
					"[%s] num_predictions: expected %s, got %s",
					v.id, tostring(exp.num_predictions), tostring(result.num_predictions)))
			end
		end

		helpers.assert_true(
			#failures == 0,
			"corpus failures (" .. #failures .. "):\n  " .. table.concat(failures, "\n  "))
	end)
end)




-- ============================================
-- ============================================
-- ======= 4/ Inline Module Vectors ============
-- ============================================
-- ============================================

-- The prompt_builder Lua module ships its own canonical test vectors (M.test_vectors())
-- that mirror PromptBuilder.js:promptBuilderTestVectors(). Run them here as an
-- additional layer of validation that is independent from the JSON corpus file.

helpers.describe("prompt_builder — inline module vectors", function()
	helpers.it("all inline test_vectors() pass", function()
		if not ok_pb or type(prompt_builder.test_vectors) ~= "function" then
			return
		end

		local vectors  = prompt_builder.test_vectors()
		local failures = {}

		for _, v in ipairs(vectors) do
			local result = prompt_builder.build_params(v.buffer, v.config)
			local exp    = v.expected

			if exp.max_tokens ~= nil and result.max_tokens ~= exp.max_tokens then
				table.insert(failures, string.format(
					"[%s] max_tokens: expected %s, got %s",
					v.id, tostring(exp.max_tokens), tostring(result.max_tokens)))
			end

			if exp.temperature ~= nil then
				local diff = math.abs(result.temperature - exp.temperature)
				if diff > 1e-9 then
					table.insert(failures, string.format(
						"[%s] temperature: expected %.4f, got %.4f",
						v.id, exp.temperature, result.temperature))
				end
			end

			if exp.context_tail ~= nil and result.context_tail ~= exp.context_tail then
				table.insert(failures, string.format(
					"[%s] context_tail: expected '%s', got '%s'",
					v.id, exp.context_tail, result.context_tail))
			end

			if exp.context_length_max ~= nil and #result.context > exp.context_length_max then
				table.insert(failures, string.format(
					"[%s] context too long: got %d, max %d",
					v.id, #result.context, exp.context_length_max))
			end

			if exp.language ~= nil and result.language ~= exp.language then
				table.insert(failures, string.format(
					"[%s] language: expected '%s', got '%s'",
					v.id, exp.language, result.language))
			end
		end

		helpers.assert_true(
			#failures == 0,
			"inline vector failures (" .. #failures .. "):\n  " .. table.concat(failures, "\n  "))
	end)
end)
