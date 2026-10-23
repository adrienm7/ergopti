--- tests/unit/modules/gestures/engine/test_paused_wake_recovery.lua

--- ==============================================================================
--- MODULE: Gesture Wake Recovery Across Global Pause
--- DESCRIPTION:
--- A wake while globally paused must retain the required native rebuild until
--- resume. These normal fixture cases use an externally stopped watcher and
--- the native running-state contract across controlled callback turns.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.gesture_runtime_fixture").with_fixture





-- ========================================
-- ========================================
-- ======= 1/ Owned Runtime Helpers =======
-- ========================================
-- ========================================

--- Retires every controlled native owner even when the scenario asserts red.
--- @param scenario function Receives the public module and native fixture ports.
local function with_runtime(scenario)
	with_fixture({}, function(gestures, runtime, watcher)
		local ok, detail = xpcall(function()
			scenario(gestures, runtime, watcher)
		end, debug.traceback)
		local cleanup_ok, cleanup_detail = xpcall(function()
			helpers.assert_eq(gestures.stop(), true, "the owned gesture fixture must retire")
			helpers.assert_eq(watcher:running(), false, "the owned touch watcher must stop")
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil, "the owned touch watcher must unpublish")
			helpers.assert_eq(_G.ERGOPTI_GESTURE_PRIMER, nil, "the owned primer must unpublish")
			helpers.assert_eq(_G.ERGOPTI_SLEEP_WATCHER, nil, "the owned wake watcher must unpublish")
			for _, handle in ipairs(runtime.primer_handles) do
				helpers.assert_eq(handle.running, false, "every retired primer must stop")
			end
			for _, handle in ipairs(runtime.wake_handles) do
				helpers.assert_eq(handle.running, false, "every retired wake watcher must stop")
			end
			for _, handle in ipairs(require("adapters.timer_scheduler").handles) do
				helpers.assert_eq(handle.active, false, "every owned timer must cancel")
			end
		end, debug.traceback)
		print("# gesture_cleanup " .. (cleanup_ok and "PASS" or "FAIL")
			.. " scenario=" .. (ok and "PASS" or "FAIL")
			.. " starts=" .. tostring(watcher.start_calls)
			.. " stops=" .. tostring(watcher.stop_calls)
			.. " primers=" .. tostring(#runtime.primer_handles)
			.. " wakes=" .. tostring(#runtime.wake_handles)
			.. " touch_owned=" .. tostring(_G.ERGOPTI_TOUCH_WATCHERS[42] ~= nil)
			.. " primer_owned=" .. tostring(_G.ERGOPTI_GESTURE_PRIMER ~= nil)
			.. " wake_owned=" .. tostring(_G.ERGOPTI_SLEEP_WATCHER ~= nil))
		if not cleanup_ok then
			error((ok and "" or detail .. "\n") .. "FIXTURE CLEANUP FAILED:\n" .. cleanup_detail, 0)
		end
		if not ok then error(detail, 0) end
	end)
end

--- Delivers one frame only while the native port reports monitoring enabled.
--- @param runtime table Captured frame callback and engine accounting.
--- @param watcher table Controlled touchdevice object.
local function deliver_touch(runtime, watcher)
	if watcher:running() then runtime.frame_callback(nil, { {} }, 0, 1) end
end

--- Commits the runtime and its first touch callback, then enters slow health mode.
--- @param gestures table Public gestures module.
--- @param runtime table Captured native capabilities.
--- @param watcher table Controlled touchdevice object.
local function prepare_live_runtime(gestures, runtime, watcher)
	helpers.assert_eq(gestures.start(), true)
	deliver_touch(runtime, watcher)
	helpers.assert_eq(runtime.engine_process_calls, 1)
	helpers.assert_eq(_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME, true)
	local scheduler = require("adapters.timer_scheduler")
	scheduler.handles[1].callback()
	helpers.assert_eq(#scheduler.handles, 2,
		"the first-frame observation must enter the normal slow health timer")
end





-- ==========================================
-- ==========================================
-- ======= 2/ Normal Wake Transitions =======
-- ==========================================
-- ==========================================

helpers.describe("gesture wake recovery across global pause", function()
	helpers.it("recovers an externally stopped watcher on an unpaused wake", function()
		with_runtime(function(gestures, runtime, watcher)
			prepare_live_runtime(gestures, runtime, watcher)
			local starts = watcher.start_calls
			-- A native state transition between callback turns, not a refused factory.
			watcher.running_state = false
			runtime.wake_handles[1].callback(require("hs.caffeinate.watcher").systemDidWake)
			helpers.assert_eq(watcher.start_calls, starts + 1)
			helpers.assert_eq(watcher:running(), true)
			deliver_touch(runtime, watcher)
			helpers.assert_eq(runtime.engine_process_calls, 2)
		end)
	end)

	helpers.it("rebuilds a paused wake before the first resumed touch", function()
		with_runtime(function(gestures, runtime, watcher)
			prepare_live_runtime(gestures, runtime, watcher)
			helpers.assert_eq(gestures.suspend(), true)
			local starts = watcher.start_calls
			local registrations = runtime.frame_callback_registrations
			watcher.running_state = false
			runtime.wake_handles[1].callback(require("hs.caffeinate.watcher").systemDidWake)
			helpers.assert_eq(watcher.start_calls, starts, "PAUSE must perform no native restart")
			helpers.assert_eq(runtime.frame_callback_registrations, registrations)
			helpers.assert_eq(gestures.resume(), true)
			helpers.assert_eq(watcher:running(), true,
				"RESUME must replay the observed wake before the next slow health tick")
			deliver_touch(runtime, watcher)
			helpers.assert_eq(runtime.engine_process_calls, 2,
				"the first resumed touch frame must reach the engine immediately")
		end)
	end)

	helpers.it("retains repeated paused wakes through native restart refusal and OFF", function()
		with_runtime(function(gestures, runtime, watcher)
			prepare_live_runtime(gestures, runtime, watcher)
			local wake = runtime.wake_handles[1]
			local event = require("hs.caffeinate.watcher").systemDidWake
			helpers.assert_eq(gestures.suspend(), true)
			watcher.running_state = false
			wake.callback(event)
			helpers.assert_eq(gestures.suspend(), true)
			wake.callback(event)
			-- Native start() returns self even when MTDeviceStart fails and running()
			-- remains false. The existing fixture models that legal no-effect result.
			watcher.start_mode = "unsettled"
			helpers.assert_eq(gestures.resume(), false,
				"a required native rebuild that stays stopped must refuse RESUME")
			helpers.assert_eq(gestures.is_enabled(), true)
			helpers.assert_eq(gestures.is_suspended(), true)
			helpers.assert_eq(runtime.engine_process_calls, 1)
			watcher.start_mode = "commit"
			helpers.assert_eq(gestures.resume(), true,
				"the same retained rebuild intent must be retryable")
			helpers.assert_eq(watcher:running(), true)
			local recovered_starts = watcher.start_calls
			wake.callback(event)
			helpers.assert_eq(gestures.resume(), true)
			helpers.assert_eq(watcher.start_calls, recovered_starts,
				"a retired wake callback and a settled intent must not rebuild again")
			deliver_touch(runtime, watcher)
			helpers.assert_eq(runtime.engine_process_calls, 2)
			helpers.assert_eq(gestures.suspend(), true)
			watcher.running_state = false
			runtime.wake_handles[#runtime.wake_handles].callback(event)
			helpers.assert_eq(gestures.disable_all(), true)
			helpers.assert_eq(gestures.resume(), true)
			helpers.assert_eq(gestures.is_enabled(), false)
			helpers.assert_eq(watcher.start_calls, recovered_starts,
				"OFF during the retained wake must preserve disabled intent")
		end)
	end)
end)
