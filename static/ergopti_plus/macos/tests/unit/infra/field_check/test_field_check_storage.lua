--- tests/unit/infra/field_check/test_field_check_storage.lua

--- ==============================================================================
--- MODULE: Field Run Storage Probe
--- DESCRIPTION:
--- The field run's storage check over scripted ports:
--- 1. the keystats database is opened read-only and passes only on SQLite's
---    "ok"; a damaged one fails with the number of issue lines, never their
---    text, and a database not resolved yet or absent is skipped;
--- 2. each configuration file is its own step: absent is skipped, a parse
---    error fails that file only;
--- 3. a logs folder that refuses a write, a missing day log and unpublished
---    file watchers each fail their own step.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local DB = "/Users/someone/Library/Caches/ergopti_plus/metrics/db.sqlite"
local QUICK_CHECK = "/usr/bin/sqlite3 -readonly " .. DB .. " PRAGMA quick_check;"

--- Builds scripted ports; `world` records every command.
--- @return table ports, table world
local function make_ports()
	local world = {
		commands = {},
		sqlite = { 0, "ok\n" },
		files = {
			{ name = "config_toml", path = "/c/config.toml", present = true },
			{ name = "personal_toml", path = "/c/personal.toml", present = false },
		},
		unparsable = {},
		logs = { today_present = true, writable = true, files = 6, bytes = 30 * 1048576 + 5 },
		owners = 1,
		database = { path = DB, present = true },
	}
	local ports = {
		exec = function(executable, args, timeout_s, callback)
			world.commands[#world.commands + 1] = { key = executable .. " " .. table.concat(args, " "), timeout = timeout_s }
			callback(world.sqlite[1], world.sqlite[2], "")
		end,
		config_files = function() return world.files end,
		parse_toml = function(path) return world.unparsable[path] == nil end,
		log_facts = function() return world.logs end,
		watcher_owners = function() return world.owners end,
		keystats_database = function() return world.database end,
	}
	return ports, world
end

--- Runs the check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("storage", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("storage probe", function()
	helpers.it("passes a healthy database, parsing files, writable logs and owned watchers", function()
		local ports, world = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.keystats_db.value, "quick_check_ok")
		helpers.assert_eq(world.commands[1].key, QUICK_CHECK, "the database must be opened read-only")
		helpers.assert_eq(steps.config_config_toml.value, "parsed")
		helpers.assert_eq(steps.config_personal_toml.state, "skip")
		helpers.assert_eq(steps.log_total_mb.value, "30")
		helpers.assert_eq(steps.log_files.value, "6")
		helpers.assert_eq(steps.file_watchers.value, "owners_1")
	end)

	helpers.it("fails a damaged database with a count, never its text", function()
		local ports, world = make_ports()
		world.sqlite = { 0, "*** in database main ***\nPage 12: btreeInitPage() returns error code 11\n" }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.keystats_db.value, "issues_2")
		world.sqlite = { 26, "" }
		helpers.assert_eq(run(ports).keystats_db.value, "exit_26")
		world.sqlite = { nil, "" }
		helpers.assert_eq(run(ports).keystats_db.value, "timeout")
	end)

	helpers.it("skips a database not resolved yet or absent", function()
		local ports, world = make_ports()
		world.database = { path = nil, present = false }
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.keystats_db.value, "not_initialized")
		helpers.assert_eq(#world.commands, 0)
		world.database = { path = DB, present = false }
		helpers.assert_eq(run(ports).keystats_db.value, "absent")
	end)

	helpers.it("fails only the file that does not parse", function()
		local ports, world = make_ports()
		world.files[2].present = true
		world.unparsable["/c/personal.toml"] = true
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.config_personal_toml.value, "parse_error")
		helpers.assert_eq(steps.config_config_toml.state, "pass")
	end)

	helpers.it("fails unwritable logs, a missing day log and unpublished watchers by name", function()
		local ports, world = make_ports()
		world.logs.writable = false
		helpers.assert_eq(run(ports).log_writable.state, "fail")
		world.logs.writable = true
		world.logs.today_present = false
		helpers.assert_eq(run(ports).log_today.value, "absent")
		world.logs.today_present = true
		world.owners = 0
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.file_watchers.value, "none")
	end)
end)
