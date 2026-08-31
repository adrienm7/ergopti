--- tests/unit/modules/test_gesture_pump_chain.lua

--- ==============================================================================
--- MODULE: Reader to Decoder to Action, Without a Touchpad
--- DESCRIPTION:
--- Drives `gestures.pump()` with a scripted event list and checks that a real
--- multitouch sequence ends in the bound action.
---
--- WHY THIS SEAM NEEDED ITS OWN TEST:
--- Every piece already had one. The decoder is tested against fixtures, the slot
--- naming against the declared slot space, the emit order against a fake device.
--- The feature would still not work if any two of them disagreed about a name,
--- and until now the only place they met was on a machine with a touchpad —
--- which is to say, nowhere this suite could reach.
---
--- The gesture round trip in tests/hardware covers the same join through a real
--- kernel. This one runs everywhere, on every distribution's LuaJIT, in a
--- millisecond, and fails with a message about which link broke rather than
--- "no touchpad".
---
--- WHY A SCRIPTED LIST AND NOT A REAL DEVICE:
--- The events ARE the contract. What the kernel adds — that it drops an EV_ABS
--- whose value has not changed, that a node needs the input group — belongs to
--- the hardware harness, and finding one of those there is precisely how this
--- division of labour earns itself.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")
local Decoder = helpers.load_module("modules.gestures.mt_decoder")

local BTN_TOUCH = 0x14a
local TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f, [5] = 0x148 }

--- The evdev events for one whole gesture, as the kernel would deliver them.
--- @param fingers integer
--- @param dx integer
--- @param dy integer
--- @return table
local function gesture_events(fingers, dx, dy)
	local events = {}
	local function push(t, c, v) events[#events + 1] = { type = t, code = c, value = v } end
	local base_x, base_y = 1000, 900

	for index = 0, fingers - 1 do
		push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_TRACKING_ID, 500 + index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200)
		push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y)
		if index > 0 then push(Decoder.EV_KEY, TOOL[index], 0) end
		push(Decoder.EV_KEY, TOOL[index + 1], 1)
		if index == 0 then push(Decoder.EV_KEY, BTN_TOUCH, 1) end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end

	for step = 1, 4 do
		for index = 0, fingers - 1 do
			push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
			push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200 + math.floor(dx * step / 4))
			push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y + math.floor(dy * step / 4))
		end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end

	for index = fingers - 1, 0, -1 do
		push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		push(Decoder.EV_KEY, TOOL[index + 1], 0)
		if index > 0 then push(Decoder.EV_KEY, TOOL[index], 1) end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end
	push(Decoder.EV_KEY, BTN_TOUCH, 0)
	push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)

	return events
end

--- Runs one gesture through the manager's own pump with faked adapters.
--- @param slot string The slot to bind.
--- @param events table
--- @return table fired The actions that ran, as {slot, action}.
local function pump_gesture(slot, events)
	local reader = Fakes.evdev_reader({ events = events })
	package.loaded["adapters.evdev_reader"] = reader

	local M = helpers.load_module("modules.gestures.manager")
	M.init({ enabled = false, persist = false })
	M.set_action(slot, "enter")

	local fired = {}
	local real_dispatch = M.dispatch_gesture
	M.dispatch_gesture = function(gesture)
		fired[#fired + 1] = gesture
		return real_dispatch(gesture)
	end

	-- The manager only pumps once start_reading() has opened a device. The finder
	-- needs a real /proc entry, so the reading state is set through the same
	-- public path a caller uses and the fake reader stands in for the device.
	reader.open("/dev/input/event-fake", reader.TOUCHPAD)
	M._test_begin_reading(Decoder.new())
	helpers.assert_true(M.enable(), "a live reader must enable dispatch before the pump runs")
	M.pump()

	package.loaded["adapters.evdev_reader"] = nil
	return fired
end




-- =================================================================
-- =================================================================
-- ======= 1/ The whole chain ======================================
-- =================================================================
-- =================================================================

helpers.describe("gesture pump: reader to decoder to action", function()

	helpers.it("turns a three-finger upward swipe into a dispatched gesture", function()
		local fired = pump_gesture("swipe_3_up", gesture_events(3, 0, -600))
		helpers.assert_eq(#fired, 1, "exactly one gesture out of one gesture in")
		helpers.assert_eq(fired[1].fingers, 3, "the count the events reported")
		helpers.assert_eq(fired[1].direction, "up",
			"evdev Y grows downward — a sign error here inverts every vertical gesture")
	end)

	helpers.it("turns a five-finger tap into a dispatched gesture", function()
		local fired = pump_gesture("tap_5", gesture_events(5, 0, 0))
		helpers.assert_eq(#fired, 1)
		helpers.assert_eq(fired[1].fingers, 5,
			"five is a count libinput cannot report at all, which is why this driver "
				.. "reads the device itself")
		helpers.assert_true(fired[1].tap)
	end)

	helpers.it("dispatches nothing when the fingers barely move and never lift", function()
		local partial = gesture_events(3, 0, -600)
		-- Everything except the lift: a gesture in progress is not a gesture.
		local truncated = {}
		for index = 1, #partial - 8 do truncated[index] = partial[index] end
		helpers.assert_eq(#pump_gesture("swipe_3_up", truncated), 0,
			"a gesture only exists once the last finger is up; firing early would "
				.. "act on a movement the user has not finished making")
	end)

end)
