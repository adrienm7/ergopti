--- tests/unit/ui/menu/menu_llm/test_llm_factory_identity_transaction.lua

--- ==============================================================================
--- MODULE: LLM Factory Identity Transaction
--- DESCRIPTION:
--- Exercises the real menu transaction with scoped dependencies and exact receipts.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

helpers.describe("LLM Factory Identity Transaction", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 aborts factory construction after backend setter " .. mode, function()
			with_activation("ollama", {true}, {
				backend_setter_mode = mode,
				runtime_backend = "mlx",
			}, function(action, state, calls)
				helpers.assert_eq(action, nil)
				helpers.assert_eq(state.llm_backend, "ollama")
				helpers.assert_eq(calls.runtime_backend(), "mlx",
					"the mutate-then-refuse backend setter must be compensated")
				helpers.assert_eq(calls.backend_setters, 2)
				helpers.assert_eq(calls.models_constructed or 0, 0)
				helpers.assert_eq(calls.switchers_constructed or 0, 0)
				helpers.assert_eq(#calls.display_models, 0)
			end)
		end)

		helpers.it("HS-012 blocks display successors after model setter " .. mode, function()
			with_activation("ollama", {true}, {
				model_setter_mode = mode,
				runtime_backend = "api",
			}, function(action, state, calls)
				helpers.assert_eq(action, nil)
				helpers.assert_eq(state.llm_model, "candidate-model")
				helpers.assert_eq(calls.model_setters, 2,
					"the mutate-then-refuse model setter must be compensated")
				helpers.assert_eq(calls.runtime_model(), "old-runtime",
					"compensation must restore the observed runtime predecessor, not the target preference")
				helpers.assert_eq(calls.runtime_backend(), "api",
					"a failed model acquisition must compensate the already-committed backend")
				helpers.assert_eq(calls.backend_setters, 2)
				helpers.assert_eq(calls.models_constructed, 1,
					"the resolver manager is the only allowed construction")
				helpers.assert_eq(calls.settings_constructed or 0, 0)
				helpers.assert_eq(calls.switchers_constructed or 0, 0)
				helpers.assert_eq(#calls.display_models, 0)
				helpers.assert_eq(calls.power_resolutions or 0, 0)
			end)
		end)
	end

	helpers.it("HS-012 yields backend compensation to a direct Core successor", function()
		with_activation("ollama", {true}, {
			backend_setter_mode = "false",
			backend_direct_successor = true,
			backend_direct_successor_target = "mlx",
			runtime_backend = "api",
		}, function(action, _, calls)
			helpers.assert_eq(action, nil)
			helpers.assert_eq(calls.nested_backend_result(), true)
			helpers.assert_eq(calls.backend_setters, 2,
				"the stale predecessor must not issue a third setter call over Core B")
			helpers.assert_eq(calls.runtime_backend(), "mlx")
			helpers.assert_eq(calls.models_constructed or 0, 0)
		end)
	end)

	helpers.it("HS-012 refuses a reentrant backend factory before stale rollback can clobber it", function()
		with_activation("ollama", {true}, {
			backend_setter_mode = "false",
			backend_reenter = true,
			backend_reenter_target = "mlx",
			runtime_backend = "api",
		}, function(action, _, calls)
			helpers.assert_eq(action, nil)
			helpers.assert_eq(calls.backend_setters, 2,
				"only the outer candidate and its exact predecessor compensation may reach Core")
			helpers.assert_eq(calls.runtime_backend(), "api")
			local nested = calls.nested_factory_result()
			helpers.assert_type(nested, "table")
			helpers.assert_eq(nested.build_item, nil,
				"the nested successor must fail closed while the predecessor callback is on-stack")
			helpers.assert_eq(calls.models_constructed or 0, 0,
				"neither refused factory may construct a model manager")
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 compensates No Model setter " .. mode .. " before successors", function()
			with_activation("ollama", {true}, {
				model = "",
				no_model_setter_mode = mode,
				runtime_model = "old-runtime",
				runtime_backend = "api",
			}, function(action, state, calls)
				helpers.assert_eq(action, nil)
				helpers.assert_eq(state.llm_model, "")
				helpers.assert_eq(calls.runtime_models, {"", "old-runtime"})
				helpers.assert_eq(calls.runtime_model(), "old-runtime")
				helpers.assert_eq(calls.runtime_backend(), "api")
				helpers.assert_eq(calls.backend_setters, 2)
				helpers.assert_eq(calls.models_constructed, 1)
				helpers.assert_eq(calls.settings_constructed or 0, 0)
				helpers.assert_eq(calls.switchers_constructed or 0, 0)
				helpers.assert_eq(#calls.display_models, 0)
				helpers.assert_eq(calls.power_resolutions or 0, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 compensates startup identities after profile constructor "
			.. mode, function()
			with_activation("ollama", {true}, {
				profile_constructor_mode = mode,
				runtime_backend = "api",
				runtime_model = "old-runtime",
			}, function(action, _, calls)
				helpers.assert_eq(action, nil)
				helpers.assert_eq(calls.profiles_constructed, 1)
				helpers.assert_eq(calls.runtime_model(), "old-runtime")
				helpers.assert_eq(calls.model_setters, 2)
				helpers.assert_eq(calls.runtime_backend(), "api")
				helpers.assert_eq(calls.backend_setters, 2)
				helpers.assert_eq(calls.runtime_display_model(), "old-display",
					"a refused initial profile identity must preserve the displayed predecessor")
				for _, displayed_model in ipairs(calls.display_models) do
					helpers.assert_eq(displayed_model, "old-display",
						"only exact predecessor compensation may reach the display boundary")
				end
			end)
		end)
	end
end)

return true
