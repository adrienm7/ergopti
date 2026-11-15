--- tests/unit/modules/gestures/engine/test_tap_detector.lua

--- ==============================================================================
--- MODULE: Touchpad Tap-To-Click Detection
--- DESCRIPTION:
--- libinput turns some touches into a click and the kernel never reports it.
--- These cases replay touchpad traces in `libinput record` format through
--- tap_detector and pin libinput's tap rules: 1/2/3-finger taps within the
--- 180 ms timer and the 1.3 mm motion threshold count, a rest, a pointer
--- motion, the drag of a tap-and-drag, a button press, a fourth finger, a
--- finger landing after a lift and a stale timer do not.
--- ==============================================================================

local helpers = require("tests.helpers")

local Detector = helpers.load_module("modules.gestures.tap_detector")
local Record = helpers.load_module("tests.support.touchpad_record")

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SLOT, TRACKING, POS_X, POS_Y = 0x2f, 0x39, 0x35, 0x36
local BTN_TOUCH, TOOL = 0x14a, { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f }

--- Reads a fixture of tests/fixtures.
--- @param name string
--- @return string text
local function fixture(name)
	local file = assert(io.open(helpers.driver_root() .. "/tests/fixtures/" .. name, "rb"))
	local text = file:read("*a")
	file:close()
	return text
end

--- The finger counts a fixture declares on its `# ergopti-expect-taps:` line.
--- @param text string
--- @return table counts
local function expected_taps(text)
	local line = assert(text:match("# ergopti%-expect%-taps:%s*([%d ]+)"), "the trace declares its taps")
	local counts = {}
	for count in line:gmatch("%d") do counts[#counts + 1] = tonumber(count) end
	return counts
end

--- Replays a trace through a detector and returns every tap's finger count.
--- @param trace table A decoded trace.
--- @param units number Units per millimetre on both axes.
--- @return table counts
local function replay(trace, units)
	local detector, counts = Detector.new({ units_x = units, units_y = units }), {}
	for _, event in ipairs(trace.events) do
		local fingers = detector.feed(event)
		if fingers then counts[#counts + 1] = fingers end
	end
	return counts
end

--- One touch: fingers land at once, stay `hold_ms`, each moving `travel` units
--- along x by the end, and lift at once. 10 ms frames.
--- @return table events
local function touch(fingers, hold_ms, travel, start_us)
	local base = start_us or 1000000
	local events, now = {}, base
	local function push(kind, code, value) events[#events + 1] = { type = kind, code = code, value = value, timestamp_us = now } end
	for index = 0, fingers - 1 do
		push(EV_ABS, SLOT, index); push(EV_ABS, TRACKING, 10 + index)
		push(EV_ABS, POS_X, 100 + index * 200); push(EV_ABS, POS_Y, 300)
	end
	push(EV_KEY, BTN_TOUCH, 1); push(EV_KEY, TOOL[fingers], 1); push(EV_SYN, 0, 0)
	-- Frames every 10 ms; the last one before the lift has the whole travel.
	local frames = math.max(2, math.floor(hold_ms / 10))
	for frame = 1, frames - 1 do
		now = base + math.floor(hold_ms * 1000 * frame / frames)
		for index = 0, fingers - 1 do
			push(EV_ABS, SLOT, index); push(EV_ABS, POS_X, 100 + index * 200 + math.floor(travel * frame / (frames - 1)))
		end
		push(EV_SYN, 0, 0)
	end
	now = base + hold_ms * 1000
	for index = 0, fingers - 1 do push(EV_ABS, SLOT, index); push(EV_ABS, TRACKING, -1) end
	push(EV_KEY, TOOL[fingers], 0); push(EV_KEY, BTN_TOUCH, 0); push(EV_SYN, 0, 0)
	return events
end

--- Feeds events to a fresh 10-units-per-mm detector.
--- @return table counts
local function feed(events)
	return replay({ events = events }, 10)
end

helpers.describe("tap detector: libinput's tap rules on a recorded trace", function()
	helpers.it("(tap-click) a libinput record decodes into the taps it declares", function()
		local text = fixture("tap_click_record_synaptics.yml")
		local trace = assert(Record.decode(text))
		helpers.assert_eq(trace.name, "SYNA8004:00 06CB:CD8B Touchpad")
		-- The trace's pad: 1250 x 800 units at 12 units per millimetre.
		helpers.assert_eq(replay(trace, 12), expected_taps(text),
			"one, two, three fingers, then the tap of the tap-and-drag and the two of the double tap")
	end)

	helpers.it("(tap-click) the same trace through the binary evdev reader gives the same taps", function()
		local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
		local reader = helpers.load_module("platform.input.evdev_reader")
		local codec = require("platform.input.event")
		local text = fixture("tap_click_record_synaptics.yml")
		local trace = assert(Record.decode(text))
		local pending, cursor = {}, 1
		for _, event in ipairs(trace.events) do
			pending[#pending + 1] = codec.encode(event.type, event.code, event.value, codec.native_size(), event.timestamp_us)
		end
		reader._set_backend({
			open = function() return 77 end,
			read = function(_, count)
				local bytes = pending[cursor]
				if not bytes then return nil, "would_block" end
				helpers.assert_eq(#bytes, count); cursor = cursor + 1; return bytes
			end,
			close = function() return true end,
		})
		local detector, counts = Detector.new({ units_x = 12, units_y = 12 }), {}
		local ok, detail = xpcall(function()
			helpers.assert_eq(reader.open("/controlled/recorded-touchpad", reader.TOUCHPAD), true)
			-- The reader drains a bounded batch per call, as the daemon's tick does.
			repeat
				local drained = reader.drain(function(event)
					local fingers = detector.feed(event)
					if fingers then counts[#counts + 1] = fingers end
				end, reader.TOUCHPAD)
			until not drained or drained == 0
			helpers.assert_eq(reader.close(reader.TOUCHPAD), true)
		end, debug.traceback)
		reader._reset_backend()
		for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(saved) do package.loaded[name] = value end
		if not ok then error(detail, 0) end
		helpers.assert_eq(cursor - 1, #pending, "every recorded event was read")
		helpers.assert_eq(counts, expected_taps(text), "the kernel's stamps survive the binary decode")
	end)
end)

helpers.describe("tap detector: the thresholds", function()
	helpers.it("(tap-click) the timer counts from the last finger landing: 180 ms taps, 190 ms does not", function()
		helpers.assert_eq(feed(touch(1, 180, 0)), { 1 })
		helpers.assert_eq(feed(touch(1, 190, 0)), {})
		helpers.assert_eq(feed(touch(3, 170, 0)), { 3 })
	end)

	helpers.it("(tap-click) a finger moving 1.3 mm still taps, 1.4 mm is motion", function()
		helpers.assert_eq(feed(touch(1, 100, 13)), { 1 }, "13 units at 10 units/mm")
		helpers.assert_eq(feed(touch(1, 100, 14)), {})
		helpers.assert_eq(feed(touch(2, 100, 14)), {}, "two moving fingers are a scroll")
	end)

	helpers.it("(tap-click) four fingers never tap", function()
		helpers.assert_eq(feed(touch(4, 80, 0)), {})
	end)

	helpers.it("(tap-click) a physical button pressed during the touch kills the tap", function()
		local events = touch(1, 80, 0)
		table.insert(events, #events - 4, { type = EV_KEY, code = 0x110, value = 1, timestamp_us = 1040000 })
		helpers.assert_eq(feed(events), {})
	end)

	helpers.it("(tap-click) a touch straddling SYN_DROPPED is no tap, the next one is", function()
		local events = touch(1, 80, 0)
		table.insert(events, 6, { type = EV_SYN, code = 3, value = 0, timestamp_us = 1000000 })
		for _, event in ipairs(touch(1, 80, 0, 3000000)) do events[#events + 1] = event end
		helpers.assert_eq(feed(events), { 1 })
	end)

	helpers.it("(tap-click) a touchscreen, which reports no BTN_TOOL_* finger count, never taps", function()
		local events = {}
		for _, event in ipairs(touch(2, 80, 0)) do
			if event.code ~= TOOL[2] or event.type ~= EV_KEY then events[#events + 1] = event end
		end
		helpers.assert_eq(feed(events), {})
	end)

	helpers.it("(tap-click) a pad without resolution gets libinput's 69 x 50 mm", function()
		local x, y = Detector.units_per_mm({ x = { minimum = 0, maximum = 1380, resolution = 0 },
			y = { minimum = 0, maximum = 1000, resolution = 0 } })
		helpers.assert_eq(x, 20); helpers.assert_eq(y, 20)
		local rx = Detector.units_per_mm({ x = { minimum = 0, maximum = 1380, resolution = 12 },
			y = { minimum = 0, maximum = 1000, resolution = 12 } })
		helpers.assert_eq(rx, 12, "a reported resolution wins")
		helpers.assert_nil(Detector.units_per_mm({ x = { minimum = 0, maximum = 0, resolution = 0 },
			y = { minimum = 0, maximum = 1000, resolution = 0 } }))
	end)

	helpers.it("(tap-click) the button maps: lrm by default, lmr swaps middle and right", function()
		helpers.assert_eq(Detector.button_for(1, Detector.MAP_LRM), "left")
		helpers.assert_eq(Detector.button_for(2, Detector.MAP_LRM), "right")
		helpers.assert_eq(Detector.button_for(3, Detector.MAP_LRM), "middle")
		helpers.assert_eq(Detector.button_for(2, Detector.MAP_LMR), "middle")
		helpers.assert_eq(Detector.button_for(3, Detector.MAP_LMR), "right")
	end)
end)
