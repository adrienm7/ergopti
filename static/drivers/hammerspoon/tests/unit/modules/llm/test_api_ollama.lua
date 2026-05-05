--- tests/unit/modules/llm/test_api_ollama.lua

--- ==============================================================================
--- MODULE: llm.api_ollama Unit Tests
--- DESCRIPTION:
--- Tests the lightweight, side-effect-free public surface of the Ollama
--- controller: model heuristics (is_thinking_model) and the readiness flag.
--- The actual networked entry points (fetch_*, warmup, check_availability) are
--- exercised at integration time only — they require hs.task and hs.http.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")




-- =====================================
-- =====================================
-- ======= 1/ is_thinking_model =========
-- =====================================
-- =====================================

helpers.describe("ApiOllama.is_thinking_model", function()
	helpers.it("returns true for qwen3 family", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("Qwen3-1.7B"), true)
		helpers.assert_eq(ApiOllama.is_thinking_model("qwen3:8b"), true)
	end)

	helpers.it("returns true for deepseek family", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("deepseek-r1"), true)
	end)

	helpers.it("returns true for r1 suffix", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("foo-r1"), true)
		helpers.assert_eq(ApiOllama.is_thinking_model("foo:r1"), true)
	end)

	helpers.it("returns true when name contains 'think'", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("magnus-thinking"), true)
	end)

	helpers.it("returns false for plain non-thinking models", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("gemma-4-E2B-it"), false)
		helpers.assert_eq(ApiOllama.is_thinking_model("llama3.2"), false)
		helpers.assert_eq(ApiOllama.is_thinking_model("mistral"), false)
	end)

	helpers.it("returns false for non-string input", function()
		helpers.assert_eq(ApiOllama.is_thinking_model(nil), false)
		helpers.assert_eq(ApiOllama.is_thinking_model(42), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Readiness flag ===========
-- =====================================
-- =====================================

helpers.describe("ApiOllama.is_ready", function()
	helpers.it("starts as false (model not warmed up)", function()
		helpers.assert_eq(ApiOllama.is_ready(), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ cancel_streaming =========
-- =====================================
-- =====================================

helpers.describe("ApiOllama.cancel_streaming", function()
	helpers.it("does not error when no stream is active", function()
		ApiOllama.cancel_streaming()
	end)
end)
