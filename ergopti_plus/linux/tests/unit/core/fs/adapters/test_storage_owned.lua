--- tests/unit/core/fs/adapters/test_storage_owned.lua

--- Replays the shared owned-alias protocol and checks the Linux adapter installs it.
local helpers = require("tests.helpers")
local Contract = require("tests.lua.core_fs.storage_owned_contract")
Contract.register(helpers)
Contract.register_adapter(helpers)
