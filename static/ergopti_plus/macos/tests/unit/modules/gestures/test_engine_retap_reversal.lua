--- tests/unit/modules/gestures/test_engine_retap_reversal.lua

--- Regression tests for two gesture engine state machine bugs:
---
--- gestures-engine-retap: a one-finger bridge between two multi-finger taps must
--- commit the first gesture and restart tracking for the second. The historical
--- source-only assertions proved that a restart block contained reset statements,
--- but not that any real frame sequence could reach it.
---
--- gestures-engine-reversal: an incremental rebase triggered by direction reversal
--- sets gs.liveAxisSign = nil (to allow the new direction to fire). commitGesture
--- used `gs.liveAxisSign ~= nil` to detect whether any live fire had occurred.
--- After a reversal-rebase, liveAxisSign is nil even though a live fire DID happen,
--- so the tap guard (`if not had_live_fire and total_delta < TAP_MAX_DELTA`) failed
--- to suppress the spurious tap at lift-off.
---
--- Fix: gs.hadLiveFire is sticky across a reversal rebase. A confirmed drop below
--- two contacts marks the current gesture lifted, and any later multi-finger frame
--- starts a fresh gesture regardless of whether its finger count matches the old.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/gestures/engine.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function triggerLiveAxisIfNeeded")
helpers.assert_true(src ~= nil, "modules/gestures/engine.lua source must be locatable")

-- Test 1 (gestures-engine-reversal): hadLiveFire is in the initial state table.
local has_initial = src:find("hadLiveFire    = false", 1, true) ~= nil
helpers.assert_true(
	has_initial,
	"engine.lua initial gesture state must include hadLiveFire = false (gestures-engine-reversal)"
)

-- Test 2 (gestures-engine-reversal): hadLiveFire is set at incremental live fire.
local incremental_fire = src:find("gs.hadLiveFire    = true", 1, true) ~= nil
helpers.assert_true(
	incremental_fire,
	"engine.lua incremental live fire must set gs.hadLiveFire = true (gestures-engine-reversal)"
)

-- Test 3 (gestures-engine-reversal): commitGesture uses gs.hadLiveFire, not liveAxisSign ~= nil.
-- Pre-fix: `local had_live_fire = (gs.liveAxisSign ~= nil)`
local old_check = src:find("had_live_fire = (gs.liveAxisSign ~= nil)", 1, true) ~= nil
helpers.assert_true(
	not old_check,
	"engine.lua commitGesture must not use `had_live_fire = (gs.liveAxisSign ~= nil)` — cleared by rebase (gestures-engine-reversal)"
)

local new_check = src:find("had_live_fire = gs.hadLiveFire", 1, true) ~= nil
helpers.assert_true(
	new_check,
	"engine.lua commitGesture must use `had_live_fire = gs.hadLiveFire` (sticky, not cleared by rebase) (gestures-engine-reversal)"
)

local current_time = 0

local function fingers(count)
	local touches = {}
	for index = 1, count do
		touches[index] = {
			absoluteVector = { position = { x = 100 + index, y = 100 } },
		}
	end
	return touches
end

local function fresh_engine()
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["infra.logger"] = nil
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			if key == "tap_max_ms" then return 0.5 end
			if key == "finger_confirm_ms" then return 0.05 end
			if key == "finger_drop_confirm_ms" then return 0.2 end
			if key == "finger_count_stable_ms" then return 0.06 end
			return 0
		end,
	}
	local _ = helpers.load_with_stubs("infra.logger")
	local engine = helpers.load_with_stubs("modules.gestures.engine")
	_G.hs.timer.secondsSinceEpoch = function() return current_time end
	return engine
end

helpers.describe("gestures.engine: rapid re-tap reachability", function()
	helpers.it("commits and separates taps across a confirmed one-finger bridge", function()
		local fired = {}
		local engine = fresh_engine()
		engine.init({
			enabled = true,
			ga = { tap_4 = "first_tap", tap_2 = "second_tap" },
			modes = {},
			sensitivities = {},
		}, {
			execute_single = function(action)
				fired[#fired + 1] = action
				return true
			end,
			execute_axis = function() return false end,
			set_gesture_in_progress = function() end,
		})

		current_time = 0
		engine.process_frame(fingers(4))
		current_time = 0.01
		engine.process_frame(fingers(1))
		current_time = 0.22
		engine.process_frame(fingers(1))
		current_time = 0.23
		engine.process_frame(fingers(2))
		current_time = 0.3
		engine.process_frame({})

		helpers.assert_eq(#fired, 2,
			"a confirmed one-finger bridge must not merge two multi-finger taps")
		helpers.assert_eq(fired[1], "first_tap",
			"the gesture before the bridge must commit with its original finger count")
		helpers.assert_eq(fired[2], "second_tap",
			"the gesture after the bridge must start with an independent finger count")
	end)
end)

-- HS-199: every commit call site must use the same visible exception boundary.
helpers.assert_true(
	src:find("pcall(commitGesture", 1, true) == nil,
	"gesture commits must not discard failures through bare pcall (HS-199)"
)

print("[PASS] test_engine_retap_reversal")
