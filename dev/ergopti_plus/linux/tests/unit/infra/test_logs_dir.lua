--- tests/unit/infra/test_logs_dir.lua

--- ==============================================================================
--- MODULE: Logs Folder Resolution (Linux)
--- DESCRIPTION:
--- The daemon's logs folder is ${XDG_STATE_HOME:-~/.local/state}/ergopti_plus/
--- logs, or the LogsDirPath override kept in bootstrap storage. The sink's
--- log_dir(), main_log_path(), errors_log_path() and crash_reports_dir() are
--- the one resolver every consumer asks: the tray, the gesture actions, the
--- health check and the crash reporter.
---
--- ROOT CAUSES ENCODED (logs-dir-resolver):
--- 1. The folder was $XDG_DATA_HOME/ergopti/logs: logs are state in the XDG
---    layout, and the folder had a different name on every driver.
--- 2. It could not be moved; the override now can, and a folder the user
---    merely picked gets an ergopti_plus subfolder so the retention purge never
---    deletes in the user's own folder.
--- 3. Crash dumps went to ~/.local/share/ergopti/crashes, away from the log
---    that explains them.
--- 4. The resolver read the saved override while the sink kept writing the
---    folder it was installed with: after a save in the paths editor, which
---    does not restart the daemon, "open today's log" named a file nobody
---    wrote. It names the sink's folder until repoint() moves the sink.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs `body` with controlled environment variables and bootstrap storage.
--- @param env table Variables returned by os.getenv (others fall through).
--- @param stored table Bootstrap storage values.
--- @param body function Receives (ConfigPaths, LoggerSink, storage values).
local function with_paths(env, stored, body)
	local real_getenv = os.getenv
	local saved_storage = package.loaded["adapters.storage"]
	local saved_paths = package.loaded["infra.config_paths"]
	local saved_sink = package.loaded["infra.logger_sink"]
	local values = stored
	os.getenv = function(name)
		if env[name] ~= nil then return env[name] or nil end
		return real_getenv(name)
	end
	package.loaded["adapters.storage"] = {
		get = function(key, fallback)
			if values[key] == nil then return fallback end
			return values[key]
		end,
		set = function(key, value) values[key] = value; return true end,
		delete = function(key) values[key] = nil; return true end,
	}
	package.loaded["infra.config_paths"] = nil
	package.loaded["infra.logger_sink"] = nil
	local ok, err = pcall(function()
		body(require("infra.config_paths"), require("infra.logger_sink"), values)
	end)
	os.getenv = real_getenv
	package.loaded["adapters.storage"] = saved_storage
	package.loaded["infra.config_paths"] = saved_paths
	package.loaded["infra.logger_sink"] = saved_sink
	if not ok then error(err, 0) end
end

helpers.describe("logs folder resolution (logs-dir-resolver)", function()
	helpers.it("defaults to $XDG_STATE_HOME/ergopti_plus/logs", function()
		with_paths({ XDG_STATE_HOME = "/state", HOME = "/home/u" }, {}, function(ConfigPaths, Sink)
			helpers.assert_eq(ConfigPaths.default_logs_dir(), "/state/ergopti_plus/logs")
			helpers.assert_eq(Sink.log_dir(), "/state/ergopti_plus/logs")
		end)
	end)

	helpers.it("falls back to ~/.local/state when XDG_STATE_HOME is empty", function()
		with_paths({ XDG_STATE_HOME = "", HOME = "/home/u" }, {}, function(ConfigPaths)
			helpers.assert_eq(ConfigPaths.default_logs_dir(), "/home/u/.local/state/ergopti_plus/logs")
		end)
	end)

	helpers.it("follows the override and appends the application folder to a foreign one", function()
		with_paths({ XDG_STATE_HOME = "/state" }, { ["paths.logs_dir"] = "/sync/logs/" },
			function(ConfigPaths, Sink)
				helpers.assert_eq(ConfigPaths.get_logs_dir(), "/sync/logs/ergopti_plus")
				local day = os.date("%Y-%m-%d")
				helpers.assert_eq(Sink.main_log_path(), "/sync/logs/ergopti_plus/ErgoptiPlus_" .. day .. ".log")
				helpers.assert_eq(Sink.errors_log_path(),
					"/sync/logs/ergopti_plus/ErgoptiPlus_errors_" .. day .. ".log")
				helpers.assert_eq(Sink.crash_reports_dir(), "/sync/logs/ergopti_plus/crash_reports")
			end)
	end)

	helpers.it("keeps a folder already named after the application", function()
		with_paths({ XDG_STATE_HOME = "/state" }, { ["paths.logs_dir"] = "/sync/ergopti_plus" },
			function(ConfigPaths)
				helpers.assert_eq(ConfigPaths.get_logs_dir(), "/sync/ergopti_plus")
			end)
	end)

	helpers.it("ignores a relative stored override", function()
		with_paths({ XDG_STATE_HOME = "/state" }, { ["paths.logs_dir"] = "logs" }, function(ConfigPaths)
			helpers.assert_eq(ConfigPaths.get_logs_dir(), "/state/ergopti_plus/logs")
		end)
	end)

	helpers.it("stores a normalized override and clears the default", function()
		with_paths({ XDG_STATE_HOME = "/state" }, {}, function(ConfigPaths, _, values)
			helpers.assert_true(ConfigPaths.set_logs_dir("/sync/logs") == true)
			helpers.assert_eq(values["paths.logs_dir"], "/sync/logs/ergopti_plus")
			helpers.assert_true(ConfigPaths.set_logs_dir("/state/ergopti_plus/logs") == true)
			helpers.assert_nil(values["paths.logs_dir"], "the default is never stored as an override")
			local refused, err = ConfigPaths.set_logs_dir("relative")
			helpers.assert_true(refused == false, "a relative folder is refused")
			helpers.assert_not_nil(err)
			helpers.assert_nil(values["paths.logs_dir"])
		end)
	end)

	-- The daemon is never restarted by the paths editor, so the stored override
	-- and the folder the sink writes can differ until the sink is moved. Every
	-- consumer must name the folder the lines actually reach.
	helpers.it("names the folder the installed sink writes until it is moved there", function()
		-- A unique absolute POSIX prefix: the override must be an absolute path.
		local base = os.tmpname()
		os.remove(base)
		local first = base .. "_first"
		local second = base .. "_moved/ergopti_plus"
		local day = os.date("%Y-%m-%d")
		local function remove_day_files(dir)
			os.remove(dir .. "/ErgoptiPlus_" .. day .. ".log")
			os.remove(dir .. "/ErgoptiPlus_errors_" .. day .. ".log")
		end
		local function read(path)
			local handle = io.open(path, "r")
			if not handle then return nil end
			local content = handle:read("*a")
			handle:close()
			return content
		end
		with_paths({ XDG_STATE_HOME = "/state" }, {}, function(_, Sink, values)
			-- A stand-in core that only receives the sink, so the process-wide
			-- logger other suites capture is left untouched.
			local emit = nil
			local Logger = {
				set_sink = function(fn) emit = fn end,
				enable_repeat_collapsing = function() end,
				disable_repeat_collapsing = function() end,
			}
			remove_day_files(first)
			remove_day_files(second)
			local ok, err = pcall(function()
				helpers.assert_true(Sink.install(Logger, { log_dir = first }), "the first folder is writable")
				values["paths.logs_dir"] = second
				helpers.assert_eq(Sink.log_dir(), first,
					"a saved override the sink has not moved to yet must not be named")
				helpers.assert_eq(Sink.main_log_path(), first .. "/ErgoptiPlus_" .. day .. ".log")
				helpers.assert_eq(Sink.crash_reports_dir(), first .. "/crash_reports")

				local moved, move_err = Sink.repoint()
				helpers.assert_true(moved == true, "the sink moves to the saved folder: " .. tostring(move_err))
				helpers.assert_eq(Sink.log_dir(), second)
				emit("[INFO] [logs_dir_test] marker-after-repoint", "info")
				helpers.assert_contains(read(second .. "/ErgoptiPlus_" .. day .. ".log") or "",
					"marker-after-repoint", "the next line reaches the new folder")
				helpers.assert_true(not (read(first .. "/ErgoptiPlus_" .. day .. ".log") or ""):find("marker%-after%-repoint"),
					"the old folder receives nothing after the move")
			end)
			Sink.uninstall(Logger)
			remove_day_files(first)
			remove_day_files(second)
			if not ok then error(err, 0) end
		end)
	end)

	-- The paths editor asks this before storing a folder: install() at the next
	-- start would otherwise fall back to stdout for a folder it cannot use.
	helpers.it("prepares a logs folder only when it can be created and written", function()
		local base = os.tmpname()
		os.remove(base)
		with_paths({ XDG_STATE_HOME = "/state" }, {}, function(_, Sink)
			local fresh = base .. "_prepared/ergopti_plus"
			local ready, err = Sink.prepare_dir(fresh)
			helpers.assert_true(ready == true, "a new folder is created: " .. tostring(err))
			local probe = io.open(fresh .. "/probe.txt", "w")
			helpers.assert_not_nil(probe, "the prepared folder exists and is writable")
			probe:close()
			os.remove(fresh .. "/probe.txt")

			local blocker = base .. "_blocker"
			local handle = assert(io.open(blocker, "w"))
			handle:write("x")
			handle:close()
			local refused, why = Sink.prepare_dir(blocker .. "/ergopti_plus")
			os.remove(blocker)
			helpers.assert_true(refused == false, "a folder under a file cannot be created")
			helpers.assert_not_nil(why)
			helpers.assert_true(Sink.prepare_dir("relative/ergopti_plus") == false, "a relative folder is refused")
		end)
	end)

	helpers.it("writes crash dumps into the logs folder", function()
		with_paths({ XDG_STATE_HOME = "/state" }, {}, function()
			package.loaded["modules.diagnostics.crash_reporter"] = nil
			local CrashReporter = require("modules.diagnostics.crash_reporter")
			helpers.assert_eq(CrashReporter.get_crash_dir(), "/state/ergopti_plus/logs/crash_reports")
			package.loaded["modules.diagnostics.crash_reporter"] = nil
		end)
	end)
end)
