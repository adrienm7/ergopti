--- tests/unit/ui/menu/llm/test_api_account_address.lua

--- ==============================================================================
--- MODULE: Per-Account API Addresses (Linux)
--- DESCRIPTION:
--- A provider whose address names the user's account (Azure resource, AWS
--- region, Cloudflare account id, Databricks workspace, Snowflake account)
--- writes a template in api_providers.json. The add-entry form asks one value
--- per placeholder, stores the filled address as the entry's base_url and
--- asks for the model, which such a provider never defaults; the catalogue
--- loader accepts the row without a default model; a request never goes to an
--- unfilled template.
---
--- ROOT CAUSE ENCODED:
--- These providers could only be reached through the generic OpenAI-compatible
--- entry, the user typing the whole address; the catalogue refused a row
--- without a default model.
--- ==============================================================================

package.loaded["tests.support.ui.menu.llm.llm_backend_rows_fixture"] = nil
local Fixture = require("tests.support.ui.menu.llm.llm_backend_rows_fixture")
local helpers, setup, find = Fixture.helpers, Fixture.setup, Fixture.find
local Json = require("json")

local AZURE = { id = "azure", label = "Azure OpenAI", base_url = "https://{resource}.openai.azure.com/openai/v1",
	default_model = "", format = "openai" }

--- Adds the Azure row to the scripted remote of the fixture.
local function with_azure()
	local remote = package.loaded["modules.llm.api_remote"]
	local providers, provider = remote.providers, remote.provider
	remote.providers = function()
		local list = providers()
		list[#list + 1] = AZURE
		return list
	end
	remote.provider = function(id) return id == "azure" and AZURE or provider(id) end
end





-- =========================================
-- =========================================
-- ======= 1/ The add-entry form ===========
-- =========================================
-- =========================================

helpers.describe("Per-account address: the form fills the template", function()
	helpers.it("asks the resource, the key and the model, and stores the filled address", function()
		local build, state, restore = setup("api")
		with_azure()
		state.answers = { " contoso ", "azure-key", "my-deployment" }
		find(build(), "➕ Azure OpenAI").action()
		restore()
		helpers.assert_eq(#state.prompts, 3, "resource, key, model: no URL prompt")
		helpers.assert_eq(state.prompts[1].text, require("infra.i18n").get("menu.llm.api_prompt_field.resource"))
		helpers.assert_eq(state.prompts[1].initial, "")
		helpers.assert_eq(state.prompts[2].hidden, true)
		helpers.assert_eq(state.prompts[3].initial, "", "no catalogue default model")
		helpers.assert_eq(#state.entries, 1)
		helpers.assert_eq(state.entries[1].base_url, "https://contoso.openai.azure.com/openai/v1")
		helpers.assert_eq(state.entries[1].model, "my-deployment")
		helpers.assert_eq(#state.errors, 0)
	end)

	helpers.it("refuses a value that would change the host, and saves nothing", function()
		local build, state, restore = setup("api")
		with_azure()
		state.answers = { "evil.example/x?", "azure-key", "my-deployment" }
		find(build(), "➕ Azure OpenAI").action()
		restore()
		helpers.assert_eq(#state.prompts, 1, "stops at the refused value")
		helpers.assert_eq(#state.errors, 1)
		helpers.assert_contains(state.errors[1], require("infra.i18n").get("menu.llm.api_prompt_field_invalid"))
		helpers.assert_eq(#state.entries, 0)
	end)

	helpers.it("saves nothing without a model, since none defaults", function()
		local build, state, restore = setup("api")
		with_azure()
		state.answers = { "contoso", "azure-key", "  " }
		find(build(), "➕ Azure OpenAI").action()
		restore()
		helpers.assert_eq(#state.entries, 0)
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ Catalogue and requests =======
-- =========================================
-- =========================================

helpers.describe("Per-account address: the catalogue row and its requests", function()
	local function catalogue(desc)
		local Remote = helpers.load_module("modules.llm.api_remote")
		return Remote.parse_catalogue(Json.encode({ provider_order = { "azure" }, providers = { azure = desc },
			model_prices = {} })), Remote
	end

	helpers.it("a template row without a default model is loaded", function()
		local parsed = catalogue(AZURE)
		helpers.assert_eq(parsed.order[1], "azure")
	end)

	helpers.it("a fixed address still needs its default model, and a stray brace is refused", function()
		local fixed = {}
		for key, value in pairs(AZURE) do fixed[key] = value end
		fixed.base_url = "https://api.example.com/v1"
		helpers.assert_eq(#catalogue(fixed).order, 0, "a fixed address without a default model")
		fixed.base_url = "https://{Resource}.example.com/v1"
		helpers.assert_eq(#catalogue(fixed).order, 0, "a brace outside a {name} placeholder")
	end)

	helpers.it("an entry without its filled address is refused before anything is sent", function()
		local Remote = helpers.load_module("modules.llm.api_remote")
		Remote._reset_for_test()
		local original = Remote.provider
		Remote.provider = function(id) return id == "azure" and AZURE or original(id) end
		local endpoint, reason = Remote.endpoint({ provider = "azure", token = "k", base_url = "" }, "my-deployment")
		local filled = Remote.endpoint({ provider = "azure", token = "k",
			base_url = "https://contoso.openai.azure.com/openai/v1" }, "my-deployment")
		Remote.provider = original
		helpers.assert_nil(endpoint)
		helpers.assert_contains(reason, "no account address")
		helpers.assert_eq(filled.url, "https://contoso.openai.azure.com/openai/v1/chat/completions")
		helpers.assert_eq(filled.headers.Authorization, "Bearer k")
	end)
end)
