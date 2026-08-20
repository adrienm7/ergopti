--- tests/meta/test_mlx_warmup_timeout_cancel.lua

--- ==============================================================================
--- MODULE: Regression — api_mlx warmup timeout cancelled via TimerScheduler (M-2)
--- DESCRIPTION:
--- The TimerScheduler handle returned by TimerScheduler.after() is a plain table
--- {fired, id, timer} with no :stop() method. Two sites in api_mlx.lua previously
--- called pcall(function() _warmup_timeout:stop() end), which:
---   (a) raised "attempt to call a nil value (field 'stop')" (swallowed by pcall),
---   (b) left the underlying hs.timer running as an orphan,
---   (c) when the orphan fired it clobbered _warmup_timeout and flipped
---       _warmup_in_flight=false, corrupting a later warmup cycle.
---
--- Fix: every timeout teardown selects the exact retained handle through
--- cancel_warmup_timer(), which calls TimerScheduler.cancel(handle) and clears
--- the slot only after that adapter reports literal true.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("api_mlx: warmup timeout uses TimerScheduler.cancel not :stop() (M-2)", function()
	local function read_src()
		-- Selected by a declaration unique to modules/llm/api_mlx.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_user_port_override")
		helpers.assert_true(src ~= nil, "modules/llm/api_mlx.lua source must be locatable")
		return src
	end

	helpers.it("api_mlx.lua contains no _warmup_timeout:stop() call", function()
		local src = read_src()
		helpers.assert_true(
			src:find("_warmup_timeout:stop") == nil,
			"api_mlx.lua must NOT call _warmup_timeout:stop() — the handle has no :stop method; use TimerScheduler.cancel()"
		)
	end)

	helpers.it("api_mlx.lua delegates exact warmup timeout teardown to TimerScheduler.cancel", function()
		local src = read_src()
		local helper_at = src:find("local function cancel_warmup_timer", 1, true)
		local helper_end = helper_at and src:find("\n--- Schedules one generation%-fenced warmup retry", helper_at)
		helpers.assert_true(helper_at ~= nil and helper_end ~= nil,
			"the exact warmup timer cleanup helper must remain independently locatable")
		local helper = src:sub(helper_at, helper_end - 1)
		helpers.assert_true(
			helper:find("slot_name == \"timeout\" and _warmup_timeout", 1, true) ~= nil,
			"the helper must select the exact retained warmup timeout capability")
		helpers.assert_true(helper:find("TimerScheduler.cancel(handle)", 1, true) ~= nil,
			"the retained scheduler handle must be cancelled through its owning adapter")
		helpers.assert_true(
			helper:find("slot_name == \"timeout\" and _warmup_timeout == handle", 1, true) ~= nil,
			"successful cancellation may clear only the exact timeout generation it settled")
		local _, timeout_call_count = src:gsub("cancel_warmup_timer%(\"timeout\"%)", "")
		helpers.assert_true(timeout_call_count >= 3,
			"warmup completion, reset, and stop paths must all use the exact cleanup helper")
	end)
end)
