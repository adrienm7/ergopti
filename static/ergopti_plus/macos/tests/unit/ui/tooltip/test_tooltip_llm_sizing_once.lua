--- tests/unit/ui/tooltip/test_tooltip_llm_sizing_once.lua

--- ==============================================================================
--- MODULE: Prediction tooltip — the width is measured once per show
--- DESCRIPTION:
--- The 2026-11-06 field report measured tooltip.show_predictions at 12.02 and
--- 10.99 ms against its 5 ms budget, both on the first frame of a request
--- (1 prediction, 3 reserved slots). show_predictions sized the panel by
--- assembling the whole block once per highlight position (one per slot), then
--- once more to render, and each assembly lays out every line twice natively
--- (hs.canvas minimumTextSize). The widest line is already measured over both
--- renderings of every row, so the width cannot depend on which row is
--- highlighted: the sizing now assembles once. The count of native layout
--- calls no longer grows with the reserved slots (tooltip-sizing-once).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads tooltip_llm over a counting renderer and returns the number of native
--- text layouts one show_predictions call performs.
--- @param reserved integer Reserved slots.
--- @param predictions table Prediction payloads.
--- @return integer layouts
--- @return number width The fixed width the sizing committed.
local function layouts_for(reserved, predictions)
	local layouts, width = 0, nil
	helpers.with_stub_scope({ "infra.logger", "ui.tooltip.renderer", "ui.tooltip.tooltip_llm" }, function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["ui.tooltip.renderer"] = {
			canvas = {
				minimumTextSize = function()
					layouts = layouts + 1
					return { w = 100, h = 10 }
				end,
			},
			ELEM_INFO = 6,
			hide = function() return true end,
			set_element_text = function() return true end,
			-- The show is abandoned after the render: only the sizing is measured
			render = function(_blocks, state)
				width = state.fixed_width
				return false
			end,
		}
		package.loaded["ui.tooltip.tooltip_llm"] = nil
		local Tooltip = helpers.load_with_stubs("ui.tooltip.tooltip_llm")
		Tooltip.show_predictions(predictions, 1, true, "Model", "alt", 0, {}, nil, nil, reserved)
	end)
	return layouts, width
end

helpers.describe("tooltip_llm: show_predictions sizes the panel once (tooltip-sizing-once)", function()
	helpers.it("the native layouts do not grow with the reserved slots (tooltip-sizing-once)", function()
		local preds = { { chunks = {}, nw = "bonjour" } }
		local one, width_one = layouts_for(1, preds)
		local five, width_five = layouts_for(5, preds)
		helpers.assert_true(one > 0, "the counting renderer measured nothing: the case proves nothing")
		helpers.assert_true(width_one ~= nil and width_five ~= nil, "the sizing committed no width")
		helpers.assert_eq(five, one, "each reserved slot assembled and measured the whole block again")
	end)
end)
