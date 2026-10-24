--- tests/unit/infra/network/test_network_route_plan_contract.lua

--- ==============================================================================
--- MODULE: Test Network Route Plan Contract
--- DESCRIPTION:
--- Replays the shared per-origin route plan vectors under LuaJIT through the
--- actual driver path owner, so the Linux interpreter answers the same corpus
--- as macOS and the Go and shell twins before the plan reaches production here.
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
