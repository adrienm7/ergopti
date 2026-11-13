--- tests/unit/infra/config/test_legacy_folder_migration.lua

--- ==============================================================================
--- MODULE: Legacy Folder Migration (Linux)
--- DESCRIPTION:
--- Replays the shared migration contract, then runs the Linux plan over an
--- in-memory home: the config, state and data folders of the old name merge
--- into the ergopti folder of the same XDG base, a clashing entry goes to the
--- backup folder of that base, the cache folder is created and the daemon runs
--- it before its logger.
--- Nothing here touches a real user folder.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.lua.settings.legacy_folder_migration_contract")
local Migration = require("infra.legacy_folder_migration")
local AppDirs = require("core.fs.engine.app_dirs")

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

--- A private scratch folder for the native-port cases, removed by `drop`.
--- @return string dir
local function scratch()
	local dir = os.tmpname()
	os.remove(dir)
	assert(os.execute("mkdir -p -- '" .. dir .. "'"))
	return dir
end

local function drop(dir) os.execute("rm -rf -- '" .. dir .. "'") end

local function write(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

helpers.describe("Linux legacy folder migration", function()
	helpers.it("merges each XDG base's old folder into its ergopti folder (legacy-folder-migration-linux)", function()
		local ports, snapshot = Contract.memory_ports({
			"/home/u/.config/" .. LEGACY .. "/",
			"/home/u/.local/state/" .. LEGACY .. "/",
			"/home/u/.local/share/" .. LEGACY .. "/",
			"/home/u/.config/" .. LEGACY .. "/storage.json",
			"/home/u/.config/" .. LEGACY .. "/api_keys.json",
			"/home/u/.config/" .. NAME .. "/config.toml",
			"/home/u/.config/" .. NAME .. "/api_keys.json",
			"/home/u/.local/state/" .. LEGACY .. "/logs/a.log",
			"/home/u/.local/share/" .. LEGACY .. "/runtimes/ollama/x",
		})
		local report = Migration.run({ config_paths = fake_paths, ports = ports,
			storage = { get = function(_, default) return default end, set = function() return true end } })
		local after = table.concat(snapshot(), " ")
		helpers.assert_true(after:find("/home/u/.config/" .. NAME .. "/storage.json", 1, true) ~= nil,
			"the bootstrap storage moved beside the configuration")
		helpers.assert_true(after:find("/home/u/.config/" .. NAME .. "/" .. AppDirs.migration.backup_folder .. "/"
			.. LEGACY .. "/api_keys.json", 1, true) ~= nil, "a clashing entry goes to the backup folder")
		helpers.assert_true(after:find("/home/u/.config/" .. LEGACY, 1, true) == nil,
			"the old configuration folder is gone")
		helpers.assert_true(after:find("/home/u/.local/state/" .. NAME .. "/logs/a.log", 1, true) ~= nil,
			"the logs moved with the state folder")
		helpers.assert_true(after:find("/home/u/.local/share/" .. NAME .. "/runtimes/ollama/x", 1, true) ~= nil,
			"the managed runtime moved with the data folder")
		helpers.assert_true(after:find("/home/u/.local/state/" .. LEGACY, 1, true) == nil,
			"an emptied old folder is removed")
		helpers.assert_true(after:find("/home/u/.cache/" .. NAME .. "/", 1, true) ~= nil, "the cache folder exists")
		helpers.assert_eq(#report.moved, 3, "storage, logs and runtimes moved")
		helpers.assert_eq(#report.backed_up, 1, "one entry backed up")
		helpers.assert_eq(#report.kept, 0, "nothing left behind")
		helpers.assert_true(report.cache_ready, "cache folder reported ready")
	end)

	helpers.it("keeps a file published after the check, on real folders (legacy-folder-migration-linux-race)", function()
		local dir = scratch()
		local ok, err = pcall(function()
			assert(os.execute("mkdir -p -- '" .. dir .. "/old' '" .. dir .. "/new'"))
			write(dir .. "/old/storage.json", "LEGACY")
			local ports = Migration.native_ports()
			local rename = ports.rename
			ports.rename = function(from, to)
				-- Another writer publishes the destination between the check and the rename.
				if to == dir .. "/new/storage.json" then write(to, "CONCURRENT-NEW") end
				return rename(from, to)
			end
			local report = require("settings.engine.migration.legacy_folder_migration_core").apply({
				{ from_dir = dir .. "/old", to_dir = dir .. "/new", backup_dir = dir .. "/new/bak/old" } }, ports)
			helpers.assert_eq(read(dir .. "/new/storage.json"), "CONCURRENT-NEW", "the newer file survives")
			helpers.assert_eq(read(dir .. "/new/bak/old/storage.json"), "LEGACY", "the old file went to the backup")
			helpers.assert_eq(#report.moved, 0, "no move reported over the newer file")
			helpers.assert_eq(#report.backed_up, 1, "the backup is reported")
		end)
		drop(dir)
		assert(ok, err)
	end)

	helpers.it("lists exact names and reports an unlistable folder, on real folders (legacy-folder-migration-linux-list)",
		function()
		local dir = scratch()
		local ok, err = pcall(function()
			assert(os.execute("mkdir -p -- '" .. dir .. "/old' '" .. dir .. "/new'"))
			-- A newline is a legal filename byte: line-split listing invented two names.
			write(dir .. "/old/line\nbreak", "NL")
			write(dir .. "/notdir", "FILE")
			local Core = require("settings.engine.migration.legacy_folder_migration_core")
			local ports = Migration.native_ports()
			local report = Core.apply({
				{ from_dir = dir .. "/old", to_dir = dir .. "/new", backup_dir = dir .. "/new/bak/old" },
				{ from_dir = dir .. "/notdir", to_dir = dir .. "/new", backup_dir = dir .. "/new/bak/notdir" },
			}, ports)
			helpers.assert_eq(read(dir .. "/new/line\nbreak"), "NL", "the newline-named entry moved")
			helpers.assert_eq(#report.moved, 1, "one move")
			helpers.assert_eq(#report.removed, 1, "the emptied old folder is removed")
			helpers.assert_eq(#report.kept, 1, "the unlistable source is reported")
			helpers.assert_eq(report.kept[1].reason, "list_failed", "not read as an empty folder")
			helpers.assert_eq(read(dir .. "/notdir"), "FILE", "and left untouched")
		end)
		drop(dir)
		assert(ok, err)
	end)

	helpers.it("reports a folder the user cannot read (legacy-folder-migration-linux-permission)", function()
		local id = io.popen("id -u")
		local uid = id and id:read("*l")
		if id then id:close() end
		-- root reads any folder, so the refusal exists only for an ordinary user.
		if uid == "0" then return end
		local dir = scratch()
		local ok, err = pcall(function()
			assert(os.execute("mkdir -p -- '" .. dir .. "/old' '" .. dir .. "/new'"))
			write(dir .. "/old/storage.json", "LEGACY")
			assert(os.execute("chmod 000 -- '" .. dir .. "/old'"))
			local report = require("settings.engine.migration.legacy_folder_migration_core").apply({
				{ from_dir = dir .. "/old", to_dir = dir .. "/new", backup_dir = dir .. "/new/bak/old" } },
				Migration.native_ports())
			assert(os.execute("chmod 700 -- '" .. dir .. "/old'"))
			helpers.assert_eq(#report.kept, 1, "the refusal is reported")
			helpers.assert_eq(report.kept[1].reason, "list_failed", "not read as an empty folder")
			helpers.assert_eq(read(dir .. "/old/storage.json"), "LEGACY", "the old entry stays")
		end)
		os.execute("chmod 700 -- '" .. dir .. "/old' 2>/dev/null")
		drop(dir)
		assert(ok, err)
	end)

	helpers.it("leaves a legacy folder linked to the current one, on real folders (legacy-folder-migration-linux-alias)",
		function()
		local dir = scratch()
		local ok, err = pcall(function()
			local base = dir .. "/config"
			assert(os.execute("mkdir -p -- '" .. base .. "/" .. NAME .. "'"))
			write(base .. "/" .. NAME .. "/config.toml", "ACTIVE")
			assert(os.execute("ln -s -- '" .. base .. "/" .. NAME .. "' '" .. base .. "/" .. LEGACY .. "'"))
			local paths = {
				config_home = function() return base end,
				state_home = function() return dir .. "/state" end,
				data_home = function() return dir .. "/data" end,
				cache = function() return dir .. "/cache/" .. NAME end,
			}
			for _ = 1, 2 do
				local report = Migration.run({ config_paths = paths,
					storage = { get = function(_, default) return default end, set = function() return true end } })
				helpers.assert_eq(read(base .. "/" .. NAME .. "/config.toml"), "ACTIVE", "the live file stays")
				helpers.assert_eq(#report.aliased, 1, "the link is recognised as the current folder")
				helpers.assert_eq(#report.backed_up + #report.kept + #report.moved, 0, "nothing is archived")
			end
		end)
		drop(dir)
		assert(ok, err)
	end)

	helpers.it("follows a configuration folder chosen inside the old folder (legacy-folder-migration-linux-locator)",
		function()
		local old_custom = "/home/u/.config/" .. LEGACY .. "/custom"
		local new_custom = "/home/u/.config/" .. NAME .. "/custom"
		local function storage(values, accepts)
			return {
				get = function(key, default) local value = values[key]; if value == nil then return default end; return value end,
				set = function(key, value) if not accepts then return false end; values[key] = value; return true end,
			}
		end
		local values = { ["paths.config_dir"] = old_custom, [AppDirs.linux_storage_key] = "/home/u/Documents/logs" }
		local ports, snapshot = Contract.memory_ports({ old_custom .. "/config.toml", "/home/u/.config/" .. LEGACY .. "/storage.json" })
		local report = Migration.run({ config_paths = fake_paths, ports = ports, storage = storage(values, true) })
		helpers.assert_true(table.concat(snapshot(), " "):find(new_custom .. "/config.toml", 1, true) ~= nil,
			"the chosen folder moved")
		helpers.assert_eq(values["paths.config_dir"], new_custom, "the bootstrap setting names it where it went")
		helpers.assert_eq(values[AppDirs.linux_storage_key], "/home/u/Documents/logs", "an outside folder is untouched")
		helpers.assert_eq(#report.relocated, 1, "the relocation is reported")

		values = { ["paths.config_dir"] = old_custom }
		ports, snapshot = Contract.memory_ports({ old_custom .. "/config.toml" })
		report = Migration.run({ config_paths = fake_paths, ports = ports, storage = storage(values, false) })
		helpers.assert_eq(values["paths.config_dir"], old_custom, "a refused setting keeps its value")
		helpers.assert_true(table.concat(snapshot(), " "):find(old_custom .. "/config.toml", 1, true) ~= nil,
			"and the folder moves back to the path it names")
		helpers.assert_eq(#report.restored, 1, "the move back is reported")
		local lines = {}
		Migration.log({ info = function() end, warn = function(_, fmt, ...) lines[#lines + 1] = fmt:format(...) end },
			report)
		local logged = table.concat(lines, "\n")
		helpers.assert_true(logged:find("back to " .. old_custom, 1, true) ~= nil, "the move back is warned")
		helpers.assert_true(logged:find("paths.toml", 1, true) == nil, "naming the Linux locator, not paths.toml")
	end)

	helpers.it("renames a custom logs folder named like the old folder and moves its logs (legacy-folder-migration-linux-custom-logs)",
		function()
		local function storage(values, accepts)
			return {
				get = function(key, default) local value = values[key]; if value == nil then return default end; return value end,
				set = function(key, value) if not accepts then return false end; values[key] = value; return true end,
			}
		end
		for _, value in ipairs({ "/data/" .. LEGACY, "/data/" .. LEGACY .. "/" .. NAME, "/data/" .. LEGACY .. "/" }) do
			local values = { [AppDirs.linux_storage_key] = value }
			local ports, snapshot = Contract.memory_ports({
				"/data/" .. LEGACY .. "/" .. NAME .. "/ErgoptiPlus_2026-11-05.log",
				"/data/" .. LEGACY .. "/notes.txt",
			})
			local report = Migration.run({ config_paths = fake_paths, ports = ports, storage = storage(values, true) })
			local after = " " .. table.concat(snapshot(), " ") .. " "
			helpers.assert_eq(values[AppDirs.linux_storage_key], "/data/" .. NAME, value)
			helpers.assert_true(after:find(" /data/" .. NAME .. "/ErgoptiPlus_2026-11-05.log ", 1, true) ~= nil,
				"the logs follow: " .. after)
			helpers.assert_true(after:find(" /data/" .. LEGACY .. "/notes.txt ", 1, true) ~= nil, "the user's files stay")
			helpers.assert_eq(#report.relocated, 1)
		end
		-- A refused setting moves nothing.
		local values = { [AppDirs.linux_storage_key] = "/data/" .. LEGACY }
		local ports, snapshot = Contract.memory_ports({ "/data/" .. LEGACY .. "/" .. NAME .. "/a.log" })
		local report = Migration.run({ config_paths = fake_paths, ports = ports, storage = storage(values, false) })
		helpers.assert_eq(values[AppDirs.linux_storage_key], "/data/" .. LEGACY)
		helpers.assert_true(table.concat(snapshot(), " "):find("/data/" .. LEGACY .. "/" .. NAME .. "/a.log", 1, true) ~= nil)
		helpers.assert_eq(report.kept[#report.kept].reason, "refused")
	end)

	helpers.it("keeps any other custom logs folder (legacy-folder-migration-linux-custom-kept)", function()
		for _, value in ipairs({ "/data/logs", "/data/logs/" .. NAME, "/data/" .. LEGACY .. "_old", "/data/" .. LEGACY .. "/sub",
			LEGACY, "" }) do
			helpers.assert_nil(Migration.custom_legacy_logs(value), value)
		end
		local values = { [AppDirs.linux_storage_key] = "/data/logs/" .. NAME }
		local ports = Contract.memory_ports({ "/data/logs/" .. NAME .. "/a.log" })
		Migration.run({ config_paths = fake_paths, ports = ports, storage = {
			get = function(key, default) return values[key] or default end,
			set = function() error("an unrelated custom folder must not be stored") end,
		} })
		helpers.assert_eq(values[AppDirs.linux_storage_key], "/data/logs/" .. NAME)
	end)

	helpers.it("logs every move, backup and kept entry", function()
		local lines = {}
		local logger = {
			info = function(_, fmt, ...) lines[#lines + 1] = "INFO " .. fmt:format(...) end,
			warn = function(_, fmt, ...) lines[#lines + 1] = "WARN " .. fmt:format(...) end,
		}
		Migration.log(logger, {
			moved = { { from = "/a", to = "/b" } },
			backed_up = { { from = "/e", to = "/bak/e", taken = "/f" } },
			kept = { { from = "/c", to = "/d", reason = "backup_exists" } },
			removed = {},
			aliased = {},
			cache_ready = true,
		})
		helpers.assert_eq(#lines, 3)
		helpers.assert_true(lines[1]:find("^INFO Moved legacy folder entry /a to /b") ~= nil, lines[1])
		helpers.assert_true(lines[2]:find("^WARN Moved legacy folder entry /e to the backup /bak/e") ~= nil, lines[2])
		helpers.assert_true(lines[3]:find("^WARN Kept legacy folder entry /c") ~= nil, lines[3])
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
