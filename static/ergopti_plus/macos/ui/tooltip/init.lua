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

-- Callback fired when the tooltip transitions to visible state.
-- Registered from llm_bridge to create the persistent Escape trap at HEAD.
local _on_show_callback = nil
-- Injected by the keymap LLM bridge. Keeping this as a callback avoids a
-- tooltip -> keymap require cycle while making stale action epochs inert at the
-- final rendering/interaction boundary.
local _runtime_guard = function() return true end


local function runtime_available()
	local ok, available = pcall(_runtime_guard)
	return ok and available == true
end





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
--- Respects the hotstring dequeue guard: if a stacked multi-row tooltip is
--- currently cycling through its rows, mouse/scroll events are ignored so
--- longer-lived rows survive past the first row's expiry deadline.
function M.hide()
	TooltipLLM.hide()
	TooltipHotstring.hide()
end

--- Bypasses all guards and hides both tooltip types immediately.
--- Use for keyboard-triggered dismissals or when the caller needs an
--- authoritative hide regardless of any active dequeue cycle.
function M.hide_forced()
	TooltipLLM.hide()
	TooltipHotstring.hide_forced()
end

--- Authoritative hide for the keyboard hot path without synchronous log I/O.
function M.hide_forced_silent()
	if TooltipLLM.hide_silent then TooltipLLM.hide_silent() else TooltipLLM.hide() end
	TooltipHotstring.hide_forced()
end

--- Checks if any tooltip is currently rendered on screen.
--- @return boolean True if visible.
function M.is_visible()
	return TooltipLLM.is_visible() or TooltipHotstring.is_visible()
end

--- Registers a callback invoked whenever any tooltip transitions to visible state.
--- @param fn function|nil Callback with no arguments; pass nil to unregister.
function M.set_on_show_callback(fn)
	_on_show_callback = (type(fn) == "function") and fn or nil
end

--- Installs the live LLM action-epoch guard in both facade and interactive UI.
--- @param fn function|nil Zero-arity predicate; nil restores the open default.
function M.set_runtime_guard(fn)
	_runtime_guard = type(fn) == "function" and fn or function() return true end
	if type(TooltipLLM.set_runtime_guard) == "function" then
		TooltipLLM.set_runtime_guard(_runtime_guard)
	end
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
	if is_enabled and _on_show_callback then pcall(_on_show_callback) end
end

--- Displays a stacked multi-row tooltip for hotstring previews.
--- Each row is { text, tint, trigger_label }.
--- @param rows table Array of row descriptors.
--- @param is_enabled boolean Guard clause.
function M.show_stacked(rows, is_enabled)
	TooltipLLM.hide()
	TooltipHotstring.show_stacked(rows, is_enabled)
	if is_enabled and _on_show_callback then pcall(_on_show_callback) end
end

--- Displays a persistent loading indicator that will not auto-dismiss.
--- Must be used instead of show() for LLM generation states so the indicator
--- stays on screen until replaced in-place by the prediction results.
--- @param content string|userdata The loading text to display.
--- @param is_enabled boolean Guard clause to prevent rendering if disabled.
--- @param background_color table|nil Optional background tint.
function M.show_loading(content, is_enabled, background_color)
	if not runtime_available() then return false end
	TooltipLLM.hide()
	TooltipHotstring.show_loading(content, is_enabled, background_color)
	if is_enabled and _on_show_callback then pcall(_on_show_callback) end
	return true
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
	if not runtime_available() then return false end
	-- Reset hotstring state without hiding the shared canvas so the LLM render overwrites
	-- the loading indicator in-place — no blank frame between the two tooltips.
	TooltipHotstring.dismiss_silent()
	TooltipLLM.show_predictions(predictions, current_index, is_enabled, info_bar, shortcut_modifier, indent, navigation_modifiers, background_color, loading_text, max_reserved_count)
	if is_enabled and _on_show_callback then pcall(_on_show_callback) end
	return true
end

function M.navigate(delta)
	if not runtime_available() then return false end
	return TooltipLLM.navigate(delta)
end
function M.set_navigate_callback(cb) TooltipLLM.set_navigate_callback(cb) end
function M.set_accept_callback(cb) TooltipLLM.set_accept_callback(cb) end
function M.set_cancel_callback(cb) TooltipLLM.set_cancel_callback(cb) end
function M.set_enter_validates(v) TooltipLLM.set_enter_validates(v) end
function M.get_current_index()
	if not runtime_available() then return nil end
	return TooltipLLM.get_current_index()
end
function M.is_llm_visible() return TooltipLLM.is_visible() end
function M.is_hotstring_visible() return TooltipHotstring.is_visible() end
function M.make_diff_styled(...) return TooltipLLM.make_diff_styled(...) end




-- ==================================
-- ===== 1.2) Timer & Color API =====
-- ==================================

--- Resets the AI prediction auto-dismiss countdown using the currently configured delay.
--- Call this after final predictions arrive, or when the delay setting changes.
--- A configured delay of 0 means infinite display (no timer is started).
function M.reset_llm_timer()
	if not runtime_available() then return false end
	return TooltipLLM.reset_timer()
end

--- Arms the backend-agnostic chain timing origin. See TooltipLLM.set_chain_start.
--- @param timestamp number Epoch seconds (typically hs.timer.secondsSinceEpoch()).
function M.set_chain_start(timestamp)
	if not runtime_available() then return false end
	return TooltipLLM.set_chain_start(timestamp)
end

--- Finalises the active chain: computes TTLT and renders the full timing line.
--- Called by prediction_engine when the chain ends — success or failure.
function M.mark_chain_complete()
	if not runtime_available() then return false end
	return TooltipLLM.mark_chain_complete()
end

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
