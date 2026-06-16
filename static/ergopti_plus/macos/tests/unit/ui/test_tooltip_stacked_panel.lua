--- tests/unit/ui/test_tooltip_stacked_panel.lua

--- ==============================================================================
--- MODULE: Tooltip Stacked Panel — Rounded Colored Background (regression)
--- DESCRIPTION:
--- Locks down the element structure of the multi-row (hotstring) tooltip: a
--- single ROUNDED background rectangle is the colored panel, and NO clip element
--- is ever emitted.
---
--- ROOT CAUSE ENCODED: an earlier fix tried to round the colored rectangle with a
--- rounded action="clip" element. On builds that do not honor the clip action the
--- element rendered with its DEFAULT fillColor (red), turning the whole tooltip
--- solid red instead of a translucent red tint. The replacement draws ONE rounded
--- panel background (apply_tint at the canvas alpha) and rounds the per-row
--- override and the border to match. These assertions fail if a clip element is
--- reintroduced or the panel background loses its rounding.
---
--- NOTE: the stub hs.canvas is a no-op mock, so the element STRUCTURE (not the
--- rendered pixels) is what is testable; M._build_stacked_elements is pure for
--- exactly this reason.
--- ==============================================================================

local helpers = require("tests.helpers")

local Renderer = helpers.load_with_stubs("ui.tooltip.renderer")

helpers.describe("tooltip stacked panel: rounded colored background, no clip", function()
	helpers.it("element 1 is a rounded filled rectangle (the colored panel)", function()
		local els = Renderer._build_stacked_elements(1)
		helpers.assert_eq(els[1].type, "rectangle")
		helpers.assert_eq(els[1].action, "fill")
		helpers.assert_true(type(els[1].roundedRectRadii) == "table"
			and (els[1].roundedRectRadii.xRadius or 0) > 0,
			"the panel background must be rounded so the colored rectangle matches the border")
	end)

	helpers.it("never emits a clip / resetClip element (the all-red tooltip cause)", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			for _, el in ipairs(Renderer._build_stacked_elements(n)) do
				helpers.assert_true(el.action ~= "clip" and el.action ~= "resetClip",
					"no clip/resetClip action — its default red fill turned the tooltip solid red")
			end
		end
	end)

	helpers.it("has the panel + rows + separators + border element count", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			-- 1 panel + 3*n per-row + (n-1) separators + 1 border = 4n + 1
			helpers.assert_eq(#els, n * 4 + 1)
		end
	end)

	helpers.it("ends with a rounded stroked border", function()
		local els = Renderer._build_stacked_elements(2)
		local last = els[#els]
		helpers.assert_eq(last.action, "strokeAndFill")
		helpers.assert_true(type(last.roundedRectRadii) == "table",
			"the border must be rounded to match the panel")
	end)

	helpers.it("per-row override slots start skipped (panel paints the common case)", function()
		-- For row i (1-based) the override background lives at (i-1)*3 + 2.
		local els = Renderer._build_stacked_elements(2)
		helpers.assert_eq(els[2].action, "skip")  -- row 1 override
		helpers.assert_eq(els[5].action, "skip")  -- row 2 override
	end)
end)
