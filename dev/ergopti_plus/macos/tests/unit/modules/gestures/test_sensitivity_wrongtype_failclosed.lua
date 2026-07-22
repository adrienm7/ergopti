--- tests/unit/modules/gestures/test_sensitivity_wrongtype_failclosed.lua

--- ==============================================================================
--- MODULE: Regression — gesture sensitivity fails closed on a wrong-typed value
--- DESCRIPTION:
--- Audit finding F-H9. set_sensitivity stored whatever value arrived (a one-liner
--- with no coercion) and get_sensitivity fell back only on nil. A persisted
--- config.toml / plist value can arrive as a string (hand edit, AHK migration,
--- half-written plist). The engine then runs math.floor(abs(sd) / sensitivity)
--- inside the gesture eventtap — `10 / "fast"` raises and is swallowed to the HS
--- Console (the gesture silently dies) — and the menu runs string.format("%.1f",
--- sens), which raises and blanks the whole gestures submenu under the builder
--- pcall. Fix: coerce to a positive number, failing closed to DEFAULT_SENSITIVITY.
--- ==============================================================================

local helpers = require("tests.helpers")

local Gestures = helpers.load_with_stubs("modules.gestures")

helpers.describe("gesture sensitivity fails closed to DEFAULT_SENSITIVITY on a wrong type", function()
	helpers.it("a non-numeric string is replaced by the numeric default", function()
		Gestures.set_sensitivity("swipe_2_left", "fast")
		local v = Gestures.get_sensitivity("swipe_2_left")
		helpers.assert_eq(type(v), "number")
		helpers.assert_eq(v, Gestures.DEFAULT_SENSITIVITY)
	end)

	helpers.it("the stored value is always safe for the engine arithmetic and the menu format", function()
		Gestures.set_sensitivity("swipe_2_left", "fast")
		local s = Gestures.get_sensitivity("swipe_2_left")
		-- Both crashed on the raw string before the fix.
		helpers.assert_true(pcall(function() return math.floor(10 / s) end),
			"engine arithmetic must never divide by a non-number")
		helpers.assert_true(pcall(function() return string.format("%.1f", s) end),
			"menu format must never %.1f a non-number")
	end)

	helpers.it("a zero or negative sensitivity also fails closed (no divide-by-zero)", function()
		Gestures.set_sensitivity("swipe_2_left", 0)
		helpers.assert_eq(Gestures.get_sensitivity("swipe_2_left"), Gestures.DEFAULT_SENSITIVITY)
		Gestures.set_sensitivity("swipe_2_left", -2)
		helpers.assert_eq(Gestures.get_sensitivity("swipe_2_left"), Gestures.DEFAULT_SENSITIVITY)
	end)

	helpers.it("a genuine positive number is stored verbatim", function()
		Gestures.set_sensitivity("swipe_2_left", 5)
		helpers.assert_eq(Gestures.get_sensitivity("swipe_2_left"), 5)
		-- A numeric-looking string is accepted (coerced), since the menu writes numbers.
		Gestures.set_sensitivity("swipe_2_left", "2.5")
		helpers.assert_eq(Gestures.get_sensitivity("swipe_2_left"), 2.5)
	end)
end)
