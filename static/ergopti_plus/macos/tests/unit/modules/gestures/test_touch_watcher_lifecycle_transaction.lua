--- tests/unit/modules/gestures/test_touch_watcher_lifecycle_transaction.lua

--- ==============================================================================
--- MODULE: Gesture Touch-Watcher Lifecycle Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the private touchdevice watcher through the public gesture lifecycle
--- with native-faithful refusal states. It proves startup commits only a running
--- watcher, teardown retains an exact live capability until release settles, and
--- queued frames become inert before engine teardown.
---
--- FEATURES & RATIONALE:
--- 1. Native-State Doubles: Start and stop can return normally without changing
---    running state, matching the private module's observable failure contract.
--- 2. Exact Cleanup Retry: A refused watcher remains owned and the next stop call
---    retries the same object rather than forgetting or replacing it.
--- 3. Dormancy Preservation: A running watcher with alive false remains valid
---    before the kernel delivers the first physical touch.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.gesture_runtime_fixture").with_fixture





-- ===========================================
-- ===========================================
-- ======= 1/ Watcher Commit Contracts =======
-- ===========================================
-- ===========================================

helpers.describe("gesture touch watchers are exact lifecycle transactions", function()
	for _, start_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects native watcher start mode " .. start_mode, function()
			with_fixture({ start_mode = start_mode }, function(gestures, _, watcher)
				helpers.assert_eq(gestures.start(), false,
					"gesture startup must reject a watcher that never becomes running")
				helpers.assert_eq(watcher.running_state, false)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil,
					"a fully rolled-back start refusal must not remain published")
			end)
		end)
	end

	for _, frame_mode in ipairs({ "nil", "throw" }) do
		helpers.it("rejects frame callback registration mode " .. frame_mode, function()
			with_fixture({ frame_callback_mode = frame_mode }, function(gestures)
				helpers.assert_eq(gestures.start(), false,
					"missing native callback ownership must reject gesture startup")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
			end)
		end)
	end

	helpers.it("commits running watcher while preserving pre-touch dormancy", function()
		with_fixture({ alive_state = false }, function(gestures, _, watcher)
			helpers.assert_eq(gestures.start(), true,
				"running true and alive false is the valid kernel-gated state")
			helpers.assert_eq(watcher.running_state, true)
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher)
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("accepts the native userdata watcher capability", function()
		with_fixture({ watcher_kind = "userdata" }, function(gestures, _, watcher)
			helpers.assert_eq(type(watcher), "userdata")
			helpers.assert_eq(gestures.start(), true)
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher)
			helpers.assert_eq(gestures.stop(), true)
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
		end)
	end)

	helpers.it("refuses start under suspension without constructing successor owners", function()
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.start(), true)
			helpers.assert_eq(gestures.suspend(), true)
			local watcher_starts = watcher.start_calls
			local primer = _G.ERGOPTI_GESTURE_PRIMER
			local wake_watcher = _G.ERGOPTI_SLEEP_WATCHER
			local cleanup_before = runtime.action_cleanup_calls
			local resumes_before = runtime.action_resume_calls

			helpers.assert_eq(gestures.start(), false,
				"ScriptControl suspension must be admission-authoritative")
			helpers.assert_eq(gestures.is_suspended(), true)
			helpers.assert_eq(gestures.is_enabled(), true,
				"a refused duplicate start must preserve the feature snapshot")
			helpers.assert_eq(runtime.action_cleanup_calls, cleanup_before + 1)
			helpers.assert_eq(runtime.action_resume_calls, resumes_before)
			helpers.assert_eq(watcher.start_calls, watcher_starts)
			helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER == primer)
			helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER == wake_watcher)
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("retains a partially activated start until exact rollback settles", function()
		with_fixture({ start_mode = "partial_throw", stop_mode = "false" },
			function(gestures, runtime, watcher, device)
				helpers.assert_eq(gestures.start(), false)
				helpers.assert_eq(watcher.running_state, true)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_DEVICES[42], device)
				local process_calls = runtime.engine_process_calls
				runtime.frame_callback(nil, { {} }, nil, nil)
				helpers.assert_eq(runtime.engine_process_calls, process_calls,
					"a never-committed callback must remain inert during cleanup debt")

				watcher.stop_mode = "commit"
				local stop_calls_before_retry = watcher.stop_calls
				helpers.assert_eq(gestures.stop(), true)
				helpers.assert_eq(watcher.stop_calls, stop_calls_before_retry + 1,
					"module stop must retry the exact rollback-refused candidate")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
			end)
	end)

	for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and retries native watcher stop mode " .. stop_mode, function()
			with_fixture({}, function(gestures, runtime, watcher, device)
				helpers.assert_eq(gestures.start(), true)
				local captured_callback = runtime.frame_callback
				watcher.stop_mode = stop_mode

				helpers.assert_eq(gestures.stop(), false,
					"a still-running watcher must keep teardown unsettled")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher,
					"the exact live watcher must remain owned for retry")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_DEVICES[42], device,
					"the exact device owner must remain pinned with cleanup debt")
				helpers.assert_eq(watcher.running_state, true)
				local process_calls = runtime.engine_process_calls
				captured_callback(nil, { {} }, nil, nil)
				helpers.assert_eq(runtime.engine_process_calls, process_calls,
					"a queued frame must be inert after stop fencing")

				watcher.stop_mode = "commit"
				helpers.assert_eq(gestures.stop(), true,
					"teardown must retry and settle the same retained watcher")
				helpers.assert_eq(watcher.stop_calls, 2)
				helpers.assert_eq(watcher.running_state, false)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_DEVICES[42], nil)
			end)
		end)
	end

	for _, boundary in ipairs({
		"primer_factory", "primer_start", "touch_factory", "touch_start",
		"timer_factory", "wake_factory", "wake_start",
	}) do
		helpers.it("rolls back and rebuilds an ON startup when " .. boundary
			.. " reenters suspend", function()
			with_fixture({ reenter_boundary = boundary },
				function(gestures, runtime, watcher)
					helpers.assert_eq(gestures.start(), false)
					helpers.assert_eq(runtime.suspend_results, { true })
					helpers.assert_eq(gestures.is_enabled(), true,
						"the exact ON feature snapshot must survive startup rollback")
					helpers.assert_eq(gestures.is_suspended(), true)
					for _, handle in ipairs(runtime.primer_handles) do
						local scheduler_count = #require("adapters.timer_scheduler").handles
						handle.callback({ getType = function() return 0 end })
						helpers.assert_eq(#require("adapters.timer_scheduler").handles,
							scheduler_count, "a rolled-back primer callback must stay inert")
					end

					helpers.assert_eq(gestures.resume(), true,
						"RESUME must reconstruct every native owner after interrupted startup")
					helpers.assert_eq(gestures.is_enabled(), true)
					helpers.assert_eq(gestures.is_suspended(), false)
					helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER ~= nil)
					helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER.running)
					helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER ~= nil)
					helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER.running)
					helpers.assert_eq(watcher.running_state, true)
					helpers.assert_eq(gestures.stop(), true)
				end)
		end)
	end

	for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains exact primer rollback debt after reentrant suspend mode "
			.. stop_mode, function()
			local options = {
				reenter_boundary = "primer_start",
				primer_stop_mode = stop_mode,
			}
			with_fixture(options, function(gestures, runtime)
				helpers.assert_eq(gestures.start(), false)
				local retained = runtime.primer_handles[1]
				helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER == retained,
					"the exact stop-refused primer must remain owned")
				helpers.assert_eq(retained.running, true)
				local scheduler_count = #require("adapters.timer_scheduler").handles
				retained.callback({ getType = function() return 0 end })
				helpers.assert_eq(#require("adapters.timer_scheduler").handles,
					scheduler_count, "cleanup-debt callbacks must remain fenced")

				options.primer_stop_mode = "commit"
				helpers.assert_eq(gestures.resume(), true,
					"RESUME retries the retained primer before constructing a successor")
				helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER ~= retained)
				helpers.assert_eq(retained.running, false)
				helpers.assert_eq(gestures.is_enabled(), true)
				helpers.assert_eq(gestures.is_suspended(), false)
				helpers.assert_eq(gestures.stop(), true)
			end)
		end)
	end

	for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("settles interrupted startup debt before OFF and rebuilds on later ON mode "
			.. stop_mode, function()
			local options = {
				reenter_boundary = "primer_start",
				primer_stop_mode = stop_mode,
			}
			with_fixture(options, function(gestures, _, watcher)
				helpers.assert_eq(gestures.start(), false)
				helpers.assert_eq(gestures.disable_all(), false,
					"OFF may not commit while interrupted-start native debt refuses")
				helpers.assert_eq(gestures.is_enabled(), true)
				helpers.assert_eq(gestures.is_suspended(), true)

				options.primer_stop_mode = "commit"
				helpers.assert_eq(gestures.disable_all(), true)
				helpers.assert_eq(gestures.is_enabled(), false)
				helpers.assert_eq(gestures.resume(), true)
				helpers.assert_eq(gestures.is_enabled(), false)
				helpers.assert_eq(gestures.is_suspended(), false)
				helpers.assert_eq(_G.ERGOPTI_GESTURE_PRIMER, nil)
				helpers.assert_eq(_G.ERGOPTI_SLEEP_WATCHER, nil)

				helpers.assert_eq(gestures.enable_all(), true,
					"a later ON must reconstruct the native runtime, not only action admission")
				helpers.assert_eq(gestures.is_enabled(), true)
				helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER ~= nil)
				helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER ~= nil)
				helpers.assert_eq(watcher.running_state, true)
				helpers.assert_eq(gestures.stop(), true)
			end)
		end)
	end
end)
