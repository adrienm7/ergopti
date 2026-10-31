--- tests/unit/infra/config/test_network_proxy_override_contract.lua

--- ==============================================================================
--- MODULE: Test Network Proxy Override Contract
--- DESCRIPTION:
--- Registers the shared proxy override controls through the actual driver
--- path owner: the macOS download preludes read the same setting.
--- ==============================================================================

--- Register the exact shared proxy override controls.
local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Contract = require("test.network_proxy_override_contract")
local function read(relative)
    local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
    local bytes = file:read("*a")
    assert(file:close())
    return bytes
end
Contract.register(read, helpers)
