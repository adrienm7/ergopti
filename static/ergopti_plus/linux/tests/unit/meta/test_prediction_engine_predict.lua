--- tests/unit/meta/test_prediction_engine_predict.lua

--- ==============================================================================
--- MODULE: Prediction Engine Load-Order Regression Guard
--- DESCRIPTION:
--- Regression test for a nil-global crash in modules/llm/prediction_engine.lua.
---
--- ROOT CAUSE ENCODED:
--- M.predict() called _build_system_prompt() / _build_user_context() which were
--- defined as `local function`s BELOW predict. Lua does not hoist `local
--- function`, so at the call site those names resolved to nil globals and
--- predict() crashed with "attempt to call a nil value" on the very first
--- prediction — the entire LLM feature was dead
--- (project-lua-closure-before-local-nil-global). Forward-declaring the two
--- locals above predict fixes it.
---
--- The existing tray/adapters tests never caught this because predict() is only
--- reached with the LLM backend mocked; here we mock the lazy deps so predict()
--- runs all the way to the prompt builders (the crash site).
--- ==============================================================================

local helpers = require("tests.helpers")





-- ============================================================
-- ============================================================
-- ======= 1/ Behavioural: predict() reaches builders =========
-- ============================================================
-- ============================================================

helpers.describe("prediction_engine.predict: no nil-global crash on the prompt builders", function()
	helpers.it("predict() builds the prompt and reaches ollama.chat without crashing", function()
		-- Mock the lazy-required backends so predict() passes its guards and runs
		-- through _build_system_prompt()/_build_user_context(). load_module only
		-- wipes the target module, so these package.loaded entries survive it.
		local chat_called = false
		package.loaded["modules.llm.api_ollama"] = {
			chat = function() chat_called = true end,
			cancel = function() end,
		}
		package.loaded["modules.llm.profiles"] = {
			get_current_model = function() return "test-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		package.loaded["adapters.text_sender"] = {
			send = function() end,
			eraseChars = function() end,
		}

		local pe = helpers.load_module("modules.llm.prediction_engine")
		local ok, err = pcall(pe.predict, "the quick brown fox //")

		-- Restore the module cache before asserting so a failure can't leak mocks.
		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm.profiles"] = nil
		package.loaded["adapters.text_sender"] = nil

		helpers.assert_true(ok, "predict() must not crash building the prompt; got: " .. tostring(err))
		helpers.assert_true(chat_called, "predict() should reach ollama.chat after building the prompt")
	end)
end)
