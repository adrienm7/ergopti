--- tests/unit/platform/remap/test_watchers_capsword.lua

--- ==============================================================================
--- MODULE: karabiner.watchers CapsWord Guard Regression (F-HIGH-7)
--- DESCRIPTION:
--- Guards the fix for F-HIGH-7: M.start_gesture_watcher's eventtap callback
--- (mouseMoved, scrollWheel, gesture, all three mouse-button events — the
--- hottest possible eventtap) called deactivate_capsword() with NO
--- pcall/Logger.pcall, even though that function contains an unguarded
--- hs.task.new(...) call. Every sibling eventtap added in the same refactor
--- window wraps its callback body in Logger.pcall; this one instance was
--- missed, so an exception thrown mid-callback (e.g. hs.task.new erroring)
--- would propagate out of the eventtap callback uncaught.
---
--- Two layers of coverage:
---   1. Source-position check: the eventtap callback body must call
---      deactivate_capsword() only via Logger.pcall, never bare.
---   2. Behavioral: drive the captured callback with hs.task.new stubbed to
---      throw, and assert the callback itself never raises.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================================
-- =====================================================
-- ======= 1/ Source-position guard (unguarded call) ===
-- =====================================================
-- =====================================================

helpers.describe("karabiner.watchers: deactivate_capsword is never called bare in the eventtap body (F-HIGH-7)", function()

	local function read_source()
		-- Selected by a declaration unique to platform/remap/watchers.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_current_layout_from_hitoolbox")
		helpers.assert_true(src ~= nil, "platform/remap/watchers.lua source must be locatable")
		return src
	end

	helpers.it("the eventtap callback body wraps the per-lease closure in Logger.pcall", function()
		local src = read_source()

		-- Isolate M.start_gesture_watcher's body (up to its matching top-level
		-- "end" — the next line at the same zero-indent level).
		local body_start = src:find("function M.start_gesture_watcher", 1, true)
		helpers.assert_true(body_start ~= nil, "M.start_gesture_watcher must exist")
		local body_end = src:find("\nend\n", body_start, true)
		helpers.assert_true(body_end ~= nil, "M.start_gesture_watcher must have a top-level 'end'")
		local body = src:sub(body_start, body_end)

		helpers.assert_true(body:find("local function deactivate_current_capsword", 1, true) ~= nil,
			"each watcher start must capture its exact lease in a private callback closure")

		-- The bug: a bare "deactivate_capsword()" call with no Logger.pcall wrapper.
		-- A correct fix reads "Logger.pcall(LOG, deactivate_capsword)" instead.
		helpers.assert_true(body:find("\t\t\tdeactivate_current_capsword()\n", 1, true) == nil,
			"the per-lease callback must NOT be called bare in the eventtap callback (F-HIGH-7)")
		helpers.assert_true(body:find("Logger.pcall(LOG, deactivate_current_capsword)", 1, true) ~= nil,
			"the eventtap callback must invoke the per-lease closure via Logger.pcall")
	end)
end)




-- ===========================================================
-- ===========================================================
-- ======= 2/ Behavioral: throwing hs.task.new is contained ==
-- ===========================================================
-- ===========================================================

helpers.describe("karabiner.watchers: eventtap callback survives a throwing deactivate_capsword (F-HIGH-7)", function()

	-- Builds a fresh watchers module with hs.eventtap.new stubbed to capture the
	-- pointer-event callback, and hs.task.new replaced with a function that raises
	-- (simulating any unguarded exception inside deactivate_capsword). The clock
	-- is fixed comfortably past CAPSWORD_CHECK_INTERVAL_S (100 ms) so
	-- deactivate_capsword's own throttle guard (now_s - _capsword_last_check_s <
	-- CAPSWORD_CHECK_INTERVAL_S) does not short-circuit BEFORE reaching
	-- hs.task.new on the very first call — _capsword_last_check_s starts at 0.
	local function make_watchers_with_throwing_task()
		package.loaded["platform.remap.watchers"] = nil
		package.loaded["adapters.shell_runner"] = nil
		package.loaded["platform.remap.ke_variables"] = {
			supersede_capsword_activation = function() return false, 0 end,
			capsword_revision = function() return 0 end,
			set_if_revision = function() return false, 0 end,
		}

		local captured = { cb = nil }
		local state = { now = 1000, task_attempts = 0 }
		local watchers = helpers.load_with_stubs("platform.remap.watchers", {
			eventtap = {
				new = function(_types, cb)
					captured.cb = cb
					return { start = function() return true end, stop = function() end }
				end,
				event = { types = {
					mouseMoved = 1, scrollWheel = 2, gesture = 3,
					leftMouseDown = 4, rightMouseDown = 5, otherMouseDown = 6,
				} },
			},
			task = {
				new = function()
					state.task_attempts = state.task_attempts + 1
					error("boom: injected hs.task.new failure")
				end,
			},
			timer = {
				secondsSinceEpoch = function() return state.now end,
			},
		})

		return watchers, captured, state
	end

	helpers.it("invoking the captured callback does not raise even when deactivate_capsword throws", function()
		local _watchers, captured = make_watchers_with_throwing_task()
		local dummy_event = {}

		local ok_start, watcher_or_err = pcall(
			_watchers.start_gesture_watcher,
			nil,
			"0123456789abcdef0123456789abcdef"
		)
		helpers.assert_true(ok_start, "start_gesture_watcher itself must not raise: " .. tostring(watcher_or_err))
		helpers.assert_true(type(captured.cb) == "function",
			"start_gesture_watcher must register an eventtap callback")

		local ok_cb, cb_err = pcall(captured.cb, dummy_event)
		-- The callback ANSWERS whether it consumed the event; that second return is
		-- the answer, not an error. An eventtap callback returning nil is read by
		-- Hammerspoon as "do not consume", so the type is the invariant.
		helpers.assert_true(type(cb_err) == "boolean" or cb_err == nil,
			"and must answer whether it consumed the event")
		helpers.assert_true(ok_cb,
			"the eventtap callback must not raise even when deactivate_capsword's hs.task.new throws (F-HIGH-7)")
	end)

	helpers.it("the callback returns false (never consumes the pointer event) even when it throws internally", function()
		local _watchers, captured = make_watchers_with_throwing_task()
		_watchers.start_gesture_watcher(nil, "0123456789abcdef0123456789abcdef")

		local ok, result = pcall(captured.cb, {})
		helpers.assert_true(ok, "callback must not raise")
		helpers.assert_eq(result, false, "the watcher must never consume the pointer event")
	end)

	helpers.it("a throwing task constructor releases the probe lock for the next event", function()
		local watchers, captured, state = make_watchers_with_throwing_task()
		watchers.start_gesture_watcher(nil, "0123456789abcdef0123456789abcdef")

		captured.cb({})
		state.now = state.now + 1
		captured.cb({})

		helpers.assert_eq(state.task_attempts, 2,
			"each post-throttle pointer event must retry after task creation raises")
	end)
end)
