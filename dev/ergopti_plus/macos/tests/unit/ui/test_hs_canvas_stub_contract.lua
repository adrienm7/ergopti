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


helpers.describe("hs.canvas stub: frame snapshots", function()
	helpers.it("copies the constructor frame instead of borrowing the caller's table", function()
		helpers.with_fresh_modules({ "tests.stubs.hs" }, function()
			local native = require("tests.stubs.hs")
			local requested = { x = 1, y = 2, w = 30, h = 40 }
			local canvas = native.canvas.new(requested)
			requested.x, requested.w = 900, 999
			helpers.assert_eq(canvas:frame().x, 1, "only a native frame setter may move the surface")
			helpers.assert_eq(canvas:frame().w, 30, "the allocated dimensions are independently owned")
		end)
	end)

	helpers.it("copies each accepted setter frame and keeps its native chainable receipt", function()
		helpers.with_fresh_modules({ "tests.stubs.hs" }, function()
			local native = require("tests.stubs.hs")
			local canvas = native.canvas.new({ x = 1, y = 2, w = 30, h = 40 })
			local requested = { x = 5, y = 6, w = 70, h = 80 }
			helpers.assert_true(canvas:frame(requested) == canvas)
			requested.y, requested.h = 900, 999
			helpers.assert_eq(canvas:frame().y, 6, "a later caller mutation cannot move the accepted frame")
			helpers.assert_eq(canvas:frame().h, 80, "a later caller mutation cannot resize the accepted frame")
		end)
	end)

	helpers.it("returns independent native rect snapshots for every getter", function()
		helpers.with_fresh_modules({ "tests.stubs.hs" }, function()
			local native = require("tests.stubs.hs")
			local canvas = native.canvas.new({ x = 1, y = 2, w = 30, h = 40 })
			local first, second = canvas:frame(), canvas:frame()
			first.x, first.h = 900, 999
			helpers.assert_eq(second.x, 1, "a second getter retains its independently captured position")
			helpers.assert_eq(second.h, 40, "a second getter retains its independently captured dimensions")
			helpers.assert_eq(canvas:frame().x, 1, "editing a getter never moves the native surface")
			helpers.assert_eq(second.__luaSkinType, "NSRect", "the native frame wrapper returns a rect table")
		end)
	end)

	helpers.it("keeps a GraphicsRenderer drawing callback's frame edits behind the explicit setter", function()
		helpers.with_stub_scope({ "adapters.graphics_renderer" }, function()
			local renderer = helpers.load_with_stubs("adapters.graphics_renderer")
			local canvas = renderer.createWindow({ x = 1, y = 2, w = 30, h = 40 })
			helpers.assert_true(canvas ~= 0, "the real adapter must allocate its native surface")
			local observations = { callbacks = 0 }
			renderer.drawBitmap(canvas, function(surface)
				observations.callbacks = observations.callbacks + 1
				local proposed = surface:frame()
				proposed.x = 5
				observations.before_setter = surface:frame().x
				surface:frame(proposed)
				proposed.x = 900
				observations.after_setter = surface:frame().x
			end)
			helpers.assert_eq(observations.callbacks, 1, "the real production draw callback executed")
			helpers.assert_eq(observations.before_setter, 1, "the getter mutation alone cannot move the canvas")
			helpers.assert_eq(observations.after_setter, 5, "only the explicit native setter commits the move")
			helpers.assert_eq(canvas:frame().x, 5, "later mutation never changes the committed native geometry")
			renderer.destroyWindow(canvas)
		end)
	end)
end)
