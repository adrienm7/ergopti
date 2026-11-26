-- tests/unit/ai/engine/prediction/test_test_button.lua

--- ==============================================================================
--- MODULE: macOS AI Menu Test Prediction (ai-test-prediction)
--- DESCRIPTION:
--- Replays the shared contract for the AI menu's « Test a prediction » and pins
--- the macOS wiring: the engine reaches the backend through the raw completion,
--- with no offer the user could accept, and the row reaches the engine.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.ai.test_prediction_contract")(helpers)

helpers.describe("macOS test prediction wiring", function()
	helpers.it("goes to the backend, never to a prediction surface", function()
		local engine = assert(helpers.read_driver_unit("core_llm.fetch_raw_completion("))
		local start = assert(engine:find("function M.test_prediction()", 1, true))
		local stop = assert(engine:find("\nend\n", start, true))
		local body = engine:sub(start, stop)
		helpers.assert_true(body:find("core_llm.fetch_raw_completion(", 1, true) ~= nil, "the backend's one request")
		helpers.assert_true(body:find("test_prediction_temperature()", 1, true) ~= nil, "at the test's own temperature")
		helpers.assert_true(body:find("now_ms = function() return hs.timer.absoluteTime() / 1e6 end", 1, true) ~= nil,
			"on the monotonic clock")
		for _, forbidden in ipairs({ "perform_check", "fetch_llm_prediction", "show_predictions", "open_answer_surface" }) do
			helpers.assert_eq(body:find(forbidden, 1, true), nil, "no engine answer: " .. forbidden)
		end
	end)

	helpers.it("reads the test's temperature from the shared defaults", function()
		local raw = assert(io.open(helpers.shared("ai/data/defaults.json"), "rb"))
		local defaults = hs.json.decode(raw:read("*a")); raw:close()
		helpers.assert_true(defaults.llm_test_prediction_temperature > defaults.llm_temperature, "above the setting")
		helpers.assert_eq(require("ai.engine.api.common").test_prediction_temperature(),
			defaults.llm_test_prediction_temperature)
	end)

	helpers.it("the row reaches the engine", function()
		local menu = assert(helpers.read_driver_unit("keymap.test_prediction()"), "wired to the keymap")
		-- The source helper expands config_keys, so the command reads as its value.
		helpers.assert_true(menu:find('["llm_test_prediction"] = function()', 1, true) ~= nil, "the menu registers the command")
		helpers.assert_true(helpers.read_driver_source("M.test_prediction = LLMBridge.test_prediction") ~= nil)
		helpers.assert_true(helpers.read_driver_source("engine.test_prediction()") ~= nil)
	end)
end)
