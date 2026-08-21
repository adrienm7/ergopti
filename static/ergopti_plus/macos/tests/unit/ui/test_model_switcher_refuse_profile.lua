--- tests/unit/ui/test_model_switcher_refuse_profile.lua

--- ==============================================================================
--- MODULE: Model Switcher Profile Decision Regression
--- DESCRIPTION:
--- Proves through the real profile-decision callback that refusing a suggested
--- profile has no effects while accepting it commits every required effect.
--- ==============================================================================

local helpers = require("tests.helpers")

local function build_fixture(dialog_choice)
	local noop = function() end
	local calls = {
		profiles = {},
		saves = 0,
		updates = 0,
		notifications = {},
	}
	local state = {
		llm_active_profile = "basic",
		llm_model = "old-model",
		llm_num_predictions = 1,
	}
	local runtime_profile = "basic"

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.dialog_util"] = {
		block_alert = function()
			if dialog_choice == "throw" then error("dialog exploded") end
			return dialog_choice
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(...)
			calls.notifications[#calls.notifications + 1] = {...}
			return true
		end,
	}
	package.loaded["ui.menu.menu_llm.profile_label"] = {
		format = function(label) return label end,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_num_predictions = 1 },
		get_active_profile = function() return {id = runtime_profile} end,
		set_active_profile = function(profile_id)
			calls.profiles[#calls.profiles + 1] = profile_id
			runtime_profile = profile_id
		end,
		set_llm_model_mlx = noop,
		set_llm_model_ollama = noop,
	}
	package.loaded["ui.menu.menu_llm.model_switcher"] = nil

	local switcher = require("ui.menu.menu_llm.model_switcher").new({
		state = state,
		models_mgr = {
			get_presets = function() return {} end,
			get_model_info = function()
				return { params = 3, type = "chat" }
			end,
			get_actual_model_name = function(name) return name end,
			check_requirements = function() end,
		},
		keymap = {},
		save_prefs = function()
			calls.saves = calls.saves + 1
			return true
		end,
		update_menu = function() calls.updates = calls.updates + 1 end,
	})

	return switcher, state, calls
end

helpers.describe("model switcher: suggested profile decision", function()
	helpers.it("leaves state and runtime untouched when the user refuses", function()
		local switcher, state, calls = build_fixture("button.cancel")

		helpers.assert_eq(switcher.apply_recommended_prompt_profile("candidate-model"), true)

		helpers.assert_eq(state.llm_active_profile, "basic")
		helpers.assert_eq(calls.profiles, {},
			"refusal must not reload the already-active profile into runtime")
		helpers.assert_eq(calls.saves, 0,
			"refusal must not publish an unchanged preference")
		helpers.assert_eq(calls.updates, 0,
			"refusal must not redraw an unchanged menu")
	end)

	helpers.it("sets, saves, and renders the accepted profile exactly once", function()
		local switcher, state, calls = build_fixture("button.confirm")

		helpers.assert_eq(switcher.apply_recommended_prompt_profile("candidate-model"), true)

		helpers.assert_eq(state.llm_active_profile, "advanced")
		helpers.assert_eq(calls.profiles, { "advanced" })
		helpers.assert_eq(calls.saves, 1)
		helpers.assert_eq(calls.updates, 1)
	end)

	helpers.it("reports a throwing profile dialog as a failed action", function()
		local switcher, state, calls = build_fixture("throw")

		helpers.assert_eq(switcher.apply_recommended_prompt_profile("candidate-model"), false)
		helpers.assert_eq(state.llm_active_profile, "basic")
		helpers.assert_eq(calls.profiles, {})
		helpers.assert_eq(calls.saves, 0)
		helpers.assert_eq(calls.updates, 0)
	end)

	helpers.it("reports No Model as a visible failed action", function()
		local switcher, state, calls = build_fixture("button.confirm")

		helpers.assert_eq(switcher.apply_recommended_prompt_profile(""), false)
		helpers.assert_eq(state.llm_active_profile, "basic")
		helpers.assert_eq(calls.profiles, {})
		helpers.assert_eq(calls.saves, 0)
		helpers.assert_eq(calls.updates, 0)
		helpers.assert_eq(#calls.notifications, 1)
		helpers.assert_eq(calls.notifications[1][1],
			"menu.profiles.recommended_unavailable_title")
		helpers.assert_eq(calls.notifications[1][3], "warning")
	end)
end)

return true
