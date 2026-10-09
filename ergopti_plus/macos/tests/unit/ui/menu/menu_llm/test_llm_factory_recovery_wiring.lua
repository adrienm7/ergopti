--- tests/unit/ui/menu/menu_llm/test_llm_factory_recovery_wiring.lua

--- ==============================================================================
--- MODULE: LLM Factory Recovery Wiring
--- DESCRIPTION:
--- Exercises the real menu transaction with scoped dependencies and exact receipts.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

helpers.describe("LLM Factory Recovery Wiring", function()
	helpers.it("HS-034 forwards the live candidate recovery owner through the real factory", function()
		local candidate_calls = 0
		with_activation("ollama", {}, {
			candidate_recovery_gate = function()
				candidate_calls = candidate_calls + 1
				return false
			end,
		}, function(_, _, calls)
			helpers.assert_type(calls.switcher_ctx.profile_mutation_gate, "function")
			helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), false)
			helpers.assert_eq(candidate_calls, 1)

			calls.profile_deps.settle_profile_candidate_recovery = function()
				error("dynamic candidate gate", 0)
			end
			local throw_ok, throw_error = pcall(calls.switcher_ctx.profile_mutation_gate)
			helpers.assert_eq(throw_ok, false)
			helpers.assert_true(tostring(throw_error):find("dynamic candidate gate", 1, true) ~= nil)

			calls.profile_deps.settle_profile_candidate_recovery = function() return true end
			helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), true)
		end)
	end)

	helpers.it("HS-034 wires the live candidate gate to real switch and No Model entrypoints", function()
		local candidate_calls = 0
		local gate_result = false
		with_activation("ollama", {}, {
			real_switcher = true,
			candidate_recovery_gate = function()
				candidate_calls = candidate_calls + 1
				return gate_result
			end,
		}, function(_, _, calls)
			local selector = calls.models_selector_ctx
			helpers.assert_type(selector and selector.switch_model, "function")
			helpers.assert_type(selector and selector.disable_model, "function")
			local runtime_before = #calls.runtime_models
			local display_before = #calls.display_models

			helpers.assert_eq(selector.switch_model("replacement"), false)
			helpers.assert_eq(selector.disable_model(), false)
			helpers.assert_eq(candidate_calls, 2)
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(#calls.runtime_models, runtime_before)
			helpers.assert_eq(#calls.display_models, display_before)
			helpers.assert_eq(calls.saves, 0)
			helpers.assert_eq(calls.updates, 0)
		end)
	end)

	helpers.it("HS-034 rechecks the live factory gate at a real pending-model continuation", function()
		local gate_result = true
		with_activation("ollama", {}, {
			real_switcher = true,
			candidate_recovery_gate = function() return gate_result end,
		}, function(_, state, calls)
			local selector = calls.models_selector_ctx
			local runtime_before = #calls.runtime_models
			local display_before = #calls.display_models
			helpers.assert_eq(selector.switch_model("replacement"), true)
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_type(calls.requirements_ok, "function")

			gate_result = false
			helpers.assert_eq(calls.requirements_ok(), false)
			helpers.assert_eq(state.llm_model, "candidate-model")
			helpers.assert_eq(#calls.runtime_models, runtime_before)
			helpers.assert_eq(#calls.display_models, display_before)
			helpers.assert_eq(calls.saves, 0)
			helpers.assert_eq(calls.updates, 0)
		end)
	end)

	helpers.it("HS-033 wires both recovery owners through the real MenuLLM factory", function()
		local false_calls = 0
		with_activation("ollama", {}, {
			delete_recovery_gate = function()
				false_calls = false_calls + 1
				return false
			end,
		}, function(_, _, calls)
			helpers.assert_true(calls.profile_deps == calls.root_deps,
				"ProfilesManager must receive the exact shared dependency table")
			helpers.assert_type(calls.switcher_ctx.profile_mutation_gate, "function")
			helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), false)
			helpers.assert_eq(false_calls, 1)

			local throwing_gate = function() error("dynamic Delete gate", 0) end
			calls.profile_deps.settle_profile_delete_recovery = throwing_gate
			local throw_ok, throw_error = pcall(calls.switcher_ctx.profile_mutation_gate)
			helpers.assert_eq(throw_ok, false)
			helpers.assert_true(tostring(throw_error):find("dynamic Delete gate", 1, true) ~= nil)

			local true_calls = 0
			local true_gate = function()
				true_calls = true_calls + 1
				return true
			end
			calls.profile_deps.settle_profile_delete_recovery = true_gate
			helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), true)
			helpers.assert_eq(true_calls, 1,
				"the forwarding closure must read the live callback after construction")
			helpers.assert_true(calls.profile_deps.settle_llm_switcher_recovery
				== calls.switcher_settlement,
				"ProfilesManager must receive the exact ModelSwitcher settlement owner")
		end)
	end)

	helpers.it("HS-031 propagates the recommended-profile result through the menu adapter", function()
		with_activation("ollama", {}, {recommendation_result = false}, function(_, _, calls)
			helpers.assert_type(calls.profile_deps, "table")
			helpers.assert_type(calls.profile_deps.apply_recommended_prompt_profile, "function")
			helpers.assert_eq(calls.profile_deps.apply_recommended_prompt_profile({force_dialog = true}), false)
		end)
	end)

	helpers.it("(no-model-runtime) reapplies a persisted No Model identity after reload", function()
		with_activation("ollama", {}, { model = "" }, function(_, state, calls)
			helpers.assert_eq(state.llm_model, "")
			helpers.assert_eq(calls.runtime_models, { "" },
				"startup must override the prediction engine's backend default")
			helpers.assert_eq(calls.display_models, { "" })
		end)
	end)
end)

return true
