--- ui/tooltip/init.lua

--- ==============================================================================
--- MODULE: Tooltip Orchestrator
--- DESCRIPTION:
--- Central facade exposing a unified API for all tooltip interactions.
---
--- FEATURES & RATIONALE:
--- 1. Facade Pattern: Shields external callers from internal module splits.
--- 2. Clean Routing: Delegates complex AI vs simple hotstring tasks dynamically.
--- ==============================================================================

local M = {}
local Config          = require("ui.tooltip.config")
local TooltipLLM      = require("ui.tooltip.tooltip_llm")
local TooltipHotstring = require("ui.tooltip.tooltip_hotstring")





-- ===========================
-- ===========================
-- ======= 1/ API Core =======
-- ===========================
-- ===========================

--- Setup general configuration parameters.
--- @param params table Configuration dictionary.
function M.setup(params) Config.setup(params) end

--- Safely sets the general tooltip timeout.
--- @param seconds number The duration in seconds.
function M.set_timeout(seconds) Config.set_timeout(seconds) end

--- Safely sets the LLM specific tooltip timeout.
--- @param seconds number The duration in seconds.
function M.set_llm_timeout(seconds) Config.set_llm_timeout(seconds) end

--- Explicitly enables or disables colorization.
--- @param enabled boolean True to allow color, false to enforce gray.
function M.set_colorization_enabled(enabled) Config.set_colorization_enabled(enabled) end

--- Safely hides any currently active tooltip.
function M.hide()
	TooltipLLM.hide()
	TooltipHotstring.hide()
end

--- Checks if any tooltip is currently rendered on screen.
--- @return boolean True if visible.
function M.is_visible()
	return TooltipLLM.is_visible() or TooltipHotstring.is_visible()
end




-- ==================================
-- ===== 1.1) Sub API Functions =====
-- ==================================

--- Displays a standard text tooltip (hotstring mode).
--- @param content string|userdata The text to display.
--- @param is_llm_origin boolean Alters styling if origin is AI.
--- @param is_enabled boolean Guard clause to prevent rendering if disabled.
--- @param background_color table|nil Optional background tint.
function M.show(content, is_llm_origin, is_enabled, background_color)
	TooltipLLM.hide()
	TooltipHotstring.show(content, is_llm_origin, is_enabled, background_color)
end

--- Displays AI predictions with interactive navigation (LLM mode).
--- @param predictions table List of AI choices.
--- @param current_index number Selected index.
--- @param is_enabled boolean Guard clause.
--- @param info_bar string Bottom info text.
--- @param shortcut_modifier string Modifier key required.
--- @param indent number Indentation level for visual alignment.
--- @param navigation_modifiers table Key modifiers required to navigate.
--- @param background_color table Optional tint.
--- @param loading_text string Text to show if loading.
--- @param max_reserved_count number Skeleton slots to render.
function M.show_predictions(predictions, current_index, is_enabled, info_bar, shortcut_modifier, indent, navigation_modifiers, background_color, loading_text, max_reserved_count)
	TooltipHotstring.hide()
	TooltipLLM.show_predictions(predictions, current_index, is_enabled, info_bar, shortcut_modifier, indent, navigation_modifiers, background_color, loading_text, max_reserved_count)
end

function M.navigate(delta) TooltipLLM.navigate(delta) end
function M.set_navigate_callback(cb) TooltipLLM.set_navigate_callback(cb) end
function M.set_accept_callback(cb) TooltipLLM.set_accept_callback(cb) end
function M.set_cancel_callback(cb) TooltipLLM.set_cancel_callback(cb) end
function M.set_enter_validates(v) TooltipLLM.set_enter_validates(v) end
function M.get_current_index() return TooltipLLM.get_current_index() end
function M.make_diff_styled(...) return TooltipLLM.make_diff_styled(...) end




-- ==================================
-- ===== 1.2) Timer & Color API =====
-- ==================================

--- Resets the AI prediction auto-dismiss countdown using the currently configured delay.
--- Call this after final predictions arrive, or when the delay setting changes.
--- A configured delay of 0 means infinite display (no timer is started).
function M.reset_llm_timer() TooltipLLM.reset_timer() end

--- Returns the tinted background color for a display context, or nil if colorization is off.
--- Delegates to Config.tint() so callers never need to import the config directly.
--- @param key string Context key — "hotstring_star", "hotstring_autocorrect", "hotstring_personal", "ai_loading", "ai_prediction".
--- @return table|nil The RGBA color table, or nil.
function M.tint(key) return Config.tint(key) end

--- Overrides the default accent color for a given display context.
--- Pass nil to remove the tint (tooltip renders with standard dark background).
--- @param key string The context key to override.
--- @param color table|nil The new RGBA color table, or nil.
function M.set_accent_color(key, color) Config.set_accent_color(key, color) end

return M
