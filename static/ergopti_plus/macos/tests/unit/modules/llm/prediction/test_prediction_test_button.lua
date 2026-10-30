-- tests/unit/modules/llm/prediction/test_prediction_test_button.lua

--- ==============================================================================
--- MODULE: macOS AI Menu Test Prediction (ai-test-prediction)
--- DESCRIPTION:
--- Replays the shared contract for the AI menu's « Test a prediction » and pins
--- the macOS wiring: the engine reaches the backend through the raw completion,
--- with no offer the user could accept, and the row reaches the engine.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.test_prediction_contract")(helpers)

--- Reads one driver source.
--- @param path string Relative to the driver's root.
--- @return string
local function source(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

helpers.describe("macOS test prediction wiring", function()
	helpers.it("goes to the backend, never to a prediction surface", function()
		local engine = source("modules/llm/prediction_engine.lua")
		local start = assert(engine:find("function M.test_prediction()", 1, true))
		local stop = assert(engine:find("\nend\n", start, true))
		local body = engine:sub(start, stop)
		helpers.assert_true(body:find("core_llm.fetch_raw_completion(", 1, true) ~= nil, "the backend's one request")
		for _, forbidden in ipairs({ "perform_check", "fetch_llm_prediction", "show_predictions", "open_answer_surface" }) do
			helpers.assert_eq(body:find(forbidden, 1, true), nil, "no engine answer: " .. forbidden)
		end
	end)

	helpers.it("the row reaches the engine", function()
		local menu = source("ui/menu/menu_llm/init.lua")
		helpers.assert_true(menu:find("COMMAND.LLM_TEST_PREDICTION", 1, true) ~= nil, "the menu registers the command")
		helpers.assert_true(menu:find("keymap.test_prediction()", 1, true) ~= nil, "wired to the keymap")
		helpers.assert_true(source("modules/keymap/init.lua"):find("M.test_prediction = LLMBridge.test_prediction", 1, true) ~= nil)
		helpers.assert_true(source("modules/keymap/llm_bridge.lua"):find("engine.test_prediction()", 1, true) ~= nil)
	end)
end)
