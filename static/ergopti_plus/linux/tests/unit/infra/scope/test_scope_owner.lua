--- tests/unit/infra/scope/test_scope_owner.lua

--- Replays the shared scope-owner protocol and checks the Linux owners install it.
local helpers = require("tests.helpers")
local Contract = require("test.scope_owner_contract")
Contract.register(helpers)
Contract.register_owners(helpers, { "infra.i18n", "infra.script_settings", "ui.error_dialog.bridge" })
