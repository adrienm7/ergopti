--- tests/unit/infra/test_config_migrate.lua

--- ==============================================================================
--- MODULE: Config Migration (macOS)
--- DESCRIPTION:
--- Runs the shared config migration contract with the macOS driver id: the
--- cross-driver corpus replayed through _shared/lua/config_migrate.lua, byte
--- preservation of every record no step touches, and the boot run's backup,
--- publication and read-only refusal of a newer file. It also pins where the
--- root boot runs the migration: before the first-run wizard can create the
--- file, and before config_overrides and Preferences read it.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.config_migrate_contract").register(helpers, { driver = "hs" })
require("test.config_migrate_records_contract").register(helpers, { driver = "hs" })
require("test.common_autocorrection_migration_contract").register(helpers, helpers.shared)

--- Returns root init.lua with line comments removed.
local function init_code()
	local source = helpers.read_driver_unit("local function abort_pre_runtime_boot")
	helpers.assert_true(type(source) == "string" and source ~= "",
		"root init.lua must remain discoverable by its pre-runtime abort boundary")
	return (source:gsub("%-%-[^\n]*", ""))
end

helpers.describe("config migration: root boot order (config-migrate-boot-order)", function()
	helpers.it("migrates config.toml before the first-run wizard and before any reader", function()
		local code = init_code()
		local migrate = code:find("ConfigMigrate.boot(", 1, true)
		local guard = code:find("onboarding_mod.should_run(cfg_path)", 1, true)
		local overrides = code:find("config_overrides.apply(", 1, true)
		local preferences = code:find("Preferences.load(", 1, true)
		helpers.assert_true(migrate and guard and overrides and preferences,
			"every boot marker must still exist")
		helpers.assert_true(migrate < guard and migrate < overrides and migrate < preferences,
			"the migration runs before the first-run wizard, config_overrides and Preferences")
		local _, calls = code:gsub("ConfigMigrate%.boot%(", "")
		helpers.assert_eq(calls, 1, "the boot migrates exactly once")
		local call = code:sub(migrate, (code:find("})", migrate, true) or migrate))
		helpers.assert_true(call:find("driver%s*=%s*\"hs\"") ~= nil,
			"the macOS boot migrates with its own driver id")
		helpers.assert_true(call:find("REGISTRY_PATH", 1, true) ~= nil,
			"the boot loads the shared registry")
		helpers.assert_true(call:find("ConfigTomlPath", 1, true) ~= nil,
			"the boot migrates the config.toml every reader uses")
	end)
end)
