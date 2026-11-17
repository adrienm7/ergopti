--- tests/unit/settings/scope/test_owner.lua

--- Replays the shared scope-owner protocol and checks the macOS owners install it.
local helpers = require("tests.helpers")
local Contract = require("tests.lua.settings.scope_owner_contract")
Contract.register(helpers)
Contract.register_owners(helpers, { "core.i18n.engine.i18n", "core.logger.engine.logger", "diagnostics.ui.error_dialog" })
