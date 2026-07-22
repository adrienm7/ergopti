--- tests/unit/llm/test_llm_api_providers.lua
local helpers = require("tests.helpers")

-- Bootstrap the hs stub so hs.json.decode is available
package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")

-- Load the module. This will trigger load_api_providers() internally
-- which reads static/ergopti_plus/_shared/modules/llm/api_providers.json
local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote")

helpers.describe("LLM API Providers Catalogue", function()
	helpers.it("loads providers from api_providers.json", function()
		helpers.assert_true(type(ApiRemote.PROVIDERS) == "table", "PROVIDERS should be a table")
		helpers.assert_true(ApiRemote.PROVIDERS["openai"] ~= nil, "OpenAI provider must exist")
		helpers.assert_true(ApiRemote.PROVIDERS["anthropic"] ~= nil, "Anthropic provider must exist")
	end)

	helpers.it("loads provider order", function()
		helpers.assert_true(type(ApiRemote.PROVIDER_ORDER) == "table", "PROVIDER_ORDER should be a table")
		helpers.assert_true(#ApiRemote.PROVIDER_ORDER >= 3, "PROVIDER_ORDER should have multiple entries")
		helpers.assert_eq(ApiRemote.PROVIDER_ORDER[1], "openai", "First provider should be openai")
	end)
end)
