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
	local keycode_map = hs.keycodes.map
	package.loaded["platform.remap.watchers"] = nil
	package.loaded["adapters.event_tap_guard"] = {
		handle_disabled = function() return false end,
	}

	local h = {
		fail_once = false,
		fail_read_start = false,
		fail_read_terminate_once = false,
		fail_callback_restore_once = false,
		layout = "ABC",
		raw_timers = {},
		scheduled_timers = {},
		reads = {},
		app_watchers = {},
		hotkeys = {},
		layout_changes = {},
		read_lifecycle = {},
		launches = {},
	}

	local function raw_timer(kind, callback)
		local handle = {
			kind = kind,
			callback = callback,
			stop_attempts = 0,
			active = true,
		}
		function handle:stop()
			self.stop_attempts = self.stop_attempts + 1
			if h.fail_once and self.stop_attempts == 1 then
				error("injected " .. kind .. " stop failure")
			end
			self.active = false
			return self
		end
		h.raw_timers[#h.raw_timers + 1] = handle
		return handle
	end

	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			local handle = {
				delay = delay,
				callback = callback,
				cancel_attempts = 0,
				cancelled = false,
				fired = false,
			}
			h.scheduled_timers[#h.scheduled_timers + 1] = handle
			return handle
		end,
		cancel = function(handle)
			handle.cancel_attempts = handle.cancel_attempts + 1
			if h.fail_once and handle.cancel_attempts == 1 then return false end
			handle.cancelled = true
			return true
		end,
	}

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

	local previous_callback = function() end
	h.previous_input_callback = previous_callback
	h.current_input_callback = previous_callback
	h.restore_attempts = 0
	local function input_source_changed(...)
		if select("#", ...) == 0 then return h.current_input_callback end
		local callback = ...
		if callback == previous_callback then
			h.restore_attempts = h.restore_attempts + 1
			if (h.fail_once or h.fail_callback_restore_once) and h.restore_attempts == 1 then
				error("injected callback restore failure")
			end
		end
		h.current_input_callback = callback
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
			return true
		end,
		launchOrFocus = function(name)
			h.launches[#h.launches + 1] = name
			return true
		end,
		get = function() return nil end,
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
			doAfter = function(_delay, callback) return raw_timer("debounce", callback) end,
			doEvery = function(_delay, callback) return raw_timer("poll", callback) end,
		},
		application = application,
	})
	return h
end


-- =========================================
-- =========================================
-- ======= 2/ Input-Source Teardown ========
-- =========================================
-- =========================================

helpers.describe("watchers input-source teardown is exact and retryable", function()
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
		helpers.assert_eq(h.restore_attempts, 1)
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
		helpers.assert_eq(h.restore_attempts, 2)
		helpers.assert_eq(h.current_input_callback, h.previous_input_callback)
		helpers.assert_eq(debounce_timer.stop_attempts, 2)
		helpers.assert_eq(poll_timer.stop_attempts, 2)
		helpers.assert_eq(watchdog.cancel_attempts, 2)
		helpers.assert_eq(read.terminate_attempts, 2)
		helpers.assert_true(read.terminated)
	end)

	helpers.it("does not overwrite a third-party callback installed after ours", function()
		local h = fresh_harness()
		h.watchers.start_input_source_watcher(function() end)
		local third_party = function() end
		h.current_input_callback = third_party

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
		helpers.assert_eq(h.current_input_callback, third_party,
			"teardown owns only its exact installed callback slot")
		helpers.assert_eq(h.restore_attempts, 0,
			"a newer callback must not be replaced with our predecessor")
	end)

	helpers.it("refuses restart while only the callback capability remains unsettled", function()
		local h = fresh_harness()
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		local installed_callback = h.current_input_callback
		local first_poll_timer = h.raw_timers[1]

		h.fail_callback_restore_once = true
		helpers.assert_eq(h.watchers.stop_input_source_watcher(), false)
		helpers.assert_true(not first_poll_timer.active,
			"the poll timer must be allowed to settle independently")
		helpers.assert_eq(h.current_input_callback, installed_callback,
			"the failed exact callback restore must remain owned for retry")

		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), false)
		helpers.assert_eq(#h.raw_timers, 1,
			"cleanup debt must block construction of a replacement poll timer")
		helpers.assert_eq(h.current_input_callback, installed_callback,
			"cleanup debt must not overwrite the retained callback capability")

		helpers.assert_eq(h.watchers.stop_input_source_watcher(), true)
		helpers.assert_eq(h.current_input_callback, h.previous_input_callback)
		helpers.assert_eq(h.watchers.start_input_source_watcher(function() end), true)
		helpers.assert_eq(#h.raw_timers, 2,
			"restart is allowed only after the exact retained capability settles")
	end)
end)


-- =========================================
-- =========================================
-- ======= 3/ App-Watcher Teardown =========
-- =========================================
-- =========================================

helpers.describe("watchers app-switch teardown is exact and retryable", function()
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

-- This file installs a module-level test double. Restore the loader slot so a
-- later test file cannot capture it order-dependently at require time.
package.loaded["adapters.shell_runner"] = nil
