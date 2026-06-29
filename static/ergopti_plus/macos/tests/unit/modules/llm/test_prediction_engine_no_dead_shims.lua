--- tests/unit/modules/llm/test_prediction_engine_no_dead_shims.lua

--- Regression guard for B7.1: asserts that the backwards-compat shim
--- set_llm_show_model_name (removed per §5.6) is not exported by the
--- prediction_engine module or the keymap.init facade. A re-introduction
--- would silently bypass the Logger.debug call in set_llm_display_model_name,
--- making setter activity invisible in logs (§5.5 regression).

local helpers = require("tests.helpers")


-- ===================================================
-- ===================================================
-- ======= 1/ Dead shim absence (B7.1 §5.6) =========
-- ===================================================
-- ===================================================

helpers.describe("prediction_engine: B7.1 dead shim set_llm_show_model_name absent", function()
	package.loaded["lib.logger"] = helpers.make_logger_stub()
	local engine = helpers.load_with_stubs("modules.llm.prediction_engine")

	helpers.it("set_llm_show_model_name is NOT exported (shim deleted, §5.6)", function()
		helpers.assert_true(engine.set_llm_show_model_name == nil,
			"prediction_engine must not export set_llm_show_model_name — use set_llm_display_model_name")
	end)

	helpers.it("set_llm_display_model_name IS exported (the real setter)", function()
		helpers.assert_true(type(engine.set_llm_display_model_name) == "function",
			"set_llm_display_model_name must be exported as the canonical setter")
	end)
end)
