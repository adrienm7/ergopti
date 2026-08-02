--- tests/unit/modules/karabiner/test_watchers_capsword.lua

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
		-- Selected by a declaration unique to modules/karabiner/watchers.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_current_layout_from_hitoolbox")
		helpers.assert_true(src ~= nil, "modules/karabiner/watchers.lua source must be locatable")
		return src
	end

	helpers.it("the eventtap callback body wraps deactivate_capsword() in Logger.pcall", function()
		local src = read_source()

		-- Isolate M.start_gesture_watcher's body (up to its matching top-level
		-- "end" — the next line at the same zero-indent level).
		local body_start = src:find("function M.start_gesture_watcher", 1, true)
		helpers.assert_true(body_start ~= nil, "M.start_gesture_watcher must exist")
		local body_end = src:find("\nend\n", body_start, true)
		helpers.assert_true(body_end ~= nil, "M.start_gesture_watcher must have a top-level 'end'")
		local body = src:sub(body_start, body_end)

		helpers.assert_true(body:find("deactivate_capsword", 1, true) ~= nil,
			"the callback body must still reference deactivate_capsword")

		-- The bug: a bare "deactivate_capsword()" call with no Logger.pcall wrapper.
		-- A correct fix reads "Logger.pcall(LOG, deactivate_capsword)" instead.
		helpers.assert_true(body:find("\t\t\tdeactivate_capsword()\n", 1, true) == nil,
			"deactivate_capsword() must NOT be called bare in the eventtap callback (F-HIGH-7)")
		helpers.assert_true(body:find("Logger.pcall(LOG, deactivate_capsword)", 1, true) ~= nil,
			"the eventtap callback must call deactivate_capsword via Logger.pcall(LOG, deactivate_capsword)")
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
		package.loaded["modules.karabiner.watchers"] = nil
		package.loaded["adapters.shell_runner"] = nil

		local captured = { cb = nil }
		local watchers = helpers.load_with_stubs("modules.karabiner.watchers", {
			eventtap = {
				new = function(_types, cb)
					captured.cb = cb
					return { start = function() end, stop = function() end }
				end,
				event = { types = {
					mouseMoved = 1, scrollWheel = 2, gesture = 3,
					leftMouseDown = 4, rightMouseDown = 5, otherMouseDown = 6,
				} },
			},
			task = {
				new = function() error("boom: injected hs.task.new failure") end,
			},
			timer = {
				secondsSinceEpoch = function() return 1000 end,
			},
		})

		return watchers, captured
	end

	helpers.it("invoking the captured callback does not raise even when deactivate_capsword throws", function()
		local _watchers, captured = make_watchers_with_throwing_task()
		local dummy_event = {}

		local ok_start, watcher_or_err = pcall(_watchers.start_gesture_watcher, nil)
		helpers.assert_true(ok_start, "start_gesture_watcher itself must not raise: " .. tostring(watcher_or_err))
		helpers.assert_true(type(captured.cb) == "function",
			"start_gesture_watcher must register an eventtap callback")

		local ok_cb = pcall(captured.cb, dummy_event)
		helpers.assert_true(ok_cb,
			"the eventtap callback must not raise even when deactivate_capsword's hs.task.new throws (F-HIGH-7)")
	end)

	helpers.it("the callback returns false (never consumes the pointer event) even when it throws internally", function()
		local _watchers, captured = make_watchers_with_throwing_task()
		_watchers.start_gesture_watcher(nil)

		local ok, result = pcall(captured.cb, {})
		helpers.assert_true(ok, "callback must not raise")
		helpers.assert_eq(result, false, "the watcher must never consume the pointer event")
	end)
end)
