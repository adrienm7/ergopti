--- tests/support/ui/menu/menu_llm/ollama/ollama_readiness_async_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_ollama_readiness_async
--- DESCRIPTION:
--- Prelude shared by the test_ollama_readiness_async_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

-- These ports load the actual API, daemon lifecycle and shared fixed-frame
-- receiver. Only their original physical task is controlled; manager probes,
-- retry timers and descendant ownership remain the fixture's existing ports.
-- This is source/model receiving, not native daemon or API authentication.
local Foreground = assert(loadfile(helpers.driver_root()
	.. "../../../tools/test/fixtures/managed_ollama_foreground_ports.lua"))()
-- Match the original manager's literal loopback probe port; no native endpoint
-- or daemon traffic is synthesized by these controlled task ports.
Foreground.PORT = 11434
local source_root = helpers.driver_root() .. "../../.."

local function foreground_fixture(options)
	local previous_path = package.path
	local ok, daemon = xpcall(function()
		return Foreground.new(source_root, source_root, options)
	end, debug.traceback)
	package.path = previous_path
	if not ok then error(daemon, 0) end
	return daemon
end

local function publish_daemon_ready(daemon)
	local task = assert(daemon.tasks[1])
	helpers.assert_true(task.owned)
	helpers.assert_true(task.private)
	helpers.assert_eq(daemon.calls[1][4], "native_managed",
		"the actual API must classify the admitted foreground source before launch")
	helpers.assert_eq(task.settled, false)
	task.emit("ERGOPTI_MANAGED_DAEMON_V1 " .. Foreground.NONCE .. " ACTIVE\n")
	task.emit("ERGOPTI_MANAGED_DAEMON_V1 " .. Foreground.NONCE .. " READY\n")
	helpers.assert_eq(task.settled, false,
		"READY publishes readiness while the original foreground lifetime stays owned")
end

local function retire_daemon(daemon, status, before_completion)
	local task = assert(daemon.tasks[1])
	task.emit("ERGOPTI_MANAGED_DAEMON_V1 " .. Foreground.NONCE
		.. " RETIRED " .. tostring(status) .. "\n")
	if before_completion then before_completion() end
	task.complete(status, "", "")
end

local MODULES = {
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"infra.text_utils",
	"modules.llm.api_ollama",
	"modules.llm.ollama_binary",
	"modules.llm.ollama_endpoint",
	"modules.llm.ollama_server_command",
	"modules.llm.network_env",
	"adapters.task_lifecycle",
	"adapters.shell_runner",
	"adapters.timer_scheduler",
	"adapters.http_client",
	"ui.download_window",
	"ui.menu.menu_llm.requirement_operation_registry",
	"ui.menu.menu_llm.models_manager_ollama",
}

--- Receives argv from the actual emitted wrapper through the canonical Bash owner.
--- The fixture's old args field describes the executed CLI; native_args retains
--- the exact shell constructor. No shell text is parsed into expected argv.
--- @param executable string Actual task constructor executable.
--- @param argv table Actual task constructor arguments.
--- @return table Executed CLI arguments.
local retained_receivers = {}

local function receive_pull_argv(executable, argv)
	helpers.assert_eq(executable, "/bin/bash")
	helpers.assert_eq(#argv, 2)
	helpers.assert_eq(argv[1], "-c")
	helpers.assert_type(argv[2], "string")
	local packet_path = helpers.temp_dir() .. "/ollama-pull-argv-" .. tostring(os.time())
		.. "-" .. tostring(math.random(1, 1000000000)) .. ".sh"
	local owner = { path = packet_path }
	local function close_source()
		owner.file_close_attempted = true
		local ok, closed, err = pcall(function() return owner.file:close() end)
		if ok and closed == true then owner.file = nil; return true end
		return nil, tostring(ok and err or closed)
	end
	local function close_process()
		owner.process_close_attempted = true
		local ok, closed, reason, code = pcall(function() return owner.process:close() end)
		local terminal = ok and (closed == true or closed == nil)
			and (reason == "exit" or reason == "signal")
			and type(code) == "number" and code >= 0 and code % 1 == 0
		if terminal then
			owner.process = nil
			return true, closed, reason, code
		end
		return nil, tostring(ok and reason or closed)
	end
	local function quote(value)
		if package.config:sub(1, 1) ~= "/" then
			helpers.assert_true(not value:find('["%%\r\n]'), "unsafe native fixture command path")
			return '"' .. value .. '"'
		end
		return "'" .. value:gsub("'", "'\\''") .. "'"
	end
	local ok, result = xpcall(function()
		owner.file = assert(io.open(packet_path, "w"))
		owner.packet_created = true
		assert(owner.file:write(argv[2]))
		assert(close_source())
		local receiver = helpers.driver_root() .. "../../../tools/test/fixtures/macos-opaque-exec-argv.cjs"
		owner.process = assert(io.popen("node " .. quote(receiver) .. " " .. quote(packet_path), "r"))
		local output = assert(owner.process:read("*a"))
		local retired, closed, reason, code = close_process()
		assert(retired, closed)
		helpers.assert_eq(closed, true, output)
		helpers.assert_eq(reason, "exit")
		helpers.assert_eq(code, 0)
		local packet = assert(require("json").decode(output))
		helpers.assert_eq(packet.executable, "/opt/homebrew/bin/ollama")
		helpers.assert_type(packet.args, "table")
		return packet.args
	end, debug.traceback)
	local cleanup_error
	-- Close every acquired handle on the same exceptional path. An ambiguous
	-- attempted close is not retried and cannot admit packet removal.
	if owner.process and not owner.process_close_attempted then
		local closed, err = close_process()
		if not closed then cleanup_error = err end
	end
	if owner.file and not owner.file_close_attempted then
		local closed, err = close_source()
		if not closed and not cleanup_error then cleanup_error = err end
	end
	if owner.file or owner.process then
		cleanup_error = cleanup_error or "receiver handle closure was not acknowledged"
	elseif owner.packet_created then
		local removed_ok, removed, err = pcall(os.remove, packet_path)
		if removed_ok and removed == true then owner.packet_created = false else
			cleanup_error = tostring(removed_ok and err or removed)
		end
	end
	if owner.file or owner.process or owner.packet_created then
		-- Returned module state strongly retains unresolved owners; GC is never
		-- an acknowledgement, and this fixture adds no reaper or timer.
		owner.original_error = not ok and result or nil
		owner.result = ok and result or nil
		owner.cleanup_error = cleanup_error
		retained_receivers[#retained_receivers + 1] = owner
	end
	if not ok then error(result, 0) end
	if cleanup_error then error(cleanup_error, 0) end
	return result
end

local function with_fixture(spec, body)
	spec = spec or {}
	local saved_modules = {}
	for _, name in ipairs(MODULES) do saved_modules[name] = package.loaded[name] end
	local saved_hs = _G.hs

	local ok, err = xpcall(function()
		local synchronous_exec_calls = 0
		local spawns = {}
		local timers = {}
		local native_tasks = {}
		local http_callbacks = {}
		local shared_system_checks = {}
		local notifications = {}
		local download_options = nil
		local starts = spec.start_results or {}
		local synchronous_completions = spec.synchronous_completions or {}
		local native_synchronous_completions = spec.native_synchronous_completions or {}
		local timer_commits = spec.timer_commits or {}
		local task_starts = spec.task_start_results or {}
		local native_task_results = spec.native_task_results or {}
		local menu_updates = 0

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = {
			notify = function(...)
				notifications[#notifications + 1] = table.pack(...)
				return true
			end,
		}
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.text_utils"] = {
			shell_quote = function(value) return "'" .. tostring(value) .. "'" end,
		}
		package.loaded["modules.llm.ollama_binary"] = {
			resolve = function() return "/opt/homebrew/bin/ollama" end,
		}
		package.loaded["modules.llm.ollama_server_command"] = {
			build = function() return "exec /opt/homebrew/bin/ollama serve" end,
		}
		local window_session = 0
		package.loaded["ui.download_window"] = {
			session_id = function() return window_session end,
			is_active = function() return window_session > 0 end,
			show = function(options)
				window_session = window_session + 1
				download_options = options
				return true
			end,
			update = function() return true end,
			complete = function() return true end,
		}

		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local index = #spawns + 1
				local record = {
					executable = executable,
					args = args,
					starts = 0,
					completions = 0,
					settled = false,
					settlement_observers = {},
				}
				local handle = {}
				function handle.start()
					record.starts = record.starts + 1
					local completion = synchronous_completions[index]
					if completion ~= nil then
						record.complete(table.unpack(completion, 1, completion.n or #completion))
					end
					if starts[index] == "nil" then
						record.settled = true
						return nil
					end
					if starts[index] == false then
						record.settled = true
						return false
					end
					return true
				end
				function handle.terminate() return true, "pending" end
				function handle.isSettled() return record.settled end
				function handle.onSettled(observer)
					if record.settled then observer() else
						record.settlement_observers[#record.settlement_observers + 1] = observer
					end
					return true
				end
				function record.complete(code, stdout, stderr)
					record.completions = record.completions + 1
					local first = not record.settled
					record.settled = true
					local result = on_done(code, stdout, stderr)
					if first then
						local observers = record.settlement_observers
						record.settlement_observers = {}
						for _, observer in ipairs(observers) do observer() end
					end
					return result
				end
				record.handle = handle
				spawns[index] = record
				return handle
			end,
		}

		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				local index = #timers + 1
				local handle = {
					cancelled = false,
					timer = {},
					settlement_observers = {},
				}
				local record = {delay = delay, handle = handle, fires = 0}
				function record.fire()
					record.fires = record.fires + 1
					handle.timer = nil
					local observers = handle.settlement_observers
					handle.settlement_observers = {}
					for _, observer in ipairs(observers) do observer() end
					return callback()
				end
				timers[index] = record
				return handle, timer_commits[index] ~= false
			end,
			cancel = function(handle)
				handle.cancelled = true
				handle.timer = nil
				local observers = handle.settlement_observers
				handle.settlement_observers = {}
				for _, observer in ipairs(observers) do observer() end
				return true
			end,
			onSettled = function(handle, observer)
				if handle.timer == nil then observer() else
					handle.settlement_observers[#handle.settlement_observers + 1] = observer
				end
				return true
			end,
		}

		package.loaded["adapters.http_client"] = {
			new = function()
				local client = { settled = false, observers = {} }
				function client.post(url, headers, body, callback)
					local record = { url = url, body = body, headers = headers }
					function record.callback(status, response_body, response_headers)
						local first = not client.settled
						local result = callback({
							status = status,
							body = response_body,
							headers = response_headers,
						})
						if first then
							client.settled = true
							local observers = client.observers
							client.observers = {}
							for _, observer in ipairs(observers) do observer() end
						end
						return result
					end
					http_callbacks[#http_callbacks + 1] = record
					return true
				end
				function client.cancel()
					if not client.settled then
						client.settled = true
						local observers = client.observers
						client.observers = {}
						for _, observer in ipairs(observers) do observer() end
					end
					return true
				end
				function client.onSettled(observer)
					if client.settled then observer() else
						client.observers[#client.observers + 1] = observer
					end
					return true
				end
				return client
			end,
		}

		local manager
		package.loaded["adapters.task_lifecycle"] = {
			native = function(label, executable, on_done, on_chunk_or_args, args)
				local index = #native_tasks + 1
				if native_task_results[index] == false then return nil end
				if type(spec.on_native_construct) == "function" then
					spec.on_native_construct(manager, label)
				end
				local on_stream = type(on_chunk_or_args) == "function"
					and on_chunk_or_args or nil
				local argv = on_stream and (args or {}) or on_chunk_or_args
				local executed_args = argv
				if label == "Ollama model pull" then
					executed_args = receive_pull_argv(executable, argv)
				end
				local task = {
					index = index,
					label = label,
					executable = executable,
					args = executed_args, native_args = argv, native_executable = executable,
					on_done = on_done,
					on_stream = on_stream,
					starts = 0,
					terminate_calls = 0,
					running = false,
				}
				function task:terminate()
					self.terminate_calls = self.terminate_calls + 1
					return self
				end
				function task:isRunning() return self.running end
				native_tasks[#native_tasks + 1] = task
				return task
			end,
			start = function(task)
				task.starts = task.starts + 1
				task.running = true
				local completion = native_synchronous_completions[task.index]
				if completion ~= nil then
					task.running = false
					task.on_done(table.unpack(completion, 1, completion.n or #completion))
				end
				if task_starts[task.index] == "nil" then
					task.running = false
					return nil
				end
				if task_starts[task.index] == false then
					task.running = false
					return false
				end
				return true
			end,
		}

		_G.hs = {
			execute = function()
				synchronous_exec_calls = synchronous_exec_calls + 1
				error("synchronous hs.execute is forbidden in readiness")
			end,
			timer = {
				doAfter = function() return {stop = function() return true end} end,
				secondsSinceEpoch = function() return 100 end,
			},
			json = {encode = function() return "{}" end},
			http = {asyncPost = function(url, body, headers, callback)
				http_callbacks[#http_callbacks + 1] = {
					url = url, body = body, headers = headers, callback = callback,
				}
				return nil
			end},
			urlevent = {openURL = function() return true end},
		}

		local daemon = foreground_fixture({
			start = function(task)
				if spec.daemon_start_result == false then
					-- A refused start may retain partial native acquisition. The
					-- attempted original task stays unsettled until RETIRED78 plus
					-- its exact physical completion; start false is no closure ACK.
					return false
				end
				return true
			end,
		})
		package.loaded["modules.llm.api_ollama"] = daemon.api
		local endpoint_port = spec.ollama_port or 11434
		package.loaded["modules.llm.ollama_endpoint"] = {
			get_port = function() return endpoint_port end,
			get_base_url = function() return "http://127.0.0.1:" .. tostring(endpoint_port) end,
		}

		-- Own the genuine methods with an independently read native policy path.
		-- The fixture's other cached adapter doubles cannot select a fake policy.
		local native_root = helpers.driver_root():gsub("\\", "/")
		package.loaded["modules.llm.network_env"] = nil
		local network = require("modules.llm.network_env")
		local native_policy_path = native_root .. "modules/llm/network-retry.sh"
		local native_policy = assert(io.open(native_policy_path, "r"))
		assert(native_policy:close())
		network.policy_path = function() return native_policy_path end
		package.loaded["modules.llm.network_env"] = network
		package.loaded["ui.menu.menu_llm.models_manager_ollama"] = nil
		manager = require("ui.menu.menu_llm.models_manager_ollama").new({
			active_tasks = {},
			save_prefs = function() return true end,
			update_menu = function()
				menu_updates = menu_updates + 1
				return true
			end,
			shared_system_check = function(...)
				shared_system_checks[#shared_system_checks + 1] = table.pack(...)
				if type(spec.shared_system_check) == "function" then
					return spec.shared_system_check(...)
				end
				return false
			end,
			state = {},
			keymap = {},
		}, {}, function() return 0 end)
		helpers.assert_eq(#timers, 1)
		helpers.assert_eq(timers[1].delay, 0)
		helpers.assert_eq(
			package.loaded["adapters.timer_scheduler"].cancel(timers[1].handle), true)
		helpers.assert_eq(timers[1].handle.timer, nil)
		table.remove(timers, 1)

		body({
			manager = manager,
			set_ollama_port = function(port) endpoint_port = port end,
			daemon = daemon,
			spawns = spawns,
			timers = timers,
			native_tasks = native_tasks,
			http_callbacks = http_callbacks,
			download_options = function() return download_options end,
			shared_system_checks = shared_system_checks,
			notifications = notifications,
			menu_updates = function() return menu_updates end,
			synchronous_exec_calls = function() return synchronous_exec_calls end,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end

--- Accepts the real manager's download continuation without replacing it.
--- @param _target_model string The requested display model.
--- @param _backend string The backend label.
--- @param _repo string The resolved Ollama repository.
--- @param start_download function The manager-owned pull continuation.
--- @return boolean accepted Whether the pull accepted native ownership.
local function accept_model_download(_target_model, _backend, _repo, start_download)
	return start_download()
end

--- Drives a missing model through readiness, inventory, and pull dispatch.
--- @param fixture table The real-manager fixture.
--- @param freshness table Mutable generation state.
--- @return boolean accepted Whether the outer requirement request was accepted.
--- @return table terminal External terminal counters and failure reasons.
local function start_missing_model_pull(fixture, freshness)
	local terminal = {successes = 0, failures = 0, reasons = {}}
	local accepted = fixture.manager.check_requirements("missing-model", function()
		terminal.successes = terminal.successes + 1
		return true
	end, function(reason)
		terminal.failures = terminal.failures + 1
		terminal.reasons[#terminal.reasons + 1] = reason
		return true
	end, {is_current = function() return freshness.current end})

	fixture.spawns[1].complete(0, '{"version":"ready"}', "")
	helpers.assert_eq(fixture.native_tasks[1].args, {"list"},
		"the inventory task must receive the native four-argument argv form")
	helpers.assert_nil(fixture.native_tasks[1].on_stream)
	fixture.native_tasks[1].on_done(0, "NAME ID SIZE\n", "")
	return accepted, terminal
end

return {
	Foreground = Foreground,
	MODULES = MODULES,
	accept_model_download = accept_model_download,
	foreground_fixture = foreground_fixture,
	publish_daemon_ready = publish_daemon_ready,
	receive_pull_argv = receive_pull_argv,
	retained_receivers = retained_receivers,
	retire_daemon = retire_daemon,
	source_root = source_root,
	start_missing_model_pull = start_missing_model_pull,
	with_fixture = with_fixture,
}
