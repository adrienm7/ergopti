--- tests/unit/infra/network/test_managed_network_failure.lua

--- ==============================================================================
--- MODULE: Shared Managed Network Failure Registration (Linux)
--- DESCRIPTION:
--- Reads canonical data and independent corpora through the native shared path
--- owner, then registers every portable classification and action control.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")

--- Reads one corpus resource through the existing Linux path owner.
--- @param relative string Shared resource path.
--- @return table
local function read(relative)
	local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return Json.decode(bytes)
end

helpers.describe("shared managed network failure contract", function()
	require("tests.lua.core.managed_network_contract").register(read, helpers)
end)
