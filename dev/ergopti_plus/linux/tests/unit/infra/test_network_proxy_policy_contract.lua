--- tests/unit/infra/test_network_proxy_policy_contract.lua

--- ==============================================================================
--- MODULE: Test Network Proxy Policy Contract
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- Register the exact shared policy controls through the actual driver path owner.
local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Contract = require("test.network_proxy_policy_contract")
local function read(relative)
    local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
    local bytes = file:read("*a")
    assert(file:close())
    return bytes
end
Contract.register_base(read, helpers)
Contract.register_bypass(read, helpers)
