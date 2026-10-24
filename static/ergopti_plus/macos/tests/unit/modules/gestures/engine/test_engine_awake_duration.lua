--- tests/unit/modules/gestures/engine/test_engine_awake_duration.lua

--- ==============================================================================
--- MODULE: Gesture Engine Awake-Duration Regression Tests
--- DESCRIPTION:
--- Composes the real engine, geometry and timer scheduler over independent native
--- awake and civil clocks. A legitimate system-clock correction must neither
--- change tap classification nor spend or extend a live reversal's rearm window.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.gestures.engine",
	"modules.gestures.geometry",
	"adapters.timer_scheduler",
	"infra.logger",
	"infra.timings",
	"adapters.accessibility_permission",
	"adapters.mouse_control",
	"error_description",
	"number_policy",
}


--- Produces the ordinary contact shape delivered to process_frame by its owner.
--- @param count number Contact count.
--- @param x number Horizontal position.
--- @return table touches
local function contacts(count, x)
	local touches = {}
	for index = 1, count do
		touches[index] = {
			absoluteVector = { position = { x = x + index, y = 100 } },
		}
	end
	return touches
end


--- Runs real elapsed-time consumers against healthy, independently sampled clocks.
--- @param callback function Receives the engine and observable native boundaries.
local function with_engine_scope(callback)
	helpers.with_stub_scope(OWNED_MODULES, function()
		local world = { awake = 10000, civil = 1700000000, fired = {}, taps = {} }
		_G.hs = {
			timer = {
				absoluteTime = function() return world.awake * 1e9 end,
				secondsSinceEpoch = function() return world.civil end,
			},
			eventtap = {
				event = { types = { scrollWheel = 22, gesture = 29 } },
				new = function(types, fn)
					local tap = { types = types, fn = fn, enabled = false }
					function tap:start() self.enabled = true; return self end
					function tap:stop() self.enabled = false; return self end
					function tap:isEnabled() return self.enabled end
					world.taps[#world.taps + 1] = tap
					return tap
				end,
			},
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		-- Canonical gestures timings, in seconds, from the shared timing registry.
		local seconds = {
			tap_max_ms = 0.7,
			live_rearm_ms = 0.08,
			live_rearm_reverse_ms = 0.03,
			finger_confirm_ms = 0.05,
			finger_drop_confirm_ms = 0.2,
			finger_count_stable_ms = 0.06,
		}
		package.loaded["infra.timings"] = {
			sec = function(group, key)
				assert(group == "gestures" and seconds[key] ~= nil, "unexpected engine timing")
				return seconds[key]
			end,
		}
		package.loaded["adapters.accessibility_permission"] = { is_trusted = function() return true end }
		package.loaded["adapters.mouse_control"] = { any_button_down = function() return false end }
		local Engine = require("modules.gestures.engine")
		local Timer = require("adapters.timer_scheduler")
		helpers.assert_eq(Engine.init({
			enabled = true,
			ga = { tap_2 = "mission_control", swipe_3_right = "word_next", swipe_3_left = "word_prev" },
			modes = {},
			sensitivities = {},
		}, {
			execute_single = function(action, slot)
				world.fired[#world.fired + 1] = { action = action, slot = slot }
				return true
			end,
			execute_axis = function() error("the configured actions must use single dispatch") end,
			set_gesture_in_progress = function() end,
		}), true, "the real engine must acquire its healthy exact scroll blocker")
		local ok, failure = xpcall(function() callback(Engine, world, Timer) end, debug.traceback)
		helpers.assert_eq(Engine.stop(), true, "the exact scroll blocker must retire even after a failed oracle")
		helpers.assert_eq(#world.taps, 1)
		helpers.assert_eq(world.taps[1]:isEnabled(), false)
		helpers.assert_eq(Timer.activeCount(), 0, "reading awake time must not acquire a timer")
		if not ok then error(failure, 0) end
	end)
end


--- Restores the exact process-level first-frame receipt even after setup or teardown failure.
--- @param callback function Receives the real engine and observable native boundaries.
local function with_engine(callback)
	local received_first_frame = rawget(_G, "ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME")
	local ok, failure = xpcall(function() with_engine_scope(callback) end, debug.traceback)
	rawset(_G, "ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME", received_first_frame)
	if not ok then error(failure, 0) end
end


--- Checks a stationary contact sequence and a subsequent independent short tap.
--- @param elapsed number Actual awake contact duration.
--- @param correction number Civil-clock step during contact.
--- @param expected number Expected actions from the first contact sequence.
local function classify_contact(elapsed, correction, expected)
	with_engine(function(Engine, world)
		Engine.process_frame(contacts(2, 100))
		world.awake = world.awake + elapsed
		world.civil = world.civil + elapsed + correction
		Engine.process_frame({})
		helpers.assert_eq(#world.fired, expected,
			"only awake contact duration may decide whether the release dispatches a tap")
		if expected == 1 then
			helpers.assert_eq(world.fired[1].action, "mission_control")
			helpers.assert_eq(world.fired[1].slot, "tap_2")
		end

		world.awake = world.awake + 1
		world.civil = world.civil + 1
		Engine.process_frame(contacts(2, 100))
		world.awake = world.awake + 0.1
		world.civil = world.civil + 0.1
		Engine.process_frame({})
		helpers.assert_eq(#world.fired, expected + 1,
			"release must reset the previous gesture before the next healthy short tap")
		helpers.assert_eq(world.fired[#world.fired].action, "mission_control")
		helpers.assert_eq(world.fired[#world.fired].slot, "tap_2")
	end)
end


helpers.describe("gesture classification measures awake contact duration", function()
	helpers.it("keeps a short tap when the civil clock jumps forward", function()
		classify_contact(0.1, 60, 1)
	end)

	helpers.it("rejects a long stationary hold when the civil clock jumps backward", function()
		classify_contact(2, -60, 0)
	end)

	helpers.it("keeps an ordinary short tap without a civil correction", function()
		classify_contact(0.1, 0, 1)
	end)

	helpers.it("rejects an ordinary long stationary hold without a civil correction", function()
		classify_contact(2, 0, 0)
	end)
end)


--- Establishes a real live swipe before applying one civil correction on reversal.
--- @param callback function Receives the live engine and observable action boundary.
local function with_live_swipe(callback)
	with_engine(function(Engine, world)
		Engine.process_frame(contacts(3, 100))
		world.awake = world.awake + 0.1
		world.civil = world.civil + 0.1
		Engine.process_frame(contacts(3, 110))
		helpers.assert_eq(#world.fired, 1, "the healthy positive swipe must fire before the clock correction")
		helpers.assert_eq(world.fired[1].action, "word_next")
		helpers.assert_eq(world.fired[1].slot, "swipe_3_right")
		callback(Engine, world)
	end)
end


helpers.describe("gesture live rearm measures awake duration", function()
	helpers.it("does not spend the reversal delay when the civil clock jumps forward", function()
		with_live_swipe(function(Engine, world)
			world.awake = world.awake + 0.01
			world.civil = world.civil + 60.01
			Engine.process_frame(contacts(3, 100))
			helpers.assert_eq(#world.fired, 1,
				"a civil-clock jump must not spend the live reversal's awake rearm delay")
			world.awake = world.awake + 0.04
			world.civil = world.civil + 0.04
			Engine.process_frame(contacts(3, 100))
			helpers.assert_eq(#world.fired, 2, "the same reversal must fire after its real delay elapses")
			helpers.assert_eq(world.fired[2].action, "word_prev")
			helpers.assert_eq(world.fired[2].slot, "swipe_3_left")
		end)
	end)

	helpers.it("rearms the reversal after its awake delay despite a civil-clock rollback", function()
		with_live_swipe(function(Engine, world)
			world.awake = world.awake + 0.05
			world.civil = world.civil - 59.95
			Engine.process_frame(contacts(3, 100))
			helpers.assert_eq(#world.fired, 2,
				"a civil-clock rollback must not extend the live reversal's awake rearm delay")
			helpers.assert_eq(world.fired[2].action, "word_prev")
			helpers.assert_eq(world.fired[2].slot, "swipe_3_left")
		end)
	end)
end)
