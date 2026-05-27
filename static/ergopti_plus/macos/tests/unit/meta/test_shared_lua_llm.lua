--- tests/unit/meta/test_shared_lua_llm.lua

--- ==============================================================================
--- MODULE: Shared Lua LLM Modules — Cross-Driver Compliance Tests
--- DESCRIPTION:
--- Validates the two shared Lua LLM modules against their cross-driver test
--- vectors, ensuring the Lua implementations stay in sync with the JS reference
--- implementations in shared/domain/PromptBuilder.js and
--- shared/domain/ProfileSelector.js.
---
--- COVERAGE:
--- 1. PromptBuilder — every vector from M.test_vectors() is executed against
---    M.build_params() and the result is asserted field by field.
--- 2. ProfileSelector — every vector from M.test_vectors() is executed against
---    M.resolve_system_prompt() / M.get_active_profile() and asserted.
--- 3. Constant parity — all 10 PromptBuilder constants are checked against their
---    canonical JS values to detect accidental drift.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================
-- ==========================================
-- ======= 1/ Module loading ================
-- ==========================================
-- ==========================================

-- Resolve shared/lua path relative to the driver root
local driver_root = helpers.driver_root()
local shared_lua  = driver_root .. "../shared/lua/"

-- Prepend shared/lua/ to the Lua package path so require("llm.xxx") resolves
local orig_path = package.path
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local ok_pb, PromptBuilder    = pcall(require, "llm.prompt_builder")
local ok_ps, ProfileSelector  = pcall(require, "llm.profile_selector")

-- Restore original path to avoid polluting other tests
package.path = orig_path




-- ==========================================
-- ==========================================
-- ======= 2/ PromptBuilder tests ===========
-- ==========================================
-- ==========================================

helpers.describe("shared_lua_llm — PromptBuilder: module loads", function()
	helpers.it("prompt_builder module is available on the shared Lua path", function()
		helpers.assert_true(ok_pb,
			"shared/lua/llm/prompt_builder.lua not found or has syntax error: "
			.. tostring(PromptBuilder))
	end)
end)

helpers.describe("shared_lua_llm — PromptBuilder: constant parity with JS reference", function()
	helpers.it("CONTEXT_TAIL_WORDS = 5", function()
		if not ok_pb then return end
		helpers.assert_eq(5, PromptBuilder.CONTEXT_TAIL_WORDS, "CONTEXT_TAIL_WORDS")
	end)
	helpers.it("DEFAULT_MAX_TOKENS = 150", function()
		if not ok_pb then return end
		helpers.assert_eq(150, PromptBuilder.DEFAULT_MAX_TOKENS, "DEFAULT_MAX_TOKENS")
	end)
	helpers.it("MIN_MAX_TOKENS = 15", function()
		if not ok_pb then return end
		helpers.assert_eq(15, PromptBuilder.MIN_MAX_TOKENS, "MIN_MAX_TOKENS")
	end)
	helpers.it("WORDS_TO_TOKENS_RATIO = 6", function()
		if not ok_pb then return end
		helpers.assert_eq(6, PromptBuilder.WORDS_TO_TOKENS_RATIO, "WORDS_TO_TOKENS_RATIO")
	end)
	helpers.it("TOKEN_BUDGET_OVERHEAD = 10", function()
		if not ok_pb then return end
		helpers.assert_eq(10, PromptBuilder.TOKEN_BUDGET_OVERHEAD, "TOKEN_BUDGET_OVERHEAD")
	end)
	helpers.it("TEMP_DIVERSITY_CAP = 1.0", function()
		if not ok_pb then return end
		helpers.assert_eq(1.0, PromptBuilder.TEMP_DIVERSITY_CAP, "TEMP_DIVERSITY_CAP")
	end)
	helpers.it("TEMP_INCREMENT_PER_PRED = 0.1", function()
		if not ok_pb then return end
		helpers.assert_eq(0.1, PromptBuilder.TEMP_INCREMENT_PER_PRED, "TEMP_INCREMENT_PER_PRED")
	end)
	helpers.it("GREEDY_TEMP_THRESHOLD = 0.15", function()
		if not ok_pb then return end
		helpers.assert_eq(0.15, PromptBuilder.GREEDY_TEMP_THRESHOLD, "GREEDY_TEMP_THRESHOLD")
	end)
	helpers.it("CONTEXT_CHARS_PER_WORD = 40", function()
		if not ok_pb then return end
		helpers.assert_eq(40, PromptBuilder.CONTEXT_CHARS_PER_WORD, "CONTEXT_CHARS_PER_WORD")
	end)
	helpers.it("CONTEXT_MIN_CHARS = 100", function()
		if not ok_pb then return end
		helpers.assert_eq(100, PromptBuilder.CONTEXT_MIN_CHARS, "CONTEXT_MIN_CHARS")
	end)
end)

helpers.describe("shared_lua_llm — PromptBuilder: build_params vectors", function()
	helpers.it("all cross-driver test vectors pass", function()
		if not ok_pb then return end
		local vectors = PromptBuilder.test_vectors()
		helpers.assert_true(type(vectors) == "table" and #vectors > 0,
			"test_vectors() must return a non-empty table")

		for _, v in ipairs(vectors) do
			local result = PromptBuilder.build_params(v.buffer, v.config)
			helpers.assert_true(type(result) == "table",
				"vector '" .. v.id .. "': build_params must return a table")

			local exp = v.expected
			if exp.max_tokens ~= nil then
				helpers.assert_eq(exp.max_tokens, result.max_tokens,
					"vector '" .. v.id .. "': max_tokens")
			end
			if exp.temperature ~= nil then
				helpers.assert_eq(exp.temperature, result.temperature,
					"vector '" .. v.id .. "': temperature")
			end
			if exp.context_tail ~= nil then
				helpers.assert_eq(exp.context_tail, result.context_tail,
					"vector '" .. v.id .. "': context_tail")
			end
			if exp.language ~= nil then
				helpers.assert_eq(exp.language, result.language,
					"vector '" .. v.id .. "': language")
			end
			if exp.min_words ~= nil then
				helpers.assert_eq(exp.min_words, result.min_words,
					"vector '" .. v.id .. "': min_words")
			end
			if exp.num_predictions ~= nil then
				helpers.assert_eq(exp.num_predictions, result.num_predictions,
					"vector '" .. v.id .. "': num_predictions")
			end
			if exp.context_length_max ~= nil then
				helpers.assert_true(#result.context <= exp.context_length_max,
					"vector '" .. v.id .. "': context length "
					.. #result.context .. " exceeds max " .. exp.context_length_max)
			end
		end
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 3/ ProfileSelector tests =========
-- ==========================================
-- ==========================================

helpers.describe("shared_lua_llm — ProfileSelector: module loads", function()
	helpers.it("profile_selector module is available on the shared Lua path", function()
		helpers.assert_true(ok_ps,
			"shared/lua/llm/profile_selector.lua not found or has syntax error: "
			.. tostring(ProfileSelector))
	end)
end)

helpers.describe("shared_lua_llm — ProfileSelector: resolve_system_prompt vectors", function()
	helpers.it("all resolve_system_prompt test vectors pass", function()
		if not ok_ps then return end
		local vectors = ProfileSelector.test_vectors()
		helpers.assert_true(type(vectors) == "table" and #vectors > 0,
			"test_vectors() must return a non-empty table")

		for _, v in ipairs(vectors) do
			if v.call == "resolve_system_prompt" then
				local result = ProfileSelector.resolve_system_prompt(v.profile, v.vars)
				helpers.assert_true(type(result) == "table",
					"vector '" .. v.id .. "': resolve_system_prompt must return a table")

				local exp = v.assert
				if exp.value ~= nil then
					helpers.assert_eq(exp.value, result[exp.field],
						"vector '" .. v.id .. "': field '" .. exp.field .. "'")
				end
				if exp.not_null then
					helpers.assert_true(result[exp.field] ~= nil,
						"vector '" .. v.id .. "': field '" .. exp.field .. "' must not be nil")
				end
				if exp.contains ~= nil then
					local val = tostring(result[exp.field] or "")
					helpers.assert_true(val:find(exp.contains, 1, true) ~= nil,
						"vector '" .. v.id .. "': field '" .. exp.field
						.. "' must contain '" .. exp.contains .. "'")
				end
			elseif v.call == "get_active_profile" then
				local result = ProfileSelector.get_active_profile(
					v.profile_id, v.user_profiles)
				helpers.assert_true(result ~= nil,
					"vector '" .. v.id .. "': get_active_profile must not return nil")

				local exp = v.assert
				if exp.starts_with ~= nil then
					local field_val = tostring(result[exp.field] or "")
					helpers.assert_true(
						field_val:sub(1, #exp.starts_with) == exp.starts_with,
						"vector '" .. v.id .. "': field '" .. exp.field
						.. "' must start with '" .. exp.starts_with .. "'")
				end
			end
		end
	end)
end)
