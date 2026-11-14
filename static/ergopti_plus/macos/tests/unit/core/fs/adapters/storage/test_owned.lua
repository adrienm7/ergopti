--- tests/unit/core/fs/adapters/storage/test_owned.lua

--- Replays the shared owned-alias protocol and checks the macOS adapter installs it.
local helpers = require("tests.helpers")
local Contract = require("tests.lua.core_fs.storage_owned_contract")
Contract.register(helpers)
Contract.register_adapter(helpers)
