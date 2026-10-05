--- tests/unit/infra/test_config_migrate.lua

--- ==============================================================================
--- MODULE: Config Migration (Linux)
--- DESCRIPTION:
--- Runs the shared config migration contract with the Linux driver id under
--- the Linux runner (LuaJIT in CI): the cross-driver corpus replayed through
--- _shared/lua/config_migrate.lua, byte preservation of every record no step
--- touches, and the boot run's backup, publication and read-only refusal of a
--- newer file. It also pins where the daemon runs the migration: at the top
--- of main(), before the hotstring, gesture and shortcut readers.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.config_migrate_contract").register(helpers, { driver = "linux" })
require("test.config_migrate_records_contract").register(helpers, { driver = "linux" })
require("test.common_autocorrection_migration_contract").register(helpers, require("infra.paths").shared)

--- The daemon entry point with line comments removed: main() cannot run
--- headless, so its order is read from the source.
local function daemon_code()
	local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local source = fh:read("*a")
	fh:close()
	return (source:gsub("%-%-[^\n]*", ""))
end

helpers.describe("config migration: daemon boot order (config-migrate-boot-order)", function()
	helpers.it("migrates config.toml at the start of main, before any config reader", function()
		local code = daemon_code()
		local main_at = code:find("local function main()", 1, true)
		local migrate = code:find("require(\"config_migrate\").boot(", 1, true)
		local hotstrings = code:find("hotstrings_config.init(", 1, true)
		local gestures = code:find("gestures.init({", 1, true)
		local shortcuts = code:find("shortcuts.init({", 1, true)
		helpers.assert_true(main_at and migrate and hotstrings and gestures and shortcuts,
			"every boot marker must still exist")
		helpers.assert_true(main_at < migrate and migrate < hotstrings and migrate < gestures
			and migrate < shortcuts,
			"the migration runs inside main, before the hotstring, gesture and shortcut readers")
		local _, calls = code:gsub("require%(\"config_migrate\"%)%.boot%(", "")
		helpers.assert_eq(calls, 1, "the daemon migrates exactly once")
		local call = code:sub(migrate, (code:find("})", migrate, true) or migrate))
		helpers.assert_true(call:find("driver%s*=%s*\"linux\"") ~= nil,
			"the daemon migrates with its own driver id")
		helpers.assert_true(call:find("REGISTRY_PATH", 1, true) ~= nil,
			"the daemon loads the shared registry")
	end)
end)
