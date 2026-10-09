--- tests/unit/infra/test_hs_delayed_timer_stub_contract.lua

--- ==============================================================================
--- MODULE: Hammerspoon Delayed Timer Stub Contract
--- DESCRIPTION:
--- Pins Hammerspoon 1.1.1's specialized timer wrapper: temporary start delays
--- leave the configured delay intact, methods expose native return shapes, and
--- a callback may rearm the retained timer without losing its next delivery.
--- ==============================================================================

local helpers = require("tests.helpers")

local function timer_fixture(delay, callback)
	local hs_stub = dofile("tests/stubs/hs.lua")
	local handle = hs_stub.timer.delayed.new(delay, callback or function() end)
	return handle, hs_stub.timer.__timers[1]
end

helpers.describe("hs.timer.delayed stub: native countdown ownership", function()
	helpers.it("keeps a start override temporary and resets the next start to its default", function()
		local handle, entry = timer_fixture(10)
		helpers.assert_true(handle:start(1) == handle)
		helpers.assert_eq(entry.delay, 1)
		handle:start()
		helpers.assert_eq(entry.delay, 10, "an override must not replace the configured default")
	end)

	helpers.it("returns native setDelay receipts and restarts only a running countdown", function()
		local handle, entry = timer_fixture(10)
		helpers.assert_true(handle:setDelay(20) == handle, "setDelay returns the delayed handle")
		helpers.assert_eq(entry.running, false, "changing the default does not arm an idle timer")
		handle:start(1)
		helpers.assert_true(handle:setDelay(30) == handle)
		helpers.assert_eq(entry.delay, 30, "a running countdown restarts at the new default")
		handle:stop()
		handle:start()
		helpers.assert_eq(entry.delay, 30)
	end)

	helpers.it("reports native running and nextTrigger shapes without exposing the internal arm", function()
		local handle, entry = timer_fixture(10)
		helpers.assert_eq(type(handle.running), "function")
		helpers.assert_eq(handle:running(), false)
		helpers.assert_nil(handle:nextTrigger())
		handle:start(1)
		helpers.assert_eq(handle:running(), true)
		helpers.assert_eq(handle:nextTrigger(), 1)
		handle:start(20)
		helpers.assert_eq(entry.running, true, "the native wrapper can hide a longer override")
		helpers.assert_eq(handle:running(), false, "native nextTrigger excludes delays above the default")
		helpers.assert_nil(handle:nextTrigger())
		helpers.assert_true(handle:stop() == handle)
		helpers.assert_eq(handle:running(), false)
		helpers.assert_eq(entry.running, false)
	end)

	helpers.it("preserves a callback's rearm through its next delivery", function()
		local handle, entry
		local calls = 0
		handle, entry = timer_fixture(1, function()
			calls = calls + 1
			if calls == 1 then handle:start(0.5) end
		end)
		handle:start()
		entry:fire()
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(entry.running, true, "callback rearm survives delivery settlement")
		entry:fire()
		helpers.assert_eq(calls, 2, "the same retained native timer must deliver the retry")
		helpers.assert_eq(entry.running, false)
		entry:fire()
		helpers.assert_eq(calls, 2, "an idle countdown must not deliver again")
	end)

	helpers.it("delivers zero-delay callbacks even though native running filters them out", function()
		local calls = 0
		local handle, entry = timer_fixture(0, function() calls = calls + 1 end)
		handle:start()
		helpers.assert_eq(handle:running(), false, "native nextTrigger requires a positive remaining delay")
		helpers.assert_eq(entry.running, true, "zero-delay dispatch is still pending")
		entry:fire()
		helpers.assert_eq(calls, 1)
	end)
end)
