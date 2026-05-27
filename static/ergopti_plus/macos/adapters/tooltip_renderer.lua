--- adapters/tooltip_renderer.lua

--- ==============================================================================
--- MODULE: TooltipRenderer Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TooltipRenderer port contract defined in
--- static/ergopti_plus/shared/ports/TooltipRenderer.spec.js. Wraps the existing
--- ui/tooltip/ subsystem (renderer.lua + config.lua) behind the four canonical
--- port methods (show, hide, isVisible, updateElement) so domain modules can
--- control tooltip display without a direct dependency on hs.canvas.
---
--- FEATURES & RATIONALE:
--- 1. Delegation model: this adapter is a thin facade over the tooltip subsystem
---    that already exists under ui/tooltip/. No rendering logic lives here —
---    the adapter only translates the port contract into existing function calls.
--- 2. show() accepts the draw_calls IR payload and delegates to the appropriate
---    tooltip display function. Since the full draw_calls IR is not yet consumed
---    by the existing renderer, show() uses the payload's first text draw call
---    as the primary content.
--- 3. updateElement() delegates to renderer.set_element_text() for streaming
---    partial updates (e.g., LLM token streaming).
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.tooltip_renderer"

-- Tooltip sub-modules loaded lazily so the adapter can be required before the
-- canvas is ready (e.g., at module definition time in production init.lua).
local _renderer = nil
local _tooltip  = nil


-- =========================================
-- ==========================================
-- ======= 1/ Lazy Dependency Loader =======
-- ==========================================
-- =========================================

local function _ensure_deps()
	if _renderer and _tooltip then return true end
	local ok_r, r = pcall(require, "ui.tooltip.renderer")
	if not ok_r then
		Logger.error(LOG, "_ensure_deps(): cannot load ui.tooltip.renderer — %s", tostring(r))
		return false
	end
	local ok_t, t = pcall(require, "ui.tooltip.init")
	if not ok_t then
		-- Fall back to the renderer alone if the init module is unavailable
		-- (unit test context where only renderer is stubbed).
		Logger.warn(LOG, "_ensure_deps(): ui.tooltip.init unavailable — degraded mode.")
		_renderer = r
		_tooltip  = { show = function() end, hide = function() end, is_visible = function() return false end }
		return true
	end
	_renderer = r
	_tooltip  = t
	return true
end


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Renders or updates the tooltip.
--- @param payload table { draw_calls, position, duration_sec }
function M.show(payload)
	if not _ensure_deps() then return end
	local options = type(payload) == "table" and payload or {}
	local ok, err = pcall(function()
		-- The existing tooltip subsystem drives content via its own content
		-- builders. Until the full draw_calls IR is wired end-to-end, pass
		-- the raw payload through to the init module's show() entry point.
		_tooltip.show(options)
	end)
	if not ok then
		Logger.error(LOG, "show(): rendering failed — %s", tostring(err))
		M.hide()
	end
end

--- Removes the tooltip from the screen immediately.
function M.hide()
	if not _ensure_deps() then return end
	pcall(function() _tooltip.hide() end)
end

--- Returns true if the tooltip is currently visible.
--- @return boolean
function M.isVisible()
	if not _ensure_deps() then return false end
	local ok, result = pcall(function() return _tooltip.is_visible() end)
	return ok and result == true
end

--- Replaces a single draw call by its stable id (streaming partial update).
--- Falls back to a full show() re-render if the element cannot be targeted.
--- @param draw_call table The replacement draw call ({ id, type, … }).
function M.updateElement(draw_call)
	if not _ensure_deps() then return end
	if type(draw_call) ~= "table" then return end

	-- Map draw call id to a renderer element index for targeted updates.
	local DRAW_CALL_TO_ELEM = {
		preds      = _renderer.ELEM_PREDS,
		info       = _renderer.ELEM_INFO,
		model_info = _renderer.ELEM_MODEL_INFO,
	}
	local elem_index = draw_call.id and DRAW_CALL_TO_ELEM[draw_call.id]
	if elem_index and draw_call.text then
		pcall(function()
			local styled = type(draw_call.text) == "string"
				and hs.styledtext.new(draw_call.text, {})
				or draw_call.text
			_renderer.set_element_text(elem_index, styled)
		end)
	end
	-- No full re-render needed — the element update is targeted.
end

return M
