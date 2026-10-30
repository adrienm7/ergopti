--- tests/unit/modules/gestures/engine/test_touchpad_record.lua

--- ==============================================================================
--- MODULE: Touchpad Traces in libinput record Format
--- DESCRIPTION:
--- The decoder's fixtures are a reconstruction of the kernel protocol. A trace
--- recorded with `libinput record` on a real touchpad is a capture; this suite
--- proves the reader of that format and replays every trace kept under
--- tests/fixtures/touchpad_records against the real decoder.
---
--- WHAT IS STILL MISSING:
--- No trace from a physical touchpad is in the tree yet: that needs a Linux
--- machine (HARDWARE.md, "Record a touchpad trace"). The kernel round trip
--- (tests/hardware/run_gesture_roundtrip.lua) replays its own capture through
--- this reader, so the format is checked against what a kernel delivers.
--- ==============================================================================

local helpers = require("tests.helpers")

local Decoder = helpers.load_module("modules.gestures.mt_decoder")
local Record = helpers.load_module("tests.support.touchpad_record")

local EV_SYN, EV_KEY, EV_ABS = Decoder.EV_SYN, Decoder.EV_KEY, Decoder.EV_ABS
local TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f, [5] = 0x148 }

-- The layout `libinput record` prints: header, device description, then one
-- `- evdev:` block per frame with an explanatory comment after each row.
local LIBINPUT_LAYOUT = [[
version: 1
ndevices: 1
libinput:
  version: "1.25.0"
  git: "unknown"
system:
  os: "ubuntu:24.04"
  kernel: "6.8.0-45-generic"
  dmi: "dmi:bvnLENOVO:bvrN32ET:svnLENOVO"
devices:
- node: /dev/input/event7
  evdev:
    # Name: SYNA8004:00 06CB:CD8B Touchpad
    # ID: bus 0x18 vendor 0x6cb product 0xcd8b version 0x100
    name: "SYNA8004:00 06CB:CD8B Touchpad"
    id: [24, 1739, 52619, 256]
    codes:
      0: [0, 1, 2, 3, 4] # EV_SYN
    properties: [0, 2, 4]
  events:
  # Current time is 13:55:58
  - evdev:
    - [  0,      0,   3,  57,     218] # EV_ABS / ABS_MT_TRACKING_ID      218
    - [  0,      0,   3,  53,     573] # EV_ABS / ABS_MT_POSITION_X       573
    - [  0,      0,   1, 330,       1] # EV_KEY / BTN_TOUCH                 1
    - [  0,      0,   0,   0,       0] # ------------ SYN_REPORT (0) ---------- +0ms
  - evdev:
    - [  0,   7160,   3,  53,     575] # EV_ABS / ABS_MT_POSITION_X       575 (+2)
    - [  0,   7160,   3,  57,      -1] # EV_ABS / ABS_MT_TRACKING_ID       -1
    - [  0,   7160,   0,   0,       0] # ------------ SYN_REPORT (0) ---------- +7ms
]]

--- The frames of one gesture, stamped 10 ms apart: fingers land one at a time,
--- travel together by (dx, dy) and lift one at a time, as the kernel reports it.
--- @param fingers integer
--- @param dx integer
--- @param dy integer
--- @param start_us integer
--- @return table events
local function gesture(fingers, dx, dy, start_us)
	local events, now = {}, start_us
	local function push(kind, code, value) events[#events + 1] = { type = kind, code = code, value = value, timestamp_us = now } end
	local function sync() push(EV_SYN, Decoder.SYN_REPORT, 0); now = now + 10000 end
	for index = 0, fingers - 1 do
		push(EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(EV_ABS, Decoder.ABS_MT_TRACKING_ID, 100 + index)
		push(EV_ABS, Decoder.ABS_MT_POSITION_X, 1000 + index * 200)
		push(EV_ABS, Decoder.ABS_MT_POSITION_Y, 1000)
		if index > 0 then push(EV_KEY, TOOL[index], 0) end
		push(EV_KEY, TOOL[index + 1], 1)
		if index == 0 then push(EV_KEY, Decoder.BTN_TOUCH, 1) end
		sync()
	end
	for _ = 1, 3 do sync() end
	for step = 1, 4 do
		for index = 0, fingers - 1 do
			push(EV_ABS, Decoder.ABS_MT_SLOT, index)
			push(EV_ABS, Decoder.ABS_MT_POSITION_X, 1000 + index * 200 + math.floor(dx * step / 4))
			push(EV_ABS, Decoder.ABS_MT_POSITION_Y, 1000 + math.floor(dy * step / 4))
		end
		sync()
	end
	for index = fingers - 1, 0, -1 do
		push(EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		push(EV_KEY, TOOL[index + 1], 0)
		if index > 0 then push(EV_KEY, TOOL[index], 1) end
		sync()
	end
	push(EV_KEY, Decoder.BTN_TOUCH, 0)
	sync()
	return events
end

--- A decoder whose wall clock must never be read: every frame carries a stamp.
--- @return table
local function stamped_decoder()
	return Decoder.new({ now_sec = function() error("a recorded frame was timed by the wall clock") end })
end




-- =================================================================
-- =================================================================
-- ======= 1/ The format ===========================================
-- =================================================================
-- =================================================================

helpers.describe("touchpad record: reading libinput record", function()

	helpers.it("reads the device name and every evdev row of a libinput record", function()
		local trace = assert(Record.decode(LIBINPUT_LAYOUT))
		helpers.assert_eq(trace.name, "SYNA8004:00 06CB:CD8B Touchpad")
		helpers.assert_eq(#trace.events, 7, "the codes table and the comments are not events")
		helpers.assert_eq(trace.events[2].value, 573)
		helpers.assert_eq(trace.events[6].value, -1, "a negative value is kept")
		helpers.assert_eq(trace.events[5].timestamp_us - trace.events[4].timestamp_us, 7160,
			"the interval between frames is the recorded one")
		helpers.assert_true(trace.events[1].timestamp_us > 0, "a 0 stamp would be read as unstamped")
	end)

	helpers.it("refuses a record of several devices, an empty one and a malformed row", function()
		helpers.assert_eq(select(2, Record.decode(LIBINPUT_LAYOUT:gsub("ndevices: 1", "ndevices: 2"))),
			"a record must hold exactly one device")
		helpers.assert_eq(select(2, Record.decode(LIBINPUT_LAYOUT:gsub("version: 1\n", "version: 2\n", 1))),
			"not a version 1 libinput record")
		local empty = LIBINPUT_LAYOUT:gsub("  events:.*$", "  events:\n")
		helpers.assert_eq(select(2, Record.decode(empty)), "the record holds no evdev event")
		local broken = LIBINPUT_LAYOUT:gsub("%[  0,   7160,   3,  53,     575%]", "[  0, 7160, 3 ]")
		helpers.assert_true(tostring(select(2, Record.decode(broken))):find("malformed evdev row", 1, true) ~= nil)
	end)

	helpers.it("writes a record it reads back event for event, with its expectations", function()
		local events = gesture(3, 0, -600, 5000000)
		local text = Record.encode("Ergopti Pad", events, { { fingers = 3, direction = "up", tap = false } })
		local trace = assert(Record.decode(text))
		helpers.assert_eq(trace.name, "Ergopti Pad")
		helpers.assert_eq(#trace.events, #events)
		for index, event in ipairs(events) do
			local back = trace.events[index]
			helpers.assert_true(back.type == event.type and back.code == event.code and back.value == event.value,
				"event " .. index .. " differs after the round trip")
			helpers.assert_eq(back.timestamp_us - trace.events[1].timestamp_us, event.timestamp_us - events[1].timestamp_us)
		end
		helpers.assert_eq(#trace.expected, 1)
		helpers.assert_eq(trace.expected[1].fingers, 3)
		helpers.assert_eq(trace.expected[1].direction, "up")
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 2/ Replaying traces into the decoder ====================
-- =================================================================
-- =================================================================

--- Compares the gestures a replay produced with a trace's expectations.
--- @param label string
--- @param got table
--- @param expected table
local function assert_gestures(label, got, expected)
	helpers.assert_eq(#got, #expected, label .. ": gesture count")
	for index, want in ipairs(expected) do
		helpers.assert_eq(got[index].fingers, want.fingers, label .. ": fingers of gesture " .. index)
		helpers.assert_eq(got[index].tap == true, want.tap == true, label .. ": tap of gesture " .. index)
		if not want.tap then
			helpers.assert_eq(got[index].direction, want.direction, label .. ": direction of gesture " .. index)
		end
	end
end

helpers.describe("touchpad record: replaying into the decoder", function()

	helpers.it("(touchpad-record) a recorded session decodes into its gestures on recorded time", function()
		local events = {}
		local sessions = { { 3, 0, -600 }, { 4, 600, 0 }, { 5, 0, 0 } }
		local start = 2000000
		for _, spec in ipairs(sessions) do
			for _, event in ipairs(gesture(spec[1], spec[2], spec[3], start)) do events[#events + 1] = event end
			start = events[#events].timestamp_us + 2000000
		end
		local trace = assert(Record.decode(Record.encode("Session", events)))
		assert_gestures("session", Record.replay(stamped_decoder(), trace), {
			{ fingers = 3, direction = "up" }, { fingers = 4, direction = "right" }, { fingers = 5, tap = true },
		})
	end)

	helpers.it("(touchpad-record) every kept trace decodes into the gestures it declares", function()
		local directory = helpers.driver_root() .. "/tests/fixtures/touchpad_records"
		local Directory = require("infra.native_directory")
		helpers.assert_eq(Directory.kind(directory), "directory", "the trace directory is kept, with its README")
		local readme = false
		for _, entry in ipairs(assert(Directory.entries(directory))) do
			local name = entry.name
			if name == "README.md" then readme = true; goto continue end
			helpers.assert_true(name:match("%.yml$") ~= nil, "only libinput record files are kept here: " .. name)
			local file = assert(io.open(directory .. "/" .. name, "rb"))
			local trace, reason = Record.decode(file:read("*a"))
			file:close()
			helpers.assert_true(trace ~= nil, name .. ": " .. tostring(reason))
			helpers.assert_true(#trace.expected > 0, name .. " must declare its gestures with # ergopti-expect:")
			assert_gestures(name, Record.replay(stamped_decoder(), trace), trace.expected)
			::continue::
		end
		helpers.assert_true(readme, "the README saying how to add a trace is listed")
	end)
end)
