--- tests/unit/ui/test_hs_canvas_stub_contract.lua

--- ==============================================================================
--- MODULE: Hammerspoon canvas stub contract
--- DESCRIPTION:
--- Keeps the shared test double faithful at the renderer commit boundary. The
--- E2E gate must observe numeric canvas elements and native visibility booleans;
--- otherwise production renderer errors can be logged while the gate exits green.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("hs.canvas stub: observable native state", function()
	helpers.it("persists elements, geometry, and visibility with native return shapes", function()
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()

		local canvas = hs_stub.canvas.new({ x = 1, y = 2, w = 3, h = 4 })
		canvas:appendElements(
			{ type = "rectangle", action = "fill" },
			{ type = "text", action = "skip" }
		)

		helpers.assert_eq(type(canvas[2]), "table",
			"numeric canvas lookup must return a mutable element, not a generic method")
		canvas[2].text = "visible"
		helpers.assert_eq(canvas[2].text, "visible",
			"element writes must be observable through a native-style read-back")

		helpers.assert_true(canvas:show() == canvas,
			"native show must return the canvas object on commit")
		helpers.assert_eq(canvas:isShowing(), true,
			"isShowing must report a boolean after show")
		canvas:hide()
		helpers.assert_eq(canvas:isShowing(), false,
			"isShowing must report a boolean after hide")

		canvas:frame({ x = 5, y = 6, w = 70, h = 80 })
		helpers.assert_eq(canvas:frame().w, 70,
			"frame setter state must survive the independent getter read-back")
		local measured = canvas:minimumTextSize(2, "abc")
		helpers.assert_eq(type(measured.w), "number",
			"minimumTextSize must expose numeric geometry")
	end)
end)
