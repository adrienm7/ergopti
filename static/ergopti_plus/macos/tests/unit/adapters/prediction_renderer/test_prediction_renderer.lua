--- tests/unit/adapters/prediction_renderer/test_prediction_renderer.lua

--- ==============================================================================
--- MODULE: Prediction Renderer Adapter (macOS)
--- DESCRIPTION:
--- The TooltipRenderer port over the prediction tooltip: a named view becomes the
--- twelve positional arguments of show_predictions, in order, and the tooltip's
--- verdict comes back unchanged.
--- ==============================================================================

local helpers = require("tests.helpers")
local Renderer = require("adapters.prediction_renderer")

helpers.describe("prediction renderer adapter", function()
	helpers.it("spells a view as the positional arguments of show_predictions", function()
		local seen
		local tooltip = {
			show_predictions = function(...) seen = table.pack(...); return "verdict" end,
			hide = function() return "hidden" end,
			is_visible = function() return true end,
		}
		local renderer = Renderer.wrap(tooltip)
		local guard = function() return true end
		local result = renderer.show({
			predictions = { "p" }, current_index = 2, enabled = true, info_bar = "bar",
			shortcut_modifier = "alt", indent = 3, navigation_modifiers = { "ctrl" },
			background_color = "bg", loading_text = "…", reserved_count = 4, session_id = 9,
			commit_guard = guard,
		})
		helpers.assert_eq(result, "verdict", "the tooltip's verdict is returned unchanged")
		helpers.assert_eq(seen[1][1], "p")
		helpers.assert_eq(seen[2], 2)
		helpers.assert_eq(seen[3], true)
		helpers.assert_eq(seen[4], "bar")
		helpers.assert_eq(seen[5], "alt")
		helpers.assert_eq(seen[6], 3)
		helpers.assert_eq(seen[7][1], "ctrl")
		helpers.assert_eq(seen[8], "bg")
		helpers.assert_eq(seen[9], "…")
		helpers.assert_eq(seen[10], 4)
		helpers.assert_eq(seen[11], 9)
		helpers.assert_eq(seen[12], guard)
		helpers.assert_eq(renderer.hide(), "hidden")
		helpers.assert_eq(renderer.is_visible(), true)
	end)

	helpers.it("refuses a tooltip that cannot draw, and raises where a missing hide is used", function()
		local ok, err = pcall(Renderer.wrap, {})
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(err), "tooltip lacks show_predictions")
		local drawing_only = Renderer.wrap({ show_predictions = function() return true end })
		helpers.assert_eq(pcall(drawing_only.hide), false, "a missing hide raises, it is not skipped")
	end)
end)

return true
