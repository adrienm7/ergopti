--- tests/unit/ai/engine/ollama/test_daemon_log_rollover.lua

--- ==============================================================================
--- MODULE: Ollama Daemon Daily Log Rollover Regression
--- DESCRIPTION:
--- Exercises all real daemon-launch entry points and verifies that their
--- long-lived output pipelines derive the daily filename when each line is
--- written. Capturing today's log path in the launch command pins a
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

local function assert_runtime_daily_sink(command, owner, port)
	helpers.assert_true(type(command) == "string" and command ~= "",
		owner .. " must submit a non-empty daemon command")
	helpers.assert_true(command:find("/tmp", 1, true) ~= nil,
		owner .. " must retain the configured log directory")
	helpers.assert_true(command:find(SENTINEL_LOG, 1, true) == nil,
		owner .. " must not snapshot today's log file into a long-lived daemon")
	helpers.assert_true(command:find("%Y-%m-%d", 1, true) ~= nil,
		owner .. " must derive the destination date at write time")
	helpers.assert_true(command:find("127.0.0.1:" .. tostring(port), 1, true) ~= nil,
		owner .. " must bind the daemon to the canonical configured port")
	helpers.assert_true(command:find('read -r LINE || [ -n "$LINE" ]', 1, true) ~= nil,
		owner .. " must preserve a final log line without a trailing newline")
end

-- Native service ownership is exercised here; its missing configured daily sink
-- is a separate production debt. The stock builder's daily loop remains below.
local function with_foreground(port, callback)
	helpers.with_stub_scope({
		"ai.engine.api.ollama", "ai.adapters.managed_ollama_daemon", "core.process.adapters.shell_runner",
		"core.lifecycle.engine.core.managed_ollama_daemon_receipt", "core.lifecycle.engine.core.managed_ollama_daemon_lifecycle",
		"ai.engine.ollama.binary", "ai.engine.ollama.server_command", "ai.engine.bootstrap.managed_native_python",
		"ai.engine.ollama.endpoint", "core.fs.adapters.file_system", "core.process.adapters.task_lifecycle",
		"core.network.adapters.http_client", "core.events.timer_scheduler", "core.fs.adapters.json_codec",
		"ai.engine.api.common", "ai.engine.api.parser", "ai.engine.settings.profiles",
		"ai.engine.prediction.progressive_reveal", "core.logger.engine.logger", "core.ui.engine.notifications", "core.i18n.engine.i18n",
		"shortcuts.engine.script_control", "ai.ui.menu.models.manager_ollama",
		"ai.ui.menu.requirement_operation_registry",
	}, function()
		local fixture = { tasks = {}, builds = {} }
		local nonce = "0000000000000000000000000000f101"
		local owner_script = helpers.driver_root() .. "ai/engine/ollama/managed_ollama_serve.py"
		local logger = helpers.make_logger_stub()
		logger.today_log_path = function() return SENTINEL_LOG end
		package.loaded["core.logger.engine.logger"] = logger
		package.loaded["core.ui.engine.notifications"] = { notify = function() return true end }
		package.loaded["core.network.adapters.http_client"] = { new = function()
			return { cancel = function() return true end, isActive = function() return false end,
				isSettled = function() return true end }
		end }
		package.loaded["core.events.timer_scheduler"] = {
			after = function() error("rollover context control must not acquire a detached launch or readiness timer") end,
			cancel = function() return true end,
		}
		package.loaded["core.fs.adapters.json_codec"] = { encode = function() return "{}" end, decode = function() return {} end }
		package.loaded["ai.engine.ollama.binary"] = {
			SOURCE_NATIVE_MANAGED = "native_managed",
			resolve = function() return "/fixture/ollama", nil, "native_managed" end,
			native_candidate = function() return "/fixture/ollama", { admission = 30, idle = 60, retirement = 10 } end,
		}
		package.loaded["ai.engine.bootstrap.managed_native_python"] = { resolve = function() return "/fixture/python" end }
		package.loaded["core.fs.adapters.file_system"] = { exists = function(path)
			helpers.assert_eq(path, owner_script, "the real builder must ask for its canonical source owner")
			return true
		end }
		package.loaded["ai.engine.ollama.endpoint"] = {
			read_port_override = function() return port end, get_default_port = function() return port end,
			get_port = function() return port end,
			get_base_url = function() return "http://127.0.0.1:" .. tostring(port) end,
		}
		package.loaded["ai.engine.api.parser"], package.loaded["ai.engine.settings.profiles"] = {}, {}
		package.loaded["ai.engine.prediction.progressive_reveal"] = {}
		package.loaded["ai.engine.api.common"] = { DEFAULT_DEDUPLICATION_ENABLED = true,
			OLLAMA_KEEP_ALIVE = "5m", get_retry_policy = function() return 1, 0, 0 end }
		local overrides = {
			host = { uuid = function() return "00000000-0000-0000-0000-00000000f101" end },
			execute = function() error("daemon context must not use synchronous native execution") end,
			task = { new = function(program, done, chunk, args)
				if type(chunk) == "table" then args, chunk = chunk, nil end
				local task = { program = program, args = args, completed = false, running = false, input_closes = 0 }
				function task:start() self.running = true; return true end
				function task:closeInput() self.input_closes = self.input_closes + 1; return true end
				function task:terminate() error("the native foreground protocol must retire through original stdin EOF") end
				function task:isRunning() return self.running end
				function task.frame(role) return "ERGOPTI_MANAGED_DAEMON_V1 " .. nonce .. " " .. role .. "\n" end
				function task.emit(bytes) helpers.assert_eq(type(chunk), "function"); return chunk(task, bytes, "") end
				function task.complete(status, stdout)
					task.running, task.completed = false, true
					return done(status, stdout or "", "")
				end
				fixture.tasks[#fixture.tasks + 1] = task
				return task
			end },
		}
		local api = helpers.load_with_stubs("ai.engine.api.ollama", overrides)
		local builder = require("ai.engine.ollama.server_command")
		local build = builder.build
		builder.build = function(...)
			fixture.builds[#fixture.builds + 1] = table.pack(...)
			return build(...)
		end
		fixture.api, fixture.overrides, fixture.shell = api, overrides, require("core.process.adapters.shell_runner")
		fixture.owner_script, fixture.nonce = owner_script, nonce
		local ok, err = xpcall(function() callback(fixture) end, debug.traceback)
		for _, task in ipairs(fixture.tasks) do
			if not task.completed then task.complete(78, task.program == "/bin/sh" and task.frame("RETIRED 78") or "") end
		end
		if not ok then error(err, 0) end
	end)
end

local function assert_native_context(fixture, task, port)
	local text_utils = require("core.text.engine.utils")
	helpers.assert_eq(#fixture.builds, 1, "only the API may build the foreground daemon command")
	local input = fixture.builds[1]
	helpers.assert_eq(input.n, 5)
	helpers.assert_eq(input[1], "/fixture/ollama")
	helpers.assert_eq(input[2], SENTINEL_LOG, "the real builder must receive the original configured daily log context")
	helpers.assert_eq(input[3], port)
	helpers.assert_eq(input[4], "native_managed")
	helpers.assert_eq(input[5], fixture.nonce)
	helpers.assert_eq(task.program, "/bin/sh")
	helpers.assert_eq(task.args[1], "-c")
	local command = task.args[2]
	helpers.assert_true(command:find("exec " .. text_utils.shell_quote("/fixture/python") .. " -IB ", 1, true) == 1)
	helpers.assert_true(command:find(text_utils.shell_quote(fixture.owner_script), 1, true) ~= nil)
	helpers.assert_true(command:find("--port " .. tostring(port), 1, true) ~= nil)
	helpers.assert_true(command:find("--log-directory '/tmp'", 1, true) ~= nil,
		"native capture must retain the configured stable directory, never the launch-day filename")
	helpers.assert_true(command:find("--caller-nonce " .. text_utils.shell_quote(fixture.nonce), 1, true) ~= nil)
	helpers.assert_true(command:find("--acquire-readiness --owned-stdin", 1, true) ~= nil)
	helpers.assert_eq(command:find("nohup", 1, true), nil)
	helpers.assert_eq(command:find("pkill", 1, true), nil)
	helpers.assert_eq(fixture.shell._active_tasks[task], true)
end

helpers.describe("Ollama daemon log rollover", function()
	helpers.it("POSIX-quotes the executable and stable configured directory", function()
		local Builder = require("ai.engine.ollama.server_command")
		local text_utils = require("core.text.engine.utils")
		local ollama_bin = "/Applications/Ollama O'Brien/$bin/ollama"
		local log_dir = "/Users/O'Brien/$logs/Ergopti Logs"
		local command, command_err = Builder.build(
			ollama_bin, log_dir .. "/ErgoptiPlus_2099-01-01.log", 45678)

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
		helpers.assert_true(command:find("OLLAMA_HOST='127.0.0.1:45678'", 1, true) ~= nil,
			"the builder must consume the configured daemon port")
		helpers.assert_true(command:find('read -r LINE || [ -n "$LINE" ]', 1, true) ~= nil,
			"the log loop must process a non-empty EOF tail")
	end)

	helpers.it("routes the API-owned daemon through a runtime daily sink", function()
		-- The caller's log context is retained through the real builder. Native
		-- output logging is currently a separate open production contract; unlike
		-- the stock builder below, this command has no shell daily-output loop.
		with_foreground(11434, function(fixture)
			local api = fixture.api
			local expected_port = api.get_port()
			helpers.assert_eq(api.ensure_running(), true)
			helpers.assert_eq(#fixture.tasks, 1, "the API must acquire only its original foreground task")
			local task = fixture.tasks[1]
			assert_native_context(fixture, task, expected_port)
			helpers.assert_eq(api.startup_idle(), false, "start acknowledgement cannot publish daemon readiness")
			task.emit(task.frame("ACTIVE") .. task.frame("READY"))
			helpers.assert_true(api.startup_idle())
			helpers.assert_eq(fixture.shell._active_tasks[task], true, "READY retains original daemon custody")
			task.emit(task.frame("RETIRED 0"))
			helpers.assert_eq(fixture.shell._active_tasks[task], true, "RETIRED without physical completion retains the task")
			task.complete(0)
			helpers.assert_eq(fixture.shell._active_tasks[task], nil)
			helpers.assert_eq(#fixture.tasks, 1, "retirement cannot acquire a successor daemon")
		end)
	end)

	helpers.it("routes the menu-owned daemon through the same runtime daily sink", function()
		with_foreground(45679, function(fixture)
			local Manager = helpers.load_with_stubs("ai.ui.menu.models.manager_ollama", fixture.overrides)
			local cancelled = 0
			local manager = Manager.new({}, {}, function() return 0 end)
			manager.check_requirements("test-model", function() error("unpublished daemon cannot satisfy model requirements") end,
				function() cancelled = cancelled + 1 end)
			helpers.assert_eq(#fixture.tasks, 1)
			local probe = fixture.tasks[1]
			helpers.assert_eq(probe.program, "/usr/bin/curl", "menu flow must probe readiness asynchronously before restarting")
			probe.complete(28, "")
			helpers.assert_eq(#fixture.tasks, 2, "menu flow must reach the full API foreground restart")
			local daemon = fixture.tasks[2]
			assert_native_context(fixture, daemon, 45679)
			helpers.assert_eq(cancelled, 0, "foreground admission alone cannot settle model requirements")
			helpers.assert_eq(fixture.api.startup_idle(), false)
			daemon.emit(daemon.frame("RETIRED 78"))
			helpers.assert_eq(cancelled, 0, "the manager retains original cleanup until native physical completion")
			daemon.complete(78)
			helpers.assert_eq(cancelled, 1, "native refusal must settle the original menu request exactly once")
			helpers.assert_eq(fixture.shell._active_tasks[daemon], nil)
			helpers.assert_eq(#fixture.tasks, 2, "refused publication cannot schedule a successor daemon")
		end)
	end)

	helpers.it("delegates a verified runtime's daemon launch to ApiOllama ownership", function()
		local Logger = require("core.logger.engine.logger")
		helpers.admit_logger_privacy(Logger)
		local original_log = Logger.today_log_path
		local previous_progress = package.loaded["updater.ui.download_window"]
		local previous_api = package.loaded["ai.engine.api.ollama"]
		local task_args
		local task_done
		local daemon_calls = 0

		package.loaded["updater.ui.download_window"] = {
			is_active = function() return false end,
			show = function() end,
			set_step = function() end,
			set_detail = function() end,
			set_progress = function() end,
			set_error = function() end,
			append_log = function() end,
			hide = function() end,
		}
		package.loaded["ai.engine.ollama.binary"] = {
			resolve = function() return "/fixture/Ergopti/ollama-native-http/ollama", nil, "native_managed" end,
		}
		package.loaded["ai.engine.api.ollama"] = {
			ensure_running = function()
				daemon_calls = daemon_calls + 1
				return true
			end,
		}
		package.loaded["core.process.adapters.task_lifecycle"] = nil
		Logger.today_log_path = function() return SENTINEL_LOG end

		local Checker = helpers.load_with_stubs("ai.engine.ollama.deps_checker", {
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
			-- Ergopti's own runtime is verified, then its daemon goes to ApiOllama.
			helpers.assert_true(Checker.check_and_install_deps())
			helpers.assert_true(type(task_args) == "table", "bootstrap task arguments must be captured")
			helpers.assert_eq(task_args[3], "/bin/bash")
			helpers.assert_eq(task_args[5], "/fixture/Ergopti/ollama-native-http/ollama",
				"the verifier receives the resolved runtime")
			helpers.assert_eq(task_args[6], "", "no install folder: the verifier never downloads")
			task_done(0, "", "")
			helpers.assert_eq(daemon_calls, 1, "the verified runtime's daemon is launched by ApiOllama")
			helpers.assert_eq(Checker.get_state(), "ready")
			helpers.assert_eq(Checker.get_daemon_state(), "pending")
			helpers.assert_eq(Checker.is_daemon_ready(), false, "a launch request alone cannot manufacture daemon readiness")
		end)

		Logger.today_log_path = original_log
		package.loaded["updater.ui.download_window"] = previous_progress
		package.loaded["ai.engine.api.ollama"] = previous_api
		package.loaded["ai.engine.ollama.binary"] = nil
		if not ok then error(err) end
	end)
end)
