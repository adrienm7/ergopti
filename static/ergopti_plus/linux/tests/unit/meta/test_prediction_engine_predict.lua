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

local function install_insecure_focus()
	local previous = package.loaded["adapters.secure_field_detector"]
	package.loaded["adapters.secure_field_detector"] = {
		isSecureField = function() return false end,
		isSecureApp = function() return false end,
	}
	return function() package.loaded["adapters.secure_field_detector"] = previous end
end





-- ============================================================
-- ============================================================
-- ======= 1/ Behavioural: predict() reaches builders =========
-- ============================================================
-- ============================================================

helpers.describe("prediction_engine.predict: no nil-global crash on the prompt builders", function()
	helpers.it("predict() builds the prompt and reaches ollama.chat without crashing", function()
		local restore_focus = install_insecure_focus()
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

		local pe = helpers.load_module("modules.llm.prediction_engine")
		local ok, err = pcall(pe.predict, "the quick brown fox //")

		-- Restore the module cache before asserting so a failure can't leak mocks.
		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm.profiles"] = nil
		restore_focus()

		helpers.assert_nil(err, "predict() must not crash building the prompt; got: " .. tostring(err))
		helpers.assert_true(ok, "predict() must not crash building the prompt")
		helpers.assert_true(chat_called, "predict() should reach ollama.chat after building the prompt")
	end)

	helpers.it("checks the secure field before loading request dependencies", function()
		local names = {
			"adapters.secure_field_detector",
			"modules.llm.api_ollama",
			"modules.llm.profiles",
			"modules.llm.trigger_settings",
		}
		local loaded = {}
		local preload = {}
		for _, name in ipairs(names) do
			loaded[name] = package.loaded[name]
			preload[name] = package.preload[name]
			package.loaded[name] = nil
		end

		local detector_calls = 0
		local request_dependency_loads = 0
		package.loaded["adapters.secure_field_detector"] = {
			isSecureField = function()
				detector_calls = detector_calls + 1
				return true
			end,
		}
		package.loaded["modules.llm.trigger_settings"] = {
			get = function(name) return name == "secure_filter_enabled" end,
		}
		for _, name in ipairs({ "modules.llm.api_ollama", "modules.llm.profiles" }) do
			package.preload[name] = function()
				request_dependency_loads = request_dependency_loads + 1
				return {}
			end
		end

		local pe = helpers.load_module("modules.llm.prediction_engine")
		local ok, err = pcall(pe.predict, "credential-shaped context //")

		for _, name in ipairs(names) do
			package.loaded[name] = loaded[name]
			package.preload[name] = preload[name]
		end
		package.loaded["modules.llm.prediction_engine"] = nil

		helpers.assert_true(ok, "the privacy guard must not raise: " .. tostring(err))
		helpers.assert_eq(detector_calls, 1,
			"the secure-field verdict must be consulted for every prediction attempt")
		helpers.assert_eq(request_dependency_loads, 0,
			"a credential context must be rejected before a model or transport is loaded")
	end)
end)




-- ============================================================
-- ============================================================
-- ======= 2/ Fail-fast: no model selected ====================
-- ============================================================
-- ============================================================

helpers.describe("prediction_engine.predict: 'no model selected' guard is not dead code", function()
	helpers.it("does not dispatch to ollama.chat and warns when the profile has no model", function()
		local restore_focus = install_insecure_focus()
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
		restore_focus()
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

helpers.describe("prediction_engine: durable logical-output callback", function()
	helpers.it("reports output only after the user accepts a parsed suggestion", function()
		local restore_focus = install_insecure_focus()
		local observed = nil
		local applied = nil
		package.loaded["modules.llm.api_ollama"] = {
			chat = function(_, _, _, _, on_chunk, on_done)
				on_chunk(" est bien faite")
				on_done(" est bien faite", nil)
			end,
			cancel = function() end,
		}
		package.loaded["modules.llm.profiles"] = {
			init = function() end,
			is_enabled = function() return true end,
			get_current_model = function() return "test-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}

		local pe = helpers.load_module("modules.llm.prediction_engine")
		pe.init({
			apply_prediction = function(candidate, context)
				applied = { candidate = candidate, context = context }
				return true
			end,
			on_output = function(text, context)
			observed = { text = text, context = context }
			end,
		})
		pe.predict("Bonjour //", { app_id = "firefox", input_chars = 2 })
		helpers.assert_nil(observed, "finishing a request must not commit text")
		helpers.assert_true(pe.has_suggestions(), "a parsed completion must be offered")
		helpers.assert_true(pe.accept(1), "the first visible suggestion must be acceptable")

		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm.profiles"] = nil
		restore_focus()

		helpers.assert_not_nil(applied)
		helpers.assert_true(applied.candidate.deletes >= 2,
			"acceptance must erase the explicit trigger before typing the completion")
		helpers.assert_eq(observed.text, " est bien faite")
		helpers.assert_eq(observed.context.app_id, "firefox")
		helpers.assert_eq(observed.context.input_chars, 2)
	end)

	helpers.it("does not report a failed streamed prediction as logical output", function()
		local restore_focus = install_insecure_focus()
		local callback_count = 0
		local chat_called = false
		package.loaded["modules.llm.api_ollama"] = {
			chat = function(_, _, _, _, on_chunk, on_done)
				chat_called = true
				on_chunk("partial")
				on_done("", "network error")
			end,
			cancel = function() end,
		}
		package.loaded["modules.llm.profiles"] = {
			init = function() end,
			is_enabled = function() return true end,
			get_current_model = function() return "test-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		local pe = helpers.load_module("modules.llm.prediction_engine")
		pe.init({ auto_inject = true, on_output = function() callback_count = callback_count + 1 end })
		pe.predict("Bonjour //", { app_id = "firefox", input_chars = 2 })

		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm.profiles"] = nil
		restore_focus()

		helpers.assert_eq(chat_called, true,
			"the failure assertion is meaningful only if a request actually ran")
		helpers.assert_eq(callback_count, 0,
			"erased failure fragments must not be written as synthetic output")
	end)
end)
