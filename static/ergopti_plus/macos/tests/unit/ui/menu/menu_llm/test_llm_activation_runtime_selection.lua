--- tests/unit/ui/menu/menu_llm/test_llm_activation_runtime_selection.lua

--- ==============================================================================
--- MODULE: AI Enable Selects Only Its Own Backend's Runtime
--- DESCRIPTION:
--- Enabling the AI selects its backend, so it is the one moment besides a
--- backend row that may install a runtime, and only that backend's runtime.
--- These cases drive the real menu toggle through the activation fixture:
--- 1. An API enable installs nothing and offers nothing.
--- 2. A declined Ollama install keeps the AI off, durably, with one explanation.
--- 3. An accepted install installs Ollama exactly once, then checks the model.
--- A missing Ollama is offered through the error that says it does not answer
--- (unreachable_backend_offer.lua, llm-enable-unreachable-local): its install
--- button is the consent, and the AI is never committed on before it.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

helpers.describe("AI enable installs only its backend's runtime (ai-runtime-enable)", function()
	helpers.it("installs nothing and offers nothing for a remote API backend", function()
		with_activation("api", { true }, { ollama_installed = false }, function(action, state, calls)
			action()
			helpers.assert_eq(state.llm_enabled, true)
			helpers.assert_eq(calls.bootstrap, 0, "an API enable must not bootstrap MLX")
			helpers.assert_eq(calls.ollama_installs, 0, "an API enable must not install Ollama")
			helpers.assert_eq(calls.offers, 0, "an API enable must not offer a download")
			helpers.assert_eq(calls.runtime_notices, {})
		end)
	end)

	helpers.it("keeps the AI off, durably and with one explanation, when the install is declined", function()
		with_activation("ollama", { true, true }, {
			ollama_installed = false,
			offer_pick = function() return nil end,
		}, function(action, state, calls)
			action()
			helpers.assert_eq(#calls.offer_dialogs, 1, "one error explains and offers the install")
			helpers.assert_true(calls.offer_dialogs[1].message:find("llm.unreachable.body_unconfirmed", 1, true) ~= nil,
				"the error says readiness is unconfirmed and the AI stays off")
			helpers.assert_eq(calls.offers, 0, "no second question")
			helpers.assert_eq(calls.ollama_installs, 0, "a decline never downloads")
			helpers.assert_eq(state.llm_enabled, false, "a decline keeps the AI off")
			helpers.assert_eq(calls.saves, 0,
				"durable by construction: the enabled candidate is never committed before the install")
			helpers.assert_eq(calls.get_runtime_enabled(), false)
			helpers.assert_eq(calls.runtime_notices, {}, "the dialog was the one explanation")
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end)

	helpers.it("installs Ollama once when the install is accepted, then checks the model", function()
		with_activation("ollama", { true }, {
			ollama_installed = false,
			version_receipts = {
				{ ok = false, status = 0, body = "" },
				{ ok = true, status = 200, body = '{"version":"post-install-native-fixture"}' },
			},
			offer_pick = function() return 1 end,
		}, function(action, state, calls)
			action()
			helpers.assert_eq(#calls.offer_dialogs, 1)
			helpers.assert_eq(calls.offer_dialogs[1].choices, { "llm.unreachable.install|Ollama" })
			helpers.assert_eq(calls.offers, 0, "the install button was the consent")
			helpers.assert_eq(calls.ollama_installs, 1)
			helpers.assert_eq(calls.bootstrap, 0, "an Ollama enable must not bootstrap MLX")
			helpers.assert_eq(calls.requirements, 0,
				"the model check must wait for the accepted download")
			helpers.assert_type(calls.bootstrap_callback, "function")

			helpers.assert_eq(calls.saves, 0, "AI remains off until actual repair acknowledgement and a fresh version receipt")
			helpers.assert_eq(state.llm_enabled, false)
			calls.bootstrap_callback(true)
			helpers.assert_eq(calls.service_repairs, 1)
			helpers.assert_eq(#calls.version_requests, 2)
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_eq(calls.ollama_installs, 1)
			helpers.assert_eq(state.llm_enabled, true)
		end)
	end)
end)
