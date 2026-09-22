--- tests/unit/ui/test_healthcheck_build_commit_and_config_dir.lua

--- ==============================================================================
--- MODULE: Build commit and configuration directory in the diagnostics (macOS)
--- DESCRIPTION:
--- Two defects seen in the packaged ErgoptiPlus.app:
--- 1. "Last git commit" read "unknown": the healthcheck ran `git rev-parse` in
---    Contents/Resources, which has no .git. Package builds now stamp the
---    commit into the shared tree and every surface (snapshot, healthcheck,
---    crash report) goes through one resolver: stamp, then checkout, then a
---    logged "unknown".
--- 2. "Config dir" named the app bundle although setup had chosen another
---    folder: the healthcheck printed hs.configdir, the driver's script
---    directory. It now prints config_paths' directory and lists hs.configdir
---    separately as the script directory.
--- ==============================================================================

local helpers = require("tests.helpers")

local Snapshot = require("diagnostics.snapshot")

local SHA = "f58d15798aaaabbbbccccddddeeeeffff0000111"
local SHORT = "f58d15798"
local APP_SCRIPTS = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos"
local APP_SHARED = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/_shared"
local CHOSEN_DIR = "/Users/alice/Documents/ErgoptiConfig/"

-- The modules these fixtures replace or reload; restored after each case.
local FIXTURE_MODULES = {
	"ui.healthcheck.helpers",
	"infra.config_paths",
	"infra.diagnostic_snapshot",
	"modules.diagnostics.crash_reporter",
	"infra.logger",
}




-- =====================================
-- =====================================
-- ======= 1/ Fixtures =================
-- =====================================
-- =====================================

--- Builds an in-memory filesystem from a path → content table.
--- @param files table
--- @return table
local function fixture_fs(files)
	return {
		read = function(path) return files[path] end,
		exists = function(path) return files[path] ~= nil end,
	}
end

--- A config_paths double for a user who chose CHOSEN_DIR in setup.
--- @return table
local function chosen_config_paths()
	return {
		is_initialized = function() return true end,
		get_config_dir = function() return CHOSEN_DIR end,
		get = function(key)
			if key == "ConfigTomlPath" then return CHOSEN_DIR .. "hammerspoon/config.toml" end
			return ""
		end,
	}
end

--- A resolver double answering like a packaged build.
--- @return table
local function stamped_snapshot()
	return { resolve_commit = function() return SHORT, Snapshot.COMMIT_SOURCE_BUILD end }
end

--- Loads the healthcheck helpers as the packaged app runs them.
--- @return table H
local function packaged_helpers()
	helpers.load_with_stubs("infra.logger", {
		configdir = APP_SCRIPTS,
		execute = function() return "" end,
	})
	package.loaded["infra.config_paths"] = chosen_config_paths()
	package.loaded["infra.diagnostic_snapshot"] = stamped_snapshot()
	package.loaded["ui.healthcheck.helpers"] = nil
	return require("ui.healthcheck.helpers")
end




-- =====================================
-- =====================================
-- ======= 2/ The resolver =============
-- =====================================
-- =====================================

helpers.describe("build-commit: the macOS resolver", function()
	helpers.it("build-commit: a packaged app answers from its stamp, not a checkout", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			helpers.load_with_stubs("infra.diagnostic_snapshot")
			local Collector = require("infra.diagnostic_snapshot")
			local commit, source = Collector.resolve_commit({
				fs = fixture_fs({
					[APP_SHARED .. "/" .. Snapshot.BUILD_STAMP_FILE] = "commit=" .. SHA .. "\n",
				}),
				shared_root = APP_SHARED,
				source_dir = APP_SCRIPTS,
			})
			helpers.assert_eq(SHORT, commit)
			helpers.assert_eq(Snapshot.COMMIT_SOURCE_BUILD, source)
		end)
	end)

	helpers.it("build-commit: the boot snapshot's commit field is the stamp", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			helpers.load_with_stubs("infra.diagnostic_snapshot")
			local Collector = require("infra.diagnostic_snapshot")
			local values = Collector.collect({
				git_fs = fixture_fs({
					[APP_SHARED .. "/" .. Snapshot.BUILD_STAMP_FILE] = "commit=" .. SHA .. "\n",
				}),
				shared_root = APP_SHARED,
				source_dir = APP_SCRIPTS,
			}, {
				os_version = function() return nil end, runtime_version = function() return nil end,
				arch = function() return nil end, monitor_count = function() return nil end,
				main_screen_scale = function() return nil end, keyboard_layout = function() return nil end,
				elevated = function() return nil end, home = function() return nil end,
			})
			helpers.assert_eq(SHORT, values.commit)
		end)
	end)

	helpers.it("build-commit: an unknown commit is logged with the places it looked", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local logger = helpers.make_logger_stub()
			local warnings = {}
			logger.warn = function(tag, fmt, ...)
				warnings[#warnings + 1] = tostring(tag) .. ": " .. string.format(fmt, ...)
			end
			helpers.load_with_stubs("infra.logger")
			package.loaded["infra.logger"] = logger
			package.loaded["infra.diagnostic_snapshot"] = nil
			local Collector = require("infra.diagnostic_snapshot")
			local commit, source = Collector.resolve_commit({
				fs = fixture_fs({}), shared_root = APP_SHARED, source_dir = APP_SCRIPTS,
			})
			helpers.assert_eq(Snapshot.UNKNOWN, commit)
			helpers.assert_eq(Snapshot.COMMIT_SOURCE_UNKNOWN, source)
			helpers.assert_eq(1, #warnings, "exactly one warning explains the unknown commit")
			helpers.assert_true(warnings[1]:find(Snapshot.BUILD_STAMP_FILE, 1, true) ~= nil, warnings[1])
			helpers.assert_true(warnings[1]:find(APP_SCRIPTS, 1, true) ~= nil, warnings[1])
			helpers.assert_eq(nil, warnings[1]:find("^" .. Snapshot.MODULE .. ":"),
				"the snapshot's grep tag stays reserved for the snapshot line")
		end)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Healthcheck ==============
-- =====================================
-- =====================================

helpers.describe("build-commit: the healthcheck of a packaged app", function()
	helpers.it("build-commit: reports the stamped commit, not a git subprocess answer", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local executed = {}
			local H = packaged_helpers()
			hs.execute = function(command)
				executed[#executed + 1] = command
				return ""
			end
			local info = H.sys_info()
			helpers.assert_eq(SHORT, info.git_hash)
			helpers.assert_eq(Snapshot.COMMIT_SOURCE_BUILD, info.commit_source)
			for _, command in ipairs(executed) do
				helpers.assert_eq(nil, command:find("rev-parse", 1, true),
					"no git subprocess: the bundle has no .git to ask")
			end
		end)
	end)

	helpers.it("build-commit: the config dir is the chosen folder and the bundle is the script dir", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local info = packaged_helpers().sys_info()
			helpers.assert_eq(CHOSEN_DIR, info.config_dir,
				"the configuration directory is the one config.toml is read from")
			helpers.assert_eq(APP_SCRIPTS, info.script_dir,
				"the bundle path is reported, under its own label")
			helpers.assert_eq(nil, info.config_dir:find("ErgoptiPlus.app", 1, true))
		end)
	end)

	helpers.it("build-commit: the config file list names the files config_paths resolves", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local summary = packaged_helpers().collect_config_summary()
			helpers.assert_eq(1, #summary.config_files)
			helpers.assert_eq(CHOSEN_DIR .. "hammerspoon/config.toml", summary.config_files[1])
		end)
	end)

	helpers.it("build-commit: an uninitialised config_paths is reported, not replaced by the bundle", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			local H = packaged_helpers()
			package.loaded["infra.config_paths"] = { is_initialized = function() return false end }
			helpers.assert_eq("", H.config_dir())
			helpers.assert_eq(0, #H.collect_config_summary().config_files)
		end)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Crash report =============
-- =====================================
-- =====================================

helpers.describe("build-commit: the crash report of a packaged app", function()
	helpers.it("build-commit: carries the commit and both directories without system probes", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			helpers.load_with_stubs("infra.logger", { configdir = APP_SCRIPTS })
			package.loaded["infra.config_paths"] = chosen_config_paths()
			package.loaded["infra.diagnostic_snapshot"] = stamped_snapshot()
			package.loaded["modules.diagnostics.crash_reporter"] = nil
			local report = require("modules.diagnostics.crash_reporter").report("boom")
			helpers.assert_eq(SHORT, report.git_hash)
			helpers.assert_eq(Snapshot.COMMIT_SOURCE_BUILD, report.commit_source)
			helpers.assert_eq(CHOSEN_DIR, report.config_dir)
			helpers.assert_eq(APP_SCRIPTS, report.script_dir)
		end)
	end)

	helpers.it("build-commit: a resolver failure is reported as unknown, not raised", function()
		helpers.with_stub_scope(FIXTURE_MODULES, function()
			helpers.load_with_stubs("infra.logger", { configdir = APP_SCRIPTS })
			package.loaded["infra.config_paths"] = chosen_config_paths()
			package.loaded["infra.diagnostic_snapshot"] = {
				resolve_commit = function() error("stamp read exploded") end,
			}
			package.loaded["modules.diagnostics.crash_reporter"] = nil
			local report = require("modules.diagnostics.crash_reporter").report("boom")
			helpers.assert_eq("unknown", report.git_hash)
			helpers.assert_eq("unknown", report.commit_source)
		end)
	end)
end)
