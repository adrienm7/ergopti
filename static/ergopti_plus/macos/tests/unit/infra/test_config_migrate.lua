--- tests/unit/infra/test_config_migrate.lua

--- ==============================================================================
--- MODULE: Config Migration (macOS)
--- DESCRIPTION:
--- Runs the shared config migration contract with the macOS driver id: the
--- cross-driver corpus replayed through _shared/lua/config_migrate.lua, byte
--- preservation of every record no step touches, and the boot run's backup,
--- publication and read-only refusal of a newer file.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.config_migrate_contract").register(helpers, { driver = "hs" })
