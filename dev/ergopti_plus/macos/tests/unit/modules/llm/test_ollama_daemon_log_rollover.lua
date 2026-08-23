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
		local launch_server

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
			local handle = { timer = {} }
			launch_server = function()
				handle.timer = nil
				callback()
			end
			return handle, true
		end

		local ok, err = pcall(function()
			helpers.assert_eq(ApiOllama.ensure_running(), true)
			helpers.assert_eq(type(kill_done), "function", "stale-process completion must be captured")
			kill_done()
			helpers.assert_eq(type(launch_server), "function")
			launch_server()
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
		local previous_shell_runner = package.loaded["adapters.shell_runner"]
		local previous_timer_scheduler = package.loaded["adapters.timer_scheduler"]
		local commands = {}
		Logger.UNIFIED_LOG_FILE = SENTINEL_LOG
		package.loaded["modules.llm.ollama_binary"] = {
			resolve = function() return "/fixture/ollama", nil, true end,
		}
		package.loaded["adapters.task_lifecycle"] = nil
		package.loaded["adapters.shell_runner"] = {
			spawn = function(program, args, on_done)
				local command = {program = program, args = args, on_done = on_done}
				commands[#commands + 1] = command
				return {
					start = function() return true end,
					terminate = function() return true, "pending" end,
				}
			end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function() error("restart rollover test must not reach readiness retry") end,
			cancel = function() return true end,
		}

		local Manager = helpers.load_with_stubs("ui.menu.menu_llm.models_manager_ollama", {
			fs = { attributes = function(path)
				if path == "/opt/homebrew/bin/ollama" then
					return { mode = "file", permissions = "rwxr-xr-x" }
				end
				return nil
			end },
			execute = function() error("menu daemon startup must not use hs.execute") end,
			timer = { doAfter = function() return { stop = function() end } end },
		})

		local ok, err = pcall(function()
			local manager = Manager.new({}, {}, function() return 0 end)
			manager.check_requirements("test-model", function() end, function() end)
			helpers.assert_eq(commands[1].program, "/usr/bin/curl",
				"menu flow must probe readiness asynchronously before restarting")
			commands[1].on_done(28, "", "timeout")
			helpers.assert_not_nil(commands[2], "menu flow must reach the real daemon restart")
			helpers.assert_eq(commands[2].program, "/bin/bash")
			assert_runtime_daily_sink(commands[2].args[2], "models_manager_ollama")
		end)

		Logger.UNIFIED_LOG_FILE = original_log
		package.loaded["modules.llm.ollama_binary"] = nil
		package.loaded["adapters.shell_runner"] = previous_shell_runner
		package.loaded["adapters.timer_scheduler"] = previous_timer_scheduler
		if not ok then error(err) end
	end)

	helpers.it("delegates fresh-install daemon launch to ApiOllama ownership", function()
		local Logger = require("infra.logger")
		local original_log = Logger.UNIFIED_LOG_FILE
		local previous_progress = package.loaded["ui.download_window"]
		local previous_api = package.loaded["modules.llm.api_ollama"]
		local task_args
		local task_done
		local daemon_calls = 0

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
		package.loaded["modules.llm.api_ollama"] = {
			ensure_running = function()
				daemon_calls = daemon_calls + 1
				return true
			end,
		}
		package.loaded["adapters.task_lifecycle"] = nil
		Logger.UNIFIED_LOG_FILE = SENTINEL_LOG

		local Checker = helpers.load_with_stubs("modules.llm.ollama_deps_checker", {
			fs = { attributes = function() return "file" end },
			task = {
				new = function(_, callback, _stream, args)
					task_args = args
					task_done = callback
					local task = {
						setStreamingCallback = function() return true end,
					}
					function task:start() return self end
					return task
				end,
			},
		})
		helpers.assert_true(set_upvalue(Checker.check_and_install_deps,
			"resolve_project_root", function() return "/repo" end),
			"test must control the real bootstrap path resolver")

		local ok, err = pcall(function()
			Checker.check_and_install_deps()
			helpers.assert_true(type(task_args) == "table", "bootstrap task arguments must be captured")
			helpers.assert_eq(task_args[3], "/bin/bash")
			helpers.assert_eq(task_args[5], "",
				"the install script receives only the optional resolved executable")
			task_done(0, "", "")
			helpers.assert_eq(daemon_calls, 1,
				"the checker must not detach its own unjoinable serve process")
		end)

		Logger.UNIFIED_LOG_FILE = original_log
		package.loaded["ui.download_window"] = previous_progress
		package.loaded["modules.llm.api_ollama"] = previous_api
		package.loaded["modules.llm.ollama_binary"] = nil
		if not ok then error(err) end
	end)
end)
