--- tests/unit/modules/llm/test_words_wrongtype_failclosed.lua

--- ==============================================================================
--- MODULE: Regression — menu_llm word display coerces before the > 0 comparison
--- DESCRIPTION:
--- Audit finding F-M10 (menu half; the engine setter/read half is covered in
--- test_prediction_engine.lua "set_llm_max_words / set_llm_min_words coerce..."). A
--- wrong-typed llm_max_words/llm_min_words from config.toml reached
--- `state.llm_max_words > 0` in the AI/Generation submenu builder, raising
--- "attempt to compare string with number" — the whole AI submenu then vanished
--- under the builder pcall. The display must coerce via tonumber first.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_llm word display coerces before the > 0 comparison", function()
	helpers.it("source: the generation menu uses tonumber before comparing llm_*_words", function()
		-- Selected by a declaration unique to ui/menu/menu_llm/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.terminate_orphan_mlx_server")
		helpers.assert_true(src ~= nil, "ui/menu/menu_llm/init.lua source must be locatable")

		helpers.assert_true(src:find("tonumber(state.llm_max_words)", 1, true) ~= nil,
			"max-words display must coerce via tonumber(state.llm_max_words)")
		helpers.assert_true(src:find("tonumber(state.llm_min_words)", 1, true) ~= nil,
			"min-words display must coerce via tonumber(state.llm_min_words)")
		-- The raw-value comparisons that crashed on a string must be gone.
		helpers.assert_true(src:find("state.llm_max_words > 0", 1, true) == nil,
			"must NOT compare the raw state.llm_max_words with > 0 (crashes on a string)")
		helpers.assert_true(src:find("state.llm_min_words > 0", 1, true) == nil,
			"must NOT compare the raw state.llm_min_words with > 0 (crashes on a string)")
	end)
end)
