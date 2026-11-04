--- tests/support/modules/llm/core/init_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_init
--- DESCRIPTION:
--- Prelude shared by the test_init_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- A prior test may have installed a stub modules.llm.profiles (with empty
-- get_all_profiles) that would leak into this file's top-level require.
-- Force the real implementation to be reloaded so profile accessors work.
package.loaded["modules.llm.profiles"]   = nil
package.loaded["llm.profile_selector"]   = nil

local Core = helpers.load_with_stubs("modules.llm")
local INITIAL_HS = _G.hs

local function load_core_with_timer_spy(options)
	options = options or {}
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local timer_spy_calls = {}
	local controller = {
		fail_next = options.initial_fail_next,
		cancel_failures = options.initial_cancel_failures or 0,
		cancel_mode = "true",
	}
	local scheduler_stub = {}
	local function settle_handle(handle)
		handle.committed = false
		handle.fired = true
		handle.timer = nil
		local observers = handle.settlement_observers or {}
		handle.settlement_observers = {}
		for _, observer in ipairs(observers) do observer() end
	end
	function scheduler_stub.after(delay, fn)
		local handle = {
			timer = {},
			committed = false,
			fired = false,
			settlement_observers = {},
		}
		local call = { delay = delay, fn = fn, handle = handle }
		timer_spy_calls[#timer_spy_calls + 1] = call
		function call.fire()
			if handle.committed ~= true or handle.fired then return false end
			settle_handle(handle)
			fn()
			return true
		end
		local reenter = controller.reenter_after
		if type(reenter) == "function" then
			controller.reenter_after = nil
			controller.reentrant_after_result = reenter()
		end
		local failure = controller.fail_next
		controller.fail_next = nil
		if failure == "settled" then
			handle.timer = nil
			handle.fired = true
			return handle, false
		elseif failure == "debt" then
			return handle, false
		end
		handle.committed = true
		return handle, true
	end
	function scheduler_stub.cancel(handle)
		if controller.cancel_mode == "throw" then
			error("profile warmup cancellation refusal")
		end
		if controller.cancel_mode == "false" then return false end
		if controller.cancel_mode == "nil" then return nil end
		if controller.cancel_failures > 0 then
			controller.cancel_failures = controller.cancel_failures - 1
			return false
		end
		local reenter = controller.reenter_cancel
		if type(reenter) == "function" then
			controller.reenter_cancel = nil
			controller.reentrant_result = reenter()
		end
		settle_handle(handle)
		return true
	end
	function scheduler_stub.onSettled(handle, observer)
		if handle.timer == nil then
			observer()
		else
			handle.settlement_observers[#handle.settlement_observers + 1] = observer
		end
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler_stub
	local fresh_core = helpers.load_with_stubs("modules.llm")
	local loaded_hs = package.loaded["hs"]
	local load_time_calls = {}
	for index, call in ipairs(timer_spy_calls) do load_time_calls[index] = call end
	for index = #timer_spy_calls, 1, -1 do timer_spy_calls[index] = nil end
	_G.hs = INITIAL_HS
	return fresh_core, timer_spy_calls, loaded_hs, controller, load_time_calls
end

--- Admits a native-owned Ollama daemon start for one fixture: the AI gate on
--- and an installed native-managed source authorize startup. External clients
--- remain selectable without service authority (llm-backend-ollama-start-gate).
--- @param core table A fresh core from load_core_with_timer_spy.
--- @return function restore Restores the executable resolver.
local function admit_ollama_start(core)
	helpers.assert_true(core.set_runtime_llm_enabled(true))
	local binary = package.loaded["modules.llm.ollama_binary"]
	local original_resolve = binary.resolve
	binary.resolve = function() return "/fixture/native/ollama", nil, binary.SOURCE_NATIVE_MANAGED end
	return function() binary.resolve = original_resolve end
end

return {
	Core = Core,
	INITIAL_HS = INITIAL_HS,
	admit_ollama_start = admit_ollama_start,
	load_core_with_timer_spy = load_core_with_timer_spy,
}
