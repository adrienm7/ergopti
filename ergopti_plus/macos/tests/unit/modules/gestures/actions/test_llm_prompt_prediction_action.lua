--- tests/unit/modules/gestures/actions/test_llm_prompt_prediction_action.lua

--- ==============================================================================
--- MODULE: The prompt prediction actions reach the keymap bridge
--- DESCRIPTION:
--- A binding of llm_prompt_prediction stores "<profile_id>" or
--- "<profile_id>|<count>"; dispatching it hands that value to the keymap
--- bridge's request_prompt_prediction. Each built-in profile also has its own
--- parameterless preset, llm_predict_<id>, which asks for that profile with the
--- AI menu's count.
---
--- ROOT CAUSE ENCODED:
--- Running a prediction with another prompt meant switching the AI menu's
--- global profile first. No binding could name the prompt it runs.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local ProfileSelector = require("llm.profile_selector")
local it = Fixture.it

--- Runs a callback with a keymap bridge that records prompt requests.
--- @param callback function Receives the request list.
local function with_bridge(callback)
	local saved = package.loaded["modules.keymap"]
	local requests = {}
	package.loaded["modules.keymap"] = {
		request_prompt_prediction = function(value)
			requests[#requests + 1] = value
			return true
		end,
	}
	local ok, err = pcall(callback, requests)
	package.loaded["modules.keymap"] = saved
	if not ok then error(err, 0) end
end

helpers.describe("llm_prompt_prediction action", function()
	it("sends the binding's own prompt and count to the bridge", function(fresh_actions)
		local actions = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.get_action_parameter_spec("llm_prompt_prediction"), "llm_prompt")
		helpers.assert_eq(actions.set_action_parameter("tap_3", "llm_prompt_prediction", "rewrite|2"), true)
		helpers.assert_eq(actions.set_action_parameter(
			"keyboard__cmd_1", "llm_prompt_prediction", "custom_17_4"), true,
			"a custom id is stored even if no such profile exists yet: existence is a run-time check")
		with_bridge(function(requests)
			helpers.assert_eq(actions.execute_single("llm_prompt_prediction", "tap_3"), true)
			helpers.assert_eq(actions.execute_single("llm_prompt_prediction", "keyboard__cmd_1"), true)
			helpers.assert_eq(requests[1], "rewrite|2", "the gesture's own value")
			helpers.assert_eq(requests[2], "custom_17_4", "the keyboard slot's own value")
		end)
	end)

	it("refuses an invalid value at assignment and sends nothing without one", function(fresh_actions)
		local actions = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter("tap_3", "llm_prompt_prediction", "rewrite|11"), false)
		helpers.assert_eq(actions.set_action_parameter("tap_3", "llm_prompt_prediction", "a b"), false)
		with_bridge(function(requests)
			actions.execute_single("llm_prompt_prediction", "tap_3")
			helpers.assert_eq(#requests, 0, "a binding without a valid prompt must not ask for anything")
		end)
	end)
end)

helpers.describe("llm_predict_<profile> presets", function()
	it("registers one preset per built-in profile, each asking for its profile", function(fresh_actions)
		local actions = fresh_actions()
		local profiles = ProfileSelector.load_built_in_profiles()
		helpers.assert_true(#profiles >= 5, "the built-in profiles must be loaded")
		with_bridge(function(requests)
			for index, profile in ipairs(profiles) do
				local action = "llm_predict_" .. profile.id
				helpers.assert_nil(actions.get_action_parameter_spec(action),
					action .. " takes no parameter")
				helpers.assert_eq(actions.execute_single(action, "tap_3"), true,
					action .. " must be a registered action")
				helpers.assert_eq(requests[index], profile.id,
					action .. " asks for its own profile with the AI menu's count")
			end
			helpers.assert_eq(#requests, #profiles)
		end)
	end)
end)
