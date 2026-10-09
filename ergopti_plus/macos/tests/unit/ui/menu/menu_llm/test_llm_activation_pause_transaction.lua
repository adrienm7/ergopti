--- tests/unit/ui/menu/menu_llm/test_llm_activation_pause_transaction.lua

--- ==============================================================================
--- MODULE: LLM Activation Pause Transaction
--- DESCRIPTION:
--- Exercises the real menu transaction with scoped dependencies and exact receipts.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

helpers.describe("LLM Activation Pause Transaction", function()
	helpers.it("stages an MLX bootstrap continuation until real ScriptControl commits RESUMED", function()
		with_activation("mlx", { true }, {
			real_script_control = true,
		}, function(action, state, calls)
			local script_control = calls.script_control
			helpers.assert_eq(action(), true)
			local bootstrap_callback = calls.bootstrap_callback

			helpers.assert_eq(script_control.pause_all(), true)
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(bootstrap_callback(true), true)
			helpers.assert_eq(calls.requirements, 0,
				"the bootstrap terminal must be retained while activation is fenced")

			helpers.assert_eq(script_control.resume_all(), true)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(#calls.resume_timers, 1)
			local committed_stage = calls.resume_timers[1]
			committed_stage.timer = nil
			committed_stage.callback()
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_type(calls.requirements_opts.is_current, "function")
			helpers.assert_eq(calls.requirements_opts.is_current(), true)
			helpers.assert_eq(calls.notifications, 1)
			helpers.assert_eq(committed_stage.callback(), nil)
			helpers.assert_eq(calls.requirements, 1,
				"a duplicate post-commit stage cannot dispatch a sibling")
			helpers.assert_eq(state.llm_enabled, true)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact activation stage when rollback cancel returns "
			.. mode, function()
			with_activation("mlx", { true }, {
				real_script_control = true,
			}, function(action, _, calls)
				local script_control = calls.script_control
				local resume_failures = 1
				helpers.assert_eq(script_control.register_pause_owner("llm_model_switcher", {
					pause = function() return true end,
					resume = function()
						if resume_failures == 0 then return true end
						resume_failures = resume_failures - 1
						if mode == "throw" then error("later resume owner exploded") end
						if mode == "false" then return false end
						return nil
					end,
				}), true)
				helpers.assert_eq(action(), true)
				helpers.assert_eq(script_control.pause_all(), true)
				calls.bootstrap_callback(true)

				calls.set_timer_cancel_mode(mode)
				helpers.assert_eq(script_control.resume_all(), false)
				helpers.assert_eq(script_control.is_paused(), true)
				local retained_stage = calls.resume_timers[1]
				helpers.assert_eq(calls.timer_cancel_handles[1], retained_stage)
				retained_stage.callback()
				helpers.assert_eq(calls.requirements, 0)

				calls.set_timer_cancel_mode("true")
				helpers.assert_eq(script_control.resume_all(), true)
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(calls.timer_cancel_handles[#calls.timer_cancel_handles],
					retained_stage, "resume retry must settle the same timer handle")
				helpers.assert_eq(#calls.resume_timers, 2)
				local successor = calls.resume_timers[2]
				successor.timer = nil
				successor.callback()
				helpers.assert_eq(calls.requirements, 1)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("replays a requirements success after a later pause owner " .. mode, function()
			with_activation("ollama", { true, true, true }, {
				real_script_control = true,
			}, function(action, state, calls)
				local script_control = calls.script_control
				helpers.assert_eq(action(), true)
				helpers.assert_eq(calls.requirements, 1)
				helpers.assert_eq(calls.notifications, 1)

				helpers.assert_eq(script_control.register_pause_owner("llm_model_switcher", {
					pause = function()
						calls.requirements_ok()
						if mode == "throw" then error("later pause owner exploded") end
						if mode == "false" then return false end
						return nil
					end,
					resume = function() return true end,
				}), true)
				helpers.assert_eq(script_control.pause_all(), true,
					"the synchronous drain accepts the request before local rollback reports failure")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(calls.requirements, 1,
					"the manager's consumed success may not be redispatched")
				helpers.assert_eq(calls.requirements_ok(), false,
					"the retained terminal must remain one-shot after rollback")

				helpers.assert_eq(action(), true)
				helpers.assert_eq(state.llm_enabled, false)
				helpers.assert_eq(action(), true,
					"the completed activation token must not block the next enable")
				helpers.assert_eq(calls.requirements, 2)
			end)
		end)
	end

	helpers.it("settles a token superseded by Disable All before the next enable", function()
		with_activation("mlx", { true, true }, nil, function(action, state, calls)
			helpers.assert_eq(action(), true)
			local stale_bootstrap = calls.bootstrap_callback
			state.llm_enabled = false
			helpers.assert_eq(calls.handler.set_llm_preference_runtime(false), true)
			helpers.assert_eq(calls.get_runtime_enabled(), false)
			helpers.assert_eq(stale_bootstrap(true), true)
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)

			helpers.assert_eq(action(), true,
				"a shared disable must not leave an activation token that rejects begin")
			helpers.assert_eq(calls.bootstrap, 2)
			local replacement_bootstrap = calls.bootstrap_callback
			helpers.assert_true(replacement_bootstrap ~= stale_bootstrap)
			helpers.assert_eq(replacement_bootstrap(true), true)
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_eq(calls.notifications, 1)
			helpers.assert_eq(state.llm_enabled, true)
		end)
	end)
end)

return true
