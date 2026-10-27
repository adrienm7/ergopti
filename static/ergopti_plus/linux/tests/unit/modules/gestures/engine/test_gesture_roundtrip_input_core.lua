--- tests/unit/modules/gestures/engine/test_gesture_roundtrip_input_core.lua

--- ==============================================================================
--- MODULE: Gesture Round Trip Through An Emulated Input Core
--- DESCRIPTION:
--- The uinput round trip only runs on a CI runner that exposes /dev/uinput, so
--- a harness that writes a gesture the kernel would never deliver stayed green
--- on every host until that runner: the input core drops a report in which no
--- value changed, and a five-finger tap held still reached the decoder as one
--- frame at five, which the finger_join_frames gate refuses as a graze. This
--- replays the unchanged harness through tests/support/input_core_emulation.lua
--- on every host, and proves the emulation drops what the kernel drops.
--- ==============================================================================

local helpers = require("tests.helpers")
local Emulation = require("tests.support.input_core_emulation")

local HARNESS = require("infra.paths").driver_root() .. "/tests/hardware/run_gesture_roundtrip.lua"

--- Joins printed lines for a failure message.
--- @param lines string[]
--- @return string
local function transcript(lines)
	return table.concat(lines, "\n")
end

helpers.describe("gesture round trip through the emulated input core", function()
	helpers.it("every gesture the harness writes reaches the real decoder", function()
		local code, lines = Emulation.run(HARNESS, { advertise_msc = true })
		helpers.assert_eq(code, 0, transcript(lines))
		helpers.assert_true(transcript(lines):find("=== 10 check(s), 0 failure(s) ===", 1, true) ~= nil,
			"the swipe, the five-finger tap and the four-finger swipe all decode; got\n" .. transcript(lines))
	end)

	helpers.it("a still tap without per-report stamps collapses to one frame, as on the kernel", function()
		-- Control: the emulation must drop unchanged reports, or the case above
		-- would pass against a harness the real input core breaks.
		local code, lines = Emulation.run(HARNESS, { advertise_msc = false })
		helpers.assert_eq(code, 1, transcript(lines))
		helpers.assert_true(transcript(lines):find("FAIL a five-finger tap came back as a gesture", 1, true) ~= nil,
			"without MSC_TIMESTAMP the held five fingers yield no frame; got\n" .. transcript(lines))
	end)
end)
