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

		task.terminate = function() calls = calls + 1; return true end
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
		local fn_body = source:match("local function ensure_ollama_running%(%)\n(.-)\nend\n")
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

		local fn_body = source:match("local function ensure_ollama_running%(%)\n(.-)\nend\n")
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

		local fn_body = source:match("local function ensure_ollama_running%(%)\n(.-)\nend\n")
		helpers.assert_true(fn_body, "could not locate ensure_ollama_running function body")

		local has_spawn = fn_body:find("ShellRunner%.spawn") ~= nil
		helpers.assert_true(has_spawn,
			"ensure_ollama_running must use ShellRunner.spawn for async subprocess launch")
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
	local ensure_impl = get_upvalue(ApiOllama.ensure_running, "ensure_ollama_running")
	local shell_runner = ensure_impl and get_upvalue(ensure_impl, "ShellRunner") or nil
	local scheduler = ensure_impl and get_upvalue(ensure_impl, "TimerScheduler") or nil
	local binary_resolver = ensure_impl and get_upvalue(ensure_impl, "OllamaBinary") or nil
	local original_resolve = binary_resolver and binary_resolver.resolve or nil
	helpers.assert_not_nil(original_resolve,
		"startup ownership tests must control the independent executable-resolution dependency")
	-- This describe exercises task commitment, not filesystem discovery. The
	-- bundled-path regression test drives the real resolver with executable and
	-- non-executable fixtures; supplying one valid path here isolates ownership.
	binary_resolver.resolve = function() return "/fixture/ollama", nil, true end

	local function reset_startup_state()
		helpers.assert_not_nil(ensure_impl, "the behavioral test must reach the real startup transaction")
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
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "throw", start = function() error("native start raised") end },
	}) do
		helpers.it("retries the stale-process task after start " .. case.name, function()
			reset_startup_state()
			local original_spawn = shell_runner.spawn
			local spawn_calls = 0
			local terminate_calls = 0
			shell_runner.spawn = function()
				spawn_calls = spawn_calls + 1
				return {
					start = spawn_calls == 1 and case.start or function() return true end,
					terminate = function() terminate_calls = terminate_calls + 1; return true end,
				}
			end

			local ok, err = pcall(function()
				helpers.assert_eq(ApiOllama.ensure_running(), false)
				helpers.assert_eq(ApiOllama.ensure_running(), true,
					"a refused launch must not poison the process-lifetime deduplication latch")
				helpers.assert_eq(spawn_calls, 2, "the second demand must construct a fresh kill task")
				if case.name == "throw" then
					helpers.assert_eq(terminate_calls, 1,
						"an exceptional start must revoke the ambiguous native capability before retry")
				end
			end)
			shell_runner.spawn = original_spawn
			if not ok then error(err) end
		end)
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "throw", start = function() error("serve start raised") end },
	}) do
		helpers.it("retries the full transaction after server start " .. case.name, function()
			reset_startup_state()
			local original_spawn = shell_runner.spawn
			local original_after = scheduler.after
			local spawn_calls = 0
			local kill_done
			local launch_server
			local terminate_calls = 0
			shell_runner.spawn = function(_, _, on_done)
				spawn_calls = spawn_calls + 1
				if spawn_calls == 1 then
					kill_done = on_done
					return { start = function() return true end, terminate = function() return true end }
				end
				if spawn_calls == 2 then
					return {
						start = case.start,
						terminate = function() terminate_calls = terminate_calls + 1; return true end,
					}
				end
				return { start = function() return true end, terminate = function() return true end }
			end
			scheduler.after = function(_, callback)
				launch_server = callback
				return { timer = {} }, true
			end

			local ok, err = pcall(function()
				helpers.assert_eq(ApiOllama.ensure_running(), true)
				helpers.assert_eq(type(kill_done), "function")
				kill_done()
				helpers.assert_eq(type(launch_server), "function")
				launch_server()
				helpers.assert_eq(ApiOllama.ensure_running(), true,
					"a failed nested serve launch must release the outer in-flight latch")
				helpers.assert_eq(spawn_calls, 3, "retry must restart from stale-process cleanup")
				if case.name == "throw" then helpers.assert_eq(terminate_calls, 1) end
			end)
			shell_runner.spawn = original_spawn
			scheduler.after = original_after
			if not ok then error(err) end
		end)
	end

	binary_resolver.resolve = original_resolve
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
				return {
					start = case.start,
					terminate = function() terminations = terminations + 1; return true end,
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
				terminate = function() return true end,
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
