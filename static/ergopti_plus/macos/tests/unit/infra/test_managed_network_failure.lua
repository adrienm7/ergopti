--- tests/unit/infra/test_managed_network_failure.lua

--- ==============================================================================
--- MODULE: Shared Managed Network Failure Registration (macOS)
--- DESCRIPTION:
--- Uses the established test shared-resource resolver and automatically
--- discovers every portable classification and action control in this module.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Reads one corpus resource through the existing macOS test path owner.
--- @param relative string Shared resource path.
--- @return table
local function read(relative)
	local file = assert(io.open(helpers.shared(relative), "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return Json.decode(bytes)
end

helpers.describe("shared managed network failure contract", function()
	require("test.managed_network_contract").register(read, helpers)
end)
