--- tests/unit/adapters/storage/test_storage_owned.lua

--- Replays the shared owned-alias protocol and checks the macOS adapter installs it.
local helpers = require("tests.helpers")
local Contract = require("test.storage_owned_contract")
Contract.register(helpers)
Contract.register_adapter(helpers)
