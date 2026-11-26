--- tests/unit/core/fs/adapters/test_legacy_folder_migration.lua

--- ==============================================================================
--- MODULE: Legacy Folder Migration (macOS)
--- DESCRIPTION:
--- Replays the shared migration contract, then runs the macOS plan over an
--- in-memory home: paths.toml and the remap runtime leave the old support
--- folder, the old default configuration folder becomes Ergopti/config, the old
--- logs, cache and control folders merge (a clash goes to the backup folder),
--- the owned runtime's karabiner folder stays, and paths.toml is rewritten
--- after a backup. init.lua runs it after the instance admission and before the
--- breadcrumb and config_paths read the folders. Nothing here touches a real user
--- folder.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.lua.settings.legacy_folder_migration_contract")
local Migration = require("core.fs.adapters.legacy_folder_migration")
local Core = require("settings.engine.migration.legacy_folder_migration_core")
local AppDirs = require("core.fs.engine.app_dirs")

Contract.run(helpers, helpers.shared(""))

local HOME = "/Users/u"
local OLD = HOME .. "/" .. AppDirs.migration.macos.legacy_support_relative
local NEW = HOME .. "/" .. AppDirs.macos.support_relative
local OLD_CONFIG = HOME .. "/" .. AppDirs.migration.macos.legacy_config_relative

--- Memory ports that also read and write file contents.
local function ports_with_files(tree, files)
	local ports, snapshot = Contract.memory_ports(tree)
	ports.read = function(path) return files[path] end
	ports.write = function(path, text) files[path] = text; return true end
	local rename = ports.rename
	ports.rename = function(from, to)
		local ok, why = rename(from, to)
		if ok then
			-- Collected first: adding keys while pairs walks a table is undefined.
			local moved = {}
			for path, text in pairs(files) do
				if path == from or path:sub(1, #from + 1) == from .. "/" then moved[path] = text end
			end
			for path, text in pairs(moved) do
				files[path] = nil
				files[to .. path:sub(#from + 1)] = text
			end
		end
		return ok, why
	end
	local exists = ports.exists
	ports.exists = function(path) return files[path] ~= nil or exists(path) end
	ports.replace = function(from, to)
		if files[from] == nil then return false end
		files[to], files[from] = files[from], nil
		return true
	end
	ports.remove = function(path) local had = files[path] ~= nil; files[path] = nil; return had end
	return ports, snapshot
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

--- Runs `body` with hs.fs bound to the real LuaFileSystem, as Hammerspoon's
--- own hs.fs is, so the native ports act on the scratch folder.
--- @param body function
local function with_real_fs(body)
	local lfs = require("lfs")
	local saved = {}
	local real = {
		attributes = lfs.attributes, symlinkAttributes = lfs.symlinkattributes, mkdir = lfs.mkdir,
		rmdir = lfs.rmdir, link = lfs.link, dir = lfs.dir,
	}
	for name, fn in pairs(real) do saved[name] = hs.fs[name]; hs.fs[name] = fn end
	local ok, err = pcall(body)
	for name, fn in pairs(saved) do hs.fs[name] = fn end
	assert(ok, err)
end

local function write(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("a")
	file:close()
	return text
end

helpers.describe("macOS legacy folder migration", function()
	helpers.it("moves paths.toml, the runtime and the config into the one root (legacy-folder-migration-macos)", function()
		local files = {
			[OLD .. "/paths.toml"] = 'ConfigDirPath = "' .. OLD_CONFIG .. '/"\nLogsDirPath = ""\n',
		}
		local ports, snapshot = ports_with_files({
			OLD .. "/paths.toml",
			OLD .. "/RemapRuntime/16.3.0/core.tar",
			OLD .. "/karabiner/karabiner.json",
			OLD .. "/launcher.lock",
			OLD_CONFIG .. "/hammerspoon/config.toml",
			NEW .. "/ollama-native-http/ollama",
		}, files)
		local logged = {}
		local logger = {
			info = function(_, fmt, ...) logged[#logged + 1] = fmt:format(...) end,
			warn = function(_, fmt, ...) logged[#logged + 1] = "WARN " .. fmt:format(...) end,
		}
		local report = Migration.run(logger, { home = HOME, ports = ports })
		local after = table.concat(snapshot(), " ")
		helpers.assert_true(after:find(NEW .. "/paths.toml", 1, true) ~= nil, "paths.toml moved")
		helpers.assert_true(after:find(NEW .. "/RemapRuntime/16.3.0/core.tar", 1, true) ~= nil, "runtime moved")
		helpers.assert_true(after:find(HOME .. "/" .. AppDirs.config.macos_relative .. "/hammerspoon/config.toml",
			1, true) ~= nil, "the configuration folder moved")
		helpers.assert_true(after:find(OLD .. "/karabiner/karabiner.json", 1, true) ~= nil,
			"the owned runtime's configuration home keeps its compiled folder")
		helpers.assert_true(after:find(OLD .. "/launcher.lock", 1, true) ~= nil, "runtime state is not moved")
		helpers.assert_eq(#report.moved, 3)
		helpers.assert_eq(#report.backed_up, 0)
		helpers.assert_eq(report.paths_file, "rewritten")
		helpers.assert_eq(files[NEW .. "/paths.toml"],
			'ConfigDirPath = "' .. HOME .. "/" .. AppDirs.config.macos_relative .. '/"\nLogsDirPath = ""\n')
		helpers.assert_eq(files[NEW .. "/paths.toml" .. AppDirs.migration.backup_suffix],
			'ConfigDirPath = "' .. OLD_CONFIG .. '/"\nLogsDirPath = ""\n', "the previous text is kept")
		helpers.assert_true(#logged >= 4, "every move and the rewrite are logged")
	end)

	helpers.it("keeps paths.toml naming a configuration folder whose move was refused (legacy-folder-migration-macos-refused)",
		function()
		local text = 'ConfigDirPath = "' .. OLD_CONFIG .. '/"\nLogsDirPath = ""\n'
		local files = { [OLD .. "/paths.toml"] = text }
		local ports = ports_with_files({ OLD .. "/paths.toml", OLD_CONFIG .. "/hammerspoon/config.toml" }, files)
		local rename = ports.rename
		ports.rename = function(from, to)
			if from == OLD_CONFIG then return nil, "Operation not permitted" end
			return rename(from, to)
		end
		local logger = { info = function() end, warn = function() end }
		local report = Migration.run(logger, { home = HOME, ports = ports })
		helpers.assert_eq(files[NEW .. "/paths.toml"], text, "paths.toml still names the folder that holds the data")
		helpers.assert_eq(report.paths_file, "unchanged", "and is not reported as rewritten")
	end)

	helpers.it("moves the configuration back when paths.toml cannot follow it (legacy-folder-migration-macos-unpublished)",
		function()
		local text = 'ConfigDirPath = "' .. OLD_CONFIG .. '/"\nLogsDirPath = ""\n'
		local files = { [OLD .. "/paths.toml"] = text }
		local ports, snapshot = ports_with_files({ OLD .. "/paths.toml", OLD_CONFIG .. "/hammerspoon/config.toml" }, files)
		local write = ports.write
		local refused = true
		ports.write = function(path, content)
			if refused and path == NEW .. "/paths.toml.migration-stage" then return false end
			return write(path, content)
		end
		local logger = { info = function() end, warn = function() end }
		local report = Migration.run(logger, { home = HOME, ports = ports })
		helpers.assert_eq(files[NEW .. "/paths.toml"], text, "a refused write leaves paths.toml as it was")
		helpers.assert_true(table.concat(snapshot(), " "):find(OLD_CONFIG .. "/hammerspoon/config.toml", 1, true) ~= nil,
			"the configuration is back in the folder paths.toml names")
		helpers.assert_eq(report.paths_file, "write_refused")
		helpers.assert_eq(#report.restored, 1, "the move back is reported")
		refused = false
		local again = Migration.run(logger, { home = HOME, ports = ports })
		helpers.assert_eq(again.paths_file, "rewritten", "the next boot completes, reusing the same backup")
		helpers.assert_true(table.concat(snapshot(), " "):find(HOME .. "/" .. AppDirs.config.macos_relative
			.. "/hammerspoon/config.toml", 1, true) ~= nil, "and the configuration follows")
	end)

	helpers.it("follows a configuration folder chosen below the old default one (legacy-folder-migration-macos-descendant)",
		function()
		local files = { [OLD .. "/paths.toml"] = 'ConfigDirPath = "' .. OLD_CONFIG .. '/custom/"\n' }
		local ports, snapshot = ports_with_files({ OLD .. "/paths.toml", OLD_CONFIG .. "/custom/config.toml" }, files)
		local logger = { info = function() end, warn = function() end }
		local report = Migration.run(logger, { home = HOME, ports = ports })
		local new_custom = HOME .. "/" .. AppDirs.config.macos_relative .. "/custom"
		helpers.assert_true(table.concat(snapshot(), " "):find(new_custom .. "/config.toml", 1, true) ~= nil,
			"the chosen folder moved with its ancestor")
		helpers.assert_eq(files[NEW .. "/paths.toml"], 'ConfigDirPath = "' .. new_custom .. '/"\n',
			"paths.toml names it where it went")
		helpers.assert_eq(report.paths_file, "rewritten")
	end)

	helpers.it("merges the old logs, cache and control folders, backing up what clashes (legacy-folder-migration-macos-merge)",
		function()
		local LOGS = HOME .. "/" .. AppDirs.macos.relative
		local OLD_LOGS = HOME .. "/" .. AppDirs.migration.macos.legacy_logs_relative
		local OLD_CACHE = HOME .. "/" .. AppDirs.migration.macos.legacy_cache_relative
		local OLD_CONTROL = HOME .. "/" .. AppDirs.migration.macos.legacy_control_relative
		local BACKUP = NEW .. "/" .. AppDirs.migration.backup_folder
		local ports, snapshot = ports_with_files({
			OLD_LOGS .. "/",
			OLD_CACHE .. "/",
			OLD_CONTROL .. "/",
			OLD_LOGS .. "/ErgoptiPlus_2026-11-01.log",
			OLD_LOGS .. "/" .. AppDirs.macos.launcher_log,
			LOGS .. "/" .. AppDirs.macos.launcher_log,
			OLD_CACHE .. "/metrics/day.bin",
			OLD_CONTROL .. "/control/token",
		}, {})
		local logged = {}
		local logger = {
			info = function(_, fmt, ...) logged[#logged + 1] = fmt:format(...) end,
			warn = function(_, fmt, ...) logged[#logged + 1] = "WARN " .. fmt:format(...) end,
		}
		local report = Migration.run(logger, { home = HOME, ports = ports })
		local after = " " .. table.concat(snapshot(), " ") .. " "
		helpers.assert_true(after:find(LOGS .. "/ErgoptiPlus_2026-11-01.log ", 1, true) ~= nil, "an old log moved")
		helpers.assert_true(after:find(BACKUP .. "/" .. AppDirs.migration.macos.legacy_logs_relative .. "/"
			.. AppDirs.macos.launcher_log .. " ", 1, true) ~= nil, "the clashing launcher log went to the backup")
		helpers.assert_true(after:find(HOME .. "/" .. AppDirs.macos.cache_relative .. "/metrics/day.bin ", 1, true) ~= nil,
			"the cache merged")
		helpers.assert_true(after:find(NEW .. "/control/token ", 1, true) ~= nil, "the control folder merged")
		helpers.assert_true(after:find(OLD_LOGS, 1, true) == nil and after:find(OLD_CACHE, 1, true) == nil
			and after:find(OLD_CONTROL .. "/", 1, true) == nil, "every merged old folder is gone")
		helpers.assert_eq(#report.backed_up, 1)
		helpers.assert_eq(#report.kept, 0)
		helpers.assert_eq(#report.removed, 3)
		local warned = false
		for _, line in ipairs(logged) do
			if line:find("WARN", 1, true) == 1 and line:find(BACKUP, 1, true) then warned = true end
		end
		helpers.assert_true(warned, "the backup is logged as a warning")
	end)

	-- The Mac of the 2026-11-05 field report: a custom LogsDirPath ending in the
	-- old folder name, so the logger wrote into its Ergopti subfolder.
	helpers.it("renames a custom logs folder named like the old default and moves its logs (legacy-folder-migration-macos-custom-logs)",
		function()
		local legacy_name = AppDirs.migration.macos.legacy_logs_relative:match("([^/]+)$")
		local app = AppDirs.macos.folder_name
		for _, spelling in ipairs({ "/Volumes/Data/Logs/" .. legacy_name .. "/", "~/Documents/" .. legacy_name,
			"/Volumes/Data/" .. legacy_name .. "/" .. app .. "/" }) do
			local custom = spelling:gsub("/$", ""):gsub("/" .. app .. "$", ""):gsub("^~", HOME)
			local parent = custom:match("^(.*)/[^/]+$")
			local text = 'ConfigDirPath = ""\nLogsDirPath = "' .. spelling .. '"\n'
			local files = { [NEW .. "/paths.toml"] = text }
			local ports, snapshot = ports_with_files({
				NEW .. "/paths.toml",
				custom .. "/" .. app .. "/ErgoptiPlus_2026-11-05.log",
				custom .. "/notes.txt",
			}, files)
			local logger = { info = function() end, warn = function() end }
			local report = Migration.run(logger, { home = HOME, ports = ports })
			local after = " " .. table.concat(snapshot(), " ") .. " "
			helpers.assert_eq(report.paths_file, "rewritten", spelling)
			local renamed = spelling:gsub("/$", ""):gsub("/" .. app .. "$", ""):gsub("[^/]+$", app)
				.. (spelling:sub(-1) == "/" and "/" or "")
			helpers.assert_eq(files[NEW .. "/paths.toml"], 'ConfigDirPath = ""\nLogsDirPath = "' .. renamed .. '"\n')
			helpers.assert_eq(files[NEW .. "/paths.toml" .. AppDirs.migration.backup_suffix], text)
			helpers.assert_true(after:find(" " .. parent .. "/" .. app .. "/ErgoptiPlus_2026-11-05.log ", 1, true) ~= nil,
				"the logs follow the renamed folder: " .. after)
			helpers.assert_true(after:find(" " .. custom .. "/notes.txt ", 1, true) ~= nil,
				"the user's own files in the old-named folder stay")
		end
	end)

	helpers.it("keeps any other custom logs folder (legacy-folder-migration-macos-custom-kept)", function()
		local legacy_name = AppDirs.migration.macos.legacy_logs_relative:match("([^/]+)$")
		for _, value in ipairs({ "/Volumes/Data/Logs", "/Volumes/Data/" .. legacy_name .. "_old",
			"/Volumes/Data/" .. legacy_name .. "/sub", "/Volumes/Data/my" .. legacy_name, "" }) do
			helpers.assert_nil(Migration.custom_legacy_logs(HOME, value), value)
			local text = 'LogsDirPath = "' .. value .. '"\n'
			local files = { [NEW .. "/paths.toml"] = text }
			local ports = ports_with_files({ NEW .. "/paths.toml" }, files)
			local report = Migration.run({ info = function() end, warn = function() end }, { home = HOME, ports = ports })
			helpers.assert_eq(report.paths_file, "unchanged", value)
			helpers.assert_eq(files[NEW .. "/paths.toml"], text)
		end
		-- The old default itself is the default rule's, not a custom folder.
		helpers.assert_nil(Migration.custom_legacy_logs(HOME, "~/" .. AppDirs.migration.macos.legacy_logs_relative))
	end)

	helpers.it("keeps a file or folder published after the check, on real folders (legacy-folder-migration-macos-race)",
		function()
		local dir = scratch()
		local ok, err = pcall(with_real_fs, function()
			assert(os.execute("mkdir -p -- '" .. dir .. "/old/sub' '" .. dir .. "/new'"))
			write(dir .. "/old/paths.toml", "LEGACY")
			write(dir .. "/old/sub/a", "OLD-A")
			local ports = Migration.native_ports()
			local rename = ports.rename
			ports.rename = function(from, to)
				-- Another writer publishes each destination between the check and the rename.
				if to == dir .. "/new/paths.toml" then write(to, "CONCURRENT-NEW") end
				if to == dir .. "/new/sub" then
					assert(os.execute("mkdir -p -- '" .. to .. "'"))
					write(to .. "/b", "NEW-B")
				end
				return rename(from, to)
			end
			local report = Core.apply({
				{ from = dir .. "/old/paths.toml", to = dir .. "/new/paths.toml", backup = dir .. "/bak/paths.toml" },
				{ from = dir .. "/old/sub", to = dir .. "/new/sub", backup = dir .. "/bak/sub" },
			}, ports)
			helpers.assert_eq(read(dir .. "/new/paths.toml"), "CONCURRENT-NEW", "the newer file survives")
			helpers.assert_eq(read(dir .. "/bak/paths.toml"), "LEGACY", "the old file went to the backup")
			helpers.assert_eq(read(dir .. "/new/sub/b"), "NEW-B", "the newer folder survives")
			helpers.assert_eq(read(dir .. "/new/sub/a"), nil, "the old folder did not replace it")
			helpers.assert_eq(read(dir .. "/bak/sub/a"), "OLD-A", "the old folder went to the backup")
			helpers.assert_eq(#report.moved, 0, "no move reported over a newer entry")
			helpers.assert_eq(#report.backed_up, 2, "both backups are reported")
		end)
		drop(dir)
		assert(ok, err)
	end)

	helpers.it("reports a folder whose listing raises instead of aborting the boot (legacy-folder-migration-macos-list)",
		function()
		local dir = scratch()
		local ok, err = pcall(with_real_fs, function()
			local home = dir .. "/home"
			local old_logs = home .. "/" .. AppDirs.migration.macos.legacy_logs_relative
			assert(os.execute("mkdir -p -- '" .. old_logs .. "'"))
			write(old_logs .. "/a.log", "OLD")
			local real_dir = hs.fs.dir
			-- hs.fs.dir raises on a folder it cannot open (permission, gone after the stat).
			hs.fs.dir = function(path)
				if path == old_logs then error(path .. ": Permission denied") end
				return real_dir(path)
			end
			local warned = {}
			local logger = { info = function() end,
				warn = function(_, fmt, ...) warned[#warned + 1] = fmt:format(...) end }
			local run_ok, report = pcall(Migration.run, logger, { home = home })
			helpers.assert_true(run_ok, "the refusal does not escape the migration: " .. tostring(report))
			local reasons = {}
			for _, kept in ipairs(report.kept) do reasons[#reasons + 1] = kept.from .. "=" .. kept.reason end
			helpers.assert_true(table.concat(reasons, " "):find(old_logs .. "=list_failed", 1, true) ~= nil,
				"the unlistable folder is reported: " .. table.concat(reasons, " "))
			helpers.assert_eq(read(old_logs .. "/a.log"), "OLD", "its entry stays")
			helpers.assert_true(#warned >= 1, "and warned")
		end)
		drop(dir)
		assert(ok, err)
	end)

	helpers.it("leaves a legacy logs folder linked to the current one, on real folders (legacy-folder-migration-macos-alias)",
		function()
		local dir = scratch()
		local ok, err = pcall(with_real_fs, function()
			local home = dir .. "/home"
			local logs = home .. "/" .. AppDirs.macos.relative
			local old_logs = home .. "/" .. AppDirs.migration.macos.legacy_logs_relative
			assert(os.execute("mkdir -p -- '" .. logs .. "'"))
			write(logs .. "/active.log", "CURRENT")
			assert(os.execute("ln -s -- '" .. logs .. "' '" .. old_logs .. "'"))
			local logger = { info = function() end, warn = function() end }
			for _ = 1, 2 do
				local report = Migration.run(logger, { home = home })
				helpers.assert_eq(read(logs .. "/active.log"), "CURRENT", "the live log stays")
				helpers.assert_eq(#report.aliased, 1, "the link is recognised as the current folder")
				helpers.assert_eq(#report.backed_up + #report.kept, 0, "nothing is archived")
			end
		end)
		drop(dir)
		assert(ok, err)
	end)

	helpers.it("names the owned runtime folder apart from the Ergopti root", function()
		local KePaths = require("platform.remap.ke_paths")
		helpers.assert_true(KePaths.OWNED.ARTIFACT_HOME:find(AppDirs.macos.support_relative, 1, true) ~= nil,
			"the downloaded runtime lives in the Ergopti root")
		helpers.assert_true(KePaths.OWNED.CONFIG_HOME:find(AppDirs.owned_runtime.macos_folder_name, 1, true) ~= nil,
			"the compiled configuration home keeps the owned runtime folder")
	end)

	helpers.it("runs after the instance admission, before the folders are read (legacy-folder-migration-boot-order)", function()
		local call = 'require("core.fs.adapters.legacy_folder_migration").run(Logger)'
		local source = assert(helpers.read_driver_source(call), "init.lua runs it")
		local run_at = source:find(call, 1, true)
		local admission_at = source:find("InstanceAdmission.ADMIT", 1, true)
		local breadcrumb_at = source:find('require("diagnostics.adapters.reload_breadcrumb")', 1, true)
		local paths_at = source:find('require("settings.engine.paths")', 1, true)
		helpers.assert_true(admission_at ~= nil and breadcrumb_at ~= nil and paths_at ~= nil, "init.lua anchors")
		-- A refused process must leave every folder as it found it.
		helpers.assert_true(admission_at < run_at, "after the instance admission")
		helpers.assert_true(run_at < breadcrumb_at and run_at < paths_at,
			"before the reload breadcrumb and the configuration paths")
	end)
end)
