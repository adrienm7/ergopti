--- tests/unit/modules/llm/test_api_ollama.lua

--- ==============================================================================
--- MODULE: llm.api_ollama Unit Tests
--- DESCRIPTION:
--- Tests the lightweight, side-effect-free public surface of the Ollama
--- controller: model heuristics (is_thinking_model) and the readiness flag.
--- The actual networked entry points (fetch_*, warmup, check_availability) are
--- exercised at integration time only — they require hs.task and hs.http.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")

local function set_upvalue(fn, target, value)
	for index = 1, 64 do
		local name = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then
			debug.setupvalue(fn, index, value)
			return true
		end
	end
	return false
end

local function get_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end




-- =====================================
-- =====================================
-- ======= 1/ is_thinking_model =========
-- =====================================
-- =====================================

helpers.describe("ApiOllama.is_thinking_model", function()
	helpers.it("returns true for qwen3 family", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("Qwen3-1.7B"), true)
		helpers.assert_eq(ApiOllama.is_thinking_model("qwen3:8b"), true)
	end)

	helpers.it("returns true for deepseek family", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("deepseek-r1"), true)
	end)

	helpers.it("returns true for r1 suffix", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("foo-r1"), true)
		helpers.assert_eq(ApiOllama.is_thinking_model("foo:r1"), true)
	end)

	helpers.it("returns true when name contains 'think'", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("magnus-thinking"), true)
	end)

	helpers.it("returns false for plain non-thinking models", function()
		helpers.assert_eq(ApiOllama.is_thinking_model("gemma-4-E2B-it"), false)
		helpers.assert_eq(ApiOllama.is_thinking_model("llama3.2"), false)
		helpers.assert_eq(ApiOllama.is_thinking_model("mistral"), false)
	end)

	helpers.it("returns false for non-string input", function()
		helpers.assert_eq(ApiOllama.is_thinking_model(nil), false)
		helpers.assert_eq(ApiOllama.is_thinking_model(42), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Readiness flag ===========
-- =====================================
-- =====================================

helpers.describe("ApiOllama.is_ready", function()
	helpers.it("starts as false (model not warmed up)", function()
		helpers.assert_eq(ApiOllama.is_ready(), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ cancel_streaming =========
-- =====================================
-- =====================================

helpers.describe("ApiOllama.cancel_streaming", function()
	helpers.it("commits when no stream is active", function()
		helpers.assert_eq(ApiOllama.cancel_streaming(), true)
	end)

	helpers.it("retains a task whose native termination raises, then retries it", function()
		local calls = 0
		local task = {
			terminate = function()
				calls = calls + 1
				error("native terminate failed")
			end,
		}
		helpers.assert_true(set_upvalue(ApiOllama.cancel_streaming, "_active_stream_task", task),
			"the behavioral negative control must inject the real owned-task slot")
		helpers.assert_eq(ApiOllama.cancel_streaming(), false)
		helpers.assert_eq(calls, 1)

		task.terminate = function() calls = calls + 1; return true, "settled" end
		task.isSettled = function() return true end
		helpers.assert_eq(ApiOllama.cancel_streaming(), true,
			"a retained native capability must remain retryable")
		helpers.assert_eq(calls, 2)
		helpers.assert_eq(ApiOllama.cancel_streaming(), true)
		helpers.assert_eq(calls, 2, "the successful retry must release the task slot")
	end)
end)





-- ============================================================
-- ============================================================
-- ======= 4/ Run-loop safety (no synchronous blocking) =======
-- ============================================================
-- ============================================================

helpers.describe("ApiOllama run-loop safety", function()
	helpers.it("ensure_ollama_running does not use ShellRunner.exec (synchronous)", function()
		-- ShellRunner.exec wraps hs.execute which blocks the Lua thread.
		-- When called inside a timer callback (even doAfter(0)), this permanently
		-- kills the Cocoa CFRunLoop — destroying timers, menubar, and eventtaps.
		-- Selected by a declaration unique to modules/llm/api_ollama.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local source = helpers.read_driver_source("local function read_ollama_port_override")
		helpers.assert_true(source ~= nil, "modules/llm/api_ollama.lua source must be locatable")

		-- Extract the ensure_ollama_running function body (multiline match)
		local fn_body = source:match("local function ensure_ollama_running%([^\n]*%)\n(.-)\nend\n")
		helpers.assert_true(fn_body, "could not locate ensure_ollama_running function body")

		local has_sync_exec = fn_body:find("ShellRunner%.exec") ~= nil
		helpers.assert_true(not has_sync_exec,
			"ensure_ollama_running must not use ShellRunner.exec (synchronous) — " ..
			"use ShellRunner.spawn (async) instead to avoid killing the Cocoa run loop")
	end)

	helpers.it("ensure_ollama_running does not use TimerScheduler.sleep_us", function()
		-- TimerScheduler.sleep_us wraps hs.timer.usleep which blocks the thread
		-- Selected by a declaration unique to modules/llm/api_ollama.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local source = helpers.read_driver_source("local function read_ollama_port_override")
		helpers.assert_true(source ~= nil, "modules/llm/api_ollama.lua source must be locatable")

		local fn_body = source:match("local function ensure_ollama_running%([^\n]*%)\n(.-)\nend\n")
		helpers.assert_true(fn_body, "could not locate ensure_ollama_running function body")

		local has_sleep = fn_body:find("TimerScheduler%.sleep_us") ~= nil
		helpers.assert_true(not has_sleep,
			"ensure_ollama_running must not use TimerScheduler.sleep_us — " ..
			"this blocks the Lua thread and corrupts the CFRunLoop")
	end)

	helpers.it("ensure_ollama_running uses ShellRunner.spawn for async launch", function()
		-- ShellRunner.spawn wraps hs.task (non-blocking subprocess)
		-- Selected by a declaration unique to modules/llm/api_ollama.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local source = helpers.read_driver_source("local function read_ollama_port_override")
		helpers.assert_true(source ~= nil, "modules/llm/api_ollama.lua source must be locatable")

		local fn_body = source:match("local function ensure_ollama_running%([^\n]*%)\n(.-)\nend\n")
		helpers.assert_true(fn_body, "could not locate ensure_ollama_running function body")

		local has_prepare = fn_body:find("ManagedDaemon%.prepare") ~= nil
		helpers.assert_true(has_prepare, "ensure_ollama_running must acquire its foreground daemon owner")
		local transport = helpers.read_driver_source("function M.prepare(command, nonce, callbacks)")
		helpers.assert_not_nil(transport, "the actual managed daemon transport must be locatable")
		local has_spawn = transport:find("ShellRunner%.spawn") ~= nil
		helpers.assert_true(has_spawn,
			"ensure_ollama_running must use ShellRunner.spawn through its async foreground transport")
		helpers.assert_true(transport:find('done, chunk, nil, true, true)', 1, true) ~= nil,
			"the async foreground transport must retain private owned-protocol receipt delivery")
	end)

	helpers.it("module top-level never calls ShellRunner.exec directly", function()
		-- Verify no synchronous shell call happens outside of function bodies
		-- (i.e. at require-time). Only function definitions and deferred calls
		-- (TimerScheduler.after) are allowed at top level.
		-- Selected by a declaration unique to modules/llm/api_ollama.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local source = helpers.read_driver_source("local function read_ollama_port_override")
		helpers.assert_true(source ~= nil, "modules/llm/api_ollama.lua source must be locatable")

		-- Remove all function bodies to isolate top-level code
		local top_level = source:gsub("local function [^\n]-%).-\nend\n", "")
		top_level = top_level:gsub("function M%.[^\n]-%).-\nend\n", "")

		local has_top_exec = top_level:find("ShellRunner%.exec%(") ~= nil
		helpers.assert_true(not has_top_exec,
			"api_ollama must never call ShellRunner.exec at top-level (require-time) — " ..
			"this blocks the Cocoa run loop and kills the menubar/timers")
	end)
end)


helpers.describe("ApiOllama daemon startup ownership", function()
	-- R15 has one foreground owner, not a stale-process kill and launch timer.
	-- Keep the original refusal families while using the real API, daemon adapter,
	-- shared receiver/lifecycle and ShellRunner over controlled native task ports.
	local function with_startup(starts, callback)
		helpers.with_stub_scope({
			"modules.llm.api_ollama", "adapters.managed_ollama_daemon", "adapters.shell_runner",
			"core.llm.managed_ollama_daemon_receipt", "core.llm.managed_ollama_daemon_lifecycle",
			"modules.llm.ollama_binary", "modules.llm.ollama_server_command",
			"adapters.http_client", "adapters.timer_scheduler", "adapters.json_codec",
			"modules.llm.api_common", "modules.llm.parser", "modules.llm.profiles",
			"modules.llm.progressive_reveal", "infra.logger", "infra.notifications", "infra.i18n",
			"modules.shortcuts.script_control", "modules.llm.prediction_engine",
		}, function()
			local fixture = { tasks = {}, paused = false, nonce_index = 0 }
			local nonces = { "0000000000000000000000000000f001", "0000000000000000000000000000f002" }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.notifications"] = { notify = function() return true end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["adapters.http_client"] = { new = function()
				return { cancel = function() return true end, isActive = function() return false end,
					isSettled = function() return true end }
			end }
			package.loaded["adapters.timer_scheduler"] = {
				after = function() error("foreground startup must not acquire a launch timer") end,
				cancel = function() return true end,
			}
			package.loaded["adapters.json_codec"] = { encode = function() return "{}" end, decode = function() return {} end }
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/fixture/ollama", nil, "native_managed" end,
			}
			-- Command/source admission has separate tests. This boundary supplies an
			-- independent fixed command and explicitly binds native kind and nonce.
			package.loaded["modules.llm.ollama_server_command"] = { build = function(path, _, _, kind, nonce)
				helpers.assert_eq(path, "/fixture/ollama")
				helpers.assert_eq(kind, "native_managed")
				helpers.assert_eq(nonce, nonces[fixture.nonce_index])
				return "exec /fixture/native-owner --owned-stdin"
			end }
			package.loaded["modules.llm.parser"] = {}
			package.loaded["modules.llm.profiles"] = {}
			package.loaded["modules.llm.progressive_reveal"] = {}
			package.loaded["modules.llm.api_common"] = { DEFAULT_DEDUPLICATION_ENABLED = true,
				OLLAMA_KEEP_ALIVE = "5m", get_retry_policy = function() return 1, 0, 0 end }
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return fixture.paused end, get_pause_epoch = function() return 1 end,
			}
			local api = helpers.load_with_stubs("modules.llm.api_ollama", {
				host = { uuid = function()
					fixture.nonce_index = fixture.nonce_index + 1
					local nonce = nonces[fixture.nonce_index]
					helpers.assert_not_nil(nonce, "only the declared original and successor are admitted")
					return nonce:sub(1, 8) .. "-" .. nonce:sub(9, 12) .. "-" .. nonce:sub(13, 16)
						.. "-" .. nonce:sub(17, 20) .. "-" .. nonce:sub(21, 32)
				end },
				task = { new = function(executable, done, chunk, args)
					helpers.assert_eq(executable, "/bin/sh")
					helpers.assert_eq(args[1], "-c")
					helpers.assert_eq(args[2], "exec /fixture/native-owner --owned-stdin")
					helpers.assert_eq(type(chunk), "function", "the same native task must receive retirement frames")
					local index = #fixture.tasks + 1
					local task = { input_closes = 0, start_calls = 0, completed = false,
						running = false, nonce = nonces[fixture.nonce_index] }
					function task:start()
						self.start_calls = self.start_calls + 1
						self.running = true
						local result = true
						if starts[index] then result = starts[index]() end
						if result ~= true then self.running = false end
						return result
					end
					function task:closeInput() self.input_closes = self.input_closes + 1; return true end
					function task:terminate() error("owned protocol cancellation must use original stdin EOF") end
					function task:isRunning() return self.running end
					function task.frame(role) return "ERGOPTI_MANAGED_DAEMON_V1 " .. task.nonce .. " " .. role .. "\n" end
					function task.emit(bytes) return chunk(task, bytes, "") end
					function task.complete(status, remainder)
						task.running, task.completed = false, true
						return done(status, remainder or "", "")
					end
					fixture.tasks[index] = task
					return task
				end },
			})
			local shell = require("adapters.shell_runner")
			fixture.shell = shell
			local ok, err = xpcall(function() callback(api, fixture) end, debug.traceback)
			-- Retire controlled native objects even when an assertion fails; scoped
			-- module restoration must not silently replace an uncompleted task.
			for _, task in ipairs(fixture.tasks) do
				if not task.completed then task.complete(78, task.frame("RETIRED 78")) end
			end
			if not ok then error(err, 0) end
		end)
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "nil", start = function() return nil end },
		{ name = "throw", start = function() error("native start raised") end },
	}) do
		helpers.it("retries the stale-process task after start " .. case.name, function()
			with_startup({ case.start }, function(api, fixture)
				helpers.assert_eq(api.ensure_running(), false)
				local original = fixture.tasks[1]
				helpers.assert_not_nil(original)
				helpers.assert_eq(original.input_closes, 1,
					"every non-true start must request original-owner retirement exactly once")
				helpers.assert_eq(fixture.shell._active_tasks[original], true)
				helpers.assert_eq(api.ensure_running(), false, "accepted EOF is not physical retirement")
				helpers.assert_eq(#fixture.tasks, 1, "no successor may overlap retained original custody")
				original.emit(original.frame("RETIRED 78"))
				helpers.assert_eq(api.ensure_running(), false, "RETIRED alone is not physical completion")
				helpers.assert_eq(#fixture.tasks, 1)
				original.complete(78)
				helpers.assert_eq(fixture.shell._active_tasks[original], nil)
				helpers.assert_true(api.startup_idle())
				helpers.assert_eq(api.ensure_running(), true,
					"a retired refused launch must not poison the process-lifetime deduplication latch")
				helpers.assert_eq(#fixture.tasks, 2, "the second demand must construct one fresh foreground task")
				helpers.assert_eq(original.start_calls, 1, "retry never restarts the original task")
			end)
		end)
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "nil", start = function() return nil end },
		{ name = "throw", start = function() error("serve start raised") end },
	}) do
		helpers.it("retries the full transaction after server start " .. case.name, function()
			with_startup({ case.start }, function(api, fixture)
				local settlements = {}
				helpers.assert_eq(api.ensure_running({ is_authorized = function() return true end,
					on_settled = function(committed, reason) settlements[#settlements + 1] = { committed, reason } end,
				}), false)
				helpers.assert_eq(#settlements, 1, "a real start refusal must settle the supervised request once")
				helpers.assert_eq(settlements[1][1], false)
				helpers.assert_true(tostring(settlements[1][2]):find("server task start", 1, true) ~= nil)
				local original = fixture.tasks[1]
				helpers.assert_eq(api.ensure_running(), false, "a failed start retains its exact cleanup owner")
				helpers.assert_eq(#fixture.tasks, 1)
				helpers.assert_eq(original.input_closes, 1)
				original.complete(78, original.frame("RETIRED 78"))
				helpers.assert_eq(#settlements, 1, "late retirement must not settle the waiter twice")
				helpers.assert_eq(api.ensure_running(), true, "joined serve refusal must release the outer in-flight latch")
				helpers.assert_eq(#fixture.tasks, 2, "retry begins one fresh foreground transaction")
			end)
		end)
	end

	helpers.it("settles a supervised start through the real pause boundary", function()
		with_startup({}, function(api, fixture)
			local settlements = {}
			local authorized = true
			helpers.assert_true(api.ensure_running({ is_authorized = function() return authorized end,
				on_settled = function(committed, reason) settlements[#settlements + 1] = { committed, reason } end,
			}))
			helpers.assert_eq(#settlements, 0)
			authorized, fixture.paused = false, true
			helpers.assert_eq(api.pause_warmup(), false, "pause retains original custody until native retirement")
			helpers.assert_eq(#settlements, 1)
			helpers.assert_eq(settlements[1][1], false)
			helpers.assert_eq(settlements[1][2], "startup quiesced")
			local original = fixture.tasks[1]
			helpers.assert_eq(original.input_closes, 1)
			original.emit(original.frame("ACTIVE") .. original.frame("READY"))
			helpers.assert_eq(#settlements, 1, "stale READY cannot republish the paused request")
			helpers.assert_eq(#fixture.tasks, 1, "pause cannot acquire a successor before exact join")
			original.complete(78, original.frame("RETIRED 78"))
			helpers.assert_eq(fixture.shell._active_tasks[original], nil)
			helpers.assert_true(api.pause_warmup())
			helpers.assert_eq(#fixture.tasks, 1, "a physically retired paused request cannot launch a successor")
		end)
	end)

	helpers.it("settles a supervised start only after native publication", function()
		with_startup({}, function(api, fixture)
			local settled = {}
			helpers.assert_true(api.ensure_running({ is_authorized = function() return true end,
				on_settled = function(committed, reason) settled[#settled + 1] = { committed, reason } end,
			}))
			local original = fixture.tasks[1]
			helpers.assert_eq(#settled, 0, "async admission is not proof that the daemon was published")
			helpers.assert_eq(api.startup_idle(), false)
			original.emit(original.frame("ACTIVE"))
			helpers.assert_eq(#settled, 0)
			local ready = original.frame("READY")
			original.emit(ready:sub(1, 18))
			helpers.assert_eq(#settled, 0, "a partial native frame cannot publish readiness")
			original.emit(ready:sub(19))
			helpers.assert_eq(#settled, 1)
			helpers.assert_eq(settled[1][1], true)
			helpers.assert_eq(#fixture.tasks, 1, "publication belongs to the same sole foreground task")
			helpers.assert_eq(fixture.shell._active_tasks[original], true, "READY does not retire the native task")
			original.complete(0, original.frame("RETIRED 0"))
			helpers.assert_eq(fixture.shell._active_tasks[original], nil)
			helpers.assert_eq(#settled, 1)
		end)
	end)

	helpers.it("fences a supervised start whose runtime authority is superseded", function()
		with_startup({}, function(api, fixture)
			local settled = {}
			local authorized = true
			helpers.assert_true(api.ensure_running({ is_authorized = function() return authorized end,
				on_settled = function(committed, reason) settled[#settled + 1] = { committed, reason } end,
			}))
			local original = fixture.tasks[1]
			original.emit(original.frame("ACTIVE"))
			authorized = false
			original.emit(original.frame("READY"))
			helpers.assert_eq(#fixture.tasks, 1, "a superseded backend cannot acquire a successor serve task")
			helpers.assert_eq(#settled, 1)
			helpers.assert_eq(settled[1][1], false)
			helpers.assert_eq(api.startup_idle(), false)
			helpers.assert_eq(api.ensure_running(), false, "cleanup retains the original superseded owner")
			helpers.assert_eq(original.input_closes, 1)
			original.complete(78, original.frame("RETIRED 78"))
			helpers.assert_true(api.startup_idle())
			helpers.assert_eq(#settled, 1, "stale physical completion cannot republish a business verdict")
			helpers.assert_eq(#fixture.tasks, 1)
		end)
	end)

	helpers.it("invalidates readiness when the current daemon exits", function()
		with_startup({}, function(api, fixture)
			helpers.assert_true(set_upvalue(api.is_ready, "_is_ready", true),
				"the daemon-exit regression must seed the real readiness owner")
			helpers.assert_true(set_upvalue(api.reset_ready, "_warmup_gen", 41),
				"the daemon-exit regression must seed the real warmup generation")
			helpers.assert_true(set_upvalue(api.warmup, "_warmup_active", true),
				"the daemon-exit regression must seed the in-flight warmup owner")
			local recovery_calls = 0
			package.loaded["modules.llm.prediction_engine"] = { on_ollama_daemon_exit = function()
				recovery_calls = recovery_calls + 1; return true
			end }
			helpers.assert_eq(api.ensure_running(), true)
			local original = fixture.tasks[1]
			original.emit(original.frame("ACTIVE") .. original.frame("READY"))
			helpers.assert_eq(api.is_ready(), true)
			original.emit(original.frame("RETIRED 0"))
			helpers.assert_eq(api.is_ready(), true, "RETIRED alone cannot demote a physically live daemon")
			helpers.assert_eq(recovery_calls, 0)
			original.complete(0)
			helpers.assert_eq(api.is_ready(), false, "a dead daemon must invalidate the readiness verdict immediately")
			helpers.assert_eq(get_upvalue(api.reset_ready, "_warmup_gen"), 42,
				"daemon death must fence warmup responses from the dead server")
			helpers.assert_eq(get_upvalue(api.warmup, "_warmup_active"), false,
				"daemon death must release the stale warmup intent")
			helpers.assert_eq(recovery_calls, 1, "the current daemon must delegate exactly one recovery attempt")
			helpers.assert_true(set_upvalue(api.is_ready, "_is_ready", true))
			original.complete(0)
			helpers.assert_eq(api.is_ready(), true, "a duplicate stale completion must not demote a successor readiness verdict")
			helpers.assert_eq(recovery_calls, 1, "a duplicate stale completion must not request sibling recovery")
		end)
	end)
end)

helpers.describe("ApiOllama streaming task ownership", function()
	local streaming_impl = get_upvalue(ApiOllama.fetch_batch, "post_and_parse_streaming")
	local shell_runner = streaming_impl and get_upvalue(streaming_impl, "ShellRunner") or nil

	local function request(on_fail)
		streaming_impl(
			"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
			function() error("unexpected success") end, on_fail, {}, function() end)
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "throw", start = function() error("STREAM_START_THROW") end },
	}) do
		helpers.it("releases a curl task whose start returns " .. case.name, function()
			helpers.assert_not_nil(streaming_impl, "the test must drive the real streaming function")
			helpers.assert_true(set_upvalue(streaming_impl, "_active_stream_task", nil))
			local original_spawn = shell_runner.spawn
			local spawns, failures, terminations = 0, 0, 0
			shell_runner.spawn = function()
				spawns = spawns + 1
				local settled = case.name == "false"
				return {
					start = case.start,
					terminate = function() terminations = terminations + 1; settled = true; return true, "settled" end,
					isSettled = function() return settled end,
				}
			end

			local ok, err = pcall(function()
				request(function() failures = failures + 1 end)
				helpers.assert_eq(get_upvalue(streaming_impl, "_active_stream_task"), nil)
				request(function() failures = failures + 1 end)
				helpers.assert_eq(spawns, 2, "the next prediction must retry after an uncommitted start")
				helpers.assert_eq(failures, 2)
				if case.name == "throw" then helpers.assert_eq(terminations, 2) end
			end)
			shell_runner.spawn = original_spawn
			if not ok then error(err) end
		end)
	end

	helpers.it("does not republish a task that completes inside start", function()
		helpers.assert_true(set_upvalue(streaming_impl, "_active_stream_task", nil))
		local original_spawn = shell_runner.spawn
		local failures = 0
		shell_runner.spawn = function(_, _, on_done)
			return {
				start = function()
					on_done(0, "", "")
					return true
				end,
				terminate = function() return true, "settled" end,
				isSettled = function() return true end,
			}
		end

		local ok, err = pcall(function()
			request(function() failures = failures + 1 end)
			helpers.assert_eq(get_upvalue(streaming_impl, "_active_stream_task"), nil,
				"completion must revoke ownership before start() returns to the caller")
			helpers.assert_eq(failures, 1)
		end)
		shell_runner.spawn = original_spawn
		if not ok then error(err) end
	end)

	helpers.it("(stream-nonzero-exit) rejects parseable partial output when curl exits nonzero", function()
		helpers.assert_true(set_upvalue(streaming_impl, "_active_stream_task", nil))
		local original_spawn = shell_runner.spawn
		local json_codec = get_upvalue(streaming_impl, "JsonCodec")
		local parser = get_upvalue(streaming_impl, "Parser")
		local original_decode = json_codec.decode
		local original_process = parser.process_prediction
		local successes, failures = 0, 0

		json_codec.decode = function()
			return { message = { content = "would-have-been-published" } }
		end
		parser.process_prediction = function(_, _, raw) return raw end
		shell_runner.spawn = function(_, _, on_done)
			return {
				start = function()
					on_done(28, "{}\n", "Operation timed out")
					return true
				end,
				terminate = function() return true, "settled" end,
				isSettled = function() return true end,
			}
		end

		local ok, err = pcall(function()
			streaming_impl(
				"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
				function() successes = successes + 1 end,
				function() failures = failures + 1 end, {}, function() end)
			helpers.assert_eq(successes, 0,
				"curl timeout output is partial transport data, never a prediction")
			helpers.assert_eq(failures, 1)
			helpers.assert_eq(get_upvalue(streaming_impl, "_active_stream_task"), nil)
		end)
		shell_runner.spawn = original_spawn
		json_codec.decode = original_decode
		parser.process_prediction = original_process
		if not ok then error(err) end
	end)
end)


helpers.describe("ApiOllama non-streaming decode contract", function()
	local post_and_parse = get_upvalue(ApiOllama.fetch_batch, "post_and_parse")
	local infer_client = post_and_parse and get_upvalue(post_and_parse, "_infer_client") or nil
	local json_codec = post_and_parse and get_upvalue(post_and_parse, "JsonCodec") or nil
	local logger = post_and_parse and get_upvalue(post_and_parse, "Logger") or nil

	helpers.it("classifies a successful top-level null as an invalid response", function()
		helpers.assert_not_nil(post_and_parse,
			"the regression must drive the production non-streaming parser")
		helpers.assert_not_nil(infer_client)
		helpers.assert_not_nil(json_codec)
		helpers.assert_not_nil(logger)

		local original_post = infer_client.post
		local original_encode = json_codec.encode
		local original_decode = json_codec.decode
		local original_error = logger.error
		local logs = {}
		local successes, failures = 0, 0

		infer_client.post = function(_, _, _, callback)
			callback({ status = 200, body = "null" })
		end
		json_codec.encode = function() return "{}", nil end
		json_codec.decode = function() return nil, nil end
		logger.error = function(_, format_string, ...)
			logs[#logs + 1] = string.format(format_string, ...)
		end

		local ok, err = xpcall(function()
			post_and_parse(
				"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
				function() successes = successes + 1 end,
				function() failures = failures + 1 end, {})
			helpers.assert_eq(successes, 0)
			helpers.assert_eq(failures, 1)
			local response_invalid, decode_error = 0, 0
			for _, message in ipairs(logs) do
				if message:find("RESPONSE_INVALID", 1, true) then
					response_invalid = response_invalid + 1
				end
				if message:find("JSON_DECODE_ERROR", 1, true) then
					decode_error = decode_error + 1
				end
			end
			helpers.assert_eq(response_invalid, 1,
				"a successful JSON null must reach schema validation exactly once")
			helpers.assert_eq(decode_error, 0,
				"a successful JSON null must not be reported as a decode failure")
		end, debug.traceback)

		infer_client.post = original_post
		json_codec.encode = original_encode
		json_codec.decode = original_decode
		logger.error = original_error
		if not ok then error(err) end
	end)
end)





--- ======================================
--- ======================================
--- ======= 5/ get_base_url (port) =======
--- ======================================
--- ======================================

helpers.describe("ApiOllama.get_base_url (configurable port)", function()
	helpers.it("exposes get_base_url as a function", function()
		helpers.assert_eq(type(ApiOllama.get_base_url), "function")
	end)

	-- With no user override set, the port comes from the single source
	-- (_shared/modules/llm/defaults.json llm_ollama_port = 11434, via DEFAULT_STATE) — not
	-- from a URL hardcoded at each call site. A regression that re-hardcodes a
	-- different port, or drops the llm_ollama_port default, fails here.
	helpers.it("defaults to the canonical loopback URL on port 11434", function()
		helpers.assert_eq(ApiOllama.get_base_url(), "http://127.0.0.1:11434")
	end)

	helpers.it("builds a well-formed loopback http URL", function()
		helpers.assert_true(
			ApiOllama.get_base_url():match("^http://127%.0%.0%.1:%d+$") ~= nil,
			"base url must be http://127.0.0.1:<port>")
	end)
end)


helpers.describe("ApiOllama strict local model listing", function()
	local client = get_upvalue(ApiOllama.request_chat, "_vision_client")

	local function request_with_receipt(receipt)
		local original_get, original_post = client.get, client.post
		local gets, posts, failures, successes = {}, {}, {}, {}
		client.get = function(url, _, callback)
			gets[#gets + 1] = url
			callback(receipt)
		end
		client.post = function(url, _, _, callback)
			posts[#posts + 1] = url
			callback({ status = 200, body = '{"message":{"content":"admitted answer"}}' })
		end
		ApiOllama.forget_local_models()
		local ok, err = xpcall(function()
			ApiOllama.request_chat({ model = "qwen2.5:7b", messages = {} },
				function(text) successes[#successes + 1] = text end,
				function(reason) failures[#failures + 1] = reason end)
		end, debug.traceback)
		local installed = ApiOllama.local_model_installed("qwen2.5:7b")
		client.get, client.post = original_get, original_post
		ApiOllama.forget_local_models()
		if not ok then error(err, 0) end
		return { gets = gets, posts = posts, failures = failures, successes = successes, installed = installed }
	end

	for _, body in ipairs({ '{"models":{}}', '{"models":[{}]}', '{"models":["qwen2.5:7b"]}', '[]', 'not JSON' }) do
		helpers.it("refuses unreadable inventory before chat or a missing-model offer: " .. body, function()
			local seen = request_with_receipt({ status = 200, body = body })
			helpers.assert_eq(#seen.gets, 1)
			helpers.assert_true(seen.gets[1]:match("/api/tags$") ~= nil)
			helpers.assert_eq(#seen.posts, 0, "private chat bytes need a valid inventory receipt")
			helpers.assert_eq(#seen.successes, 0)
			helpers.assert_eq(#seen.failures, 1, "a refused inventory settles the actual request once")
			helpers.assert_eq(seen.failures[1], "unreadable_model_list", "unknown inventory is never a missing model")
			helpers.assert_eq(seen.installed, nil, "an unreadable receipt cannot publish an empty installation cache")
		end)
	end

	helpers.it("keeps a failed tags endpoint distinct from a known empty inventory", function()
		local failed = request_with_receipt({ status = 404, body = '{"models":[]}' })
		helpers.assert_eq(#failed.posts, 0)
		helpers.assert_eq(#failed.failures, 1)
		helpers.assert_eq(failed.failures[1], "http_404")
		helpers.assert_eq(failed.installed, nil)
		local empty = request_with_receipt({ status = 200, body = '{"models":[]}' })
		helpers.assert_eq(#empty.posts, 0)
		helpers.assert_eq(#empty.failures, 1)
		helpers.assert_eq(empty.failures[1], ApiOllama.MODEL_MISSING)
		helpers.assert_eq(empty.installed, false)
	end)

	helpers.it("admits the requested model from either authoritative name field", function()
		for _, body in ipairs({
			'{"models":[{"name":"QWEN2.5:7B"}]}',
			'{"models":[{"model":"qwen2.5:7b"}]}',
		}) do
			local seen = request_with_receipt({ status = 200, body = body })
			helpers.assert_eq(#seen.gets, 1)
			helpers.assert_eq(#seen.posts, 1)
			helpers.assert_true(seen.posts[1]:match("/api/chat$") ~= nil)
			helpers.assert_eq(#seen.failures, 0)
			helpers.assert_eq(#seen.successes, 1)
			helpers.assert_eq(seen.successes[1], "admitted answer")
			helpers.assert_eq(seen.installed, true)
		end
	end)
end)
