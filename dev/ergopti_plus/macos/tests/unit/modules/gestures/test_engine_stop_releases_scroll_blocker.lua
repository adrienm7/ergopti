--- tests/unit/modules/gestures/test_engine_stop_releases_scroll_blocker.lua

--- ==============================================================================
--- MODULE: Regression — Engine.stop() releases the scroll-blocker eventtap
--- DESCRIPTION:
--- Guards against the bug where Engine had no stop() function: every Hammerspoon
--- reload created a new scrollBlocker eventtap via Engine.init() without stopping
--- the previous one, so N reloads left N concurrent scroll eventtaps running.
---
--- Root cause (2026-06-19): scrollBlocker was a file-local variable with no
--- teardown path. Engine.init() guards with `if not scrollBlocker` — but because
--- the module table is cached by require(), re-require returns the same module.
--- The real problem is that gestures/init.lua M.stop() never called Engine.stop().
---
--- Fix: Added Engine.stop() that stops+nils scrollBlocker; the shared exact
--- teardown helper calls it, and M.stop() delegates to that helper.
--- ==============================================================================

local helpers = require("tests.helpers")




local function touch(x, y)
	return { absoluteVector = { position = { x = x, y = y } } }
end

local function load_engine()
	package.loaded["modules.gestures.engine"] = nil
	local Engine = helpers.load_with_stubs("modules.gestures.engine")
	_G.hs.eventtap.__reset()
	_G.hs.timer.secondsSinceEpoch = function() return 1 end
	return Engine
end

local function state_with_tap(action)
	return {
		enabled = true,
		ga = { tap_3 = action },
		modes = {},
		sensitivities = {},
	}
end




-- ===========================================================
-- ===========================================================
-- ======= 1/ Engine exposes a stop() function ===============
-- ===========================================================
-- ===========================================================

helpers.describe("Engine.stop(): contract", function()
	helpers.it("Engine module exports a stop() function", function()
		local Engine = helpers.load_with_stubs("modules.gestures.engine")
		helpers.assert_true(
			type(Engine.stop) == "function",
			"Engine must export stop() so gestures/init.lua M.stop() can call it"
		)
	end)

	helpers.it("settles the blocker and discards the interrupted gesture before restart", function()
		local Engine = load_engine()
		local fired = {}
		local actions = {
			execute_single = function(action)
				table.insert(fired, action)
				return true
			end,
			execute_axis = function() return true end,
			set_gesture_in_progress = function() end,
		}
		Engine.init(state_with_tap("stale-tap"), actions)
		Engine.process_frame({ touch(100, 100), touch(110, 100), touch(105, 110) })

		helpers.assert_eq(Engine.is_blocking_scroll(), true,
			"three physical fingers must arm the scroll blocker for the regression")
		helpers.assert_eq(Engine.stop(), true,
			"Engine.stop must publish exact teardown settlement")
		helpers.assert_eq(Engine.is_blocking_scroll(), false,
			"Engine.stop must synchronously release the scroll decision")

		Engine.init(state_with_tap("fresh-tap"), actions)
		local restarted_tap = _G.hs.eventtap.__taps[#_G.hs.eventtap.__taps]
		helpers.assert_eq(restarted_tap.fn({}), false,
			"the restarted blocker must pass native scroll events")
		Engine.process_frame({})
		helpers.assert_eq(#fired, 0,
			"lifting after restart must not commit the interrupted gesture")
		helpers.assert_eq(Engine.stop(), true)
	end)

	helpers.it("retains the exact blocker when native teardown is refused", function()
		local Engine = load_engine()
		Engine.init(state_with_tap("none"), {
			execute_single = function() return true end,
			execute_axis = function() return true end,
			set_gesture_in_progress = function() end,
		})
		local blocker = _G.hs.eventtap.__taps[1]
		local native_stop = blocker.stop
		blocker.stop = function() return false end

		helpers.assert_eq(Engine.stop(), false,
			"a refused native stop must remain a retryable cleanup debt")
		helpers.assert_eq(Engine.is_blocking_scroll(), false,
			"cleanup debt must not leave native scrolling swallowed")
		Engine.init(state_with_tap("successor"), {})
		helpers.assert_eq(#_G.hs.eventtap.__taps, 1,
			"a successor blocker must not replace unsettled native ownership")

		blocker.stop = native_stop
		helpers.assert_eq(Engine.stop(), true,
			"retry must settle the exact retained blocker")
	end)

	helpers.it("retains a blocker activated before start raises and retries safely", function()
		local Engine = load_engine()
		local native_new = _G.hs.eventtap.new
		local creations = 0
		local stop_calls = 0
		_G.hs.eventtap.new = function(events, callback)
			creations = creations + 1
			local candidate = native_new(events, callback)
			if creations == 1 then
				local native_start = candidate.start
				local native_stop = candidate.stop
				candidate.start = function(self)
					native_start(self)
					error("scroll blocker start failed after activation")
				end
				candidate.stop = function(self)
					stop_calls = stop_calls + 1
					if stop_calls == 1 then error("scroll blocker rollback failed") end
					return native_stop(self)
				end
			end
			return candidate
		end
		local actions = {
			execute_single = function() return true end,
			execute_axis = function() return true end,
			set_gesture_in_progress = function() end,
		}

		helpers.assert_eq(Engine.init(state_with_tap("none"), actions), false)
		local refused = _G.hs.eventtap.__taps[1]
		helpers.assert_eq(stop_calls, 1,
			"failed acquisition must immediately attempt exact-candidate rollback")
		helpers.assert_eq(refused.fn({}), false,
			"an activated but uncommitted blocker must remain callback-inert")

		helpers.assert_eq(Engine.init(state_with_tap("none"), actions), true)
		helpers.assert_eq(stop_calls, 2,
			"retry must settle the exact retained blocker before creating a successor")
		helpers.assert_eq(creations, 2)
		Engine.process_frame({ touch(100, 100), touch(110, 100), touch(105, 110) })
		helpers.assert_eq(refused.fn({}), false,
			"the superseded native callback must reject the successor generation")
		helpers.assert_eq(_G.hs.eventtap.__taps[2].fn({}), true,
			"only the committed successor may enforce the scroll decision")
		helpers.assert_eq(Engine.stop(), true)
	end)
end)




-- ===========================================================
-- ===========================================================
-- ======= 2/ gestures init M.stop() calls Engine.stop() ====
-- ===========================================================
-- ===========================================================

helpers.describe("gestures init M.stop(): tears down engine", function()
	helpers.it("M.stop() delegates to the helper that stops Engine", function()
		local source = helpers.read_driver_source("local function schedule_emergency_recycle")
		helpers.assert_true(source ~= nil and source ~= "",
			"modules/gestures/init.lua source must be locatable")
		local teardown_pos = source:find("teardown_gesture_runtime = function", 1, true)
		local teardown_end = teardown_pos
			and source:find("\nlocal function reject_gesture_start", teardown_pos, true)
		local m_stop_pos = source:find("function M.stop()", 1, true)
		local m_stop_end = m_stop_pos and source:find("\nfunction M.diagnose()", m_stop_pos, true)
		helpers.assert_true(teardown_pos ~= nil and teardown_end ~= nil
			and m_stop_pos ~= nil and m_stop_end ~= nil,
			"the shared teardown and public stop entry point must remain bounded")

		local teardown = source:sub(teardown_pos, teardown_end - 1)
		local stop_body = source:sub(m_stop_pos, m_stop_end - 1)
		helpers.assert_true(
			teardown:find("xpcall(Engine.stop, debug.traceback)", 1, true) ~= nil,
			"the shared gesture teardown must stop Engine to release the scroll blocker")
		helpers.assert_true(
			stop_body:find("teardown_gesture_runtime(false)", 1, true) ~= nil,
			"M.stop() must route through the exact teardown that owns Engine.stop")
	end)
end)
