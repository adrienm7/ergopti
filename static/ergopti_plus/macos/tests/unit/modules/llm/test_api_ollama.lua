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

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")




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
	helpers.it("does not error when no stream is active", function()
		ApiOllama.cancel_streaming()
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
		local src_path = helpers.driver_root() .. "modules/llm/api_ollama.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh, "could not open api_ollama.lua source")
		local source = fh:read("*a")
		fh:close()

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
		local src_path = helpers.driver_root() .. "modules/llm/api_ollama.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh, "could not open api_ollama.lua source")
		local source = fh:read("*a")
		fh:close()

		local fn_body = source:match("local function ensure_ollama_running%(%)\n(.-)\nend\n")
		helpers.assert_true(fn_body, "could not locate ensure_ollama_running function body")

		local has_sleep = fn_body:find("TimerScheduler%.sleep_us") ~= nil
		helpers.assert_true(not has_sleep,
			"ensure_ollama_running must not use TimerScheduler.sleep_us — " ..
			"this blocks the Lua thread and corrupts the CFRunLoop")
	end)

	helpers.it("ensure_ollama_running uses ShellRunner.spawn for async launch", function()
		-- ShellRunner.spawn wraps hs.task (non-blocking subprocess)
		local src_path = helpers.driver_root() .. "modules/llm/api_ollama.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh, "could not open api_ollama.lua source")
		local source = fh:read("*a")
		fh:close()

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
		local src_path = helpers.driver_root() .. "modules/llm/api_ollama.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh, "could not open api_ollama.lua source")
		local source = fh:read("*a")
		fh:close()

		-- Remove all function bodies to isolate top-level code
		local top_level = source:gsub("local function [^\n]-%).-\nend\n", "")
		top_level = top_level:gsub("function M%.[^\n]-%).-\nend\n", "")

		local has_top_exec = top_level:find("ShellRunner%.exec%(") ~= nil
		helpers.assert_true(not has_top_exec,
			"api_ollama must never call ShellRunner.exec at top-level (require-time) — " ..
			"this blocks the Cocoa run loop and kills the menubar/timers")
	end)
end)
