--- tests/unit/modules/keymap/test_ignored_window_cache_lifecycle.lua

--- ==============================================================================
--- MODULE: Ignored-window cache lifecycle regression tests
--- DESCRIPTION:
--- Exercises the cache as a state machine through its TimerScheduler port. The
--- eventtap may only read a cached answer and arm work; AX/window-filter setup,
--- TTL reclassification, and teardown all have to settle outside that callback.
--- ==============================================================================

local helpers = require("tests.helpers")


local function make_scheduler()
	local scheduler = {
		timers = {},
		cancel_results = {},
	}

	function scheduler.after(delay, fn)
		local handle = {
			delay = delay,
			fn = fn,
			running = true,
			fired = false,
			cancel_calls = 0,
		}
		function handle:fire()
			if not self.running then return end
			self.running = false
			self.fired = true
			self.fn()
		end
		scheduler.timers[#scheduler.timers + 1] = handle
		return handle, true
	end

	function scheduler.cancel(handle)
		if not handle or handle.fired or not handle.running then return true end
		handle.cancel_calls = handle.cancel_calls + 1
		local result = table.remove(scheduler.cancel_results, 1)
		if result == nil then result = true end
		if result == true then handle.running = false end
		return result
	end

	function scheduler.running_count(delay)
		local count = 0
		for _, handle in ipairs(scheduler.timers) do
			if handle.running and (delay == nil or handle.delay == delay) then
				count = count + 1
			end
		end
		return count
	end

	function scheduler.fire_all(delay)
		-- Snapshot the current tail: a callback that arms follow-up work must not
		-- have that new work executed recursively by the same test helper call.
		local last = #scheduler.timers
		for index = 1, last do
			local handle = scheduler.timers[index]
			if handle.running and (delay == nil or handle.delay == delay) then
				handle:fire()
			end
		end
	end

	return scheduler
end


local function new_fixture()
	package.loaded["modules.keymap.utils"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local scheduler = make_scheduler()
	package.loaded["adapters.timer_scheduler"] = scheduler
	local state = {
		now = 100,
		window_id = 42,
		app_name = "Test Editor",
		title = "Normal Editor",
		secure = false,
		ax_reads = 0,
		secure_reads = 0,
		filter_default_reads = 0,
		app_watcher_starts = 0,
		focus_watcher_starts = 0,
		title_watcher_starts = 0,
		secure_watcher_starts = 0,
		app_watcher_stops = 0,
		focus_watcher_stops = 0,
		title_watcher_stops = 0,
		secure_watcher_stops = 0,
		app_watcher_active = false,
		focus_watcher_active = false,
		title_watcher_active = false,
		secure_watcher_active = false,
	}
	package.loaded["adapters.secure_field_detector"] = {
		isSecureApp = function() return state.secure_app == true end,
		inspectFocusedElement = function()
			state.secure_reads = state.secure_reads + 1
			if state.secure_read_fail then return nil, "secure read refused" end
			return state.secure
		end,
		watchFocusedElementChanges = function(_app, callback)
			if state.secure_watcher_fail then return nil, "secure watcher refused" end
			state.secure_watcher_starts = state.secure_watcher_starts + 1
			state.secure_callback = callback
			state.secure_watcher_active = true
			local observer = {
				stop = function(self)
					if state.secure_watcher_stop_fail then error("secure watcher stop failed") end
					state.secure_watcher_stops = state.secure_watcher_stops + 1
					state.secure_watcher_active = false
					return self
				end,
			}
			if state.secure_watcher_cleanup_debt then
				state.secure_watcher_stops = 1
				return observer, "synthetic observer cleanup debt", false
			end
			return observer, nil, true
		end,
	}
	local Utils = helpers.load_with_stubs("modules.keymap.utils")
	local hs_stub = _G.hs
	local function make_ui_watcher(kind, callback)
		return {
			start = function(self)
				state[kind .. "_watcher_starts"] = state[kind .. "_watcher_starts"] + 1
				state[kind .. "_callback"] = callback
				state[kind .. "_watcher_active"] = true
				if state[kind .. "_watcher_start_raises_after_activation"] then
					error(kind .. " watcher start failed after activation")
				end
				return self
			end,
			stop = function(self)
				state[kind .. "_watcher_stops"] = state[kind .. "_watcher_stops"] + 1
				if state[kind .. "_watcher_stops"]
					<= (state[kind .. "_watcher_stop_refusals"] or 0) then
					error(kind .. " watcher stop failed")
				end
				state[kind .. "_watcher_active"] = false
				return self
			end,
		}
	end
	hs_stub.application.watcher.new = function(callback)
		return make_ui_watcher("app", callback)
	end

	hs_stub.timer.secondsSinceEpoch = function() return state.now end
	hs_stub.window.focusedWindow = function()
		state.ax_reads = state.ax_reads + 1
		return {
			id = function() return state.window_id end,
			newWatcher = function(_self, callback)
				if state.title_watcher_fail then error("title watcher unavailable") end
				return make_ui_watcher("title", callback)
			end,
			application = function()
				return {
					pid = function() return 9001 end,
					name = function() return state.app_name end,
					newWatcher = function(_self, callback)
						if state.focus_watcher_fail then error("focus watcher unavailable") end
						return make_ui_watcher("focus", callback)
					end,
				}
			end,
			title = function() return state.title end,
		}
	end

	hs_stub.window.filter = setmetatable({
		windowFocused = "windowFocused",
		windowTitleChanged = "windowTitleChanged",
	}, {
		__index = function(_self, key)
			if key == "default" then
				state.filter_default_reads = state.filter_default_reads + 1
				error("global window enumeration is forbidden")
			end
			return nil
		end,
	})

	return {
		Utils = Utils,
		hs = hs_stub,
		scheduler = scheduler,
		state = state,
		titles = { ["Sensitive Entry"] = true },
		patterns = {},
	}
end





-- ====================================================
-- ====================================================
-- ======= 1/ Eventtap-safe cache transitions =========
-- ====================================================
-- ====================================================

helpers.describe("ignored-window cache lifecycle: eventtap-safe transitions", function()
	helpers.it("cache lifecycle: cold lookup never reads AX or hs.window.filter.default", function()
		local f = new_fixture()
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)

		local ignored = f.Utils.is_ignored_window(f.titles, f.patterns, f.state.now)

		helpers.assert_nil(ignored,
			"a cold eventtap lookup must return unknown until its deferred probe settles")
		helpers.assert_eq(f.state.ax_reads, 0,
			"the cold lookup must not query the focused AX window")
		helpers.assert_eq(f.state.filter_default_reads, 0,
			"reading hs.window.filter.default can enumerate windows and must stay off the eventtap")
		helpers.assert_eq(f.scheduler.running_count(0), 1,
			"the cold lookup must arm exactly one zero-delay refresh")

		helpers.assert_true(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns))
		helpers.assert_eq(f.state.filter_default_reads, 0,
			"preparation must never enumerate every application's windows")
		helpers.assert_eq(f.state.focus_watcher_starts, 1,
			"preparation must watch focus changes only in the current app")
		helpers.assert_eq(f.state.title_watcher_starts, 1,
			"preparation must watch title changes only on the current window")
		helpers.assert_eq(f.state.secure_watcher_starts, 1,
			"preparation must watch focused-element changes only in the current app")
		helpers.assert_eq(f.state.ax_reads, 1,
			"the prewarm must populate the classification cache with one AX probe")
		helpers.assert_eq(f.state.secure_reads, 1,
			"the prewarm must classify the focused field exactly once")
	end)

	helpers.it("cache lifecycle: an expired TTL returns nil before its off-tap refresh", function()
		local f = new_fixture()
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns)
		local normal, initial_generation = f.Utils.is_ignored_window(
			f.titles, f.patterns, f.state.now)
		helpers.assert_eq(normal, false, "the prewarm must establish a known-normal cache")

		f.state.title = "Sensitive Entry"
		f.state.now = f.state.now + 5
		local ax_before = f.state.ax_reads
		local zero_before = f.scheduler.running_count(0)
		local expired, dirty_generation = f.Utils.is_ignored_window(
			f.titles, f.patterns, f.state.now)

		helpers.assert_nil(expired,
			"an expired safety TTL must fail closed, never return the previous window's false")
		helpers.assert_eq(f.state.ax_reads, ax_before,
			"TTL expiry must not perform its AX reclassification in the caller")
		helpers.assert_eq(f.scheduler.running_count(0), zero_before + 1,
			"TTL expiry must arm one off-eventtap refresh")
		helpers.assert_true(dirty_generation > initial_generation,
			"TTL expiry must sever the typing context before passing the physical key through")

		f.scheduler.fire_all(0)
		local ignored = f.Utils.is_ignored_window(f.titles, f.patterns, f.state.now)
		helpers.assert_eq(ignored, true,
			"the deferred refresh must publish the new ignored-window classification")
		helpers.assert_eq(f.state.ax_reads, ax_before + 1,
			"the deferred refresh must execute exactly one AX probe")
	end)

	helpers.it("cache lifecycle: a title change bumps identity even when window id is unchanged", function()
		local f = new_fixture()
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns)
		local normal, initial_generation = f.Utils.is_ignored_window(
			f.titles, f.patterns, f.state.now)
		helpers.assert_eq(normal, false, "the first title must classify as normal")

		f.state.title = "Sensitive Entry"
		f.state.now = f.state.now + 0.1
		f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns)
		local ignored, changed_generation = f.Utils.is_ignored_window(
			f.titles, f.patterns, f.state.now)

		helpers.assert_eq(ignored, true,
			"a second off-tap probe must reclassify the changed title")
		helpers.assert_true(changed_generation > initial_generation,
			"title participates in context identity; a stable AX window id is not enough")
	end)

	helpers.it("cache lifecycle: missing title-watcher coverage never publishes a clean cache", function()
		local f = new_fixture()
		f.state.title_watcher_fail = true
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)

		helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), false,
			"prewarm must report that same-window title changes cannot be observed")
		local ax_before = f.state.ax_reads
		f.state.title = "Sensitive Entry"
		f.state.now = f.state.now + 1
		local ignored = f.Utils.is_ignored_window(f.titles, f.patterns, f.state.now)

		helpers.assert_nil(ignored,
			"without title-change coverage, the previous normal answer is unsafe before TTL")
		helpers.assert_eq(f.state.ax_reads, ax_before,
			"the physical-key lookup must remain AX-free while degraded tracking retries off-tap")
	end)

	helpers.it("cache lifecycle: focused-element changes fail closed until off-tap refresh", function()
		local f = new_fixture()
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), true)
		local secure, initial_generation = f.Utils.is_secure_field(f.state.now)
		helpers.assert_eq(secure, false, "the plain focused field must be known-normal")

		f.state.secure = true
		local reads_before = f.state.secure_reads
		f.state.secure_callback()
		local dirty, dirty_generation = f.Utils.is_secure_field(f.state.now)

		helpers.assert_nil(dirty,
			"the eventtap-facing read must not reuse a verdict after focus changes")
		helpers.assert_true(dirty_generation > initial_generation,
			"a focused-element transition must sever the text-context generation")
		helpers.assert_eq(f.state.secure_reads, reads_before,
			"the cached predicate must never perform Accessibility work in its caller")
		helpers.assert_eq(f.scheduler.running_count(0), 1,
			"the observer must arm exactly one off-eventtap classification refresh")

		f.scheduler.fire_all(0)
		local refreshed = f.Utils.is_secure_field(f.state.now)
		helpers.assert_eq(refreshed, true,
			"the deferred refresh must publish the new secure-field verdict")
		helpers.assert_eq(f.state.secure_reads, reads_before + 1,
			"the deferred callback must perform one focused-element classification")
	end)

	helpers.it("cache lifecycle: missing secure-field watcher coverage remains unknown", function()
		local f = new_fixture()
		f.state.secure_watcher_fail = true
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)

		helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), false,
			"prewarm must reject a field classification it cannot keep current")
		helpers.assert_nil(f.Utils.is_secure_field(f.state.now),
			"a missing focused-element observer must never publish normal")
	end)

	helpers.it("cache lifecycle: a known secure app bypasses focused-element authorization", function()
		local f = new_fixture()
		f.state.secure_app = true
		f.state.secure_read_fail = true
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)

		helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), true)
		helpers.assert_eq(f.Utils.is_secure_field(f.state.now), true,
			"a security-sensitive app must remain a total pass-through surface")
		helpers.assert_eq(f.state.secure_reads, 0,
			"a known secure app must not depend on a readable focused element")
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 2/ Start/stop ownership ==================
-- ==================================================
-- ==================================================

helpers.describe("ignored-window cache lifecycle: start/stop ownership", function()
	helpers.it("cache lifecycle: a failed timer cancellation remains retryable", function()
		local f = new_fixture()
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		f.Utils.is_ignored_window(f.titles, f.patterns, f.state.now)
		local handle = f.scheduler.timers[1]
		helpers.assert_not_nil(handle, "the dirty cache must own one refresh handle")
		f.scheduler.cancel_results = { false, true }

		helpers.assert_eq(f.Utils.stop(), false,
			"stop must report an unsettled refresh whose cancellation failed")
		helpers.assert_eq(handle.cancel_calls, 1,
			"the first stop must attempt cancellation once")
		helpers.assert_true(handle.running,
			"a failed cancellation must retain the live handle for a later retry")

		helpers.assert_eq(f.Utils.stop(), true,
			"a second stop must retry and settle the retained refresh")
		helpers.assert_eq(handle.cancel_calls, 2,
			"the retained handle must be offered to TimerScheduler.cancel again")
		helpers.assert_eq(handle.running, false,
			"the successful retry must leave no live native timer")
	end)

	helpers.it("cache lifecycle: duplicate start preserves a known cache and generation", function()
		local f = new_fixture()
		local started_generation = f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns)
		local normal, known_generation = f.Utils.is_ignored_window(
			f.titles, f.patterns, f.state.now)
		helpers.assert_eq(normal, false, "prewarm must make the normal cache usable")
		helpers.assert_eq(known_generation, started_generation,
			"the first identity observation must not invent a transition")
		local ax_before = f.state.ax_reads
		local timers_before = #f.scheduler.timers

		local duplicate_generation = f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		local after_duplicate, observed_generation = f.Utils.is_ignored_window(
			f.titles, f.patterns, f.state.now)

		helpers.assert_eq(duplicate_generation, known_generation,
			"an already-started tracker must treat start() as idempotent")
		helpers.assert_eq(observed_generation, known_generation,
			"duplicate start must not publish a synthetic focus transition")
		helpers.assert_eq(after_duplicate, false,
			"duplicate start must preserve the known classification for the next key")
		helpers.assert_eq(f.state.ax_reads, ax_before,
			"duplicate start must not force an unnecessary AX reprobe")
		helpers.assert_eq(#f.scheduler.timers, timers_before,
			"duplicate start must not create a cold interval or refresh timer")

		helpers.assert_eq(f.Utils.stop(), true, "the settled tracker must stop cleanly")
		local restart_generation = f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		local after_restart = f.Utils.is_ignored_window(f.titles, f.patterns, f.state.now)
		helpers.assert_true(restart_generation > known_generation,
			"a real stopped-to-started transition must still advance the generation")
		helpers.assert_nil(after_restart,
			"a real restart must not reuse the previous session's cache")
	end)

	helpers.it("cache lifecycle: failed watcher teardown prevents a false-success restart", function()
		local f = new_fixture()
		f.hs.application.watcher.new = function(_callback)
			return {
				start = function(self) return self end,
				stop = function() error("application watcher stop failed") end,
			}
		end
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), true,
			"the fixture must establish both watcher capabilities before teardown")
		helpers.assert_eq(f.Utils.stop(), false,
			"the failed watcher stop must leave teardown explicitly unsettled")

		local restarted = f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		local ignored = f.Utils.is_ignored_window(f.titles, f.patterns, f.state.now)
		helpers.assert_nil(restarted,
			"start must not reuse a watcher whose native stop state is unknown")
		helpers.assert_nil(ignored,
			"an unsettled tracker must remain stopped and fail closed")
	end)

	helpers.it("cache lifecycle: retains native watchers activated before start raises", function()
		for _, kind in ipairs({ "app", "focus", "title" }) do
			local f = new_fixture()
			f.state[kind .. "_watcher_start_raises_after_activation"] = true
			f.state[kind .. "_watcher_stop_refusals"] = 1
			f.Utils.start_ignored_win_tracking(f.titles, f.patterns)

			helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), false)
			helpers.assert_true(f.state[kind .. "_watcher_active"],
				kind .. " fixture must retain an active watcher after exact rollback refuses")
			helpers.assert_eq(f.state[kind .. "_watcher_stops"], 1,
				kind .. " failed acquisition must immediately attempt exact-candidate rollback")
			local _, generation_before = f.Utils.is_ignored_window(
				f.titles, f.patterns, f.state.now)

			if kind == "app" then
				f.state.app_callback(nil, f.hs.application.watcher.activated, nil)
			else
				f.state[kind .. "_callback"]()
			end
			local _, generation_after = f.Utils.is_ignored_window(
				f.titles, f.patterns, f.state.now)
			helpers.assert_eq(generation_after, generation_before,
				kind .. " activated but uncommitted watcher callback must remain inert")

			helpers.assert_eq(f.Utils.stop(), true,
				kind .. " stop must retry and settle the exact retained watcher")
			helpers.assert_eq(f.state[kind .. "_watcher_stops"], 2)
			helpers.assert_true(f.state[kind .. "_watcher_active"] == false)
		end
	end)

	helpers.it("cache lifecycle: secure watcher teardown debt prevents restart", function()
		local f = new_fixture()
		f.state.secure_watcher_stop_fail = true
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)
		helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), true)
		helpers.assert_eq(f.Utils.stop(), false,
			"a refused secure watcher stop must remain explicit cleanup debt")
		helpers.assert_nil(f.Utils.start_ignored_win_tracking(f.titles, f.patterns),
			"restart must not overlap the unsettled focused-element observer")
	end)

	helpers.it("cache lifecycle: owns uncommitted secure observer cleanup debt", function()
		local f = new_fixture()
		f.state.secure_watcher_cleanup_debt = true
		f.Utils.start_ignored_win_tracking(f.titles, f.patterns)

		helpers.assert_eq(f.Utils.prewarm_ignored_win_watchers(f.titles, f.patterns), false)
		helpers.assert_true(f.state.secure_watcher_active)
		helpers.assert_eq(f.state.secure_watcher_stops, 1,
			"the adapter fixture must model its refused acquisition rollback")
		helpers.assert_eq(f.Utils.stop(), true,
			"keymap teardown must retry the exact observer debt returned by the adapter")
		helpers.assert_eq(f.state.secure_watcher_stops, 2)
		helpers.assert_true(f.state.secure_watcher_active == false)
	end)
end)
