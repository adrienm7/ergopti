--- tests/unit/modules/llm/remote/test_api_remote_server_message_utf8.lua

--- ==============================================================================
--- MODULE: Remote API Server-Message UTF-8 Boundary Regression Tests
--- DESCRIPTION:
--- The provider's own error text is bounded to 200 bytes for notifications and
--- logs. A raw byte cut split a multi-byte scalar in half whenever one straddled
--- byte 200, so the user saw an invalid UTF-8 tail (provider-message-utf8-2026-10-21).
--- The bound now keeps the longest complete prefix, matching Linux.
--- ==============================================================================

local helpers = require("tests.helpers")

local LIMIT = 200

--- Builds a provider body whose message places `scalar` across byte LIMIT.
--- @param shape string "error" or "root".
--- @param offset integer Bytes of the scalar before the boundary.
--- @param scalar string One multi-byte UTF-8 scalar.
--- @return string body, string expected
local function straddling(shape, offset, scalar)
	local lead = string.rep("a", LIMIT - offset)
	local message = lead .. scalar .. " after boundary"
	local body = shape == "error"
		and '{"error":{"message":"' .. message .. '"}}'
		or '{"message":"' .. message .. '"}'
	return body, lead
end


helpers.describe("api_remote: server message keeps whole UTF-8 scalars (provider-message-utf8-2026-10-21)", function()
	local api = helpers.load_with_stubs("modules.llm.api_remote")
	local extract = api.__extract_server_message_for_test

	for _, shape in ipairs({ "error", "root" }) do
		for _, scalar in ipairs({ "\195\169", "\230\188\162", "\240\159\152\128" }) do
			for offset = 1, #scalar - 1 do
				helpers.it(string.format("%s message: %d-byte scalar split after %d byte(s)", shape, #scalar, offset), function()
					local body, expected = straddling(shape, offset, scalar)
					local message = extract(body)
					helpers.assert_eq(message, expected,
						"the bound must drop the whole straddling scalar")
					helpers.assert_true(utf8.len(message) ~= nil, "the bounded message must stay valid UTF-8")
				end)
			end
		end
	end

	helpers.it("keeps a scalar that ends exactly on the boundary", function()
		local body = '{"error":{"message":"' .. string.rep("a", LIMIT - 2) .. "\195\169" .. 'tail"}}'
		helpers.assert_eq(extract(body), string.rep("a", LIMIT - 2) .. "\195\169")
	end)

	helpers.it("keeps the ordinary 200-byte ASCII ceiling", function()
		local body = '{"message":"' .. string.rep("b", LIMIT + 50) .. '"}'
		helpers.assert_eq(extract(body), string.rep("b", LIMIT))
	end)
end)
