--- tests/unit/modules/gestures/test_disable_stops_health_loop.lua

--- ==============================================================================
--- MODULE: Gesture Runtime Follows The Feature Switch Regression
--- DESCRIPTION:
--- Gestures OFF used to clear only the feature flag: boot had started the native
--- runtime unconditionally, so the touch watchers, the primer eventtap and the
--- 30 s health-check timer kept polling (and logging) with Gestures disabled.
--- The runtime now exists only while the feature is ON: enable_all acquires it,
--- disable_all releases every native owner, and a later ON rebuilds it.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.gesture_runtime_fixture").with_fixture





-- ======================================
-- ======================================
-- ======= 1/ Native Owner Probes =======
-- ======================================
-- ======================================

--- Returns the recurring-timer handles the scheduler double still runs.
--- @return table active Active handles in creation order.
local function active_timers()
	local active = {}
	for _, handle in ipairs(require("adapters.timer_scheduler").handles) do
		if handle.active then active[#active + 1] = handle end
	end
	return active
end

--- Returns whether any primer or wake-watcher handle is still running.
--- @param runtime table Fixture runtime observations.
--- @return boolean running
local function any_native_listener_running(runtime)
	for _, handle in ipairs(runtime.primer_handles) do
		if handle.running then return true end
	end
	for _, handle in ipairs(runtime.wake_handles) do
		if handle.running then return true end
	end
	return false
end

--- Moves a started runtime into its slow health-check loop, as the first
--- physical touch does, and returns the health-check timer handle.
--- @return table handle The single active health-check timer.
local function enter_health_check_loop()
	local probes = active_timers()
	helpers.assert_eq(#probes, 1, "a started runtime must own exactly one discovery timer")
	_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
	probes[1].callback()
	local health = active_timers()
	helpers.assert_eq(#health, 1, "the first frame must hand over to the health-check loop")
	helpers.assert_true(health[1] ~= probes[1], "the health check must be a new timer")
	return health[1]
end

--- Asserts that no native gesture owner is acquired or published.
--- @param runtime table Fixture runtime observations.
--- @param watcher table Touch watcher double.
--- @param label string Assertion context.
local function assert_runtime_released(runtime, watcher, label)
	helpers.assert_eq(#active_timers(), 0, label .. ": no discovery or health-check timer may run")
	helpers.assert_true(not any_native_listener_running(runtime),
		label .. ": the primer eventtap and the wake watcher must be stopped")
	helpers.assert_eq(_G.ERGOPTI_GESTURE_PRIMER, nil, label .. ": no primer may stay published")
	helpers.assert_eq(_G.ERGOPTI_SLEEP_WATCHER, nil, label .. ": no wake watcher may stay published")
	helpers.assert_eq(watcher.running_state, false, label .. ": the touch watcher must be stopped")
	helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil, label .. ": no touch watcher may stay owned")
end

--- Asserts that the complete native runtime is live.
--- @param runtime table Fixture runtime observations.
--- @param watcher table Touch watcher double.
--- @param label string Assertion context.
local function assert_runtime_live(runtime, watcher, label)
	helpers.assert_eq(#active_timers(), 1, label .. ": the discovery timer must run")
	helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER ~= nil and _G.ERGOPTI_GESTURE_PRIMER.running,
		label .. ": the primer eventtap must run")
	helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER ~= nil and _G.ERGOPTI_SLEEP_WATCHER.running,
		label .. ": the wake watcher must run")
	helpers.assert_eq(watcher.running_state, true, label .. ": the touch watcher must run")
	helpers.assert_true(runtime.frame_callback_registrations >= 1,
		label .. ": a frame callback must be registered")
end





-- ===============================================
-- ===============================================
-- ======= 2/ The Runtime Follows The Flag =======
-- ===============================================
-- ===============================================

helpers.describe("gestures runtime exists only while Gestures is ON", function()
	helpers.it("reports Gestures OFF and owns nothing before enable_all commits", function()
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.is_enabled(), false,
				"a loaded module must not claim ON before the saved preference applies")
			helpers.assert_eq(gestures.disable_all(), true,
				"the boot sync of a saved OFF must commit")
			helpers.assert_eq(#runtime.primer_handles, 0, "OFF must never construct a primer")
			helpers.assert_eq(runtime.frame_callback_registrations, 0,
				"OFF must never register a touch frame callback")
			helpers.assert_eq(#require("adapters.timer_scheduler").handles, 0,
				"OFF must never arm a discovery timer")
			helpers.assert_eq(#runtime.wake_handles, 0, "OFF must never construct a wake watcher")
			assert_runtime_released(runtime, watcher, "boot OFF")
		end)
	end)

	helpers.it("acquires the complete native runtime on enable_all", function()
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.enable_all(), true)
			helpers.assert_eq(gestures.is_enabled(), true)
			assert_runtime_live(runtime, watcher, "enable_all")
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("releases every native owner and silences the health check on disable_all", function()
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.start(), true)
			local health = enter_health_check_loop()

			helpers.assert_eq(gestures.disable_all(), true)
			helpers.assert_eq(gestures.is_enabled(), false)
			assert_runtime_released(runtime, watcher, "disable_all")

			local enumerations = runtime.device_enumerations
			local registrations = runtime.frame_callback_registrations
			health.callback()
			helpers.assert_eq(runtime.device_enumerations, enumerations,
				"a retained health-check tick must not scan devices while OFF")
			helpers.assert_eq(runtime.frame_callback_registrations, registrations,
				"a retained health-check tick must not recreate a watcher while OFF")
		end)
	end)

	helpers.it("rebuilds the native runtime when Gestures is switched back ON", function()
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.start(), true)
			helpers.assert_eq(gestures.disable_all(), true)
			helpers.assert_eq(gestures.enable_all(), true)
			helpers.assert_eq(#runtime.primer_handles, 2,
				"ON after OFF must construct a fresh primer")
			assert_runtime_live(runtime, watcher, "enable_all after disable_all")
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("leaves Gestures OFF without owners when the native start is refused", function()
		with_fixture({ start_mode = "false" }, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.enable_all(), false,
				"a refused native start must refuse the ON transition")
			helpers.assert_eq(gestures.is_enabled(), false)
			assert_runtime_released(runtime, watcher, "refused enable_all")
		end)
	end)

	helpers.it("keeps Gestures ON while a watcher refuses to stop, then retries", function()
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.start(), true)
			watcher.stop_mode = "false"
			helpers.assert_eq(gestures.disable_all(), false,
				"OFF must not commit while a native owner is still live")
			helpers.assert_eq(gestures.is_enabled(), true,
				"a refused OFF must not publish the feature as disabled")
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher,
				"the exact live watcher must stay owned for the retry")

			watcher.stop_mode = "commit"
			helpers.assert_eq(gestures.disable_all(), true)
			assert_runtime_released(runtime, watcher, "retried disable_all")
		end)
	end)
end)

return true
