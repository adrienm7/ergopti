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




-- ============================================================
-- ============================================================
-- ======= 2/ Fail-fast: no model selected ====================
-- ============================================================
-- ============================================================

helpers.describe("prediction_engine.predict: 'no model selected' guard is not dead code", function()
	helpers.it("does not dispatch to ollama.chat and warns when the profile has no model", function()
		-- Root cause: predict() used to substitute a hardcoded 'codellama' model
		-- when the profile had none selected, making the 'no model selected' guard
		-- dead code and firing a request against a model the user never chose. With
		-- the fallback removed, a nil model must short-circuit: no chat dispatch, a
		-- 'No model selected' warning instead.
		local chat_called = false
		package.loaded["modules.llm.api_ollama"] = {
			chat = function() chat_called = true end,
			cancel = function() end,
		}
		-- Profile with NO model selected.
		package.loaded["modules.llm.profiles"] = {
			get_current_model = function() return nil end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		package.loaded["adapters.text_sender"] = {
			send = function() end,
			eraseChars = function() end,
		}

		local logger    = require("logger.shim")
		local orig_warn = logger.warn
		local warns     = {}
		logger.warn = function(_t, fmt, ...)
			warns[#warns + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
		end

		local pe = helpers.load_module("modules.llm.prediction_engine")
		local ok, err = pcall(pe.predict, "the quick brown fox //")

		-- Restore before asserting so mocks/spies never leak into later tests.
		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm.profiles"] = nil
		package.loaded["adapters.text_sender"] = nil
		logger.warn = orig_warn

		helpers.assert_true(ok, "predict() must not crash when no model is selected; got: " .. tostring(err))
		helpers.assert_true(chat_called == false,
			"predict() must NOT dispatch to ollama.chat when no model is selected")
		local warned = false
		for _, m in ipairs(warns) do
			if m:find("No model selected", 1, true) then warned = true end
		end
		helpers.assert_true(warned,
			"predict() must warn 'No model selected' instead of falling back to a hardcoded model")
	end)
end)
