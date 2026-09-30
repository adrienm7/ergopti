--- tests/unit/ui/menu/menu_llm/test_llm_activation_runtime_selection.lua

--- ==============================================================================
--- MODULE: AI Enable Selects Only Its Own Backend's Runtime
--- DESCRIPTION:
--- Enabling the AI selects its backend, so it is the one moment besides a
--- backend row that may install a runtime, and only that backend's runtime.
--- These cases drive the real menu toggle through the activation fixture:
--- 1. An API enable installs nothing and offers nothing.
--- 2. A declined Ollama offer keeps the AI off, durably, with one notice.
--- 3. An accepted offer installs Ollama exactly once, then checks the model.
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

	helpers.it("keeps the AI off, durably and with one notice, when the offer is declined", function()
		with_activation("ollama", { true, true }, {
			ollama_installed = false,
			ollama_offer_choice = "ollama.offer_website",
		}, function(action, state, calls)
			action()
			helpers.assert_eq(calls.offers, 1)
			helpers.assert_eq(calls.ollama_installs, 0, "a decline never downloads")
			helpers.assert_eq(state.llm_enabled, false, "a decline keeps the AI off")
			helpers.assert_eq(calls.saves, 2,
				"the enabled candidate must be durably compensated after the decline")
			helpers.assert_eq(calls.get_runtime_enabled(), false)
			helpers.assert_eq(calls.runtime_notices, { "ollama.runtime_missing_body" })
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end)

	helpers.it("installs Ollama once when the offer is accepted, then checks the model", function()
		with_activation("ollama", { true }, {
			ollama_installed = false,
			ollama_offer_choice = "ollama.offer_download",
		}, function(action, state, calls)
			action()
			helpers.assert_eq(calls.offers, 1)
			helpers.assert_eq(calls.ollama_installs, 1)
			helpers.assert_eq(calls.bootstrap, 0, "an Ollama enable must not bootstrap MLX")
			helpers.assert_eq(calls.requirements, 0,
				"the model check must wait for the accepted download")
			helpers.assert_type(calls.bootstrap_callback, "function")

			calls.bootstrap_callback(true)
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_eq(calls.ollama_installs, 1)
			helpers.assert_eq(state.llm_enabled, true)
		end)
	end)
end)
