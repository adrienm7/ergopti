--- tests/unit/core/lifecycle/test_absolute_motion.lua

--- ==============================================================================
--- MODULE: Absolute Pointer Motion Tracker
--- DESCRIPTION:
--- A touchpad reports positions, not deltas: the hook used to publish motion for
--- EV_REL only, so CapsWord's pointer-motion switch never saw a finger slide.
--- The tracker names a report a movement only when the coordinate differs from
--- the previous one of the same contact.
--- ==============================================================================

local helpers = require("tests.helpers")

local InputEvent = require("platform.input.event")
local AbsoluteMotion = require("gestures.engine.absolute_motion")

helpers.describe("absolute pointer motion tracker", function()
	helpers.it("ignores the initial report and an unchanged coordinate, reports a change", function()
		local tracker = AbsoluteMotion.new()
		helpers.assert_eq(tracker.observe("p", InputEvent.ABS_X, 100), false, "initial X")
		helpers.assert_eq(tracker.observe("p", InputEvent.ABS_Y, 200), false, "initial Y")
		helpers.assert_eq(tracker.observe("p", InputEvent.ABS_X, 100), false, "unchanged X")
		helpers.assert_eq(tracker.observe("p", InputEvent.ABS_X, 127), true, "changed X")
		helpers.assert_eq(tracker.observe("p", InputEvent.ABS_Y, 212), true, "changed Y")
	end)

	helpers.it("keeps one history per source and forgets a lifted contact", function()
		local tracker = AbsoluteMotion.new()
		tracker.observe("a", InputEvent.ABS_X, 10)
		helpers.assert_eq(tracker.observe("b", InputEvent.ABS_X, 99), false, "another source starts afresh")
		tracker.lift("a")
		helpers.assert_eq(tracker.observe("a", InputEvent.ABS_X, 500), false, "a new landing is not a jump")
		tracker.reset()
		helpers.assert_eq(tracker.observe("b", InputEvent.ABS_X, 1), false, "reset forgets every source")
	end)

	helpers.it("treats a pressure or multitouch axis as no pointer motion and refuses a non-number", function()
		local tracker = AbsoluteMotion.new()
		helpers.assert_eq(tracker.observe("p", 0x18, 5), false)
		helpers.assert_eq(tracker.observe("p", 0x18, 9), false)
		helpers.assert_throws(function() tracker.observe("p", InputEvent.ABS_X, "1") end)
	end)

	helpers.it("the hook publishes a changed coordinate, and CapsWord's motion switch decides (CWL-001)", function()
		local hook = assert(helpers.read_driver_unit("local function hold_owner("))
		helpers.assert_contains(hook, '_call_callback("pointer event callback", _on_pointer_event, "absolute_motion", ev.code, ev.value, slot)')
		helpers.assert_contains(hook, "_absolute_motion.lift(slot)")
		helpers.assert_contains(hook, "_absolute_motion.reset()")
	end)
end)

return true
