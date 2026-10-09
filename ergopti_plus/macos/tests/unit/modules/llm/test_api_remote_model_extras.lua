--- tests/unit/modules/llm/test_api_remote_model_extras.lua

--- ==============================================================================
--- MODULE: Remote API Model-Extras Regression Tests
--- DESCRIPTION:
--- qwen-3.8-27b reasons at xhigh effort by default and stalls tiny probes, so
--- the shared catalogue carries reasoning_effort:none for it and the OpenAI
--- payload branch merges those extras. Models without extras keep a bare
--- payload, and extras never leak into Anthropic/Gemini bodies. The field
--- lives in api_providers.json only — never restated in driver code.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("api_remote.model_extras", function()

	helpers.it("merges catalogue extras into openai payloads only", function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local build = api.__build_payload_for_test
		helpers.assert_true(type(build) == "function",
			"payload builder must be exposed for tests")
		local extras = { reasoning_effort = "none" }
		local probed = build("openai", "qwen-3.8-27b", "s", "u", 0, 16, extras)
		helpers.assert_eq(probed.reasoning_effort, "none",
			"qwen probe must disable reasoning")
		helpers.assert_eq(probed.stream, false,
			"extras must not disturb the non-streaming shape")
		local bare = build("openai", "gpt-4o-mini", "s", "u", 0.1, 16, nil)
		helpers.assert_true(bare.reasoning_effort == nil,
			"a model without extras must keep a bare payload")
		local anthropic = build("anthropic", "m", "s", "u", 0.1, 16, extras)
		helpers.assert_true(anthropic.reasoning_effort == nil,
			"extras must never leak into anthropic bodies")
	end)

	helpers.it("normalizes model extras fail-closed", function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local normalize = api.__normalize_model_extras_for_test
		helpers.assert_true(type(normalize) == "function",
			"extras normalizer must be exposed for tests")
		local norm = normalize({
			["qwen-3.8-27b"] = { reasoning_effort = "none", top_k = 40, broken = { x = 1 } },
			["_comment"] = "docs",
			["flat"] = "not-a-map",
		})
		helpers.assert_eq(norm["qwen-3.8-27b"].reasoning_effort, "none",
			"string fields survive")
		helpers.assert_eq(norm["qwen-3.8-27b"].top_k, 40,
			"number fields survive")
		helpers.assert_true(norm["qwen-3.8-27b"].broken == nil,
			"nested tables are not scalars")
		helpers.assert_true(norm["_comment"] == nil,
			"documentation keys are not models")
		helpers.assert_true(norm["flat"] == nil,
			"a model must map to a field table")
	end)

	helpers.it("loads cerebras qwen extras from the shared catalogue", function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local cerebras = api.PROVIDERS.cerebras
		helpers.assert_true(type(cerebras) == "table"
			and type(cerebras.model_extras) == "table",
			"catalogue must carry cerebras model extras")
		helpers.assert_eq(cerebras.model_extras["qwen-3.8-27b"].reasoning_effort, "none",
			"qwen extras must come from api_providers.json")
	end)

end)
