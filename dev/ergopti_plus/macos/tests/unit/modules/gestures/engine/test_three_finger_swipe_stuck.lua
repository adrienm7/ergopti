--- tests/unit/modules/gestures/engine/test_three_finger_swipe_stuck.lua

--- ==============================================================================
--- MODULE: Regression — deliberate three-finger swipes keep being accepted
---         (three-finger-swipe-stuck)
--- DESCRIPTION:
--- On the maintainer's Mac (2026-10-28 field report) the vertical three-finger
--- swipe (tab_prev / tab_next) worked, then was refused for a while in a row
--- while two-finger scrolling kept working. Each case replays a frame sequence
--- from that log.
---
--- ROOT CAUSES ENCODED:
--- 1. Frames were timed when Lua processed them. The touch device queues frames
---    while the main thread is busy and delivers them in one burst, so 35 frames
---    held over 280 ms read as 2 ms and failed the 20 ms join confirmation, and a
---    late thumb could pass the landing window the same way.
--- 2. The momentum macOS emits after a swipe's last two fingers lift continued a
---    scroll the blocker had swallowed: the swipe's own tail re-armed the scroll
---    guard, so every swipe started within its momentum was refused, which made
---    the next one refused too.
--- 3. A finger-count cascade (4 -> 3 -> 2) measured the pair's travel from the
---    three-finger centroid, so the centroid jump alone aborted the gesture.
--- 4. An aborted swipe that had already fired armed the scroll guard, and
---    its pair tail was let through to scroll the page it had just switched to.
--- 5. An aborted gesture stayed aborted while one finger rested, silently
---    refusing every swipe until the whole hand lifted.
--- 6. A direction locking on the frame the third finger was confirmed logged
---    "cohesion: least contact share 0.00" before any contact could move.
--- The two-finger scroll guarantees of three-finger-swipe-vs-scroll still hold.
--- ==============================================================================

local helpers = require("tests.helpers")

-- About 125 Hz, the rate the touch device reports frames at.
local FRAME_DT_SEC = 0.008
-- Distance three fingers travel per frame in a steady swipe.
local STEP = 0.6

local FINGER_A = { x = 40, y = 50 }
local FINGER_B = { x = 50, y = 50 }
local FINGER_C = { x = 60, y = 50 }
local FINGER_D = { x = 70, y = 50 }
local THUMB    = { x = 45, y = 20 }

-- Quartz phases the scroll tap reads.
local SCROLL_CHANGED   = 2
local MOMENTUM_BEGIN   = 1
local MOMENTUM_CONTINUE = 2

-- The recommended macOS bindings, plus taps so a lost commit is observable.
local GESTURES = {
	swipe_2_up = "none", swipe_2_down = "none", swipe_2_left = "none", swipe_2_right = "none",
	swipe_3_up = "tab_prev", swipe_3_down = "tab_next",
	swipe_3_left = "none", swipe_3_right = "none",
	swipe_4_up = "none", swipe_4_down = "none", swipe_4_left = "none", swipe_4_right = "none",
	tap_2 = "none", tap_3 = "none", tap_4 = "app_expose", tap_5 = "none",
}
local WATCHED_ACTIONS = { tab_prev = true, tab_next = true, app_expose = true }





-- =================================
-- =================================
-- ======= 1/ Engine Harness =======
-- =================================
-- =================================

--- Builds a fresh engine whose capture and delivery clocks are driven apart.
--- @return table harness
local function new_harness()
	local hs = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local saved_absolute = hs.timer.absoluteTime
	local saved_scheduler = package.loaded["adapters.timer_scheduler"]
	local saved_timings = package.loaded["infra.timings"]
	local saved_logger = package.loaded["infra.logger"]
	local debug_lines = {}
	local real_logger = require("infra.logger")
	local function record(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		debug_lines[#debug_lines + 1] = ok and line or tostring(fmt)
	end
	package.loaded["infra.logger"] = setmetatable({
		debug = function(module_name, fmt, ...)
			record(fmt, ...)
			return real_logger.debug(module_name, fmt, ...)
		end,
		info = function(module_name, fmt, ...)
			record(fmt, ...)
			return real_logger.info(module_name, fmt, ...)
		end,
	}, { __index = real_logger })
	-- The delivery clock is the awake time Lua reads; the stamp is the device's
	-- own capture time, on an unrelated origin as on the real touch device.
	local delivery = 1000.0
	local stamp = 5.0
	local queued = nil
	hs.timer.secondsSinceEpoch = function() return delivery end
	hs.timer.absoluteTime = function() return delivery * 1e9 end
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["modules.gestures.frame_clock"] = nil
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

	local harness = { fired = fired, debug_lines = debug_lines, Engine = Engine }

	--- Finds the first recorded line containing a needle.
	--- @param needle string
	--- @return string|nil
	function harness.line(needle)
		for _, line in ipairs(debug_lines) do
			if line:find(needle, 1, true) then return line end
		end
		return nil
	end

	--- Finds the first rejection line naming a gate.
	--- @param gate string
	--- @return string|nil
	function harness.rejection(gate)
		return harness.line("Three-finger candidate rejected by " .. gate .. ":")
	end

	--- Advances both clocks, or only the capture clock while a burst is queued.
	--- @param seconds number
	local function advance(seconds)
		stamp = stamp + seconds
		if not queued then delivery = delivery + seconds end
	end

	--- Processes one frame now, or queues it behind the stalled main thread.
	--- @param touches table
	local function deliver(touches)
		if queued then
			queued[#queued + 1] = { touches = touches, stamp = stamp }
		else
			Engine.process_frame(touches, stamp)
		end
	end

	--- Plays one frame of contacts, each moving contact offset by `dy`.
	--- @param contacts table Array of { x, y } base positions.
	--- @param moving table|nil Set of indices that travel; nil means all of them.
	--- @param dy number Offset of the travelling contacts.
	function harness.frame(contacts, moving, dy)
		local touches = {}
		for i, c in ipairs(contacts) do
			local offset = (moving == nil or moving[i]) and dy or 0
			touches[#touches + 1] = { absoluteVector = { position = { x = c.x, y = c.y + offset } } }
		end
		deliver(touches)
		advance(FRAME_DT_SEC)
	end

	--- Lifts every finger.
	function harness.lift()
		deliver({})
		advance(FRAME_DT_SEC)
	end

	--- Lets time pass with no frame.
	--- @param seconds number
	function harness.wait(seconds)
		advance(seconds)
	end

	--- Queues the following frames: the main thread is stalled, so they are all
	--- processed together once it is free. As in the field, the device was
	--- already streaming promptly delivered frames before the stall.
	function harness.begin_burst()
		harness.lift()
		queued = {}
	end

	--- Ends a stall: the delivery clock catches up with the capture clock and
	--- every queued frame is processed at that one delivery time.
	function harness.end_burst()
		local frames = queued
		queued = nil
		delivery = delivery + (stamp - frames[1].stamp)
		for _, f in ipairs(frames) do Engine.process_frame(f.touches, f.stamp) end
	end

	--- Delivers one native scroll event to the engine's scroll tap.
	--- @param scroll_phase number Quartz scroll phase.
	--- @param momentum_phase number Quartz momentum phase.
	--- @return boolean swallowed Whether the tap swallowed it.
	function harness.scroll_event(scroll_phase, momentum_phase)
		local properties = hs.eventtap.event.properties
		return tap.fn({
			getProperty = function(_, prop)
				if prop == properties.scrollWheelEventScrollPhase then return scroll_phase end
				if prop == properties.scrollWheelEventMomentumPhase then return momentum_phase end
				return 0
			end,
		})
	end

	--- Restores the clocks and drops the engine instance.
	function harness.finish()
		Engine.stop()
		hs.timer.secondsSinceEpoch = saved_clock
		hs.timer.absoluteTime = saved_absolute
		package.loaded["adapters.timer_scheduler"] = saved_scheduler
		package.loaded["infra.timings"] = saved_timings
		package.loaded["infra.logger"] = saved_logger
		package.loaded["modules.gestures.engine"] = nil
		package.loaded["modules.gestures.frame_clock"] = nil
	end

	return harness
end

--- Plays a steady three-finger downward swipe, without lifting.
--- @param h table Harness.
--- @param frames number|nil Frame count (31 by default).
local function swipe_frames(h, frames)
	local hand = { FINGER_A, FINGER_B, FINGER_C }
	for i = 0, (frames or 30) do h.frame(hand, nil, i * STEP) end
end

--- Lists the watched actions fired.
--- @param fired table Array of action names.
--- @return table
local function watched(fired)
	local out = {}
	for _, a in ipairs(fired) do
		if WATCHED_ACTIONS[a] then out[#out + 1] = a end
	end
	return out
end

--- Counts the watched actions fired since an index.
--- @param fired table
--- @param since number Count before the part under test.
--- @return number
local function fires_since(fired, since)
	return #watched(fired) - since
end





-- =================================================
-- =================================================
-- ======= 2/ Frames Are Timed When Captured =======
-- =================================================
-- =================================================

helpers.describe("gesture timing follows the touch frame's capture time (three-finger-swipe-stuck)", function()
	helpers.it("a staggered swipe delivered in one burst still fires", function()
		local h = new_harness()
		-- The field log: the main thread stalls and 35 queued frames are
		-- processed within 2 ms, the third finger landing a frame after the pair.
		h.begin_burst()
		h.frame({ FINGER_A, FINGER_B }, nil, 0)
		swipe_frames(h, 34)
		h.end_burst()
		h.lift()
		local fires = watched(h.fired)
		local reason = h.rejection("frames held")
		h.finish()
		helpers.assert_eq(reason, nil,
			"35 frames over 280 ms of capture time are held, whatever their delivery: " .. tostring(reason))
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"the swipe the user made during the stall must fire; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("a thumb landing late is refused even when its frames arrive in a burst", function()
		local h = new_harness()
		-- The pair rests 400 ms, longer than the landing window, then a thumb
		-- lands and the hand moves: all of it queued behind a stalled main thread.
		h.begin_burst()
		for _ = 1, 50 do h.frame({ FINGER_A, FINGER_B }, nil, 0) end
		for i = 1, 30 do h.frame({ FINGER_A, FINGER_B, THUMB }, nil, i * STEP) end
		h.end_burst()
		h.lift()
		local fires = watched(h.fired)
		local reason = h.rejection("landing window")
		h.finish()
		helpers.assert_true(reason ~= nil,
			"the landing window is measured on capture time and must refuse the late contact")
		helpers.assert_eq(#fires, 0, "fired: " .. table.concat(fires, ", "))
	end)

	helpers.it("a one-frame palm spike in a burst is still refused", function()
		local h = new_harness()
		local pair = { FINGER_A, FINGER_B }
		h.begin_burst()
		h.frame(pair, nil, 0)
		h.frame({ FINGER_A, FINGER_B, THUMB }, { true, true, false }, STEP)
		for i = 2, 7 do h.frame(pair, nil, i * STEP) end
		h.end_burst()
		h.lift()
		local fires = watched(h.fired)
		h.finish()
		helpers.assert_eq(#fires, 0, "fired: " .. table.concat(fires, ", "))
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 3/ A Swipe's Own Tail Never Arms the Guard =======
-- ==========================================================
-- ==========================================================

helpers.describe("the scroll guard follows only a real scroll (three-finger-swipe-stuck)", function()
	helpers.it("momentum after a swipe whose scroll was swallowed does not refuse the next swipe", function()
		local h = new_harness()
		-- First swipe: macOS reads the hand as a scroll, and the blocker swallows
		-- its phases while three fingers are down.
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		for i = 0, 20 do
			h.frame(hand, nil, i * STEP)
			if i > 2 then
				helpers.assert_true(h.scroll_event(SCROLL_CHANGED, 0) == true,
					"the blocker must swallow the swipe's scroll phases")
			end
		end
		h.lift()
		local first = #watched(h.fired)
		helpers.assert_true(first > 0, "the first swipe must fire")
		-- macOS then emits momentum for the swallowed scroll, up to the moment the
		-- next swipe lands, 150 ms later.
		h.scroll_event(0, MOMENTUM_BEGIN)
		for _ = 1, 18 do
			h.wait(FRAME_DT_SEC)
			h.scroll_event(0, MOMENTUM_CONTINUE)
		end
		swipe_frames(h)
		h.lift()
		local reason = h.rejection("scroll guard")
		local more = fires_since(h.fired, first)
		h.finish()
		helpers.assert_eq(reason, nil, "the swipe's own momentum armed the guard: " .. tostring(reason))
		helpers.assert_true(more > 0, "a second swipe right after the first must fire")
	end)

	helpers.it("momentum after a real two-finger scroll still refuses a three-finger landing", function()
		local h = new_harness()
		local pair = { FINGER_A, FINGER_B }
		for i = 0, 30 do
			h.frame(pair, nil, i * STEP)
			helpers.assert_true(h.scroll_event(SCROLL_CHANGED, 0) == false,
				"a two-finger scroll is native and passes the blocker")
		end
		h.lift()
		h.scroll_event(0, MOMENTUM_BEGIN)
		h.wait(0.05)
		h.scroll_event(0, MOMENTUM_CONTINUE)
		swipe_frames(h)
		h.lift()
		local fires = watched(h.fired)
		local reason = h.rejection("scroll guard")
		h.finish()
		helpers.assert_true(reason ~= nil, "landing on a native momentum scroll must name the scroll guard")
		helpers.assert_eq(#fires, 0, "fired: " .. table.concat(fires, ", "))
	end)

	helpers.it("a swipe that fired and ends as a moving pair keeps its tail and arms no guard", function()
		local h = new_harness()
		swipe_frames(h, 20)
		local first = #watched(h.fired)
		helpers.assert_true(first > 0, "the first swipe must fire live")
		-- The third finger lifts while the other two keep travelling.
		for i = 21, 30 do h.frame({ FINGER_A, FINGER_B }, nil, i * STEP) end
		local blocking_tail = h.Engine.is_blocking_scroll()
		h.lift()
		h.wait(0.1)
		swipe_frames(h)
		h.lift()
		local reason = h.rejection("scroll guard")
		local more = fires_since(h.fired, first)
		h.finish()
		helpers.assert_true(blocking_tail,
			"the pair left by a swipe that already switched tabs must not scroll the new tab")
		helpers.assert_eq(reason, nil, "a fired swipe's tail is not a scroll: " .. tostring(reason))
		helpers.assert_true(more > 0, "the next swipe 100 ms later must fire")
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 4/ No Gesture State Outlives Its Hand =======
-- =====================================================
-- =====================================================

helpers.describe("a refused gesture leaves nothing armed (three-finger-swipe-stuck)", function()
	helpers.it("a staggered four-finger lift is not a moving pair", function()
		local h = new_harness()
		local hand = { FINGER_A, FINGER_B, FINGER_C, FINGER_D }
		for _ = 1, 5 do h.frame(hand, nil, 0) end
		-- Fingers leave one per frame: four, three, then two still fingers.
		h.frame({ FINGER_A, FINGER_B, FINGER_C }, nil, 0)
		h.frame({ FINGER_A, FINGER_B }, nil, 0)
		h.lift()
		local fires = watched(h.fired)
		local aborted = h.line("Gesture aborted")
		h.finish()
		helpers.assert_eq(aborted, nil, "the centroid jump of a cascade is not pair travel: " .. tostring(aborted))
		helpers.assert_true(#fires == 1 and fires[1] == "app_expose",
			"the four-finger tap must commit; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("an aborted gesture ends when the hand drops to one resting finger", function()
		local h = new_harness()
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		-- A grazing third contact, then a two-finger flick: aborted by design.
		for _ = 1, 3 do h.frame(hand, nil, 0) end
		for i = 1, 6 do h.frame({ FINGER_A, FINGER_B }, nil, i * 0.8) end
		helpers.assert_true(h.line("Gesture aborted") ~= nil, "the flick must abort as before")
		-- One finger stays on the pad for 300 ms, then three fingers swipe.
		for _ = 1, 38 do h.frame({ FINGER_A }, nil, 0) end
		swipe_frames(h)
		h.lift()
		local fires = watched(h.fired)
		h.finish()
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"a resting finger must not keep the aborted state; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("a swipe that locks on its promotion frame is not refused by cohesion", function()
		local h = new_harness()
		-- The pair drifts 2 units (below its own lock distance) while the third
		-- finger lands, so the direction locks on the very frame the third finger
		-- is confirmed, before any contact moved since that promotion.
		for i = 0, 4 do h.frame({ FINGER_A, FINGER_B }, nil, i * 0.5) end
		local hand = { FINGER_A, FINGER_B, FINGER_C }
		for _ = 1, 4 do h.frame(hand, { true, true, true }, 2.0) end
		for i = 1, 20 do h.frame(hand, nil, 2.0 + i * STEP) end
		h.lift()
		local fires = watched(h.fired)
		local reason = h.rejection("cohesion")
		h.finish()
		helpers.assert_eq(reason, nil, "no travel since the promotion is not a refusal yet: " .. tostring(reason))
		helpers.assert_true(#fires > 0 and fires[1] == "tab_next",
			"the swipe must fire; fired: " .. table.concat(h.fired, ", "))
	end)

	helpers.it("a thumb resting beside two scrolling fingers still never fires", function()
		local h = new_harness()
		h.frame({ FINGER_A, FINGER_B }, nil, 0)
		for i = 1, 40 do
			h.frame({ FINGER_A, FINGER_B, THUMB }, { true, true, false }, i * STEP)
		end
		h.lift()
		local fires = watched(h.fired)
		h.finish()
		helpers.assert_eq(#fires, 0, "fired: " .. table.concat(fires, ", "))
	end)
end)
