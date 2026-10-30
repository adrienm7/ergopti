--- tests/unit/infra/field_check/test_field_check_storage.lua

--- ==============================================================================
--- MODULE: Field Run Storage Probe
--- DESCRIPTION:
--- The field run's storage check over scripted ports:
--- 1. the keystats database is opened read-only and without a lock (immutable
---    URI: a reader's shared lock failed the ingest's COMMIT with "database is
---    locked" on 2026-10-30 20:52:44) and passes only on SQLite's "ok"; an
---    issue counts only when a second scan sees it too (a lock-free scan can
---    race a write), a damaged one fails with the number of issue lines, never
---    their text, and a database not resolved yet or absent is skipped;
--- 2. each configuration file is its own step: absent is skipped, a parse
---    error fails that file only;
--- 3. a logs folder that refuses a write, a missing day log and unpublished
---    file watchers each fail their own step.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local DB = "/Users/someone/Library/Caches/ergopti_plus/metrics/db.sqlite"
local QUICK_CHECK = "/usr/bin/sqlite3 -readonly file:" .. DB .. "?immutable=1 PRAGMA quick_check;"

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
			local scripted = world.scans and table.remove(world.scans, 1) or world.sqlite
			callback(scripted[1], scripted[2], "")
		end,
		after = function(_, callback)
			world.waits = (world.waits or 0) + 1
			callback()
		end,
		config_files = function() return world.files end,
		parse_toml = function(path) return world.unparsable[path] == nil end,
		log_facts = function() return world.logs end,
		watcher_owners = function() return world.owners end,
		keystats_database = function() return world.database end,
		keystats_start_ms = function() return world.keystats_start_ms end,
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
	helpers.it("(keystats-start-ms) names how long the deferred keystats start held the main thread", function()
		local ports, world = make_ports()
		world.keystats_start_ms = 87.4
		local steps = run(ports)
		helpers.assert_eq(steps.keystats_start_ms.state, "info")
		helpers.assert_eq(steps.keystats_start_ms.value, "87", "ledger L18 asks for under 100 ms")
		world.keystats_start_ms = nil
		helpers.assert_eq(run(ports).keystats_start_ms.value, "not_started")
	end)

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

	helpers.it("names a lock-free scan that raced a write, and fails an issue seen twice", function()
		local ports, world = make_ports()
		world.scans = { { 0, "*** in database main ***\nPage 3 is never used\n" }, { 0, "ok\n" } }
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.keystats_db.value, "concurrent_write")
		helpers.assert_eq(#world.commands, 2)
		helpers.assert_eq(world.waits, 1)
		world.commands = {}
		world.scans = { { 0, "row 1 missing from index x\n" }, { 0, "row 1 missing from index x\n" } }
		steps = run(ports)
		helpers.assert_eq(steps.keystats_db.value, "issues_1")
	end)

	helpers.it("escapes the database path in the immutable URI", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["infra.field_check_probes"] = nil
			local Probes = require("infra.field_check_probes")
			helpers.assert_eq(Probes.immutable_uri("/a b/c%d?#.sqlite"), "file:/a%20b/c%25d%3F%23.sqlite?immutable=1")
		end)
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
