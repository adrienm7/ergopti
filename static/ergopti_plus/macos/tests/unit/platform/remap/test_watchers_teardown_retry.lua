--- tests/unit/platform/remap/test_watchers_teardown_retry.lua

--- ==============================================================================
--- MODULE: Karabiner Watcher Teardown Retry Tests
--- DESCRIPTION:
--- Exercises the exact native handles owned by the input-source and app-switch
--- watchers. Every stop is forced to fail once, proving that callbacks become
--- inert immediately while the same capabilities remain available for retry.
--- ==============================================================================

local helpers = require("tests.helpers")


-- =========================================
-- =========================================
-- ======= 1/ Controllable Harness =========
-- =========================================
-- =========================================

local function fresh_harness()
	-- Never borrow the ambient `_G.hs`: a preceding broker test deliberately
	-- installs a setter-only keycodes table with no map. Resolve the canonical map
	-- from a fresh default stub before load_with_stubs builds this fixture.
	package.loaded["tests.stubs.hs"] = nil
	local keycode_map = require("tests.stubs.hs").keycodes.map
	package.loaded["platform.remap.watchers"] = nil
	-- The broker captures `local hs = hs` at require-time. Reload it only after
	-- load_with_stubs installs this harness's setter-only keycodes API.
	package.loaded["adapters.input_source_broker"] = nil

	local h = {
		fail_once = false,
		fail_read_start = false,
		fail_read_terminate_once = false,
		fail_callback_unset_once = false,
		poll_timer_failure = nil,
		poll_timer_stop_refuse_once = false,
		poll_timer_truthy_stop_running_once = false,
		poll_callback_throw = false,
		fail_next_scheduled_commit = false,
		scheduled_cancel_refuse_once = false,
		poll_timer_create_attempts = 0,
		logged_errors = {},
		layout = "ABC",
		raw_timers = {},
		scheduled_timers = {},
		reads = {},
		app_watchers = {},
		hotkeys = {},
		layout_changes = {},
		read_lifecycle = {},
		launches = {},
		bundle_launch_result = true,
		name_launch_result = true,
		activation_result = true,
		activations = 0,
		ordered_windows = {},
		focused_window = nil,
	}

	local function raw_timer(kind, callback, initially_active)
		local handle = {
			kind = kind,
			callback = callback,
			start_attempts = 0,
			stop_attempts = 0,
			active = initially_active == true,
		}
		function handle:start()
			self.start_attempts = self.start_attempts + 1
			if kind == "poll" and self.start_attempts == 1
				and h.poll_timer_failure == "start_truthy_without_activation" then
				return self
			end
			self.active = true
			if kind == "poll" and self.start_attempts == 1 then
				if h.poll_timer_failure == "callback_before_commit" then
					self.callback()
				end
				if h.poll_timer_failure == "start_throw_after_activation" then
					error("injected poll timer start failure after activation")
				end
				if h.poll_timer_failure == "start_false_after_activation" then
					return false
				end
			end
			return self
		end
		function handle:stop()
			self.stop_attempts = self.stop_attempts + 1
			if h.fail_once and self.stop_attempts == 1 then
				error("injected " .. kind .. " stop failure")
			end
			if kind == "poll" and h.poll_timer_stop_refuse_once
				and self.stop_attempts == 1 then return false end
			if kind == "poll" and h.poll_timer_truthy_stop_running_once
				and self.stop_attempts == 1 then return self end
			self.active = false
			return self
		end
		function handle:running() return self.active end
		h.raw_timers[#h.raw_timers + 1] = handle
		return handle
	end

	local logger = helpers.make_logger_stub()
	logger.error = function(_module, format_string, ...)
		h.logged_errors[#h.logged_errors + 1] = string.format(format_string, ...)
	end
	logger.pcall = function(module, fn, ...)
		local results = table.pack(pcall(fn, ...))
		if not results[1] then
			logger.error(module, "Exception: %s", tostring(results[2]))
		end
		return table.unpack(results, 1, results.n)
	end
	package.loaded["infra.logger"] = logger

	local timer_scheduler = {}
	local function schedule_after(delay, callback)
		local handle = {
			delay = delay,
			callback = callback,
			cancel_attempts = 0,
			cancelled = false,
			fired = false,
			committed = false,
		}
		h.scheduled_timers[#h.scheduled_timers + 1] = handle
		if h.fail_next_scheduled_commit then
			h.fail_next_scheduled_commit = false
			return handle, false
		end
		handle.committed = true
		return handle, true
	end
	function timer_scheduler.cancel(handle)
		handle.cancel_attempts = handle.cancel_attempts + 1
		if h.scheduled_cancel_refuse_once then
			h.scheduled_cancel_refuse_once = false
			return false
		end
		if h.fail_once and handle.cancel_attempts == 1 then return false end
		handle.cancelled = true
		handle.committed = false
		return true
	end
	setmetatable(timer_scheduler, {
		__index = function(_, key)
			if key ~= "after" then return nil end
			-- Production evaluates `TimerScheduler.after` before entering its local
			-- pcall. This injected property-read failure proves the recurring native
			-- callback itself has an outer file-visible exception boundary.
			if h.poll_callback_throw then error("injected poll callback failure") end
			return schedule_after
		end,
	})
	package.loaded["adapters.timer_scheduler"] = timer_scheduler

	package.loaded["adapters.shell_runner"] = {
		spawn = function(_command, _args, callback)
			local read_index = #h.reads + 1
			local handle = {
				callback = callback,
				start_attempts = 0,
				terminate_attempts = 0,
				terminated = false,
			}
			function handle.start()
				handle.start_attempts = handle.start_attempts + 1
				if h.fail_read_start then
					h.read_lifecycle[#h.read_lifecycle + 1] = "start-false-" .. tostring(read_index)
					return false
				end
				h.read_lifecycle[#h.read_lifecycle + 1] = "start-true-" .. tostring(read_index)
				return true
			end
			function handle.terminate()
				handle.terminate_attempts = handle.terminate_attempts + 1
				if (h.fail_once or h.fail_read_terminate_once)
					and handle.terminate_attempts == 1 then
					h.read_lifecycle[#h.read_lifecycle + 1] = "terminate-false-" .. tostring(read_index)
					return false
				end
				h.read_lifecycle[#h.read_lifecycle + 1] = "terminate-true-" .. tostring(read_index)
				handle.terminated = true
				return true
			end
			h.reads[#h.reads + 1] = handle
			return handle
		end,
	}

	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord, callback)
			local handle = { chord = chord, callback = callback }
			h.hotkeys[#h.hotkeys + 1] = handle
			return "hotkey-" .. tostring(#h.hotkeys)
		end,
	}
	package.loaded["adapters.key_state"] = { set_capslock = function() end }

	h.current_input_callback = nil
	h.input_source_set_attempts = 0
	h.input_source_unset_attempts = 0
	local function input_source_changed(callback)
		h.input_source_set_attempts = h.input_source_set_attempts + 1
		h.current_input_callback = callback
		if callback == nil then
			h.input_source_unset_attempts = h.input_source_unset_attempts + 1
			if (h.fail_once or h.fail_callback_unset_once)
				and h.input_source_unset_attempts == 1 then
				error("injected callback unset failure")
			end
		end
	end

	local front_app = {
		bundleID = function() return "com.example.front" end,
		name = function() return "Front" end,
	}
	local application = {
		watcher = {
			activated = 1,
			new = function(callback)
				local watcher = {
					callback = callback,
					start_attempts = 0,
					stop_attempts = 0,
					active = false,
				}
				function watcher:start()
					self.start_attempts = self.start_attempts + 1
					self.active = true
					return self
				end
				function watcher:stop()
					self.stop_attempts = self.stop_attempts + 1
					if h.fail_once and self.stop_attempts == 1 then
						error("injected app watcher stop failure")
					end
					self.active = false
					return self
				end
				h.app_watchers[#h.app_watchers + 1] = watcher
				return watcher
			end,
		},
		frontmostApplication = function() return front_app end,
		launchOrFocusByBundleID = function(bundle_id)
			h.launches[#h.launches + 1] = bundle_id
			return h.bundle_launch_result
		end,
		launchOrFocus = function(name)
			h.launches[#h.launches + 1] = name
			return h.name_launch_result
		end,
		get = function()
			return {
				activate = function()
					h.activations = h.activations + 1
					return h.activation_result
				end,
			}
		end,
	}

	h.watchers = helpers.load_with_stubs("platform.remap.watchers", {
		execute = function()
			return '({ "KeyboardLayout Name" = "' .. h.layout .. '"; })', true
		end,
		keycodes = {
			map = keycode_map,
			inputSourceChanged = input_source_changed,
			currentLayout = function() return "ABC" end,
		},
		timer = {
			secondsSinceEpoch = function() return 1000 end,
			doAfter = function(_delay, callback)
				return raw_timer("debounce", callback, true)
			end,
			doEvery = function(_delay, callback)
				h.poll_timer_create_attempts = h.poll_timer_create_attempts + 1
				if h.poll_timer_failure == "throw" then
					error("injected poll timer construction failure")
				end
				if h.poll_timer_failure == "nil" then return nil end
				local handle = raw_timer("poll", callback, true)
				if h.poll_timer_failure == "start_throw_after_activation" then
					error("injected combined poll start failure after activation")
				end
				return handle
			end,
			new = function(_delay, callback)
				h.poll_timer_create_attempts = h.poll_timer_create_attempts + 1
				if h.poll_timer_failure == "throw" then
					error("injected poll timer construction failure")
				end
				if h.poll_timer_failure == "nil" then return nil end
				return raw_timer("poll", callback, false)
			end,
		},
		application = application,
		window = {
			orderedWindows = function() return h.ordered_windows end,
			focusedWindow = function() return h.focused_window end,
		},
	})
	h.input_source_broker = require("adapters.input_source_broker")
	return h
end


-- =========================================
-- =========================================
-- ======= 2/ Input-Source Teardown ========
-- =========================================
-- =========================================

helpers.describe("watchers input-source teardown is exact and retryable", function()
	helpers.it("contains a throwing broker subscription before timer acquisition", function()
		local h = fresh_harness()
		h.input_source_broker.subscribe = function()
			error("injected broker subscription failure")
		end

		local start_ok, started = pcall(h.watchers.start_input_source_watcher,
			function() end)

		helpers.assert_eq(start_ok, true,
			"broker exceptions must not escape the watcher acquisition boundary")
		helpers.assert_eq(started, false,
			"an uncommitted broker subscription must reject watcher startup")
		helpers.assert_eq(h.poll_timer_create_attempts, 0,
			"poll construction must not run after broker acquisition fails")
		helpers.assert_nil(h.current_input_callback,
			"a rejected broker acquisition must leave no native callback")
	end)

	helpers.it("contains a throwing poll-timer acquisition and retries with one timer", function()
		local h = fresh_harness()
		h.poll_timer_failure = "throw"

		local start_ok, started = pcall(h.watchers.start_input_source_watcher,
			function() end)

		helpers.assert_eq(start_ok, true,
			"hs.timer.new exceptions must not escape the watcher boundary")
		helpers.assert_eq(started, false,
			"a missing fallback poll capability must reject watcher startup")
		helpers.assert_eq(#h.raw_timers, 0,
			"a throwing constructor did not return an exact timer to retain")
		helpers.assert_eq(h.input_source_unset_attempts, 1,
			"failed timer acquisition must release the committed broker subscription")
		helpers.assert_nil(h.current_input_callback,
			"successful rollback must leave no native input-source callback")

		h.poll_timer_failure = nil
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		helpers.assert_eq(h.poll_timer_create_attempts, 2,
			"the clean retry must make exactly one successor acquisition attempt")
		helpers.assert_eq(#h.raw_timers, 1,
			"the clean retry must own exactly one fallback poll timer")
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("retains an activated poll timer when start throws and cleanup refuses", function()
		local h = fresh_harness()
		h.poll_timer_failure = "start_throw_after_activation"
		h.poll_timer_stop_refuse_once = true

		local start_ok, started = pcall(h.watchers.start_input_source_watcher,
			function() end)

		helpers.assert_eq(start_ok, true,
			"a timer start exception must stay inside the acquisition transaction")
		helpers.assert_eq(started, false,
			"an uncommitted poll timer must reject watcher startup")
		local retained = h.raw_timers[1]
		helpers.assert_true(retained ~= nil and retained.active,
			"the fixture must model start activating the timer before throwing")
		helpers.assert_eq(retained.start_attempts, 1)
		helpers.assert_eq(retained.stop_attempts, 1,
			"rollback must immediately target the exact partially-started timer")
		helpers.assert_eq(h.input_source_unset_attempts, 1,
			"timer rollback must not skip the independent broker rollback")

		retained.callback()
		helpers.assert_eq(#h.reads, 0,
			"the retained timer must be generation-fenced while cleanup is pending")
		h.poll_timer_failure = nil
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), false,
			"retained timer debt must block a sibling acquisition")
		helpers.assert_eq(h.poll_timer_create_attempts, 1,
			"a refused retry must not construct a successor timer")

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true,
			"explicit teardown must retry the retained exact timer")
		helpers.assert_eq(retained.stop_attempts, 2)
		helpers.assert_true(not retained.active)
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		helpers.assert_eq(#h.raw_timers, 2,
			"one successor may exist only after the original timer is stopped")
	end)

	helpers.it("rejects a chainable poll start whose native state stays stopped", function()
		local h = fresh_harness()
		h.poll_timer_failure = "start_truthy_without_activation"

		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), false,
			"a chainable start result is not proof that the native timer is running")
		local rejected = h.raw_timers[1]
		helpers.assert_true(rejected ~= nil)
		helpers.assert_eq(rejected.active, false)
		helpers.assert_eq(rejected.stop_attempts, 1,
			"rejected acquisition must settle its exact candidate immediately")
		rejected.callback()
		helpers.assert_eq(#h.reads, 0,
			"the rejected timer callback must remain generation-fenced")
		helpers.assert_nil(h.current_input_callback,
			"timer rejection must independently roll back the broker subscription")

		h.poll_timer_failure = nil
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		helpers.assert_eq(#h.raw_timers, 2,
			"one successor may be acquired only after exact rollback settles")
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("keeps a synchronously delivered poll callback inert until commit", function()
		local h = fresh_harness()
		h.poll_timer_failure = "callback_before_commit"

		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local poll_timer = h.raw_timers[1]
		helpers.assert_eq(#h.reads, 0,
			"a callback delivered inside start() must not cross the commit boundary")
		poll_timer.callback()
		helpers.assert_eq(#h.reads, 1,
			"the same callback must become live after exact native commitment")
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("retains a chainably stopped layout timer until native state settles", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local retained = h.raw_timers[1]
		h.poll_timer_truthy_stop_running_once = true

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), false,
			"a truthy stop result cannot hide running native state")
		helpers.assert_true(retained.active)
		retained.callback()
		helpers.assert_eq(#h.reads, 0,
			"generation fencing must precede the ineffective native stop")
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), false,
			"retained cleanup debt must block a sibling recurring timer")
		helpers.assert_eq(h.poll_timer_create_attempts, 1)

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true,
			"the next teardown must retry the exact retained timer")
		helpers.assert_eq(retained.stop_attempts, 2)
		helpers.assert_eq(retained.active, false)
	end)

	helpers.it("logs a throwing recurring poll callback and keeps its timer manageable", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local poll_timer = h.raw_timers[1]
		h.poll_callback_throw = true

		local logged_before = #h.logged_errors
		local callback_ok, logged_after_or_err = pcall(function()
			poll_timer.callback()
			return #h.logged_errors
		end)

		helpers.assert_eq(callback_ok, true,
			"an async poll failure must be contained by a file-visible callback boundary")
		helpers.assert_true(logged_after_or_err > logged_before,
			"the callback exception must reach Logger.error")
		helpers.assert_true(poll_timer.active,
			"a contained callback failure must not lose the owned timer")
		h.poll_callback_throw = false
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
		helpers.assert_true(not poll_timer.active)
	end)

	helpers.it("retains broker cleanup debt after a nil poll timer until exact retry", function()
		local h = fresh_harness()
		h.poll_timer_failure = "nil"
		h.fail_callback_unset_once = true

		local start_ok, started = pcall(h.watchers.start_input_source_watcher,
			function() end)

		helpers.assert_eq(start_ok, true,
			"a nil hs.timer.new result must be contained")
		helpers.assert_eq(started, false,
			"a nil fallback poll timer cannot commit watcher startup")
		helpers.assert_eq(h.input_source_unset_attempts, 1,
			"rollback must attempt the exact broker release immediately")
		helpers.assert_nil(h.current_input_callback,
			"the injected partial unset removes the native dispatcher before throwing")
		h.poll_timer_failure = nil
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true,
			"restart must settle the retained broker debt before replacement acquisition")
		helpers.assert_eq(h.input_source_unset_attempts, 2,
			"cleanup retry must target the same native dispatcher obligation")
		helpers.assert_eq(#h.raw_timers, 1,
			"the post-cleanup retry must own exactly one fallback poll timer")
		helpers.assert_eq(h.poll_timer_create_attempts, 2)
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("retries a refused layout read on the next tick and fences its retained watchdog", function()
		local h = fresh_harness()
		h.fail_read_start = true
		h.fail_once = true
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local poll_timer = h.raw_timers[1]

		poll_timer.callback()
		local refused_read = h.reads[1]
		local retained_watchdog = h.scheduled_timers[1]
		helpers.assert_eq(refused_read.start_attempts, 1)
		helpers.assert_eq(retained_watchdog.cancel_attempts, 1,
			"a refused read must cancel its exact watchdog immediately")
		helpers.assert_true(not retained_watchdog.cancelled,
			"a refused cancellation must retain the still-live exact watchdog")

		h.fail_read_start = false
		h.fail_once = false
		poll_timer.callback()
		helpers.assert_eq(#h.reads, 2,
			"the next poll tick must retry without waiting for the five-second watchdog")
		local live_read = h.reads[2]

		retained_watchdog.callback()
		helpers.assert_eq(live_read.terminate_attempts, 0,
			"the retained watchdog from the refused read must not terminate its successor")
		poll_timer.callback()
		helpers.assert_eq(#h.reads, 2,
			"the stale watchdog must not release the successor read's pending guard")

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
		helpers.assert_eq(retained_watchdog.cancel_attempts, 2,
			"teardown must retry the exact watchdog whose first cancellation failed")
		helpers.assert_true(retained_watchdog.cancelled)
	end)

	helpers.it("rejects an uncommitted watchdog and settles it before one successor", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local poll_timer = h.raw_timers[1]
		h.fail_next_scheduled_commit = true
		h.scheduled_cancel_refuse_once = true

		poll_timer.callback()
		local retained = h.scheduled_timers[1]
		helpers.assert_eq(#h.reads, 0,
			"an adapter handle is not an armed watchdog without exact committed=true")
		helpers.assert_eq(retained.cancel_attempts, 1)
		retained.callback()
		helpers.assert_eq(#h.reads, 0,
			"the rejected candidate callback must remain outside live poll state")

		poll_timer.callback()
		helpers.assert_eq(retained.cancel_attempts, 2,
			"the next tick must settle the exact retained capability first")
		helpers.assert_true(retained.cancelled)
		helpers.assert_eq(#h.scheduled_timers, 2)
		helpers.assert_eq(#h.reads, 1,
			"one successor read may start only after watchdog cleanup settles")
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("retries a refused timeout termination before starting one successor", function()
		local h = fresh_harness()
		h.fail_read_terminate_once = true
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local poll_timer = h.raw_timers[1]

		poll_timer.callback()
		local abandoned_read = h.reads[1]
		local timeout_watchdog = h.scheduled_timers[1]
		timeout_watchdog.callback()
		helpers.assert_eq(abandoned_read.terminate_attempts, 1)
		helpers.assert_true(not abandoned_read.terminated,
			"a refused terminate must retain the exact still-live read")

		poll_timer.callback()
		helpers.assert_eq(abandoned_read.terminate_attempts, 2,
			"the next tick must retry the exact abandoned read")
		helpers.assert_true(abandoned_read.terminated)
		helpers.assert_eq(#h.reads, 2,
			"one successor may start only after the exact termination settles")
		helpers.assert_eq(h.read_lifecycle[1], "start-true-1")
		helpers.assert_eq(h.read_lifecycle[2], "terminate-false-1")
		helpers.assert_eq(h.read_lifecycle[3], "terminate-true-1")
		helpers.assert_eq(h.read_lifecycle[4], "start-true-2",
			"the successor start must occur after successful exact termination")

		poll_timer.callback()
		helpers.assert_eq(#h.reads, 2,
			"a live successor still owns the one in-flight slot")
		h.fail_read_terminate_once = false
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("settles a once-refused in-flight read before restarting the watcher", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local first_poll_timer = h.raw_timers[1]
		first_poll_timer.callback()
		local retained_read = h.reads[1]
		h.fail_read_terminate_once = true

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), false,
			"the first refused termination must retain cleanup ownership")
		helpers.assert_eq(retained_read.terminate_attempts, 1)
		helpers.assert_true(not retained_read.terminated)

		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true,
			"restart must retry the exact retained read instead of deadlocking the watcher")
		helpers.assert_eq(retained_read.terminate_attempts, 2)
		helpers.assert_true(retained_read.terminated)
		helpers.assert_eq(h.poll_timer_create_attempts, 2,
			"one successor timer may be acquired only after cleanup succeeds")
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("ignores a superseded debounce whose native stop failed", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function(layout)
			h.layout_changes[#h.layout_changes + 1] = layout
		end), true)
		local installed_callback = h.current_input_callback

		h.layout = "French"
		installed_callback()
		local stale_debounce = h.raw_timers[2]
		h.layout = "German"
		h.fail_once = true
		installed_callback()
		local current_debounce = h.raw_timers[3]
		helpers.assert_eq(stale_debounce.stop_attempts, 1,
			"the superseded exact timer must be stopped before replacement")

		h.fail_once = false
		stale_debounce.callback()
		helpers.assert_eq(#h.layout_changes, 0,
			"a retained stale debounce must not rebuild the superseded layout")
		current_debounce.callback()
		helpers.assert_eq(#h.layout_changes, 1)
		helpers.assert_eq(h.layout_changes[1], "German")
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
		helpers.assert_eq(stale_debounce.stop_attempts, 2,
			"teardown must retry the exact stale timer retained after stop failure")
	end)

	helpers.it("retains every failed handle, fences callbacks, then settles the retry", function()
		local h = fresh_harness()
		h.watchers.start_input_source_watcher(function(layout)
			h.layout_changes[#h.layout_changes + 1] = layout
		end)
		local installed_callback = h.current_input_callback
		local poll_timer = h.raw_timers[1]
		installed_callback()
		local debounce_timer = h.raw_timers[2]
		poll_timer.callback()
		local watchdog = h.scheduled_timers[1]
		local read = h.reads[1]
		helpers.assert_true(debounce_timer and watchdog and read,
			"setup must own every teardown resource")

		h.fail_once = true
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), false)
		helpers.assert_eq(h.input_source_unset_attempts, 1)
		helpers.assert_eq(debounce_timer.stop_attempts, 1)
		helpers.assert_eq(poll_timer.stop_attempts, 1)
		helpers.assert_eq(watchdog.cancel_attempts, 1)
		helpers.assert_eq(read.terminate_attempts, 1)

		installed_callback()
		poll_timer.callback()
		helpers.assert_eq(#h.raw_timers, 2,
			"the stale notification callback must not schedule another debounce")
		helpers.assert_eq(#h.reads, 1,
			"the stale poll timer must not start another subprocess")
		helpers.assert_eq(#h.layout_changes, 0)

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
		helpers.assert_eq(h.input_source_unset_attempts, 2)
		helpers.assert_nil(h.current_input_callback)
		helpers.assert_eq(debounce_timer.stop_attempts, 2)
		helpers.assert_eq(poll_timer.stop_attempts, 2)
		helpers.assert_eq(watchdog.cancel_attempts, 2)
		helpers.assert_eq(read.terminate_attempts, 2)
		helpers.assert_true(read.terminated)
	end)

	helpers.it("removes only its named broker subscriber and preserves a sibling", function()
		local h = fresh_harness()
		local sibling_calls = 0
		helpers.assert_eq(h.input_source_broker.subscribe("test.sibling", function()
			sibling_calls = sibling_calls + 1
		end), true)
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local dispatcher = h.current_input_callback

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
		helpers.assert_eq(h.current_input_callback, dispatcher,
			"teardown must leave the process-wide dispatcher for a live sibling")
		dispatcher()
		helpers.assert_eq(sibling_calls, 1,
			"removing the watcher subscriber must not remove its broker sibling")
		helpers.assert_eq(h.input_source_unset_attempts, 0,
			"the native slot stays owned until the last named subscriber leaves")
		helpers.assert_eq(h.input_source_broker.unsubscribe("test.sibling"), true)
		helpers.assert_nil(h.current_input_callback)
	end)

	helpers.it("retries an orphaned callback capability before restart", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local installed_callback = h.current_input_callback
		local first_poll_timer = h.raw_timers[1]

		h.fail_callback_unset_once = true
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), false)
		helpers.assert_true(not first_poll_timer.active,
			"the poll timer must be allowed to settle independently")
		helpers.assert_nil(h.current_input_callback,
			"the partial native unset removed the dispatcher before throwing")
		installed_callback()

		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true,
			"restart must retry the exact orphaned broker capability")
		helpers.assert_eq(h.input_source_unset_attempts, 2)
		helpers.assert_eq(#h.raw_timers, 2,
			"restart is allowed only after the exact retained capability settles")
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)

	helpers.it("never mistakes a live watcher subscription for orphaned cleanup", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local live_callback = h.current_input_callback

		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), false,
			"a duplicate start must not replace a committed watcher")
		helpers.assert_eq(h.input_source_unset_attempts, 0)
		helpers.assert_eq(h.current_input_callback, live_callback)
		helpers.assert_eq(h.poll_timer_create_attempts, 1)
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
	end)
end)


-- =========================================
-- =========================================
-- ======= 3/ App-Watcher Teardown =========
-- =========================================
-- =========================================

helpers.describe("watchers app-switch teardown is exact and retryable", function()
	helpers.it("falls through false launch results to the application object", function()
		local h = fresh_harness()
		h.bundle_launch_result = false
		h.name_launch_result = false
		h.activation_result = true
		helpers.assert_true(h.watchers.start_alt_tab_apps_hotkey() ~= nil)
		local watcher = h.app_watchers[1]
		watcher.callback("Other", 1, {
			bundleID = function() return "com.example.other" end,
			name = function() return "Other" end,
		})

		local switched = h.hotkeys[1].callback()

		helpers.assert_eq(true, switched)
		helpers.assert_eq(2, #h.launches,
			"both false launch APIs must fall through instead of masquerading as success")
		helpers.assert_eq(1, h.activations,
			"the final application-object fallback must remain reachable")
	end)

	helpers.it("keeps a failed watcher inert and refuses a duplicate until retry", function()
		local h = fresh_harness()
		helpers.assert_true(h.watchers.start_alt_tab_apps_hotkey() ~= nil)
		local first_watcher = h.app_watchers[1]
		local first_hotkey = h.hotkeys[1]

		h.fail_once = true
		helpers.assert_eq(h.watchers.stop_alt_tab_apps_tracker(), false)
		first_watcher.callback("Other", 1, {
			bundleID = function() return "com.example.other" end,
			name = function() return "Other" end,
		})
		first_hotkey.callback()
		helpers.assert_eq(#h.launches, 0,
			"a retained watcher and hotkey must be logically inert after stop intent")
		helpers.assert_nil(h.watchers.start_alt_tab_apps_hotkey(),
			"an unsettled native watcher must block duplicate construction")
		helpers.assert_eq(#h.app_watchers, 1)

		helpers.assert_eq(h.watchers.stop_alt_tab_apps_tracker(), true)
		helpers.assert_eq(first_watcher.stop_attempts, 2)
		helpers.assert_true(h.watchers.start_alt_tab_apps_hotkey() ~= nil)
		helpers.assert_eq(#h.app_watchers, 2,
			"restart is allowed only after the exact prior watcher settled")
		local second_watcher = h.app_watchers[2]
		second_watcher.callback("Other", 1, {
			bundleID = function() return "com.example.other" end,
			name = function() return "Other" end,
		})
		h.hotkeys[2].callback()
		helpers.assert_eq(h.launches[1], "com.example.front",
			"the replacement watcher remains functional after successful cleanup")
	end)
end)





-- =========================================
-- =========================================
-- ======= 4/ Window Focus Results =========
-- =========================================
-- =========================================

helpers.describe("watchers window switching honours native focus results", function()
	helpers.it("contains an exception raised by an F17 action", function()
		local h = fresh_harness()
		local focused = {
			id = function() return 1 end,
			isStandard = function() return true end,
			isMinimized = function() return false end,
		}
		local throwing = {
			id = function() return 2 end,
			isStandard = function() return true end,
			isMinimized = function() return false end,
			focus = function() error("injected focus failure") end,
		}
		h.focused_window = focused
		h.ordered_windows = { focused, throwing }
		helpers.assert_true(h.watchers.start_alt_tab_windows_hotkey() ~= nil)

		local callback_ok, callback_result = pcall(h.hotkeys[1].callback)

		helpers.assert_eq(true, callback_ok,
			"an F17 action exception must not escape into the Hammerspoon Console")
		helpers.assert_eq(false, callback_result,
			"a contained F17 action exception must fail the user action closed")
	end)

	helpers.it("continues after one candidate refuses focus", function()
		local h = fresh_harness()
		local attempts = {}
		local focused = {
			id = function() return 1 end,
			isStandard = function() return true end,
			isMinimized = function() return false end,
		}
		local refused = {
			id = function() return 2 end,
			isStandard = function() return true end,
			isMinimized = function() return false end,
			focus = function() attempts[#attempts + 1] = 2; return false end,
		}
		local accepted = {
			id = function() return 3 end,
			isStandard = function() return true end,
			isMinimized = function() return false end,
			focus = function() attempts[#attempts + 1] = 3; return true end,
		}
		h.focused_window = focused
		h.ordered_windows = { focused, refused, accepted }
		helpers.assert_true(h.watchers.start_alt_tab_windows_hotkey() ~= nil)

		local switched = h.hotkeys[1].callback()

		helpers.assert_eq(true, switched)
		helpers.assert_eq(2, #attempts,
			"a false focus result must not suppress a later eligible window")
		helpers.assert_eq(2, attempts[1])
		helpers.assert_eq(3, attempts[2])
	end)
end)

-- This file installs a module-level test double. Restore the loader slot so a
-- later test file cannot capture it order-dependently at require time.
package.loaded["adapters.shell_runner"] = nil
