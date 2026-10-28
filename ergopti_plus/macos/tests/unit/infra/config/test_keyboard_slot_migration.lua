--- tests/unit/infra/config/test_keyboard_slot_migration.lua

--- Replays the role-named keyboard slot migration contract through the macos gate.
local helpers = require("tests.helpers")

require("test.keyboard_slot_migration_contract").register(helpers, { driver = "hs" })
