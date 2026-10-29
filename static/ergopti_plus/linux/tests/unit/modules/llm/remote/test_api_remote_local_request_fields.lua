--- tests/unit/modules/llm/remote/test_api_remote_local_request_fields.lua

--- ==============================================================================
--- MODULE: Local Server Request Fields On Linux
--- DESCRIPTION:
--- A hybrid reasoning model served by a local server (Qwen3.5 on oMLX, LM
--- Studio, llama.cpp...) wrote its reasoning as plain text until max_tokens ran
--- out, so a prediction got no answer. Every local server now receives the
--- shared local_servers.json request_fields (chat_template_kwargs with
--- enable_thinking false); a cloud provider never does.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Loads the module over an inert HTTP client.
--- @return table remote
local function load_remote()
	package.loaded["adapters.http_client"] = {
		get = function() return true end,
		post = function() return true end,
		cancel = function() return true end,
	}
	local remote = helpers.load_module("modules.llm.api_remote")
	remote._reset_for_test()
	return remote
end

local function unload()
	package.loaded["adapters.http_client"] = nil
	package.loaded["modules.llm.api_remote"] = nil
end

local MESSAGES = {
	{ role = "system", content = "Continue the text." },
	{ role = "user", content = "Bonjour, je voulais" },
}

helpers.describe("api_remote: local server request fields", function()

	helpers.it("every local server turns thinking off through its chat template", function()
		local remote = load_remote()
		local checked = 0
		for _, id in ipairs({ "omlx", "lmstudio", "llamacpp", "jan" }) do
			local request = assert(remote.build_request({ provider = id, model = "qwen3.5-4b", token = "" },
				MESSAGES, { max_tokens = 40 }))
			local body = Json.decode(request.body)
			helpers.assert_true(type(body.chat_template_kwargs) == "table",
				id .. " must receive chat_template_kwargs")
			helpers.assert_eq(body.chat_template_kwargs.enable_thinking, false,
				id .. " must receive enable_thinking=false")
			helpers.assert_true(request.body:find('"enable_thinking":false', 1, true) ~= nil,
				id .. " must send the literal JSON false")
			helpers.assert_eq(body.max_tokens, 40, "a request field never replaces the token budget")
			checked = checked + 1
		end
		unload()
		helpers.assert_eq(checked, 4)
	end)

	helpers.it("a cloud provider never receives the local request fields", function()
		local remote = load_remote()
		local request = assert(remote.build_request({ provider = "cerebras", token = "csk-1" }, MESSAGES, {}))
		unload()
		helpers.assert_true(Json.decode(request.body).chat_template_kwargs == nil,
			"chat_template_kwargs is for local servers only")
	end)

end)
