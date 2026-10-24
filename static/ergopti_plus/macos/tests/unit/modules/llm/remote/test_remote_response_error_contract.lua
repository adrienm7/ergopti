--- macos/tests/unit/modules/llm/remote/test_remote_response_error_contract.lua

--- ==============================================================================
--- MODULE: Remote Provider Error Envelopes (macOS)
--- DESCRIPTION:
--- Replays the shared response_error_contract that Linux already consumes. A
--- completion beside a top-level error field was returned as the answer on
--- macOS, so a provider's refusal could be typed into the user's document.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Remote provider error envelopes (macOS)", function()
	local contract = require("test.response_error_contract")
	local Classifier = require("llm.remote_response_classifier")
	helpers.it("executes every independent Lua response vector", function()
		helpers.assert_eq(#contract.vectors, 23)
	end)
	for _, vector in ipairs(contract.vectors) do
		helpers.it("provider response: " .. vector.name, function()
			helpers.assert_eq(Classifier.classify(vector.format, vector.body).text, vector.expected or "",
				vector.name)
		end)
	end
end)
