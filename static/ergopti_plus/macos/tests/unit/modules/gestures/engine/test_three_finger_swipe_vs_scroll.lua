--- tests/unit/modules/gestures/engine/test_three_finger_swipe_vs_scroll.lua

--- ==============================================================================
--- MODULE: Regression — a two-finger scroll is never a three-finger tab swipe
---         (three-finger-swipe-vs-scroll)
--- DESCRIPTION:
--- The maintainer scrolls with two fingers and the vertical three-finger swipe
--- (tab_prev / tab_next in the recommended macOS preset) kept switching tabs.
---
--- ROOT CAUSE ENCODED: the engine recognised a gesture at whatever count it saw
--- last, from a single frame. A third contact joining a pair took the one-frame
--- fast path to maxFingers = 3, so a palm grazing the pad on and off kept the
--- gesture at three fingers; a thumb resting beside two scrolling fingers moved
--- the centroid two thirds of the scroll and passed every travel threshold; a
--- grazing contact at touch-down followed by a quick two-finger flick committed
--- as a three-finger tap; and fingers landing to stop a momentum scroll started
--- a fresh three-finger swipe. The earlier guard only refused a third contact
--- after the pair had LOCKED its direction.
---
--- The fixed engine confirms a join to a pair over several frames during the
--- touch-down landing only, requires every contact to travel with the centroid,
--- aborts a three-finger gesture that continues as a moving pair, and refuses
--- any three-or-more-finger action that starts while a scroll is still active.
--- ==============================================================================

local helpers = require("tests.helpers")

-- About 125 Hz, the rate the touch device reports frames at.
local FRAME_DT_SEC = 0.008
-- Distance two or three fingers travel per frame in a steady swipe.
local STEP = 0.6

local FINGER_A = { x = 40, y = 50 }
local FINGER_B = { x = 50, y = 50 }
local FINGER_C = { x = 60, y = 50 }
local THUMB    = { x = 45, y = 20 }

-- The recommended macOS bindings for the vertical three-finger swipe, plus a
-- three-finger tap so a mis-committed tap is observable.
local GESTURES = {
	swipe_2_up = "none", swipe_2_down = "none", swipe_2_left = "none", swipe_2_right = "none",
	swipe_3_up = "tab_prev", swipe_3_down = "tab_next",
	swipe_3_left = "none", swipe_3_right = "none",
	swipe_4_up = "space_left", swipe_4_down = "none", swipe_4_left = "none", swipe_4_right = "none",
	tap_2 = "none", tap_3 = "app_expose", tap_4 = "none", tap_5 = "none",
}
local TAB_ACTIONS = { tab_prev = true, tab_next = true, app_expose = true, space_left = true }





-- =================================
-- =================================
-- ======= 1/ Engine Harness =======
-- =================================
-- =================================

--- Builds a fresh engine on a driven clock and returns a frame player.
--- @return table harness { frame, lift, wait, scroll_event, fired, finish }
local function new_harness()
	local hs = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local saved_absolute = hs.timer.absoluteTime
	local saved_scheduler = package.loaded["adapters.timer_scheduler"]
	local saved_timings = package.loaded["infra.timings"]
	local saved_logger = package.loaded["infra.logger"]
	-- Records every DEBUG line the engine writes, so the rejection diagnostics
	-- each case expects in the field log can be asserted.
	local debug_lines = {}
	local real_logger = require("infra.logger")
	package.loaded["infra.logger"] = setmetatable({
		debug = function(module_name, fmt, ...)
			local ok, line = pcall(string.format, fmt, ...)
			debug_lines[#debug_lines + 1] = ok and line or tostring(fmt)
			return real_logger.debug(module_name, fmt, ...)
		end,
	}, { __index = real_logger })
	local clock = 1000.0
	hs.timer.secondsSinceEpoch = function() return clock end
	hs.timer.absoluteTime = function() return clock * 1e9 end
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["modules.gestures.engine"] = nil
	hs.eventtap.__reset()

	local Engine = require("modules.gestures.engine")
	local fired = {}
	local initialized = Engine.init({
		enabled = true,
		ga = GESTURES,
		modes = { swipe_3_up = "incremental", swipe_3_down = "incremental" },
		sensitivities = { swipe_3_up = 3.5, swipe_3_down = 3.5 },
	}, {
		execute_single = function(a) fired[#fired + 1] = a; return true end,
		execute_axis   = function(a) fired[#fired + 1] = a; return true end,
		set_gesture_in_progress = function() end,
	})
	helpers.assert_true(initialized == true, "the engine must initialize on the stub eventtap")
	local tap = hs.eventtap.__taps[#hs.eventtap.__taps]

	local harness = { fired = fired, debug_lines = debug_lines }

	--- Finds the first rejection line naming a gate.
	--- @param gate string Gate name as the engine logs it.
	--- @return string|nil line
	function harness.rejection(gate)
		local needle = "Three-finger candidate rejected by " .. gate .. ":"
		for _, line in ipairs(debug_lines) do
			if line:find(needle, 1, true) then return line end
		end
		return nil
	end

	--- Plays one frame of contacts, each offset by `dy` along the swipe axis.
	--- @param contacts table Array of { x, y } base positions.
	--- @param moving table|nil Set of indices that travel; nil means all of them.
	--- @param dy number Offset of the travelling contacts.
	function harness.frame(contacts, moving, dy)
		local touches = {}
		for i, c in ipairs(contacts) do
			local offset = (moving == nil or moving[i]) and dy or 0
			touches[#touches + 1] = { absoluteVector = { position = { x = c.x, y = c.y + offset } } }
		end
		Engine.process_frame(touches)
		clock = clock + FRAME_DT_SEC
	end

	--- Lifts every finger.
	function harness.lift()
		Engine.process_frame({})
		clock = clock + FRAME_DT_SEC
	end

	--- Lets time pass with no contact.
	--- @param seconds number
	function harness.wait(seconds)
		clock = clock + seconds
	end

	--- Delivers one native scroll event to the engine's scroll tap.
	--- @param momentum_phase number Quartz momentum phase.
	function harness.scroll_event(momentum_phase)
		local properties = hs.eventtap.event.properties
		tap.fn({
			getProperty = function(_, prop)
				if prop == properties.scrollWheelEventMomentumPhase then return momentum_phase end
				return 0
			end,
		})
	end

	--- Restores the clock and drops the engine instance.
	function harness.finish()
		Engine.stop()
		hs.timer.secondsSinceEpoch = saved_clock
		hs.timer.absoluteTime = saved_absolute
		package.loaded["adapters.timer_scheduler"] = saved_scheduler
		package.loaded["infra.timings"] = saved_timings
		package.loaded["infra.logger"] = saved_logger
		package.loaded["modules.gestures.engine"] = nil
	end

	return harness
end

--- Plays a steady three-finger vertical swipe and lifts.
--- @param h table Harness.
local function three_finger_swipe(h)
	local hand = { FINGER_A, FINGER_B, FINGER_C }
	for i = 0, 30 do h.frame(hand, nil, i * STEP) end
	h.lift()
end

--- Plays a steady two-finger vertical scroll and lifts.
--- @param h table Harness.
local function two_finger_scroll(h)
	local pair = { FINGER_A, FINGER_B }
	for i = 0, 30 do h.frame(pair, nil, i * STEP) end
	h.lift()
end

--- Lists the tab or three-finger actions fired.
--- @param fired table Array of action names.
--- @return table
local function tab_fires(fired)
	local out = {}
	for _, a in ipairs(fired) do
		if TAB_ACTIONS[a] then out[#out + 1] = a end
	end
	return out
end





-- ==================================================
-- ==================================================
-- ======= 2/ Two-Finger Scrolls Stay Scrolls =======
-- ==================================================
-- ==================================================

helpers.describe("a two-finger scroll never fires a three-finger action (three-finger-swipe-vs-scroll)", function()
	helpers.it("a one-frame third contact on a short scroll does not fire", function()
		local h = new_harness()
		local pair = { FINGER_A, FINGER_B }
		h.frame(pair, nil, 0)
		-- A palm grazes the pad for a single frame as the pair starts to scroll,
		-- and the flick ends before a finger drop could be confirmed.
		h.frame({ FINGER_A, FINGER_B, THUMB }, { true, true, false }, STEP)
		for i = 2, 7 do h.frame(pair, nil, i * STEP) end
		h.lift()
		local fires = tab_fires(h.fired)
		local reason = h.rejection("frames held")
		h.finish()
		helpers.assert_true(reason ~= nil,
			"the field log must name the frames held gate with its measured value")
		helpers.assert_eq(#fires, 0,
			"a third contact seen for one frame is not a three-finger gesture; fired: "
				.. table.concat(fires, ", "))
	end)

	helpers.it("a palm touching on and off during a scroll does not fire", function()
		local h = new_harness()
		local pair_plus_palm = { FINGER_A, FINGER_B, THUMB }
		local pair = { FINGER_A, FINGER_B }
		h.frame(pair, nil, 0)
		-- Two frames on, one frame off, for the whole scroll.
		for i = 1, 45 do
			if i % 3 == 0 then
				h.frame(pair, nil, i * STEP)
			else
				h.frame(pair_plus_palm, { true, true, false }, i * STEP)
			end
		end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_eq(#fires, 0,
			"a flickering third contact beside a scrolling pair is not a three-finger swipe; "
				.. "fired: " .. table.concat(fires, ", "))
	end)

	helpers.it("a thumb resting beside two scrolling fingers does not fire", function()
		local h = new_harness()
		h.frame({ FINGER_A, FINGER_B }, nil, 0)
		-- The thumb lands on the next frame and stays still while the pair scrolls.
		for i = 1, 40 do
			h.frame({ FINGER_A, FINGER_B, THUMB }, { true, true, false }, i * STEP)
		end
		h.lift()
		local fires = tab_fires(h.fired)
		local reason = h.rejection("cohesion")
		h.finish()
		helpers.assert_true(reason ~= nil,
			"the field log must name the cohesion gate with its measured value")
		helpers.assert_eq(#fires, 0,
			"two fingers moving beside a still thumb are a scroll: every contact must travel "
				.. "with the swipe; fired: " .. table.concat(fires, ", "))
	end)

	helpers.it("three contacts that continue as a moving pair abort", function()
		local h = new_harness()
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		-- A grazing third contact at touch-down, then a quick two-finger flick.
		for _ = 1, 3 do h.frame(hand, nil, 0) end
		for i = 1, 6 do h.frame({ FINGER_A, FINGER_B }, nil, i * 0.8) end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_eq(#fires, 0,
			"a gesture that drops to a travelling pair is a scroll, neither the swipe nor "
				.. "the three-finger tap; fired: " .. table.concat(fires, ", "))
	end)

	helpers.it("a thumb landing after the pair scrolled is refused as the scroll's", function()
		local h = new_harness()
		local pair = { FINGER_A, FINGER_B }
		for i = 0, 10 do h.frame(pair, nil, i * STEP) end
		for i = 11, 40 do
			h.frame({ FINGER_A, FINGER_B, THUMB }, { true, true, false }, i * STEP)
		end
		h.lift()
		local fires = tab_fires(h.fired)
		local reason = h.rejection("pair scroll")
		h.finish()
		helpers.assert_true(reason ~= nil and reason:find("locked", 1, true) ~= nil,
			"a pair whose direction locked never promotes, and the log says so: "
				.. tostring(reason))
		helpers.assert_eq(#fires, 0, "fired: " .. table.concat(fires, ", "))
	end)

	helpers.it("a contact leaving for the lift adds no phantom travel", function()
		local h = new_harness()
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		-- A palm far below the hand on the touch-down frame only, then three
		-- still fingers: the count drop used to shift the start without the end,
		-- and the palm's offset committed as a four-finger swipe toward it.
		h.frame({ FINGER_A, FINGER_B, FINGER_C, { x = 50, y = 10 } }, nil, 0)
		for _ = 1, 5 do h.frame(hand, nil, 0) end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_eq(#fires, 0,
			"a finger-count change must not turn the centroid jump into travel; fired: "
				.. table.concat(fires, ", "))
	end)

	helpers.it("a three-finger touch right after a scroll does not fire", function()
		local h = new_harness()
		two_finger_scroll(h)
		h.wait(0.1)
		three_finger_swipe(h)
		local fires = tab_fires(h.fired)
		local reason = h.rejection("scroll guard")
		h.finish()
		helpers.assert_true(reason ~= nil,
			"the field log must name the scroll guard gate with its measured value")
		helpers.assert_eq(#fires, 0,
			"fingers landing while the scroll's momentum still runs must not switch tabs; fired: "
				.. table.concat(fires, ", "))
	end)

	helpers.it("a three-finger touch during native momentum does not fire", function()
		local h = new_harness()
		-- kCGMomentumScrollPhaseContinue, as macOS sends after a flick.
		h.scroll_event(2)
		h.wait(0.05)
		three_finger_swipe(h)
		local fires = tab_fires(h.fired)
		local reason = h.rejection("scroll guard")
		h.finish()
		helpers.assert_true(reason ~= nil,
			"the field log must name the scroll guard gate with its measured value")
		helpers.assert_eq(#fires, 0,
			"a momentum scroll event seen by the scroll tap must hold three-finger swipes "
				.. "back; fired: " .. table.concat(fires, ", "))
	end)
end)





-- ================================================
-- ================================================
-- ======= 3/ Real Three-Finger Swipes Fire =======
-- ================================================
-- ================================================

helpers.describe("a deliberate three-finger swipe still switches tabs", function()
	helpers.it("three fingers landing together and swiping fire", function()
		local h = new_harness()
		three_finger_swipe(h)
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"a steady three-finger swipe must fire swipe_3_down; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("a third finger landing a frame late still makes the swipe", function()
		local h = new_harness()
		h.frame({ FINGER_A, FINGER_B }, nil, 0)
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		for i = 0, 30 do h.frame(hand, nil, i * STEP) end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"a staggered landing is still a three-finger swipe; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("fingers landing over 200 ms still make the swipe", function()
		local h = new_harness()
		-- One finger, the second a frame later, the third 200 ms after the
		-- second, the pair resting still in between.
		h.frame({ FINGER_A }, nil, 0)
		for _ = 1, 25 do h.frame({ FINGER_A, FINGER_B }, nil, 0) end
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		for i = 0, 30 do h.frame(hand, nil, i * STEP) end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"a slow landing of a still hand is a three-finger swipe; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("a third finger landing 40 ms late with the motion starting at once fires", function()
		local h = new_harness()
		for _ = 1, 5 do h.frame({ FINGER_A, FINGER_B }, nil, 0) end
		-- The hand starts moving on the very frame the third finger lands, at a
		-- brisk 125 units per second.
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		for i = 1, 25 do h.frame(hand, nil, i * 1.0) end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"the confirmation must not outlast the motion; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("a slow three-finger swipe fires", function()
		local h = new_harness()
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		-- 12 units over 1.2 s.
		for i = 0, 150 do h.frame(hand, nil, i * 0.08) end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"a slow swipe is still a swipe; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("a fast short three-finger flick fires", function()
		local h = new_harness()
		h.frame({ FINGER_A, FINGER_B }, nil, 0)
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		-- The third finger lands a frame late; 10 units in 40 ms, then the lift.
		for i = 0, 5 do h.frame(hand, nil, i * 2.0) end
		h.lift()
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"a flick lifts before any live fire and must fire at the commit; fired: "
				.. table.concat(h.fired, ", "))
	end)

	helpers.it("a two-finger touch that did not scroll arms no scroll guard", function()
		local h = new_harness()
		for _ = 1, 10 do h.frame({ FINGER_A, FINGER_B }, nil, 0) end
		h.lift()
		h.wait(0.05)
		three_finger_swipe(h)
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0,
			"only a real scroll arms the guard; a resting pair must not block the next swipe")
	end)

	helpers.it("a swipe once the scroll guard has expired fires", function()
		local h = new_harness()
		two_finger_scroll(h)
		h.wait(0.5)
		three_finger_swipe(h)
		local fires = tab_fires(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0,
			"the scroll guard must expire: a deliberate swipe half a second later fires")
	end)
end)
