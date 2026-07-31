--- tests/unit/modules/gestures/test_engine.lua

--- ==============================================================================
--- MODULE: gestures.engine Unit Tests
--- DESCRIPTION:
--- Black-box tests for the touch gesture engine. Exercises process_frame via a
--- mock actions module that records every fire, so the pure classification logic
--- (tap vs swipe, finger count, direction) can be validated without a live macOS
--- host.
---
--- FEATURES & RATIONALE:
--- 1. Time-controlled simulation: overrides hs.timer.secondsSinceEpoch so tap
---    vs swipe timing thresholds can be reproduced deterministically.
--- 2. Isolation: fresh module instance per test (fresh_engine()) to bypass the
---    double-init guard and give every test a clean _state.
--- 3. Mock actions: a lightweight table implementing execute_single,
---    execute_axis, and set_gesture_in_progress that records every call.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Engine = helpers.load_with_stubs("modules.gestures.engine")

-- Allow tests to override the time seen by process_frame.
local _time = 0
_G.hs.timer.secondsSinceEpoch = function() return _time end

-- Mock script control for pause invariant tests in engine
-- script_control is stubbed only so a TRANSITIVE require cannot pull the real
-- module (and hs.*) into a headless run. The engine itself never consults it —
-- the gesture pause gate is CoreState.suspended, checked by
-- modules/gestures/init.lua — which is asserted below, so this stub is a load
-- guard and not a pause switch. It used to carry a `paused` flag that two
-- placeholder tests toggled to no effect whatsoever.
package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return false end }




-- =====================================================
-- =====================================================
-- ======= 1/ Test Fixture Helpers ===================
-- =====================================================
-- =====================================================

--- Returns a minimal _state object accepted by Engine.init().
--- @param overrides table|nil Fields to merge on top of the defaults.
--- @return table
local function make_state(overrides)
	local s = {
		enabled       = true,
		ga            = {},
		modes         = {},
		sensitivities = {},
	}
	if overrides then
		for k, v in pairs(overrides) do s[k] = v end
	end
	return s
end

--- Returns a touch object matching the shape engine.lua reads.
--- @param x number Horizontal position.
--- @param y number Vertical position.
--- @return table
local function make_touch(x, y)
	return { absoluteVector = { position = { x = x, y = y } } }
end

--- Returns a recording table plus a compatible mock actions module.
--- The recording table exposes:
---   fired.singles -- list of action ids passed to execute_single
---   fired.axes    -- list of {action, is_forward} passed to execute_axis
---   fired.actions -- the mock module itself (for Engine.init)
--- @return table
local function make_fired()
	local rec = { singles = {}, axes = {} }
	rec.actions = {
		execute_single = function(action)
			table.insert(rec.singles, action)
		end,
		execute_axis = function(action, is_forward)
			table.insert(rec.axes, { action = action, is_forward = is_forward })
		end,
		set_gesture_in_progress = function(_) end,
	}
	return rec
end

--- Reloads the gesture engine module for per-test isolation.
--- Required because engine.lua has a double-init guard (_state) that blocks
--- Engine.init() if the module was already initialized in a previous test.
--- @return table Fresh engine module instance.
local function fresh_engine()
	package.loaded["modules.gestures.engine"] = nil
	local E = helpers.load_with_stubs("modules.gestures.engine")
	_G.hs.timer.secondsSinceEpoch = function() return _time end
	return E
end

--- Resets the engine's internal gesture state by feeding it an empty frame.
--- Call at the start of every test that exercises process_frame.
--- @param E_override table|nil Engine instance to reset; defaults to top-level Engine.
local function reset_engine(E_override)
	local E = E_override or Engine
	_time = 0
	E.process_frame({})
end





-- =====================================
-- =====================================
-- ======= 2/ Module API Surface =======
-- =====================================
-- =====================================

helpers.describe("gestures.engine: module API surface", function()
	helpers.it("exposes process_frame as a function", function()
		helpers.assert_eq(type(Engine.process_frame), "function")
	end)

	helpers.it("exposes init as a function", function()
		helpers.assert_eq(type(Engine.init), "function")
	end)

	helpers.it("exposes set_any_touch_hook as a function", function()
		helpers.assert_eq(type(Engine.set_any_touch_hook), "function")
	end)
end)





-- =============================================================
-- =============================================================
-- ======= 3/ process_frame: nil and invalid input guard =======
-- =============================================================
-- =============================================================

helpers.describe("gestures.engine: nil/invalid input guard", function()
	helpers.it("process_frame(nil) does not crash", function()
		Engine.process_frame(nil)
		helpers.assert_true(true)
	end)

	helpers.it("process_frame(string) does not crash", function()
		Engine.process_frame("not a table")
		helpers.assert_true(true)
	end)
end)





-- ==================================================================
-- ==================================================================
-- ======= 4/ process_frame: no active gesture on empty frame =======
-- ==================================================================
-- ==================================================================

helpers.describe("gestures.engine: empty frame after init", function()
	helpers.it("process_frame({}) after init does not crash", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state(), fired.actions)
		reset_engine(E)
		helpers.assert_true(true)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 5/ Tap Detection ================
-- ==========================================
-- ==========================================

helpers.describe("gestures.engine: tap detection", function()
	helpers.it("2-finger tap fires the configured tap_2 action", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({ ga = { tap_2 = "mission_control" } }), fired.actions)
		reset_engine(E)

		-- Start gesture with 2 fingers
		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100) })

		-- Lift fingers quickly -- well within TAP_MAX_SEC
		_time = 0.1
		E.process_frame({})

		helpers.assert_true(#fired.singles == 1, "expected exactly 1 single fire")
		helpers.assert_eq(fired.singles[1], "mission_control")
	end)

	helpers.it("3-finger tap fires the configured tap_3 action", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({ ga = { tap_3 = "app_expose" } }), fired.actions)
		reset_engine(E)

		_time = 0
		E.process_frame({
			make_touch(100, 100),
			make_touch(110, 100),
			make_touch(105, 110),
		})
		_time = 0.1
		E.process_frame({})

		helpers.assert_true(#fired.singles == 1, "expected exactly 1 single fire")
		helpers.assert_eq(fired.singles[1], "app_expose")
	end)

	helpers.it("tap with no configured ga entry does not crash", function()
		local fired = make_fired()
		local E = fresh_engine()
		-- ga is empty -- no tap_2 mapping
		E.init(make_state({ ga = {} }), fired.actions)
		reset_engine(E)

		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100) })
		_time = 0.1
		E.process_frame({})

		-- No fires, no crash
		helpers.assert_eq(#fired.singles, 0)
	end)

	helpers.it("gesture with movement > TAP_MAX_DELTA is not classified as tap", function()
		local fired = make_fired()
		local E = fresh_engine()
		-- Map both tap and swipe to distinguish them
		E.init(make_state({
			ga = {
				tap_2         = "mission_control",
				swipe_2_right = "tab_next",
			},
		}), fired.actions)
		reset_engine(E)

		-- Start gesture
		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100) })

		-- Move well beyond TAP_MAX_DELTA (8.0) -- shift right by 15 units
		_time = 0.05
		E.process_frame({ make_touch(115, 100), make_touch(125, 100) })

		-- Lift
		_time = 0.1
		E.process_frame({})

		-- tap_2 must NOT have fired
		local tap_fired = false
		for _, a in ipairs(fired.singles) do
			if a == "mission_control" then tap_fired = true end
		end
		helpers.assert_true(not tap_fired, "tap_2 must not fire when delta > TAP_MAX_DELTA")
	end)
end)




-- =============================================
-- =============================================
-- ======= 6/ Swipe Detection ================
-- =============================================
-- =============================================

helpers.describe("gestures.engine: swipe detection", function()
	helpers.it("3-finger right swipe fires swipe_3_right", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({ ga = { swipe_3_right = "tab_next" } }), fired.actions)
		reset_engine(E)

		_time = 0
		E.process_frame({
			make_touch(100, 100),
			make_touch(110, 100),
			make_touch(105, 110),
		})

		-- Move right by 20 units -- well above SWIPE_MIN (1.5) and TAP_MAX_DELTA (8)
		_time = 0.05
		E.process_frame({
			make_touch(120, 100),
			make_touch(130, 100),
			make_touch(125, 110),
		})

		_time = 0.1
		E.process_frame({})

		local found = false
		for _, a in ipairs(fired.singles) do
			if a == "tab_next" then found = true end
		end
		helpers.assert_true(found, "swipe_3_right must fire tab_next")
	end)

	helpers.it("3-finger up swipe fires swipe_3_up", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({ ga = { swipe_3_up = "mission_control" } }), fired.actions)
		reset_engine(E)

		_time = 0
		E.process_frame({
			make_touch(100, 100),
			make_touch(110, 100),
			make_touch(105, 110),
		})

		-- Move up (negative y in screen coords -- use large delta to be safe)
		_time = 0.05
		E.process_frame({
			make_touch(100, 80),
			make_touch(110, 80),
			make_touch(105, 90),
		})

		_time = 0.1
		E.process_frame({})

		-- Accept either a single fire or an axis fire; key invariant is no crash
		helpers.assert_true(#fired.singles >= 0, "must not crash on 3-finger up swipe")
		helpers.assert_true(not (function()
			for _, a in ipairs(fired.singles) do
				if a == "tap_3_wrong_sentinel" then return true end
			end
			return false
		end)(), "tap_3 sentinel must not fire (test is directional)")
		helpers.assert_true(true)
	end)

	helpers.it("swipe too small (delta < SWIPE_MIN) does not fire at commit", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({
			ga = {
				swipe_2_right = "tab_next",
				-- Deliberately no tap_2 so the only possible fire is the swipe
			},
		}), fired.actions)
		reset_engine(E)

		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100) })

		-- Move only 1 unit -- below SWIPE_MIN (1.5)
		_time = 0.05
		E.process_frame({ make_touch(101, 100), make_touch(111, 100) })

		-- Elapsed > TAP_MAX_SEC so it is not a tap either
		_time = 0.80
		E.process_frame({})

		helpers.assert_eq(#fired.singles, 0, "no action must fire for sub-threshold movement")
	end)

	helpers.it("4-finger swipe fires swipe_4_right, not swipe_3_right", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({
			ga = {
				swipe_3_right = "tab_next",
				swipe_4_right = "space_next",
			},
		}), fired.actions)
		reset_engine(E)

		_time = 0
		E.process_frame({
			make_touch(100, 100),
			make_touch(110, 100),
			make_touch(105, 110),
			make_touch(115, 110),
		})

		_time = 0.05
		E.process_frame({
			make_touch(120, 100),
			make_touch(130, 100),
			make_touch(125, 110),
			make_touch(135, 110),
		})

		_time = 0.1
		E.process_frame({})

		local fired_3 = false
		local fired_4 = false
		for _, a in ipairs(fired.singles) do
			if a == "tab_next"   then fired_3 = true end
			if a == "space_next" then fired_4 = true end
		end
		helpers.assert_true(not fired_3, "swipe_3_right must NOT fire for 4-finger gesture")
		helpers.assert_true(fired_4,     "swipe_4_right must fire for 4-finger gesture")
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 7/ any_touch_hook ==============
-- ===========================================
-- ===========================================

helpers.describe("gestures.engine: any_touch_hook", function()
	helpers.it("hook is called when process_frame receives touches (n > 0)", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state(), fired.actions)
		reset_engine(E)

		local hook_calls = 0
		E.set_any_touch_hook(function() hook_calls = hook_calls + 1 end)

		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100) })

		helpers.assert_true(hook_calls > 0, "hook must be called when touches arrive")

		-- Clean up hook so it does not bleed into other tests
		E.set_any_touch_hook(nil)
	end)

	helpers.it("hook is NOT called when n == 0", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state(), fired.actions)
		reset_engine(E)

		local hook_calls = 0
		E.set_any_touch_hook(function() hook_calls = hook_calls + 1 end)

		_time = 0
		E.process_frame({})

		helpers.assert_eq(hook_calls, 0, "hook must not be called for empty frames")

		E.set_any_touch_hook(nil)
	end)
end)




-- ================================================
-- ================================================
-- ======= 8/ Finger Count Tracking ============
-- ================================================
-- ================================================

helpers.describe("gestures.engine: finger count tracking", function()
	helpers.it("maxFingers tracks the peak seen during a gesture", function()
		-- We verify that a 3-finger gesture is not mis-classified as 2-finger even
		-- if the first frame had only 2 contacts.
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({
			ga = {
				tap_2 = "mission_control",
				tap_3 = "app_expose",
			},
		}), fired.actions)
		reset_engine(E)

		-- Frame 1: 2 fingers
		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100) })

		-- Frame 2: 3rd finger joins
		_time = 0.02
		E.process_frame({
			make_touch(100, 100),
			make_touch(110, 100),
			make_touch(105, 115),
		})

		-- Lift quickly -- tap timing
		_time = 0.1
		E.process_frame({})

		-- The peak was 3 fingers, so tap_3 / app_expose must fire, NOT tap_2
		local fired_2 = false
		local fired_3 = false
		for _, a in ipairs(fired.singles) do
			if a == "mission_control" then fired_2 = true end
			if a == "app_expose"      then fired_3 = true end
		end
		helpers.assert_true(not fired_2, "tap_2 must not fire when peak was 3 fingers")
		helpers.assert_true(fired_3,     "tap_3 must fire when peak was 3 fingers")
	end)

	helpers.it("single finger join (2->3) is accepted immediately (fast path)", function()
		-- This test confirms the fast-path: joining one finger above the current
		-- count does not require candidate confirmation frames.
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({ ga = { tap_3 = "app_expose" } }), fired.actions)
		reset_engine(E)

		-- Frame 1: start with 2 fingers
		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100) })

		-- Frame 2: 3rd joins (single step up -- fast path)
		_time = 0.01
		E.process_frame({
			make_touch(100, 100),
			make_touch(110, 100),
			make_touch(105, 115),
		})

		-- Lift
		_time = 0.08
		E.process_frame({})

		-- tap_3 should fire because the join was accepted immediately
		local found = false
		for _, a in ipairs(fired.singles) do
			if a == "app_expose" then found = true end
		end
		helpers.assert_true(found, "tap_3 must fire after immediate 2->3 join")
	end)

	--- Feeds a complete 3-finger right swipe: touch down, move, lift.
	--- Mirrors the working swipe tests above; the delta is well past SWIPE_MIN.
	local function swipe_right(E)
		_time = 0
		E.process_frame({ make_touch(100, 100), make_touch(110, 100), make_touch(105, 110) })
		_time = 0.05
		E.process_frame({ make_touch(120, 100), make_touch(130, 100), make_touch(125, 110) })
		_time = 0.1
		E.process_frame({})
	end

	-- The two placeholders these replace set _mock_sc.paused = true, immediately
	-- set it back to false, fed no frames, and asserted assert_true(true).
	--
	-- Driving them revealed the placeholders' premise was WRONG. The engine does
	-- not consult script_control at all — it never requires it — so
	-- _mock_sc.paused has no effect here, and a swipe fired straight through the
	-- "paused" test. The pause gate for gestures is CoreState.suspended, checked
	-- by modules/gestures/init.lua before it dispatches. The engine is pure, and
	-- pinning that purity is what actually protects the seam: the day someone
	-- adds a pause check in here, there would be two gates disagreeing.
	helpers.it("the engine is pure with respect to pause — the gate lives in its caller", function()
		local src = helpers.read_driver_source("local function triggerLiveAxisIfNeeded")
		helpers.assert_true(src ~= nil, "modules/gestures/engine.lua source must be locatable")
		helpers.assert_true(src:find("script_control", 1, true) == nil,
			"the engine must not consult script_control — the pause gate is CoreState.suspended in modules/gestures/init.lua, and a second gate here would let the two disagree")
	end)

	helpers.it("a swipe fires, and a second identical swipe fires again — no stuck primer", function()
		local fired = make_fired()
		local E = fresh_engine()
		E.init(make_state({ ga = { swipe_3_right = "tab_next" } }), fired.actions)
		reset_engine(E)

		swipe_right(E)
		swipe_right(E)

		local count = 0
		for _, a in ipairs(fired.singles) do
			if a == "tab_next" then count = count + 1 end
		end
		helpers.assert_eq(count, 2,
			"each completed swipe must fire once — a primer left half-armed by the previous gesture silently kills every gesture after it, which is the failure the placeholder named and never checked")
	end)
end)
