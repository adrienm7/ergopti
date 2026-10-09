--- tests/unit/llm/test_api_providers_test_request.lua

--- ==============================================================================
--- MODULE: Shared Test-Request Probe Catalogue Regression Tests
--- DESCRIPTION:
--- The api_providers.json test_request section (the exact minimal completion
--- both drivers send verbatim for the Test-API action) must publish exactly
--- when valid and degrade to nil otherwise — never crash the require chain
--- and never publish a half-valid probe.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Redirects the shared_llm_path to an in-memory JSON document.
--- @param json_content string File bytes.
--- @return string tmp path (caller removes it).
local function make_fake_path_stub(json_content)
	local tmp_path = os.tmpname() .. "_api_providers_test.json"
	local fh = io.open(tmp_path, "w")
	if fh then
		fh:write(json_content)
		fh:close()
	end
	package.loaded["infra.paths"] = {
		shared = function(rel) return helpers.shared(rel) end,
		shared_root = function() return helpers.shared() end,
		shared_llm_path = function(name)
			if name == "api_providers.json" then return tmp_path end
			return nil
		end,
		find_from_configdir = function() return nil end,
	}
	return tmp_path
end

local VALID = [[{
	"provider_order": ["openai"],
	"providers": {
		"openai": {
			"label": "OpenAI",
			"base_url": "https://api.openai.com/v1",
			"default_model": "gpt-4o-mini",
			"format": "openai"
		}
	},
	"model_prices": {},
	"test_request": {
		"system_prompt": "probe sys",
		"user_text": "ping",
		"temperature": 0,
		"max_tokens": 16
	}
}]]


helpers.describe("api_remote — shared test-request probe catalogue", function()

	helpers.it("publishes the probe exactly when valid", function()
		local tmp = make_fake_path_stub(VALID)
		package.loaded["modules.llm.api_remote"] = nil
		local ok, mod = pcall(require, "modules.llm.api_remote")
		pcall(os.remove, tmp)
		helpers.assert_true(ok, "valid catalogue must load")
		helpers.assert_true(type(mod.TEST_REQUEST) == "table",
			"a valid test_request section must publish")
		helpers.assert_eq(mod.TEST_REQUEST.system_prompt, "probe sys")
		helpers.assert_eq(mod.TEST_REQUEST.user_text, "ping")
		helpers.assert_eq(mod.TEST_REQUEST.temperature, 0)
		helpers.assert_eq(mod.TEST_REQUEST.max_tokens, 16)
		helpers.assert_type(mod.get_test_request_spec, "function")
		helpers.assert_true(mod.get_test_request_spec() == mod.TEST_REQUEST,
			"the panel accessor must expose the published probe")
	end)

	helpers.it("degrades to nil when the section is missing", function()
		local tmp = make_fake_path_stub([[{
			"provider_order": ["openai"],
			"providers": {
				"openai": {
					"label": "OpenAI",
					"base_url": "https://api.openai.com/v1",
					"default_model": "gpt-4o-mini",
					"format": "openai"
				}
			},
			"model_prices": {}
		}]])
		package.loaded["modules.llm.api_remote"] = nil
		local ok, mod = pcall(require, "modules.llm.api_remote")
		pcall(os.remove, tmp)
		helpers.assert_true(ok, "a missing section must not crash require")
		helpers.assert_true(mod.TEST_REQUEST == nil,
			"a missing test_request section must publish nothing")
	end)

	helpers.it("degrades to nil when the section is malformed", function()
		for _, bad_spec in ipairs({
			'{ "system_prompt": "", "user_text": "ping", "temperature": 0, "max_tokens": 16 }',
			'{ "system_prompt": "probe", "user_text": "ping", "temperature": "cold", "max_tokens": 16 }',
			'{ "system_prompt": "probe", "user_text": "ping", "temperature": 0, "max_tokens": 0 }',
		}) do
			local tmp = make_fake_path_stub(
				'{"provider_order": ["openai"], "providers": {"openai": {"label": "O", "base_url": "https://o.invalid", "default_model": "m", "format": "openai"}}, "model_prices": {}, "test_request": '
					.. bad_spec .. "}")
			package.loaded["modules.llm.api_remote"] = nil
			local ok, mod = pcall(require, "modules.llm.api_remote")
			pcall(os.remove, tmp)
			helpers.assert_true(ok, "a malformed section must not crash require: " .. bad_spec)
			helpers.assert_true(mod.TEST_REQUEST == nil,
				"a malformed test_request section must publish nothing: " .. bad_spec)
		end
	end)

end)
