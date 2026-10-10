--- tests/unit/ui/menu/menu_llm/test_ollama_readiness_async.lua

-- =============================================================================
-- MODULE: Asynchronous Ollama Readiness Regression
-- DESCRIPTION:
-- Proves that readiness and delegated native daemon work is owned asynchronously,
-- generation-fenced, and terminal exactly once without blocking the Lua runloop.
-- Also proves that a requirement request receives every terminal from the real
-- pull continuation that it dispatches.
-- =============================================================================

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

helpers.describe("HS-025 Ollama readiness is asynchronous and generation-owned", function()
	helpers.it("HS-025 returns before the first readiness curl completes", function()
		with_fixture({}, function(fixture)
			local successes, cancellations = 0, {}
			local accepted = fixture.manager.check_requirements("demo", function()
				successes = successes + 1
			end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})

			helpers.assert_eq(accepted, true)
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
			helpers.assert_eq(#fixture.spawns, 1)
			helpers.assert_eq(fixture.spawns[1].executable, "/usr/bin/curl")
			helpers.assert_eq(fixture.spawns[1].args,
				{"-s", "--max-time", "5", "http://127.0.0.1:11434/api/version"})
			helpers.assert_eq(successes, 0)
			helpers.assert_eq(cancellations, {})
			helpers.assert_eq(#fixture.native_tasks, 0)

			fixture.spawns[1].complete(0, '{"version":"0.9"}', "")
			helpers.assert_eq(#fixture.native_tasks, 1,
				"readiness success may construct the model-list task only after completion")
			helpers.assert_contains(fixture.native_tasks[1].label, "requirement check")
			fixture.spawns[1].complete(0, '{"version":"duplicate"}', "")
			helpers.assert_eq(#fixture.native_tasks, 1,
				"duplicate native completion cannot advance the owner twice")
	end)
	end)

	helpers.it("HS-025 retries off-runloop and drops a stale success exactly once", function()
		with_fixture({}, function(fixture)
			local current = true
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return current end})

			fixture.spawns[1].complete(28, "", "timeout")
			helpers.assert_eq(#fixture.spawns, 1)
			helpers.assert_eq(#fixture.daemon.tasks, 1)
			helpers.assert_eq(fixture.daemon.tasks[1].executable, "/bin/sh")
			helpers.assert_eq(fixture.daemon.tasks[1].arguments[1], "-c",
				"the native foreground owner must not run user login-profile startup")
			helpers.assert_eq(#fixture.timers, 0)
			publish_daemon_ready(fixture.daemon)
			helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_eq(fixture.timers[1].delay, 0.5)
			helpers.assert_eq(#fixture.spawns, 1,
				"retry work cannot run inline from the daemon completion")

			fixture.timers[1].fire()
			helpers.assert_eq(#fixture.spawns, 2)
			current = false
			fixture.spawns[2].complete(0, '{"version":"late"}', "")
			helpers.assert_eq(cancellations, {"stale"})
			helpers.assert_eq(#fixture.native_tasks, 0)
			fixture.spawns[2].complete(0, '{"version":"duplicate"}', "")
			helpers.assert_eq(cancellations, {"stale"})
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
	end)
	end)

	helpers.it("HS-025 reports readiness task start refusal synchronously", function()
		with_fixture({start_results = {false}}, function(fixture)
			local cancellations = {}
			local accepted = fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(cancellations, {"readiness_probe_start_refused"})
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
	end)
	end)

	helpers.it("HS-025 does not publish a synchronous completion before start commits", function()
		with_fixture({
			start_results = {"nil"},
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
		}, function(fixture)
			local cancellations = {}
			local accepted = fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(cancellations, {"readiness_probe_start_refused"})
			helpers.assert_eq(#fixture.native_tasks, 0,
				"an inline readiness result cannot construct model work before start commits")
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
	end)
		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
		}, function(fixture)
			local accepted = fixture.manager.check_requirements("demo", function() end, function() end,
				{is_current = function() return true end})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 1,
				"a buffered inline completion must advance exactly once after start commits")
		end)
	end)

	helpers.it("HS-025 reports retry timer refusal without inline fallback", function()
		with_fixture({timer_commits = {false}}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			publish_daemon_ready(fixture.daemon)
			helpers.assert_eq(cancellations, {"retry_timer_refused"})
			helpers.assert_eq(#fixture.spawns, 1,
				"a refused timer cannot burst the next readiness probe inline")
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
		end)
	end)

	helpers.it("HS-025 joins a replacement waiter without launching a second daemon", function()
		with_fixture({}, function(fixture)
			local generation = 1
			local a_cancellations = {}
			local b_successes, b_cancellations = 0, {}
			local accepted_a = fixture.manager.check_requirements("A", function() end, function(reason)
				a_cancellations[#a_cancellations + 1] = reason
			end, {is_current = function() return generation == 1 end})
			helpers.assert_eq(accepted_a, true)

			fixture.spawns[1].complete(28, "", "timeout")
			helpers.assert_eq(#fixture.spawns, 1)
			helpers.assert_eq(#fixture.daemon.tasks, 1)
			helpers.assert_eq(fixture.daemon.tasks[1].executable, "/bin/sh")
			generation = 2
			local accepted_b = fixture.manager.check_requirements("B", function()
				b_successes = b_successes + 1
			end, function(reason)
				b_cancellations[#b_cancellations + 1] = reason
			end, {is_current = function() return generation == 2 end})

			helpers.assert_eq(accepted_b, true)
			helpers.assert_eq(#fixture.spawns, 1,
				"a joined waiter must adopt the exact daemon owner instead of probing or restarting again")
			publish_daemon_ready(fixture.daemon)
			helpers.assert_eq(a_cancellations, {"stale"})
			helpers.assert_eq(b_cancellations, {})
			helpers.assert_eq(#fixture.timers, 1)
			-- Repeat the original physical observation with the same complete READY
			-- state; it cannot republish business readiness or create a new timer.
			for _, observer in ipairs(fixture.daemon.tasks[1].observers) do observer() end
			helpers.assert_eq(#fixture.timers, 1,
				"a duplicate restart completion cannot allocate a second retry owner")
			helpers.assert_eq(a_cancellations, {"stale"})

			fixture.timers[1].fire()
			helpers.assert_eq(#fixture.spawns, 2)
			fixture.spawns[2].complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(#fixture.native_tasks, 1)
			fixture.native_tasks[1].on_done(0, "NAME ID\nB fixture\n", "")
			helpers.assert_eq(#fixture.http_callbacks, 1)
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.spawns[2].complete(0, '{"version":"duplicate"}', "")

			helpers.assert_eq(b_successes, 1,
				"the current joined waiter must publish one outer success after duplicate completions")
			helpers.assert_eq(b_cancellations, {})
			helpers.assert_eq(a_cancellations, {"stale"})
			local restart_count = #fixture.daemon.tasks
			helpers.assert_eq(restart_count, 1,
				"rapid A-to-B replacement must retain one shared daemon restart capability")
		end)
	end)

	helpers.it("HS-025 settles restart start refusal and nonzero completion exactly once", function()
		with_fixture({daemon_start_result = false}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			helpers.assert_eq(cancellations, {"server task start"})
			helpers.assert_eq(fixture.daemon.tasks[1].settled, false,
				"start refusal retains the exact partial foreground transport")
			helpers.assert_eq(#fixture.timers, 0)
			retire_daemon(fixture.daemon, 78)
			helpers.assert_eq(cancellations, {"server task start"},
				"a completion delivered after start refusal must remain inert")
		end)

		with_fixture({}, function(fixture)
			local cancellations, details = {}, {}
			fixture.manager.check_requirements("demo", function() end, function(reason, detail)
				cancellations[#cancellations + 1] = reason
				details[#details + 1] = detail
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			-- The native protocol permits only the authentic refusal status78
			-- before READY; arbitrary exit7 without that receipt is retained debt.
			retire_daemon(fixture.daemon, 78, function()
				helpers.assert_eq(cancellations, {},
					"RETIRED alone cannot deliver the native terminal before physical settlement")
				helpers.assert_eq(#fixture.timers, 0)
				helpers.assert_eq(fixture.daemon.tasks[1].settled, false)
			end)
			fixture.daemon.tasks[1].complete(78, "", "duplicate")
			-- A failed restart leaves nothing at the endpoint: one reason for every
			-- caller (llm-enable-unreachable-local), the step that gave up as detail
			helpers.assert_eq(cancellations, {require("modules.llm.ollama_endpoint").UNREACHABLE})
			helpers.assert_eq(details, {"restart_failed"})
			helpers.assert_eq(#fixture.timers, 0,
				"a failed restart cannot schedule readiness work from a duplicate completion")
		end)
		with_fixture({}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			-- Preserve the original nonzero7 input independently: exit alone
			-- cannot certify a new native lifecycle that omitted RETIRED.
			fixture.daemon.tasks[1].complete(7, "", "native exit without receipt")
			helpers.assert_eq(cancellations, {"native lifecycle receipt unsettled"})
			helpers.assert_eq(#fixture.timers, 0)
			helpers.assert_eq(fixture.daemon.tasks[1].settled, true,
				"transport exit is observed but the native retirement receipt is absent")
			local refused = {}
			helpers.assert_eq(fixture.manager.check_requirements("next", function() end,
				function(reason) refused[#refused + 1] = reason end,
				{is_current = function() return true end}), false)
			helpers.assert_eq(refused, {"prior_operation_unsettled"})
			helpers.assert_eq(#fixture.daemon.tasks, 1,
				"a physical exit cannot replace the missing native retirement authority")
		end)
	end)

	helpers.it("HS-025 releases the old readiness owner before a terminal callback reenters", function()
		local reentered = false
		local reentry_accepted = nil
		with_fixture({
			on_native_construct = function(manager, label)
				if reentered or label ~= "Ollama model requirement check" then return end
				reentered = true
				reentry_accepted = manager.check_requirements("B", function() end,
					function() end, {is_current = function() return true end})
			end,
		}, function(fixture)
			local accepted = fixture.manager.check_requirements("A", function() end,
				function() end, {is_current = function() return true end})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.spawns, 1)
			fixture.spawns[1].complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(reentry_accepted, true)
			helpers.assert_eq(#fixture.spawns, 2,
				"a terminal callback must acquire a fresh owner after the predecessor releases")
			fixture.spawns[1].complete(0, '{"version":"duplicate"}', "")
			helpers.assert_eq(#fixture.spawns, 2,
				"the old completion cannot overwrite or duplicate the reentrant owner")
		end)
	end)

	helpers.it("HS-025 reports delete readiness refusal to the user", function()
		with_fixture({start_results = {false}}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.native_tasks, 0)
			helpers.assert_eq(#fixture.notifications, 1,
				"a refused readiness probe must not turn delete into a silent no-op")
			helpers.assert_eq(fixture.notifications[1][1], "ollama.delete_fail_title")
			helpers.assert_eq(fixture.notifications[1][3], "error")
			fixture.spawns[1].complete(0, '{"version":"late"}', "")
			helpers.assert_eq(#fixture.notifications, 1,
				"a late completion after refusal cannot duplicate the delete failure")
	end)
	end)

	helpers.it("HS-025 commits delete output only after the native start commits", function()
		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
			native_synchronous_completions = {
				table.pack(0, "", ""),
			},
			task_start_results = {false},
		}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.native_tasks, 1)
			helpers.assert_eq(fixture.menu_updates(), 0,
				"a pre-commit completion cannot publish a menu refresh")
			helpers.assert_eq(#fixture.notifications, 1,
				"start refusal must publish one failure and no provisional success")
			helpers.assert_eq(fixture.notifications[1][1], "ollama.delete_fail_title")
			fixture.native_tasks[1].on_done(0, "", "")
			helpers.assert_eq(#fixture.notifications, 1,
				"a late completion after start refusal must remain inert")
			helpers.assert_eq(fixture.menu_updates(), 0)
		end)

		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
			native_synchronous_completions = {
				table.pack(0, "", ""),
			},
		}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.notifications, 1)
			helpers.assert_eq(fixture.notifications[1][1], "ollama.deleted_title")
			helpers.assert_eq(fixture.menu_updates(), 1)
			fixture.native_tasks[1].on_done(0, "", "")
			helpers.assert_eq(#fixture.notifications, 1,
				"duplicate native completion must not republish deletion success")
			helpers.assert_eq(fixture.menu_updates(), 1)
		end)
	end)

	helpers.it("HS-025 reports delete task construction refusal once", function()
		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
			native_task_results = {false},
		}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.native_tasks, 0)
			helpers.assert_eq(#fixture.notifications, 1)
			helpers.assert_eq(fixture.notifications[1][1], "ollama.delete_fail_title")
			helpers.assert_eq(fixture.menu_updates(), 0)
		end)
	end)

	helpers.it("HS-025 composes the real ShellRunner and TimerScheduler ownership contracts", function()
		local saved_modules = {}
		for _, name in ipairs(MODULES) do saved_modules[name] = package.loaded[name] end
		local saved_hs = _G.hs
		local ok, err = xpcall(function()
			local shell_tasks = {}
			local native_timers = {}
			local model_tasks = {}
			local daemon = foreground_fixture({})
			package.loaded["modules.llm.api_ollama"] = daemon.api

			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.notifications"] = {notify = function() return true end}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.text_utils"] = {shell_quote = function(value) return tostring(value) end}
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/opt/homebrew/bin/ollama" end,
			}
			package.loaded["modules.llm.ollama_server_command"] = {
				build = function() return "exec /opt/homebrew/bin/ollama serve" end,
			}
			package.loaded["ui.download_window"] = {
				show = function() return true end,
				update = function() return true end,
				complete = function() return true end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, executable, on_done, on_chunk_or_args, args)
					local on_stream = type(on_chunk_or_args) == "function"
						and on_chunk_or_args or nil
					local argv = on_stream and (args or {}) or on_chunk_or_args
					local task = {
						label = label,
						executable = executable,
						on_done = on_done,
						on_stream = on_stream,
						args = argv,
					}
					model_tasks[#model_tasks + 1] = task
					return task
				end,
				start = function() return true end,
			}

			_G.hs = {
				execute = function() error("real readiness adapters must not call hs.execute") end,
				task = {new = function(executable, on_done, args)
					local task = {executable = executable, args = args, running_state = false}
					function task:start()
						self.running_state = true
						return self
					end
					function task:terminate()
						self.running_state = false
						return self
					end
					function task:complete(exit_code, stdout, stderr)
						self.running_state = false
						return on_done(exit_code, stdout, stderr)
					end
					shell_tasks[#shell_tasks + 1] = task
					return helpers.attach_native_task_environment(task)
				end},
				timer = {
					new = function(delay, callback)
						local timer = {delay = delay, running_state = false}
						function timer:start()
							self.running_state = true
							return self
						end
						function timer:stop()
							self.running_state = false
							return self
						end
						function timer:running() return self.running_state end
						function timer:fire() return callback() end
						native_timers[#native_timers + 1] = timer
						return timer
					end,
					doAfter = function() return {stop = function() return true end} end,
					secondsSinceEpoch = function() return 100 end,
				},
				json = {encode = function() return "{}" end},
				http = {asyncPost = function() return nil end},
				urlevent = {openURL = function() return true end},
			}

			package.loaded["adapters.shell_runner"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			package.loaded["ui.menu.menu_llm.models_manager_ollama"] = nil
			local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
				active_tasks = {}, state = {}, keymap = {},
				shared_system_check = function() return false end,
			}, {}, function() return 0 end)
			helpers.assert_eq(#native_timers, 1)
			helpers.assert_eq(
				require("adapters.timer_scheduler").cancelAll(), true)
			helpers.assert_eq(native_timers[1]:running(), false)
			table.remove(native_timers, 1)

			local accepted = manager.check_requirements("demo", function() end, function() end,
				{is_current = function() return true end})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#shell_tasks, 1)
			helpers.assert_eq(shell_tasks[1].executable, "/usr/bin/curl")
			shell_tasks[1]:complete(28, "", "timeout")
			helpers.assert_eq(#shell_tasks, 1)
			helpers.assert_eq(#daemon.tasks, 1)
			publish_daemon_ready(daemon)
			helpers.assert_eq(#native_timers, 1)
			helpers.assert_eq(native_timers[1]:running(), true)
			native_timers[1]:fire()
			helpers.assert_eq(native_timers[1]:running(), false,
				"the real TimerScheduler must settle its exact native retry handle before delivery")
			helpers.assert_eq(#shell_tasks, 2)
			shell_tasks[2]:complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(#model_tasks, 1)
		end, debug.traceback)

		_G.hs = saved_hs
		for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("HS-035 Ollama requirement pull terminal delivery", function()
	helpers.it("(HS-035-process-failure) forwards a pull process failure exactly once", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 2)
			helpers.assert_eq(fixture.native_tasks[2].args, {"pull", "missing-model"})
			helpers.assert_type(fixture.native_tasks[2].on_stream, "function")
			fixture.native_tasks[2].on_stream(nil, "", "pull failed")
			fixture.native_tasks[2].on_done(2, "", "pull failed")
			fixture.native_tasks[2].on_done(2, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"process_failed"})
		end)
	end)

	helpers.it("(HS-035-user-cancel) forwards user cancellation after native settlement", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			local progress = fixture.download_options()
			helpers.assert_type(progress, "table")
			helpers.assert_type(progress.on_cancel, "function")
			helpers.assert_eq(progress.on_cancel(), true)
			helpers.assert_eq(terminal.failures, 0,
				"termination request is not process settlement")
			fixture.native_tasks[2].on_done(15, "", "")
			fixture.native_tasks[2].on_done(15, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"user_cancelled"})
		end)
	end)

	helpers.it("(HS-035-construction-refusal) preserves the child construction reason", function()
		with_fixture({
			shared_system_check = accept_model_download,
			native_task_results = {[2] = false},
		}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 1)
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"task_construction_failed"})
		end)
	end)

	helpers.it("(HS-035-start-refusal) preserves the child start reason", function()
		with_fixture({
			shared_system_check = accept_model_download,
			task_start_results = {[2] = false},
		}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 2)
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"task_start_refused"})
		end)
	end)

	helpers.it("(HS-035-stale-duplicate) forwards one stale terminal from late pull completion", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local freshness = {current = true}
			local accepted, terminal = start_missing_model_pull(fixture, freshness)
			helpers.assert_eq(accepted, true)
			freshness.current = false
			fixture.native_tasks[2].on_done(0, "", "")
			fixture.native_tasks[2].on_done(0, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"stale"})
			helpers.assert_eq(#fixture.http_callbacks, 0)
		end)
	end)

	helpers.it("(HS-035-loadability-stale-duplicate) rejects a late loadability success", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local freshness = {current = true}
			local accepted, terminal = start_missing_model_pull(fixture, freshness)
			helpers.assert_eq(accepted, true)
			fixture.native_tasks[2].on_done(0, "", "")
			helpers.assert_eq(#fixture.http_callbacks, 1)
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 0)

			freshness.current = false
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.native_tasks[2].on_done(0, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"stale"})
		end)
	end)

	helpers.it("(HS-035-success-duplicate) forwards one success after loadability", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			fixture.native_tasks[2].on_done(0, "", "")
			helpers.assert_eq(terminal.successes, 0,
				"pull completion alone cannot bypass the loadability boundary")
			helpers.assert_eq(#fixture.http_callbacks, 1)
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.native_tasks[2].on_done(0, "", "duplicate")
			helpers.assert_eq(terminal.successes, 1)
			helpers.assert_eq(terminal.failures, 0)
			helpers.assert_eq(terminal.reasons, {})
		end)
	end)
end)

--- Counts the generic "Ollama failed" notices.
--- @param fixture table The real-manager fixture.
--- @return integer count
local function failure_notices(fixture)
	local count = 0
	for _, notice in ipairs(fixture.notifications) do
		if notice[1] == "ollama.fail_title" then count = count + 1 end
	end
	return count
end

helpers.describe("A silent Ollama is one reason, told once (llm-enable-unreachable-local)", function()
	helpers.it("a start that never answers cancels as unreachable, with its caller's error only (llm-enable-unreachable-local)",
		function()
			with_fixture({}, function(fixture)
				local cancellations, details = {}, {}
				fixture.manager.check_requirements("demo", function() end, function(reason, detail)
					cancellations[#cancellations + 1] = reason
					details[#details + 1] = detail
				end, {is_current = function() return true end, reports_unreachable = true})
				fixture.spawns[1].complete(7, "", "connection refused")
				publish_daemon_ready(fixture.daemon)
				for _ = 1, 30 do
					local timer = fixture.timers[#fixture.timers]
					timer.fire()
					fixture.spawns[#fixture.spawns].complete(7, "", "connection refused")
				end
				helpers.assert_eq(cancellations, {require("modules.llm.ollama_endpoint").UNREACHABLE})
				helpers.assert_eq(details, {"readiness_timeout"})
				helpers.assert_eq(failure_notices(fixture), 0,
					"the caller's error names the fix; a second, generic notice would repeat it")
			end)
		end)

	helpers.it("a caller that does not report it still gets the generic notice (llm-enable-unreachable-local)", function()
		with_fixture({}, function(fixture)
			fixture.manager.check_requirements("demo", function() end, function() end,
				{is_current = function() return true end})
			fixture.spawns[1].complete(7, "", "connection refused")
			retire_daemon(fixture.daemon, 78)
			helpers.assert_eq(failure_notices(fixture), 1, "nobody else tells the user")
		end)
	end)
end)

helpers.describe("HS035 receiver exceptional closure", function()
	local vectors = {
		{ id = "write-throws", write = "throw", error = "writer-sentinel", file_closes = 1, process_closes = 0, removes = 1 },
		{ id = "write-nil", write = "nil", error = "writer-sentinel", file_closes = 1, process_closes = 0, removes = 1 },
		{ id = "source-close-throws", file_close = "throw", error = "source-close-sentinel", file_closes = 1, process_closes = 0, removes = 0, retained = true },
		{ id = "read-throws", read = "throw", error = "reader-sentinel", file_closes = 1, process_closes = 1, removes = 1 },
		{ id = "read-nil", read = "nil", error = "reader-sentinel", file_closes = 1, process_closes = 1, removes = 1 },
		{ id = "process-close-throws", process_close = "throw", error = "process-close-sentinel", file_closes = 1, process_closes = 1, removes = 0, retained = true },
		{ id = "read-and-close-throw", read = "throw", process_close = "throw", error = "reader-sentinel", file_closes = 1, process_closes = 1, removes = 0, retained = true },
		{ id = "nonzero-exit-is-retired", process_close = "nonzero", error = "expected: true", file_closes = 1, process_closes = 1, removes = 1 },
		{ id = "packet-remove-refused", remove = "nil", error = "remove-sentinel", file_closes = 1, process_closes = 1, removes = 1, retained = true },
	}
	for _, vector in ipairs(vectors) do
		helpers.it(vector.id, function()
			local saved_open, saved_popen, saved_remove = io.open, io.popen, os.remove
			local counts = { file_closes = 0, process_closes = 0, removes = 0 }
			local events = {}
			local before = #retained_receivers
			local file = {
				write = function()
					if vector.write == "throw" then error("writer-sentinel", 0) end
					if vector.write == "nil" then return nil, "writer-sentinel" end
					return true
				end,
				close = function()
					counts.file_closes = counts.file_closes + 1
					events[#events + 1] = "file-close"
					if vector.file_close == "throw" then error("source-close-sentinel", 0) end
					return true
				end,
			}
			local process = {
				read = function()
					if vector.read == "throw" then error("reader-sentinel", 0) end
					if vector.read == "nil" then return nil, "reader-sentinel" end
					return '{"executable":"/opt/homebrew/bin/ollama","args":["pull","missing-model"]}'
				end,
				close = function()
					counts.process_closes = counts.process_closes + 1
					events[#events + 1] = "process-close"
					if vector.process_close == "throw" then error("process-close-sentinel", 0) end
					if vector.process_close == "nonzero" then return nil, "exit", 2 end
					return true, "exit", 0
				end,
			}
			io.open = function() return file end
			io.popen = function() return process end
			os.remove = function()
				counts.removes = counts.removes + 1
				events[#events + 1] = "remove"
				if vector.remove == "nil" then return nil, "remove-sentinel" end
				return true
			end
			local ok, err = xpcall(function()
				return receive_pull_argv("/bin/bash", { "-c", "receiver-owned fault input" })
			end, debug.traceback)
			io.open, io.popen, os.remove = saved_open, saved_popen, saved_remove
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find(vector.error, 1, true) ~= nil, tostring(err))
			helpers.assert_eq(counts, { file_closes = vector.file_closes, process_closes = vector.process_closes, removes = vector.removes })
			if vector.removes == 1 then helpers.assert_eq(events[#events], "remove") end
			helpers.assert_eq(#retained_receivers, before + (vector.retained and 1 or 0))
			if vector.retained then
				local owner = retained_receivers[#retained_receivers]
				helpers.assert_eq(owner.packet_created, true)
				if vector.file_close == "throw" then helpers.assert_eq(owner.file, file) end
				if vector.process_close == "throw" then helpers.assert_eq(owner.process, process) end
				-- These are receiver-owned fake handles, not an unretired native child.
				-- Drop only this injected record; real unresolved records stay owned.
				table.remove(retained_receivers)
			end
		end)
	end
end)

return { retained_receivers = retained_receivers }
