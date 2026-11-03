--- tests/unit/adapters/test_legacy_folder_migration.lua

--- ==============================================================================
--- MODULE: Legacy Folder Migration (macOS)
--- DESCRIPTION:
--- Replays the shared migration contract, then runs the macOS plan over an
--- in-memory home: paths.toml and the remap runtime leave the old support
--- folder, the old default configuration folder becomes Ergopti/config, the
--- owned runtime's karabiner folder stays, and paths.toml is rewritten after a
--- backup. init.lua runs it before config_paths reads paths.toml. Nothing here
--- touches a real user folder.
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

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

--- Memory ports that also read and write file contents.
local function ports_with_files(tree, files)
	local ports, snapshot = Contract.memory_ports(tree)
	ports.read = function(path) return files[path] end
	ports.write = function(path, text) files[path] = text; return true end
	local rename = ports.rename
	ports.rename = function(from, to)
		local ok, why = rename(from, to)
		if ok then
			for path, text in pairs(files) do
				if path == from or path:sub(1, #from + 1) == from .. "/" then
					files[path] = nil
					files[to .. path:sub(#from + 1)] = text
				end
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
		helpers.assert_eq(report.paths_file, "rewritten")
		helpers.assert_eq(files[NEW .. "/paths.toml"],
			'ConfigDirPath = "' .. HOME .. "/" .. AppDirs.config.macos_relative .. '/"\nLogsDirPath = ""\n')
		helpers.assert_eq(files[NEW .. "/paths.toml" .. AppDirs.migration.backup_suffix],
			'ConfigDirPath = "' .. OLD_CONFIG .. '/"\nLogsDirPath = ""\n', "the previous text is kept")
		helpers.assert_true(#logged >= 4, "every move and the rewrite are logged")
	end)

	helpers.it("names the owned runtime folder apart from the Ergopti root", function()
		local KePaths = require("platform.remap.ke_paths")
		helpers.assert_true(KePaths.OWNED.ARTIFACT_HOME:find(AppDirs.macos.support_relative, 1, true) ~= nil,
			"the downloaded runtime lives in the Ergopti root")
		helpers.assert_true(KePaths.OWNED.CONFIG_HOME:find(AppDirs.owned_runtime.macos_folder_name, 1, true) ~= nil,
			"the compiled configuration home keeps the owned runtime folder")
	end)

	helpers.it("runs before config_paths reads paths.toml (legacy-folder-migration-boot-order)", function()
		local source = read(helpers.driver_root() .. "/init.lua")
		local run_at = source:find('require("adapters.legacy_folder_migration").run(Logger)', 1, true)
		local paths_at = source:find('require("infra.config_paths")', 1, true)
		local logger_at = source:find('require("infra.logger")', 1, true)
		helpers.assert_true(run_at ~= nil and paths_at ~= nil and logger_at ~= nil, "init.lua runs it")
		helpers.assert_true(logger_at < run_at and run_at < paths_at,
			"after the logger, before the configuration paths")
	end)
end)
