--- tests/unit/infra/config/test_network_route_plan_contract.lua

--- ==============================================================================
--- MODULE: Test Network Route Plan Contract
--- DESCRIPTION:
--- Registers the shared per-origin route plan controls through the actual
--- driver path owner. The Go and shell twins answer the same vectors.
--- ==============================================================================

--- Register the exact shared route plan controls.
local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Contract = require("test.network_route_plan_contract")
local function read(relative)
    local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
    local bytes = file:read("*a")
    assert(file:close())
    return bytes
end
Contract.register(read, helpers)
