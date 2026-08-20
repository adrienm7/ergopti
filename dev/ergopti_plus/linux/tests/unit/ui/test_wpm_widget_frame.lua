--- tests/unit/ui/test_wpm_widget_frame.lua

--- ==============================================================================
--- MODULE: What the WPM Widget Decides Before It Draws
--- DESCRIPTION:
--- Every choice the floating widget makes — the number, the colour, the opacity,
--- whether it is idle — asserted without a display.
---
--- WHY THE ARITHMETIC IS SEPARATE FROM THE DRAWING:
--- The preview bubble taught this. Its logic was complete, its renderer needed
--- lgi and a compositor, and for weeks nobody could tell which half was broken —
--- until `build_rows` became a pure function returning a table. `frame_for` is
--- the same seam: it turns the keylogger's stats into everything the renderer
--- needs and returns a plain table, so a machine with no screen can still say
--- whether the widget would have shown the right thing.
---
--- WHAT ONLY HARDWARE CAN SAY: whether the pill appears, where, and above other
--- windows. HARDWARE.md keeps that.
---
--- WHY THE CONSTANTS ARE NOT RESTATED HERE:
--- They come from _shared/modules/wpm_widget/constants.toml, which the other two
--- drivers each mirror by hand. Copying them into a test would make a fourth
--- copy and pin THIS driver to today's values rather than to the canon — so the
--- assertions below are about relationships (the idle pill is dimmer than the
--- active one) rather than about numbers.
--- ==============================================================================

local helpers = require("tests.helpers")

local Widget = helpers.load_module("ui.wpm.widget")

-- A moment, and a keystroke that happened at it. Time is passed in rather than
-- read, which is the whole reason the fade can be tested at all.
local NOW = 1000.0

--- Stats as the keylogger reports them.
--- @param wpm number
--- @param source string|nil
--- @param age number|nil Seconds since that source last produced a character.
--- @return table
local function stats(wpm, source, age)
	return {
		wpm           = wpm,
		source_variant = source,
		source_time   = NOW - (age or 0),
	}
end




-- =================================================================
-- =================================================================
-- ======= 1/ The number ===========================================
-- =================================================================
-- =================================================================

helpers.describe("wpm widget: the number", function()

	helpers.it("shows the rounded speed and the unit separately", function()
		local frame = Widget.frame_for(stats(87.6, "manual"), NOW)
		helpers.assert_not_nil(frame, "the shared constants must load, or nothing below asserts anything")
		helpers.assert_eq(frame.number, "87",
			"the pill is eighty pixels wide and the number is set in a large face; "
				.. "'87.6 MPM' on one line does not fit, which is why the unit has its "
				.. "own strip")
		helpers.assert_eq(frame.unit, "MPM")
	end)

	helpers.it("shows zero rather than nothing when there are no stats", function()
		local frame = Widget.frame_for(nil, NOW)
		helpers.assert_eq(frame.number, "0",
			"a widget that goes blank reads as a crash; zero is a measurement and "
				.. "blank is a question")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The colour fades back to neutral =====================
-- =================================================================
-- =================================================================

helpers.describe("wpm widget: what the colour says", function()

	helpers.it("colours by the source that just typed", function()
		local ai     = Widget.frame_for(stats(60, "llm"), NOW)
		local manual = Widget.frame_for(stats(60, "manual"), NOW)
		helpers.assert_true(ai.background.red ~= manual.background.red
			or ai.background.blue ~= manual.background.blue,
			"the colour is the only thing on the pill that says WHERE the characters "
				.. "came from — an AI completion and the user's own hands must not look "
				.. "the same")
		helpers.assert_true(not ai.idle and not manual.idle)
	end)

	helpers.it("returns to neutral once the source is stale", function()
		local fresh = Widget.frame_for(stats(60, "llm", 0.2), NOW)
		local stale = Widget.frame_for(stats(60, "llm", 5.0), NOW)
		helpers.assert_true(not fresh.idle, "a keystroke from a moment ago still colours it")
		helpers.assert_true(stale.idle,
			"otherwise one AI completion leaves the pill purple for the rest of the "
				.. "session, and the colour stops meaning 'what is happening now'")
	end)

	helpers.it("dims when idle instead of disappearing", function()
		local busy = Widget.frame_for(stats(60, "manual"), NOW)
		local idle = Widget.frame_for(stats(60, "manual", 30), NOW)
		helpers.assert_true(idle.alpha < busy.alpha,
			"a widget that vanishes when the user stops typing reads as a crash — and "
				.. "the number after they stop is the one they actually want to read")
		helpers.assert_eq(idle.number, "60", "and it keeps the value it last measured")
	end)

	helpers.it("stays neutral when source colours are switched off", function()
		Widget.set_use_source_colors(false)
		local frame = Widget.frame_for(stats(60, "llm"), NOW)
		Widget.set_use_source_colors(true)
		helpers.assert_true(frame.idle,
			"the toggle governs the colour, and a toggle that leaves one source still "
				.. "painting is a toggle that did half its job")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The strip under the number ===========================
-- =================================================================
-- =================================================================

helpers.describe("wpm widget: the unit strip", function()

	helpers.it("is the pill's own colour, one shade down", function()
		local frame = Widget.frame_for(stats(60, "manual"), NOW)
		helpers.assert_not_nil(frame.strip)
		helpers.assert_true(frame.strip.red <= frame.background.red
			and frame.strip.green <= frame.background.green
			and frame.strip.blue <= frame.background.blue,
			"the canon carries a darkening FACTOR rather than a second colour, so the "
				.. "two can never be changed apart — a strip computed independently is "
				.. "the second source that arrangement exists to remove")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ Lifecycle ============================================
-- =================================================================
-- =================================================================

helpers.describe("wpm widget: starting and stopping", function()

	helpers.before_each(function() Widget._reset() end)

	helpers.it("reports whether it could start at all", function()
		helpers.assert_true(Widget.start(),
			"the shared constants are shipped with the driver, so a failure here is a "
				.. "packaging fault and the caller has to be able to see it")
		helpers.assert_true(Widget.is_running())
	end)

	helpers.it("draws nothing while stopped", function()
		helpers.assert_nil(Widget.tick(stats(60, "manual"), NOW),
			"the tick runs several times a second from the daemon's own callback; a "
				.. "stopped widget that still computed frames would be paying for a "
				.. "window nobody asked for")
	end)

	helpers.it("recomputes only when something visible changed", function()
		Widget.start()
		local first  = Widget.tick(stats(60, "manual"), NOW)
		local same   = Widget.tick(stats(60, "manual"), NOW)
		helpers.assert_eq(first.number, same.number,
			"an identical pill must not cost a GTK round trip — the tick is several "
				.. "times a second and the display server has other work")
		local moved = Widget.tick(stats(75, "manual"), NOW)
		helpers.assert_eq(moved.number, "75", "and a real change still gets through")
	end)

	helpers.it("is idempotent on stop", function()
		Widget.start()
		Widget.stop()
		Widget.stop()
		helpers.assert_true(not Widget.is_running(),
			"stop runs from the daemon's shutdown path, which can be reached twice on "
				.. "a signal that arrives during a reload")
	end)

end)
