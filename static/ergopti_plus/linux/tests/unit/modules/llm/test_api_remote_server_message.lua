--- tests/unit/modules/llm/test_api_remote_server_message.lua

--- ==============================================================================
--- MODULE: Provider Error Message UTF-8 Boundaries
--- DESCRIPTION:
--- The public server-message extractor retains complete Unicode within its byte
--- ceiling and keeps existing source-field priority and ordinary diagnostics.
--- Native transport and public callback receipts live in the hardware fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Remote = helpers.load_module("modules.llm.api_remote")
local contract = require("tests.fixtures.llm_server_message_contract")

helpers.describe("Provider error message byte boundaries", function()
	assert(#contract.vectors == 45, "every independent provider-message vector executes")
	for _, vector in ipairs(contract.vectors) do
		helpers.it("server message byte boundary: " .. vector.name, function()
			local message = Remote.server_message(vector.body)
			local detail = "HTTP 401" .. (message and (": " .. message) or "")
			helpers.assert_eq(detail, vector.expected)
		end)
	end

	helpers.it("preserves malformed decoded source text before and after the byte ceiling", function()
		for _, source in ipairs({ "a\255tail", string.rep("a", 199) .. "é" .. "\255",
			string.rep("a", 201) .. "\255" }) do
			local body = '{"error":{"message":"' .. source .. '"}}'
			helpers.assert_eq(Remote.server_message(body), source:sub(1, 200))
		end
	end)

	helpers.it("keeps provider field priority and omission unchanged", function()
		helpers.assert_eq(Remote.server_message('{"error":{"message":"chosen"},"message":"decoy"}'), "chosen")
		helpers.assert_eq(Remote.server_message('{"error":{},"message":"root"}'), "root")
		helpers.assert_eq(Remote.server_message('{"error":"string","message":"root"}'), "root")
		for _, body in ipairs({ '{}', '{"error":false}', '{"error":null}', '{"error":{"message":0}}',
			'{"error":{"message":""},"message":"root"}', 'not JSON', '[]' }) do
			helpers.assert_nil(Remote.server_message(body), body)
		end
		helpers.assert_nil(Remote.server_message(nil))
	end)
end)
