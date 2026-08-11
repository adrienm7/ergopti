--- tests/unit/modules/llm/test_ollama_daemon_log_rollover.lua

--- ==============================================================================
--- MODULE: Ollama Daemon Daily Log Rollover Regression
--- DESCRIPTION:
--- Exercises all real daemon-launch entry points and verifies that their
--- long-lived output pipelines derive the daily filename when each line is
--- written. Capturing Logger.UNIFIED_LOG_FILE in the launch command pins a
--- daemon started before midnight to yesterday's file for its whole lifetime.
--- ==============================================================================

local helpers = require("tests.helpers")

local SENTINEL_LOG = "/tmp/ErgoptiPlus_2099-01-01.log"

local function get_upvalue(fn, wanted)
	if type(fn) ~= "function" then return nil end
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == wanted then return value end
	end
	return nil
end

local function set_upvalue(fn, wanted, replacement)
	if type(fn) ~= "function" then return false end
	for index = 1, 100 do
		local name = debug.getupvalue(fn, index)
		if not name then break end
		if name == wanted then
			debug.setupvalue(fn, index, replacement)
			return true
		end
	end
	return false
end

local function assert_runtime_daily_sink(command, owner)
	helpers.assert_true(type(command) == "string" and command ~= "",
		owner .. " must submit a non-empty daemon command")
	helpers.assert_true(command:find("/tmp", 1, true) ~= nil,
		owner .. " must retain the configured log directory")
	helpers.assert_true(command:find(SENTINEL_LOG, 1, true) == nil,
		owner .. " must not snapshot Logger.UNIFIED_LOG_FILE into a long-lived daemon")
	helpers.assert_true(command:find("%Y-%m-%d", 1, true) ~= nil,
		owner .. " must derive the destination date at write time")
end

helpers.describe("Ollama daemon log rollover", function()
	helpers.it("POSIX-quotes the executable and stable configured directory", function()
		local Builder = require("modules.llm.ollama_server_command")
		local text_utils = require("infra.text_utils")
		local ollama_bin = "/Applications/Ollama O'Brien/$bin/ollama"
		local log_dir = "/Users/O'Brien/$logs/Ergopti Logs"
		local command, command_err = Builder.build(
			ollama_bin, log_dir .. "/ErgoptiPlus_2099-01-01.log")

		helpers.assert_eq(command_err, nil)
		helpers.assert_true(type(command) == "string" and command ~= "")
		helpers.assert_true(command:find(text_utils.shell_quote(ollama_bin) .. " serve", 1, true) ~= nil,
			"the executable must be one POSIX-quoted argv word")
		helpers.assert_true(command:find("LOG_DIR=" .. text_utils.shell_quote(log_dir), 1, true) ~= nil,
			"the configurable directory must be assigned through the canonical POSIX quoter")
		helpers.assert_true(command:find("ErgoptiPlus_2099-01-01.log", 1, true) == nil,
			"the builder must discard the launch-day filename")
		helpers.assert_true(command:find("%Y-%m-%d", 1, true) ~= nil,
			"the builder must derive the date inside the output loop")
	end)

	helpers.it("routes the API-owned daemon through a runtime daily sink", function()
		local ApiOllama = require("modules.llm.api_ollama")
		local ensure_impl = get_upvalue(ApiOllama.ensure_running, "ensure_ollama_running")
		local shell_runner = get_upvalue(ensure_impl, "ShellRunner")
		local scheduler = get_upvalue(ensure_impl, "TimerScheduler")
		local logger = get_upvalue(ensure_impl, "Logger")
		local binary_resolver = get_upvalue(ensure_impl, "OllamaBinary")
		helpers.assert_not_nil(shell_runner, "test must reach the real API launch transaction")
		helpers.assert_not_nil(scheduler, "test must reach the real API settle timer")
		helpers.assert_not_nil(logger, "test must reach the API logger dependency")

		local original_spawn = shell_runner.spawn
		local original_after = scheduler.after
		local original_resolve = binary_resolver and binary_resolver.resolve or nil
		local original_log = logger.UNIFIED_LOG_FILE
		local commands = {}
		local kill_done

		for name, value in pairs({
			_ollama_started = false,
			_ollama_starting = false,
			_ollama_start_generation = 0,
		}) do
			helpers.assert_true(set_upvalue(ensure_impl, name, value), "missing startup state: " .. name)
		end
		for _, name in ipairs({
			"_ollama_kill_task", "_ollama_launch_timer", "_ollama_serve_task", "_ollama_ambiguous_task",
		}) do
			helpers.assert_true(set_upvalue(ensure_impl, name, nil), "missing startup owner: " .. name)
		end

		logger.UNIFIED_LOG_FILE = SENTINEL_LOG
		if binary_resolver then
			binary_resolver.resolve = function() return "/fixture/ollama", nil, true end
		end
		shell_runner.spawn = function(program, args, on_done)
			commands[#commands + 1] = { program = program, args = args }
			if #commands == 1 then kill_done = on_done end
			return {
				start = function() return true end,
				terminate = function() return true end,
			}
		end
		scheduler.after = function(_, callback)
			callback()
			return { timer = {} }, true
		end

		local ok, err = pcall(function()
			helpers.assert_eq(ApiOllama.ensure_running(), true)
			helpers.assert_eq(type(kill_done), "function", "stale-process completion must be captured")
			kill_done()
			helpers.assert_not_nil(commands[2], "server launch must follow stale-process cleanup")
			assert_runtime_daily_sink(commands[2].args[2], "ApiOllama")
		end)

		shell_runner.spawn = original_spawn
		scheduler.after = original_after
		if binary_resolver then binary_resolver.resolve = original_resolve end
		logger.UNIFIED_LOG_FILE = original_log
		set_upvalue(ensure_impl, "_ollama_started", false)
		set_upvalue(ensure_impl, "_ollama_starting", false)
		set_upvalue(ensure_impl, "_ollama_kill_task", nil)
		set_upvalue(ensure_impl, "_ollama_launch_timer", nil)
		set_upvalue(ensure_impl, "_ollama_serve_task", nil)
		set_upvalue(ensure_impl, "_ollama_ambiguous_task", nil)
		if not ok then error(err) end
	end)

	helpers.it("routes the menu-owned daemon through the same runtime daily sink", function()
		local Logger = require("infra.logger")
		local original_log = Logger.UNIFIED_LOG_FILE
		local commands = {}
		Logger.UNIFIED_LOG_FILE = SENTINEL_LOG
		package.loaded["modules.llm.ollama_binary"] = {
			resolve = function() return "/fixture/ollama", nil, true end,
		}

		local Manager = helpers.load_with_stubs("ui.menu.menu_llm.models_manager_ollama", {
			fs = { attributes = function(path)
				if path == "/opt/homebrew/bin/ollama" then
					return { mode = "file", permissions = "rwxr-xr-x" }
				end
				return nil
			end },
			execute = function(command)
				commands[#commands + 1] = command
				return "", true
			end,
			timer = { doAfter = function() return { stop = function() end } end },
		})

		local ok, err = pcall(function()
			local manager = Manager.new({}, {}, function() return 0 end)
			manager.check_requirements("test-model", function() end, function() end)
			local daemon_command
			for _, command in ipairs(commands) do
				if command:find("nohup", 1, true) then daemon_command = command; break end
			end
			helpers.assert_not_nil(daemon_command, "menu flow must reach the real daemon restart")
			assert_runtime_daily_sink(daemon_command, "models_manager_ollama")
		end)

		Logger.UNIFIED_LOG_FILE = original_log
		package.loaded["modules.llm.ollama_binary"] = nil
		if not ok then error(err) end
	end)

	helpers.it("passes the same runtime daily sink to the fresh-install bootstrap", function()
		local Logger = require("infra.logger")
		local original_log = Logger.UNIFIED_LOG_FILE
		local previous_progress = package.loaded["ui.download_window"]
		local task_args
		local task_done

		package.loaded["ui.download_window"] = {
			is_active = function() return false end,
			show = function() end,
			set_step = function() end,
			set_detail = function() end,
			set_progress = function() end,
			set_error = function() end,
			append_log = function() end,
			hide = function() end,
		}
		package.loaded["modules.llm.ollama_binary"] = {
			resolve = function() return nil, "not installed", false end,
		}
		Logger.UNIFIED_LOG_FILE = SENTINEL_LOG

		local Checker = helpers.load_with_stubs("modules.llm.ollama_deps_checker", {
			fs = { attributes = function() return "file" end },
			task = {
				new = function(_, callback, args)
					task_args = args
					task_done = callback
					return {
						setStreamingCallback = function() return true end,
						start = function() return true end,
					}
				end,
			},
		})
		helpers.assert_true(set_upvalue(Checker.check_and_install_deps,
			"resolve_project_root", function() return "/repo" end),
			"test must control the real bootstrap path resolver")

		local ok, err = pcall(function()
			Checker.check_and_install_deps()
			helpers.assert_true(type(task_args) == "table", "bootstrap task arguments must be captured")
			assert_runtime_daily_sink(task_args[2], "ollama_deps_checker")
		end)

		if type(task_done) == "function" then task_done(0, "", "") end
		Logger.UNIFIED_LOG_FILE = original_log
		package.loaded["ui.download_window"] = previous_progress
		package.loaded["modules.llm.ollama_binary"] = nil
		if not ok then error(err) end
	end)
end)
