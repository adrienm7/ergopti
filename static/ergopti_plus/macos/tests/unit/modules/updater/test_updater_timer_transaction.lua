--- tests/unit/modules/updater/test_updater_timer_transaction.lua

--- ==============================================================================
--- MODULE: Updater Timer Transaction Regression Tests
--- DESCRIPTION:
--- Exercises recurring-timer acquisition, stale-callback fencing, and retryable
--- teardown through the updater's public lifecycle API.
---
--- ROOT CAUSE ENCODED:
--- A shorthand recurring constructor starts the native timer before returning
--- its handle. If startup throws after that mutation, assigning only the return
--- value loses the exact live timer forever. The former callback also captured
--- the current generation only when it fired, so an orphan from an old channel
--- could authenticate itself as the newest channel. These tests model both the
--- partial-start failure and a native stop refusal.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Builds a scheduler spy whose exact handles can refuse cleanup.
--- @param options table Failure controls.
--- @return table scheduler
--- @return table state
local function scheduler_spy(options)
	local state = {
		every_calls = 0,
		after_calls = 0,
		cancel_calls = 0,
		handles = {},
	}
	local scheduler = {}

	function scheduler.every(_, callback)
		state.every_calls = state.every_calls + 1
		local handle = {
			callback = callback,
			kind = "every",
			fired = false,
			stop_allowed = options.stop_allowed ~= false,
		}
		state.handles[#state.handles + 1] = handle
		if options.partial_every_once and state.every_calls == 1 then
			return handle, false
		end
		return handle, true
	end

	function scheduler.after(_, callback)
		state.after_calls = state.after_calls + 1
		local handle = {
			callback = callback,
			kind = "after",
			fired = false,
			stop_allowed = options.stop_allowed ~= false,
		}
		state.handles[#state.handles + 1] = handle
		return handle, true
	end

	function scheduler.cancel(handle)
		state.cancel_calls = state.cancel_calls + 1
		if handle.stop_allowed ~= true then return false end
		handle.fired = true
		return true
	end

	return scheduler, state
end


--- Loads a fresh packaged updater against one injected scheduler.
--- @param scheduler table TimerScheduler test double.
--- @param http_calls table Mutable HTTP observation record.
--- @return table updater
local function fresh_updater(scheduler, http_calls)
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["modules.updater"] = nil
	return helpers.load_with_stubs("modules.updater", {
		processInfo = { bundleID = "com.ergoptiplus.app.hammerspoon", version = "1.1.1" },
		http = {
			asyncGet = function()
				http_calls.count = http_calls.count + 1
			end,
		},
	})
end


helpers.describe("updater: recurring timer acquisition is transactional", function()

	helpers.it("retains partial-start debt, fences it, and refuses a successor", function()
		local scheduler, state = scheduler_spy({
			partial_every_once = true,
			stop_allowed = false,
		})
		local http_calls = { count = 0 }
		local updater = fresh_updater(scheduler, http_calls)

		helpers.assert_eq(updater.start_background_checks("stable", 100, function() end), false,
			"a partially acquired recurring timer must not publish a successful start")
		helpers.assert_eq(state.every_calls, 1)
		local orphan = state.handles[1]
		orphan.callback()
		helpers.assert_eq(http_calls.count, 0,
			"a partial-start callback must be fenced before it can issue an HTTP request")

		helpers.assert_eq(updater.start_background_checks("dev", 100, function() end), false,
			"a successor must be refused while exact cleanup debt remains")
		helpers.assert_eq(state.every_calls, 1,
			"refusing cleanup must not allocate a second recurring timer")

		orphan.stop_allowed = true
		helpers.assert_eq(updater.stop_background_checks(), true,
			"teardown must retry and settle the retained exact handle")
	end)

	helpers.it("invalidates a committed timer before a refused native stop", function()
		local scheduler, state = scheduler_spy({ stop_allowed = true })
		local http_calls = { count = 0 }
		local updater = fresh_updater(scheduler, http_calls)

		helpers.assert_eq(updater.start_background_checks("stable", 100, function() end), true)
		local recurring = state.handles[1]
		recurring.stop_allowed = false
		helpers.assert_eq(updater.stop_background_checks(), false,
			"a native stop refusal must remain visible to the caller")

		recurring.callback()
		helpers.assert_eq(http_calls.count, 0,
			"an old-channel callback must stay fenced even while its handle awaits cleanup")
		helpers.assert_eq(updater.restart_background_checks("dev", 100, function() end), false)
		helpers.assert_eq(state.every_calls, 1,
			"restart must not replace a handle whose stop was refused")

		recurring.stop_allowed = true
		helpers.assert_eq(updater.stop_background_checks(), true)
	end)

end)
