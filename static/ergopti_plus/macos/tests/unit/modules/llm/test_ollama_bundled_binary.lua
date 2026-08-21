--- tests/unit/modules/llm/test_ollama_bundled_binary.lua

--- ==============================================================================
--- MODULE: Bundled Ollama Executable Contract Regression
--- DESCRIPTION:
--- Drives the real executable resolver and all three launch surfaces with the
--- `ERGOPTI_OLLAMA_BIN` path exported by the native launcher. A bundled build
--- must never fall back to Homebrew, PATH, or a network install while its owned
--- executable is valid, and must fail closed if that owned file becomes unsafe.
--- ==============================================================================

local helpers = require("tests.helpers")

local FIXTURE_BIN = "/Fixture/Ergopti Plus.app/Contents/Resources/Tools/Ollama/ollama"

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

local function override_environment()
	local original_getenv = os.getenv
	os.getenv = function(name)
		if name == "ERGOPTI_OLLAMA_BIN" then return FIXTURE_BIN end
		return original_getenv(name)
	end
	return function() os.getenv = original_getenv end
end

helpers.describe("bundled Ollama executable contract", function()
	helpers.it("fails closed when the launcher-owned file is not executable", function()
		local restore_environment = override_environment()
		package.loaded["modules.llm.ollama_binary"] = nil
		local Resolver = helpers.load_with_stubs("modules.llm.ollama_binary", {
			fs = { attributes = function(path)
				if path == FIXTURE_BIN then
					return { mode = "file", permissions = "rw-r--r--" }
				end
				if path == "/opt/homebrew/bin/ollama" then
					return { mode = "file", permissions = "rwxr-xr-x" }
				end
				return nil
			end },
		})

		local ok, err = pcall(function()
			local path, resolve_err, managed = Resolver.resolve()
			helpers.assert_eq(path, nil,
				"an invalid managed bundle must not be hidden by a system fallback")
			helpers.assert_eq(managed, true)
			helpers.assert_true(type(resolve_err) == "string"
				and resolve_err:find("ERGOPTI_OLLAMA_BIN", 1, true) ~= nil,
				"the failure must identify the broken launcher contract")
		end)

		restore_environment()
		if not ok then error(err) end
	end)

	helpers.it("launches the API-owned server from the exported bundle path", function()
		local restore_environment = override_environment()
		local ApiOllama = require("modules.llm.api_ollama")
		local ensure_impl = get_upvalue(ApiOllama.ensure_running, "ensure_ollama_running")
		local shell_runner = get_upvalue(ensure_impl, "ShellRunner")
		local scheduler = get_upvalue(ensure_impl, "TimerScheduler")
		local resolver = get_upvalue(ensure_impl, "OllamaBinary")
		local executable_probe = resolver and get_upvalue(resolver.resolve, "is_executable_file")
		local resolver_hs = get_upvalue(executable_probe, "hs")
		helpers.assert_not_nil(resolver_hs, "test must reach the real resolver filesystem port")

		local original_attributes = resolver_hs.fs.attributes
		local original_spawn = shell_runner.spawn
		local original_after = scheduler.after
		local kill_done
		local serve_command
		resolver_hs.fs.attributes = function(path, ...)
			if path == FIXTURE_BIN then
				return { mode = "file", permissions = "rwxr-xr-x" }
			end
			return original_attributes(path, ...)
		end
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
			set_upvalue(ensure_impl, name, nil)
		end
		shell_runner.spawn = function(_, args, on_done)
			if not kill_done then kill_done = on_done else serve_command = args[2] end
			return { start = function() return true end, terminate = function() return true end }
		end
		scheduler.after = function(_, callback)
			callback()
			return { timer = {} }, true
		end

		local ok, err = pcall(function()
			helpers.assert_eq(ApiOllama.ensure_running(), true)
			helpers.assert_eq(type(kill_done), "function")
			kill_done()
			helpers.assert_true(type(serve_command) == "string"
				and serve_command:find(FIXTURE_BIN, 1, true) ~= nil,
				"the API server command must use the exact launcher-exported executable")
		end)

		resolver_hs.fs.attributes = original_attributes
		shell_runner.spawn = original_spawn
		scheduler.after = original_after
		set_upvalue(ensure_impl, "_ollama_started", false)
		set_upvalue(ensure_impl, "_ollama_starting", false)
		set_upvalue(ensure_impl, "_ollama_kill_task", nil)
		set_upvalue(ensure_impl, "_ollama_launch_timer", nil)
		set_upvalue(ensure_impl, "_ollama_serve_task", nil)
		set_upvalue(ensure_impl, "_ollama_ambiguous_task", nil)
		restore_environment()
		if not ok then error(err) end
	end)

	helpers.it("uses the exported path for both menu server and CLI tasks", function()
		local restore_environment = override_environment()
		local previous_shell_runner = package.loaded["adapters.shell_runner"]
		local previous_timer_scheduler = package.loaded["adapters.timer_scheduler"]
		local function hs_overrides(task_bins)
			return {
				fs = { attributes = function(path)
					if path == FIXTURE_BIN then
						return { mode = "file", permissions = "rwxr-xr-x" }
					end
					return nil
				end },
				execute = function() error("menu Ollama work must not use hs.execute") end,
				task = { new = function(bin, _done, _stream, _args)
					task_bins[#task_bins + 1] = bin
					local task = {}
					function task:start() return self end
					return task
				end },
				timer = { doAfter = function() return { stop = function() end } end },
			}
		end
		local function install_async_ports(server_ready, commands)
			package.loaded["adapters.shell_runner"] = {
				spawn = function(program, args, on_done)
					local command = {program = program, args = args, on_done = on_done}
					commands[#commands + 1] = command
					return {
						start = function()
							if program == "/usr/bin/curl" then
								on_done(server_ready and 0 or 28,
									server_ready and '{"version":"fixture"}' or "", "")
							end
							return true
						end,
						terminate = function() return true, "pending" end,
					}
				end,
			}
			package.loaded["adapters.timer_scheduler"] = {
				after = function() error("this fixture must not advance past daemon launch") end,
				cancel = function() return true end,
			}
		end

		local commands, task_bins = {}, {}
		package.loaded["modules.llm.ollama_binary"] = nil
		package.loaded["adapters.task_lifecycle"] = nil
		install_async_ports(false, commands)
		local Manager = helpers.load_with_stubs("ui.menu.menu_llm.models_manager_ollama",
			hs_overrides(task_bins))
		local manager = Manager.new({}, {}, function() return 0 end)
		manager.check_requirements("test-model", function() end, function() end)
		local daemon_command
		for _, command in ipairs(commands) do
			if command.program == "/bin/bash" then daemon_command = command.args[2]; break end
		end

		package.loaded["modules.llm.ollama_binary"] = nil
		package.loaded["adapters.task_lifecycle"] = nil
		install_async_ports(true, commands)
		Manager = helpers.load_with_stubs("ui.menu.menu_llm.models_manager_ollama",
			hs_overrides(task_bins))
		manager = Manager.new({}, {}, function() return 0 end)
		manager.check_requirements("test-model", function() end, function() end)

		local ok, err = pcall(function()
			helpers.assert_true(type(daemon_command) == "string"
				and daemon_command:find(FIXTURE_BIN, 1, true) ~= nil,
				"the menu-owned server command must use the exported executable")
			helpers.assert_eq(task_bins[#task_bins], FIXTURE_BIN,
				"the menu CLI task must use the same exported executable")
		end)

		restore_environment()
		package.loaded["adapters.shell_runner"] = previous_shell_runner
		package.loaded["adapters.timer_scheduler"] = previous_timer_scheduler
		if not ok then error(err) end
	end)

	helpers.it("passes the exported executable through the bootstrap boundary", function()
		local restore_environment = override_environment()
		local Logger = require("infra.logger")
		local previous_progress = package.loaded["ui.download_window"]
		local task_args
		local task_done
		package.loaded["ui.download_window"] = {
			is_active = function() return false end,
			show = function() end, set_step = function() end, set_detail = function() end,
			set_progress = function() end, set_error = function() end,
			append_log = function() end, hide = function() end,
		}
		package.loaded["modules.llm.ollama_binary"] = nil
		package.loaded["adapters.task_lifecycle"] = nil
		local Checker = helpers.load_with_stubs("modules.llm.ollama_deps_checker", {
			fs = { attributes = function(path, attribute)
				if path == FIXTURE_BIN then
					if attribute == "mode" then return "file" end
					return { mode = "file", permissions = "rwxr-xr-x" }
				end
				if attribute == "mode" then return "file" end
				return { mode = "directory", permissions = "rwxr-xr-x" }
			end },
			task = { new = function(_, callback, _stream, args)
				task_args = args
				task_done = callback
				local task = {
					setStreamingCallback = function() return true end,
				}
				function task:start() return self end
				return task
			end },
		})
		helpers.assert_true(set_upvalue(Checker.check_and_install_deps,
			"resolve_project_root", function() return "/repo" end))

		local ok, err = pcall(function()
			Checker.check_and_install_deps()
			helpers.assert_true(type(task_args) == "table")
			helpers.assert_true(task_args[2]:find(FIXTURE_BIN, 1, true) ~= nil,
				"the bootstrap server pipeline must use the exported executable")
			helpers.assert_eq(task_args[3], FIXTURE_BIN,
				"the bootstrap shell must receive the pre-provisioned executable")
		end)

		if type(task_done) == "function" then task_done(0, "", "") end
		package.loaded["ui.download_window"] = previous_progress
		restore_environment()
		if not ok then error(err) end
	end)
end)
