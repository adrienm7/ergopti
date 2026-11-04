--- tests/unit/modules/llm/ollama/test_api_ollama_basics.lua

--- ==============================================================================
--- MODULE: llm.api_ollama Unit Tests
--- DESCRIPTION:
--- Tests the lightweight, side-effect-free public surface of the Ollama
--- controller: model heuristics (is_thinking_model) and the readiness flag.
--- Warmup ownership also executes against the actual HTTP and timer adapters
--- over controlled native ports; network and native macOS receiving stay separate.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.ollama.api_ollama_fixture"] = nil
local Fixture = require("tests.support.modules.llm.ollama.api_ollama_fixture")
local ApiOllama = Fixture.ApiOllama
local set_upvalue = Fixture.set_upvalue





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
