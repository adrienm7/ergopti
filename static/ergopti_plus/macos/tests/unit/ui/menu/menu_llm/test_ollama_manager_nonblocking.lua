--- tests/unit/ui/menu/menu_llm/test_ollama_manager_nonblocking.lua

--- Regression test for M-15: Ollama model-manager menu actions must not
--- block the Hammerspoon run loop.
---
--- Three call sites were synchronous:
--- 1. ensure_ollama_running — even a bounded curl blocked the single Lua runloop
---    for up to its configured timeout, including from timer callbacks.
--- 2. check_requirements — ollama list was run with hs.execute (blocking).
--- 3. delete_model — ollama rm was run with hs.execute (blocking).
---
--- Fixes:
--- 1. Readiness curl and daemon restart use ShellRunner; retained timers own retries.
--- 2. check_requirements uses TaskLifecycle.native (non-blocking) for ollama list.
--- 3. delete_model uses TaskLifecycle.native (non-blocking) for ollama rm.

local helpers = require("tests.helpers")

helpers.describe("Ollama manager nonblocking boundaries", function()
	helpers.it("keeps readiness and model operations off synchronous shell APIs", function()
		-- Selected by a declaration unique to ui/menu/menu_llm/models_manager_ollama.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function get_ollama_path")
		helpers.assert_true(src ~= nil,
			"ui/menu/menu_llm/models_manager_ollama.lua source must be locatable")

		-- Test 1: readiness and daemon restart must have no synchronous shell call.
		helpers.assert_true(
			src:find("pcall(hs.execute", 1, true) == nil
				and src:find("hs.execute(", 1, true) == nil,
			"Ollama manager shell work must never use blocking hs.execute"
		)
		helpers.assert_true(
			src:find('require("adapters.shell_runner")', 1, true) ~= nil
				and src:find("ShellRunner.spawn", 1, true) ~= nil
				and src:find("OLLAMA_READINESS_PROBE_TIMEOUT_SEC", 1, true) ~= nil
				and src:find('"--max-time", tostring(OLLAMA_READINESS_PROBE_TIMEOUT_SEC)', 1, true) ~= nil,
			"readiness curl must be an owned ShellRunner argv task with the bounded timeout"
		)
		helpers.assert_true(
			src:find('require("adapters.timer_scheduler")', 1, true) ~= nil
				and src:find("TimerScheduler.after", 1, true) ~= nil,
			"readiness retries must use the retained timer adapter instead of raw timer callbacks"
		)

		-- Test 2: check_requirements must NOT use hs.execute for ollama list.
		helpers.assert_true(
			src:find('hs%.execute.*" list', 1, false) == nil,
			"check_requirements must not call hs.execute for 'ollama list' — use TaskLifecycle.native instead"
		)

		-- Test 3: delete_model must NOT use hs.execute for ollama rm.
		helpers.assert_true(
			src:find('hs%.execute.*" rm ', 1, false) == nil,
			"delete_model must not call hs.execute for 'ollama rm' — use TaskLifecycle.native instead"
		)

		-- Test 4: all model operations must use the guarded native-task adapter.
		local count = 0
		for _ in src:gmatch("TaskLifecycle%.native") do count = count + 1 end
		helpers.assert_true(
			count >= 4,
			string.format(
				"models_manager_ollama.lua must have at least 4 guarded native task launches; found %d",
				count
			)
		)

	end)
end)

return true
