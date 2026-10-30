--- tests/unit/modules/llm/remote/test_api_remote_local_request_fields.lua

--- ==============================================================================
--- MODULE: Local Server Request Fields Regression Tests
--- DESCRIPTION:
--- Qwen3.5 served by oMLX wrote its reasoning as plain text, without <think>
--- tags, until max_tokens ran out: the parser found no answer and the stream
--- watchdog fired. Any hybrid reasoning model behaves so on any local server,
--- so every local server provider carries the shared local_servers.json
--- request_fields (chat_template_kwargs.enable_thinking=false) and the OpenAI
--- payload merges them. Cloud providers never receive them, and a field the
--- request already sets always wins.
--- ==============================================================================

local helpers = require("tests.helpers")
local Policy = require("llm.local_server_auth")


helpers.describe("api_remote.local_request_fields", function()

	helpers.it("every local server provider carries the thinking switch", function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local LocalServers = require("modules.llm.local_servers")
		helpers.assert_true(#LocalServers.ORDER > 0, "the shared catalogue lists local servers")
		for _, id in ipairs(LocalServers.ORDER) do
			local fields = api.PROVIDERS[id].request_fields
			helpers.assert_true(type(fields) == "table" and type(fields.chat_template_kwargs) == "table",
				id .. " must carry chat_template_kwargs")
			helpers.assert_eq(fields.chat_template_kwargs.enable_thinking, false,
				id .. " must turn thinking off")
		end
		for _, id in ipairs({ "openai", "cerebras", "anthropic" }) do
			helpers.assert_true(api.PROVIDERS[id] and api.PROVIDERS[id].request_fields == nil,
				id .. " is a cloud provider and must not carry local request fields")
		end
	end)

	helpers.it("merges the request fields into the openai payload as literal JSON", function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local JsonCodec = require("adapters.json_codec")
		local fields = api.PROVIDERS.omlx.request_fields
		local payload = api.__build_payload_for_test("openai", "qwen3.5-4b", "s", "u", 0.3, 40, nil, fields)
		helpers.assert_eq(payload.chat_template_kwargs.enable_thinking, false)
		helpers.assert_eq(payload.max_tokens, 40, "a request field never replaces the token budget")
		local encoded = assert(JsonCodec.encode(payload))
		helpers.assert_true(encoded:find('"enable_thinking":false', 1, true) ~= nil,
			"the server must read the JSON literal false, got " .. encoded)
		local bare = api.__build_payload_for_test("openai", "gpt-4o-mini", "s", "u", 0.3, 40, nil, nil)
		helpers.assert_true(bare.chat_template_kwargs == nil, "no request field without a local server")
		local anthropic = api.__build_payload_for_test("anthropic", "m", "s", "u", 0.3, 40, nil, fields)
		helpers.assert_true(anthropic.chat_template_kwargs == nil, "never in an anthropic body")
	end)

	helpers.it("a field the request already sets wins over the catalogue", function()
		local body = Policy.apply_request_fields({ model = "m", max_tokens = 4 },
			{ model = "x", max_tokens = 9000, extra = 1 })
		helpers.assert_eq(body.model, "m")
		helpers.assert_eq(body.max_tokens, 4)
		helpers.assert_eq(body.extra, 1)
	end)

	helpers.it("projects request fields fail-closed per field", function()
		local fields = Policy.request_fields({ request_fields = {
			_comment = "docs", list = { 1, 2 }, empty = {}, flag = true,
			nested = { a = { b = "c" } }, ["bad name"] = 1,
		} })
		helpers.assert_true(fields._comment == nil, "documentation keys are dropped")
		helpers.assert_true(fields.list == nil, "arrays are not plain request fields")
		helpers.assert_true(fields.empty == nil, "an empty object carries nothing")
		helpers.assert_true(fields["bad name"] == nil, "a name must be a JSON identifier")
		helpers.assert_eq(fields.flag, true)
		helpers.assert_eq(fields.nested.a.b, "c")
	end)

end)
