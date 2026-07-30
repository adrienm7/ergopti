--- tests/unit/modules/llm/test_load_api_entries_deferred.lua

--- ==============================================================================
--- MODULE: Regression — LLM API-entry load deferred off the boot path (F-HIGH-4)
--- DESCRIPTION:
--- modules.llm runs load_api_entries() at module-require time. That function
--- decrypts every keychain-referenced token via a BLOCKING
--- `security find-generic-password` shell-out (and can raise a modal
--- Keychain-unlock prompt). Because modules.llm is on the boot require chain
--- (init → keymap → llm_bridge → llm), running it synchronously blocked boot
--- before the keyboard eventtap was created — N saved entries = N blocking
--- subprocess spawns, and a locked Keychain froze the whole run loop on a prompt.
---
--- Fix: defer the load with TimerScheduler.after(0) so it runs on the next
--- run-loop tick, past eventtap creation. The harness runs doAfter(0) inline, so
--- this is pinned structurally: the require-path load must be deferred via the
--- scheduler, never a bare synchronous top-level call.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("llm: persisted API-entry load is deferred off the require path (F-HIGH-4)", function()
	local function read_src()
		-- Selected by a declaration unique to modules/llm/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.start_background_network_bootstrap")
		helpers.assert_true(src ~= nil, "modules/llm/init.lua source must be locatable")
		return src
	end

	helpers.it("defers the require-path load via TimerScheduler.after(0)", function()
		local src = read_src()
		helpers.assert_true(
			src:find("TimerScheduler.after(0, function() pcall(M.load_api_entries) end)", 1, true) ~= nil,
			"the persisted-entry load (blocking Keychain decrypt) must be deferred via TimerScheduler.after(0)")
	end)

	helpers.it("does NOT call load_api_entries synchronously at top level on require", function()
		local src = read_src()
		-- A column-0 `pcall(M.load_api_entries)` is the old synchronous boot-path
		-- call. After the fix the only occurrence is inside the scheduler closure
		-- (preceded by `function() `, not by a newline).
		helpers.assert_true(src:find("\npcall(M.load_api_entries)") == nil,
			"load_api_entries must not be called synchronously at top level (it blocks boot before the tap exists)")
	end)
end)
