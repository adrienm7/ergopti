--- tests/unit/meta/test_event_taps_recover_when_disabled.lua

--- ==============================================================================
--- MODULE: Event-Tap Native Recovery and Watchdog Backstops
--- DESCRIPTION:
--- Hammerspoon 1.1.1 consumes CoreGraphics disable notifications in Objective-C,
--- re-enables the affected tap, and returns before Lua callbacks run. Production
--- callbacks must carry no unreachable guard overhead. Independent watchdogs
--- remain necessary for taps still disabled after another native/lifecycle fault.
---
--- ROOT CAUSE ENCODED:
--- The former whole-class scan required every owner to reference a Lua recovery
--- API that the runtime could never call. This scan now rejects that entire fake
--- class and separately pins the three persistent watchdog backstops.
--- ==============================================================================

local helpers = require("tests.helpers")

local IMPOSSIBLE_LUA_MARKERS = {
	"EventTapGuard",
	"event_tap_guard",
	"handle_disabled",
	"tapDisabledByTimeout",
	"tapDisabledByUserInput",
	"disable_counts",
}


--- Reads one production unit selected by a move-stable unique declaration.
--- @param marker string Unique literal declaration.
--- @return string Production source.
local function production_unit(marker)
	local source, err = helpers.read_driver_unit(marker)
	helpers.assert_not_nil(source, err)
	return source
end


helpers.describe("event taps: native-only disable handling stays outside Lua", function()

	helpers.it("finds the production tap-owner class before checking it", function()
		local source = helpers.read_driver_source()
		local _, owner_count = source:gsub("eventtap%.new", "")

		helpers.assert_true(owner_count >= 10,
			"the scan must reach the production tap owners or every absence check is vacuous")
	end)

	helpers.it("keeps impossible disable handling off every production callback", function()
		local source = helpers.read_driver_source()
		helpers.assert_not_nil(source, "the production-source scan must not be empty")

		for _, marker in ipairs(IMPOSSIBLE_LUA_MARKERS) do
			helpers.assert_true(not source:find(marker, 1, true),
				"production still carries unreachable native-disable marker: " .. marker)
		end
	end)

end)


helpers.describe("event taps: persistent watchdog backstops", function()

	helpers.it("retains keymap tap-state polling and restart", function()
		local source = production_unit("local TAP_WATCHDOG_SEC = 1")

		helpers.assert_contains(source,
			"pcall(hs.timer.new, TAP_WATCHDOG_SEC, function()")
		helpers.assert_contains(source,
			"Logger.pcall(LOG, tap_watchdog, candidate, generation)")
		helpers.assert_contains(source, "_watchdog_timer ~= timer")
		helpers.assert_contains(source, "not eventtap_is_enabled(name, t)")
		helpers.assert_contains(source, "start_eventtap(name, t)")
	end)

	helpers.it("retains keylogger hook-state polling and restart", function()
		local source = production_unit("local TAP_WATCHDOG_INTERVAL_SEC = 5")

		helpers.assert_contains(source,
			"acquire_recurring_timer(TAP_WATCHDOG_INTERVAL_SEC,")
		helpers.assert_contains(source,
			"function(candidate) _tap_watchdog_timer = candidate end")
		helpers.assert_contains(source, "not KeyboardHook.isRunning()")
		helpers.assert_contains(source,
			"local restart_ok, restarted = Logger.pcall(LOG, KeyboardHook.start)")
		helpers.assert_contains(source,
			"local state_ok, running = Logger.pcall(LOG, KeyboardHook.isRunning)")
		helpers.assert_contains(source,
			"restart_ok and restarted == true and state_ok and running == true")
	end)

	helpers.it("retains script-control tap-state polling and restart", function()
		local source = production_unit("local TAP_WATCHDOG_INTERVAL_SEC = 2")

		helpers.assert_contains(source,
			"TimerScheduler.every, TAP_WATCHDOG_INTERVAL_SEC, function()")
		helpers.assert_contains(source, "not eventtap_is_enabled(_tap)")
		helpers.assert_contains(source,
			"start_eventtap_exact(_tap, \"Script-control watchdog recovery\")")
	end)

end)
