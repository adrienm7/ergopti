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
local Logger          = require("infra.logger")

local LOG = "tooltip"

-- Callback fired when the tooltip transitions to visible state.
-- Registered from llm_bridge to create the persistent Escape trap at HEAD.
local _on_show_callback = nil
-- Injected by the keymap LLM bridge. Keeping this as a callback avoids a
-- tooltip -> keymap require cycle while making stale action epochs inert at the
-- final rendering/interaction boundary.
local _runtime_guard = function() return true end
-- The standard canvas is shared by loading/hotstring and prediction owners.
-- A native callback can synchronously paint a successor while its predecessor
-- is still inside dismiss/render/hide. Keep the latest committed operation as
-- a replay capability so the outer stale tail can repair, but never republish,
-- the successor before control returns to its caller.
local _surface_generation = 0
local _surface_boundary_depth = 0
local _latest_surface_operation = nil
local _surface_repairing = false
-- An authoritative hide requested from inside an opaque render/hide boundary
-- cannot be reported as complete: that boundary can still repaint after the
-- nested call returns. Invalidate the in-flight owner immediately and retain
-- cleanup debt until a caller retries after the whole boundary unwinds.
local _forced_hide_pending = false
local _forced_hide_generation = 0


local function runtime_available()
	local ok, available = pcall(_runtime_guard)
	return ok and available == true
end

local function surface_operation_current(operation)
	if _latest_surface_operation ~= operation then return false end
	if type(operation.commit_guard) ~= "function" then return true end
	local guard_ok, current = pcall(operation.commit_guard)
	return guard_ok and current == true and _latest_surface_operation == operation
end

local function repair_latest_surface()
	if _surface_repairing or _forced_hide_pending then return false end
	_surface_repairing = true
	local repaired = false
	for _ = 1, 16 do
		local operation = _latest_surface_operation
		if not operation or operation.committed ~= true
			or type(operation.repair) ~= "function" then
			break
		end
		_surface_boundary_depth = _surface_boundary_depth + 1
		local repair_ok, repair_result = xpcall(function()
			return operation.repair(function()
				return surface_operation_current(operation)
			end)
		end, debug.traceback)
		_surface_boundary_depth = math.max(0, _surface_boundary_depth - 1)
		if _latest_surface_operation == operation
			and surface_operation_current(operation) then
			repaired = repair_ok and repair_result == true
			break
		end
	end
	_surface_repairing = false
	if not repaired and not _forced_hide_pending then
		Logger.error(LOG, "Latest tooltip surface could not be repaired after reentrant supersession.")
	end
	return repaired
end

local function run_surface_operation(commit_guard, apply, repair)
	-- A forced-hide debt owns the shared canvas until its exact retry settles.
	-- In particular, PredictionEngine.reset() must not fall through from its
	-- forced hides to a normal hide and report PAUSE complete under a live paint.
	if _forced_hide_pending then return false end
	if type(commit_guard) == "function" then
		local observed_generation = _surface_generation
		local guard_ok, current = pcall(commit_guard)
		if not guard_ok or current ~= true
			or observed_generation ~= _surface_generation then return false end
	end
	_surface_generation = _surface_generation + 1
	local operation = {
		generation = _surface_generation,
		commit_guard = commit_guard,
		committed = false,
		repair = repair,
	}
	_latest_surface_operation = operation
	_surface_boundary_depth = _surface_boundary_depth + 1
	local apply_ok, apply_result = xpcall(function()
		return apply(function() return surface_operation_current(operation) end)
	end, debug.traceback)
	local current = surface_operation_current(operation)
	operation.committed = apply_ok and apply_result == true and current
	_surface_boundary_depth = math.max(0, _surface_boundary_depth - 1)
	if not current and _surface_boundary_depth == 0
		and not _forced_hide_pending then
		repair_latest_surface()
	end
	if not apply_ok then
		Logger.error(LOG, "Tooltip surface transaction raised: %s.", tostring(apply_result))
	end
	return operation.committed == true, operation
end

--- Publishes a completed show only after its external ownership callback runs.
--- A failed Escape-trap arm leaves visible pixels with no matching interaction
--- owner, so revoke both surfaces rather than reporting a partial success.
--- @param shown boolean Whether the concrete tooltip owner committed its show.
--- @return boolean published True when the full facade transition committed.
local function publish_show(shown)
	if shown ~= true then return false end
	if not _on_show_callback then return true end
	local callback_ok, callback_result = xpcall(_on_show_callback, debug.traceback)
	if callback_ok and callback_result == true then return true end

	Logger.error(LOG, "Tooltip on-show callback did not commit (result: %s). Visible surface revoked.",
		tostring(callback_result))
	local cleanup_ok, cleanup_result = xpcall(M.hide_forced, debug.traceback)
	if not cleanup_ok or cleanup_result ~= true then
		Logger.error(LOG, "Tooltip on-show failure cleanup did not commit (result: %s).",
			tostring(cleanup_result))
	end
	return false
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

local function hide_surface(expected_session, owns)
	if not owns() then return false end
	local llm_hidden
	if expected_session ~= nil then
		if type(TooltipLLM.hide_session) ~= "function" then return false end
		llm_hidden = TooltipLLM.hide_session(expected_session, owns) == true
	else
		llm_hidden = TooltipLLM.hide() == true
	end
	if not owns() then return false end
	local hotstring_hidden = TooltipHotstring.hide() == true
	if not owns() then return false end
	return llm_hidden and hotstring_hidden
end

local function hide_forced_surface(silent)
	local llm_hidden
	if silent and type(TooltipLLM.hide_silent) == "function" then
		llm_hidden = TooltipLLM.hide_silent() == true
	else
		llm_hidden = TooltipLLM.hide() == true
	end
	local hotstring_hidden = TooltipHotstring.hide_forced() == true
	return llm_hidden and hotstring_hidden
end

--- Invalidates every prior surface operation and attempts an authoritative
--- physical hide only when no opaque surface mutation remains on stack.
--- @param silent boolean Whether to use the log-free LLM hide path.
--- @return boolean hidden True only when this exact request settled both owners.
local function request_forced_hide(silent)
	_surface_generation = _surface_generation + 1
	_latest_surface_operation = nil
	_forced_hide_pending = true
	_forced_hide_generation = _forced_hide_generation + 1
	local request_generation = _forced_hide_generation

	if _surface_boundary_depth > 0 or _surface_repairing then return false end

	-- Treat the physical hide itself as a boundary. A nested forced hide may
	-- supersede it, but no surface operation can paint while cleanup is pending.
	_surface_boundary_depth = _surface_boundary_depth + 1
	local hide_ok, hide_result = xpcall(function()
		return hide_forced_surface(silent)
	end, debug.traceback)
	_surface_boundary_depth = math.max(0, _surface_boundary_depth - 1)

	if hide_ok and hide_result == true
		and _forced_hide_generation == request_generation then
		_forced_hide_pending = false
		return true
	end
	if not hide_ok then
		Logger.error(LOG, "Authoritative tooltip hide raised: %s.", tostring(hide_result))
	end
	return false
end

--- Safely hides any currently active tooltip.
--- Respects the hotstring dequeue guard: if a stacked multi-row tooltip is
--- currently cycling through its rows, mouse/scroll events are ignored so
--- longer-lived rows survive past the first row's expiry deadline.
--- @param expected_session any|nil Optional exact streaming request identity.
--- @param commit_guard function|nil Optional live request predicate.
--- @return boolean True when both owners are stopped or safely guarded.
function M.hide(expected_session, commit_guard)
	-- A capability-free hide cannot settle while an older surface callback can
	-- still repaint. Exact session-scoped hides keep successor replay semantics.
	if expected_session == nil
		and (_surface_boundary_depth > 0 or _surface_repairing) then
		return false
	end
	return run_surface_operation(commit_guard,
		function(owns)
			return hide_surface(expected_session, owns)
		end,
		function(owns)
			return hide_surface(expected_session, owns)
		end)
end

--- Bypasses all guards and hides both tooltip types immediately.
--- Use for keyboard-triggered dismissals or when the caller needs an
--- authoritative hide regardless of any active dequeue cycle.
--- @return boolean True when both owners are verified stopped.
function M.hide_forced()
	return request_forced_hide(false)
end

--- Authoritative hide for the keyboard hot path without synchronous log I/O.
--- @return boolean True when both owners are verified stopped.
function M.hide_forced_silent()
	return request_forced_hide(true)
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
	if _forced_hide_pending then return false end
	if TooltipLLM.hide() ~= true then return false end
	local shown = TooltipHotstring.show(content, is_llm_origin, is_enabled, background_color) == true
	return publish_show(shown)
end

--- Displays a stacked multi-row tooltip for hotstring previews.
--- Each row is { text, tint, trigger_label }.
--- @param rows table Array of row descriptors.
--- @param is_enabled boolean Guard clause.
function M.show_stacked(rows, is_enabled)
	if _forced_hide_pending then return false end
	if TooltipLLM.hide() ~= true then return false end
	local shown = TooltipHotstring.show_stacked(rows, is_enabled) == true
	return publish_show(shown)
end

--- Displays a persistent loading indicator that will not auto-dismiss.
--- Must be used instead of show() for LLM generation states so the indicator
--- stays on screen until replaced in-place by the prediction results.
--- @param content string|userdata The loading text to display.
--- @param is_enabled boolean Guard clause to prevent rendering if disabled.
--- @param background_color table|nil Optional background tint.
local function show_loading_surface(content, is_enabled, background_color, owns)
	if not runtime_available() or not owns() then return false end
	if TooltipLLM.hide() ~= true then return false end
	if not owns() then return false end
	local shown = TooltipHotstring.show_loading(content, is_enabled, background_color) == true
	return shown == true and owns()
end

function M.show_loading(content, is_enabled, background_color)
	local shown, operation = run_surface_operation(nil,
		function(owns)
			return show_loading_surface(content, is_enabled, background_color, owns)
		end,
		function(owns)
			return show_loading_surface(content, is_enabled, background_color, owns)
		end)
	if shown ~= true then return false end
	local published = publish_show(true)
	return published == true and surface_operation_current(operation)
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
--- @param session_id any|nil Stable request identity for same-stream repaints.
--- @param commit_guard function|nil Live request predicate.
local function show_predictions_surface(predictions, current_index, is_enabled, info_bar,
	shortcut_modifier, indent, navigation_modifiers, background_color, loading_text,
	max_reserved_count, session_id, owns)
	if not runtime_available() or not owns() then return false end
	-- Reset hotstring state without hiding the shared canvas so the LLM render overwrites
	-- the loading indicator in-place — no blank frame between the two tooltips.
	if TooltipHotstring.dismiss_silent() ~= true then return false end
	if not owns() then return false end
	local shown = TooltipLLM.show_predictions(predictions, current_index, is_enabled, info_bar,
		shortcut_modifier, indent, navigation_modifiers, background_color, loading_text,
		max_reserved_count, session_id, owns) == true
	if not owns() then return false end
	if not shown then
		TooltipHotstring.hide_forced()
		return false
	end
	return true
end

function M.show_predictions(predictions, current_index, is_enabled, info_bar, shortcut_modifier, indent, navigation_modifiers, background_color, loading_text, max_reserved_count, session_id, commit_guard)
	local shown, operation = run_surface_operation(commit_guard,
		function(owns)
			return show_predictions_surface(predictions, current_index, is_enabled, info_bar,
				shortcut_modifier, indent, navigation_modifiers, background_color,
				loading_text, max_reserved_count, session_id, owns)
		end,
		function(owns)
			return show_predictions_surface(predictions, current_index, is_enabled, info_bar,
				shortcut_modifier, indent, navigation_modifiers, background_color,
				loading_text, max_reserved_count, session_id, owns)
		end)
	if shown ~= true then return false end
	local published = publish_show(true)
	return published == true and surface_operation_current(operation)
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
function M.has_visible_hotstring_lease(token) return TooltipHotstring.has_visible_lease(token) end
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
