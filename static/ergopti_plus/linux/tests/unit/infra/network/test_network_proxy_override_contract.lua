--- tests/unit/infra/network/test_network_proxy_override_contract.lua

--- ==============================================================================
--- MODULE: Test Network Proxy Override Contract
--- DESCRIPTION:
--- Registers the shared proxy override controls through the actual Linux path
--- owner: the Linux proxy policy binding hands the stored override to every
--- managed download and to the managed Ollama daemon.
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
