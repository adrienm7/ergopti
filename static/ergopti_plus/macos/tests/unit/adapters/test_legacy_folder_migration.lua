--- tests/unit/adapters/test_legacy_folder_migration.lua

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
local Contract = require("test.legacy_folder_migration_contract")
local Migration = require("adapters.legacy_folder_migration")
local AppDirs = require("app_dirs")

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
	return ports, snapshot
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

	helpers.it("names the owned runtime folder apart from the Ergopti root", function()
		local KePaths = require("platform.remap.ke_paths")
		helpers.assert_true(KePaths.OWNED.ARTIFACT_HOME:find(AppDirs.macos.support_relative, 1, true) ~= nil,
			"the downloaded runtime lives in the Ergopti root")
		helpers.assert_true(KePaths.OWNED.CONFIG_HOME:find(AppDirs.owned_runtime.macos_folder_name, 1, true) ~= nil,
			"the compiled configuration home keeps the owned runtime folder")
	end)

	helpers.it("runs after the instance admission, before the folders are read (legacy-folder-migration-boot-order)", function()
		local call = 'require("adapters.legacy_folder_migration").run(Logger)'
		local source = assert(helpers.read_driver_source(call), "init.lua runs it")
		local run_at = source:find(call, 1, true)
		local admission_at = source:find("InstanceAdmission.ADMIT", 1, true)
		local breadcrumb_at = source:find('require("adapters.reload_breadcrumb")', 1, true)
		local paths_at = source:find('require("infra.config_paths")', 1, true)
		helpers.assert_true(admission_at ~= nil and breadcrumb_at ~= nil and paths_at ~= nil, "init.lua anchors")
		-- A refused process must leave every folder as it found it.
		helpers.assert_true(admission_at < run_at, "after the instance admission")
		helpers.assert_true(run_at < breadcrumb_at and run_at < paths_at,
			"before the reload breadcrumb and the configuration paths")
	end)
end)
