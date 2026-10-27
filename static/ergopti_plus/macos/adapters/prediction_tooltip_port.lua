-- adapters/prediction_tooltip_port.lua

--- ==============================================================================
--- MODULE: Prediction Tooltip Port Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TooltipRenderer port of the shared request
--- plan (_shared/lua/llm/request_plan/ports.lua): show, hide and is_visible over
--- the prediction tooltip. The engine and the streaming handler describe what to
--- draw as one named view; this adapter spells it out as the positional
--- arguments tooltip.show_predictions takes, so the twelve-argument call lives
--- in one place instead of five.
---
--- FEATURES & RATIONALE:
--- 1. One view table: predictions, current_index, enabled, info_bar,
---    shortcut_modifier, indent, navigation_modifiers, background_color,
---    loading_text, reserved_count, session_id, commit_guard.
--- 2. The result of the tooltip is returned unchanged (a render the commit guard
---    refused stays false), so no caller sees a different success value.
--- 3. show_predictions is checked at wrap time; hide and is_visible are called
---    as the tooltip offers them, and a missing one raises where it is used.
--- ==============================================================================

local Ports = require("llm.request_plan.ports")

local M = {}




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- Wraps a prediction tooltip as a TooltipRenderer.
--- @param tooltip table Offers show_predictions, hide and is_visible.
--- @return table renderer { show(view), hide(), is_visible() }
function M.wrap(tooltip)
	if type(tooltip) ~= "table" then error("prediction_tooltip_port.wrap: tooltip must be a table", 2) end
	if type(tooltip.show_predictions) ~= "function" then
		error("prediction_tooltip_port.wrap: tooltip lacks show_predictions", 2)
	end
	local renderer = {
		show = function(view)
			return tooltip.show_predictions(
				view.predictions, view.current_index, view.enabled, view.info_bar,
				view.shortcut_modifier, view.indent, view.navigation_modifiers,
				view.background_color, view.loading_text, view.reserved_count,
				view.session_id, view.commit_guard)
		end,
		-- Looked up at call time: a caller that only draws never needs them.
		hide = function() return tooltip.hide() end,
		is_visible = function() return tooltip.is_visible() end,
	}
	return Ports.check("TooltipRenderer", renderer)
end

return M
