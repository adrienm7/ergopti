--- tests/unit/infra/config/test_legacy_folder_migration.lua

--- ==============================================================================
--- MODULE: Legacy Folder Migration (Linux)
--- DESCRIPTION:
--- Replays the shared migration contract, then runs the Linux plan over an
--- in-memory home: the config, state and data folders of the old name merge
--- into the ergopti folder of the same XDG base, a clashing entry stays where it
--- was, the cache folder is created and the daemon runs it before its logger.
--- Nothing here touches a real user folder.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("test.legacy_folder_migration_contract")
local Migration = require("infra.legacy_folder_migration")
local AppDirs = require("app_dirs")

Contract.run(helpers, helpers.driver_root() .. "/../_shared")

local LEGACY = AppDirs.migration.linux.legacy_folder
local NAME = AppDirs.linux.folder_name

--- Config paths over a fixed fake home.
local fake_paths = {
	config_home = function() return "/home/u/.config" end,
	state_home = function() return "/home/u/.local/state" end,
	data_home = function() return "/home/u/.local/share" end,
	cache = function() return "/home/u/.cache/" .. NAME end,
}

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

helpers.describe("Linux legacy folder migration", function()
	helpers.it("merges each XDG base's old folder into its ergopti folder (legacy-folder-migration-linux)", function()
		local ports, snapshot = Contract.memory_ports({
			"/home/u/.config/" .. LEGACY .. "/storage.json",
			"/home/u/.config/" .. LEGACY .. "/api_keys.json",
			"/home/u/.config/" .. NAME .. "/config.toml",
			"/home/u/.config/" .. NAME .. "/api_keys.json",
			"/home/u/.local/state/" .. LEGACY .. "/logs/a.log",
			"/home/u/.local/share/" .. LEGACY .. "/runtimes/ollama/x",
		})
		local report = Migration.run({ config_paths = fake_paths, ports = ports })
		local after = table.concat(snapshot(), " ")
		helpers.assert_true(after:find("/home/u/.config/" .. NAME .. "/storage.json", 1, true) ~= nil,
			"the bootstrap storage moved beside the configuration")
		helpers.assert_true(after:find("/home/u/.config/" .. LEGACY .. "/api_keys.json", 1, true) ~= nil,
			"a clashing entry stays in the old folder")
		helpers.assert_true(after:find("/home/u/.local/state/" .. NAME .. "/logs/a.log", 1, true) ~= nil,
			"the logs moved with the state folder")
		helpers.assert_true(after:find("/home/u/.local/share/" .. NAME .. "/runtimes/ollama/x", 1, true) ~= nil,
			"the managed runtime moved with the data folder")
		helpers.assert_true(after:find("/home/u/.local/state/" .. LEGACY, 1, true) == nil,
			"an emptied old folder is removed")
		helpers.assert_true(after:find("/home/u/.cache/" .. NAME .. "/", 1, true) ~= nil, "the cache folder exists")
		helpers.assert_eq(#report.moved, 3, "storage, logs and runtimes moved")
		helpers.assert_eq(#report.kept, 1, "one entry kept")
		helpers.assert_true(report.cache_ready, "cache folder reported ready")
	end)

	helpers.it("logs every move and every kept entry", function()
		local lines = {}
		local logger = {
			info = function(_, fmt, ...) lines[#lines + 1] = "INFO " .. fmt:format(...) end,
			warn = function(_, fmt, ...) lines[#lines + 1] = "WARN " .. fmt:format(...) end,
		}
		Migration.log(logger, {
			moved = { { from = "/a", to = "/b" } },
			kept = { { from = "/c", to = "/d", reason = "destination_exists" } },
			removed = {},
			cache_ready = true,
		})
		helpers.assert_eq(#lines, 2)
		helpers.assert_true(lines[1]:find("^INFO Moved legacy folder entry /a to /b") ~= nil, lines[1])
		helpers.assert_true(lines[2]:find("^WARN Kept legacy folder entry /c") ~= nil, lines[2])
	end)

	helpers.it("runs before the logger sink and the bootstrap storage (legacy-folder-migration-boot-order)", function()
		local source = read(helpers.driver_root() .. "/ergopti_hotstrings.lua")
		local run_at = source:find("LegacyFolderMigration.run()", 1, true)
		local sink_at = source:find("LoggerSink.install(Logger)", 1, true)
		local log_at = source:find("LegacyFolderMigration.log(Logger", 1, true)
		helpers.assert_true(run_at ~= nil and sink_at ~= nil and log_at ~= nil, "the daemon runs and logs it")
		helpers.assert_true(run_at < sink_at, "the migration runs before the logger sink opens its folder")
		helpers.assert_true(sink_at < log_at, "its report is logged once the logger is ready")
		local storage_at = source:find('require("adapters.storage")', 1, true)
		helpers.assert_true(storage_at == nil or run_at < storage_at, "and before the bootstrap storage loads")
	end)
end)
