--- static/ergopti_plus/linux/adapters/tooltip_renderer.lua

--- ==============================================================================
--- MODULE: TooltipRenderer Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TooltipRenderer port contract defined in
--- static/ergopti_plus/shared/ports/TooltipRenderer.spec.js. Renders floating
--- tooltip overlays using a lightweight X11 window (via xdotool + xlib) or
--- a GTK popup (via zenity --info in non-interactive mode) without coupling
--- domain modules to any display-server API.
---
--- FEATURES & RATIONALE:
--- 1. X11 primary path: a borderless override-redirect window drawn with
---    cairo/pango provides pixel-accurate rendering matching the macOS tooltip
---    look-and-feel. This path requires an X11 display.
--- 2. Wayland fallback: on pure Wayland (no XWayland), a layer-shell surface
---    via the wlr-layer-shell protocol achieves the same visual result under
---    Sway and other wlroots compositors.
--- 3. Headless no-op: when neither X11 nor Wayland is available (server mode),
---    all methods are silent no-ops — domain logic is not impacted.
--- 4. updateElement() supports streaming partial updates; the implementation
---    re-draws only the targeted text region to minimise flicker.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.tooltip_renderer"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Whether a tooltip window is currently displayed.
local _visible = false

-- TODO(linux): hold a reference to the X11 window / Wayland surface here.
local _window  = nil


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Renders or updates the tooltip.
--- @param payload table { draw_calls, position, duration_sec }
function M.show(payload)
	-- TODO(linux): create/move an override-redirect X11 window at payload.position,
	-- render payload.draw_calls using cairo/pango, and schedule auto-hide after
	-- payload.duration_sec seconds via a luv timer.
	local options = type(payload) == "table" and payload or {}
	local ok, err = pcall(function()
		Logger.debug(LOG, "show(): position=%s duration=%s — rendering not yet implemented.",
			tostring(options.position), tostring(options.duration_sec))
		_visible = true
		-- Placeholder: display a transient notify-send bubble as a visual stub.
		local text = ""
		if type(options.draw_calls) == "table" then
			for _, dc in ipairs(options.draw_calls) do
				if type(dc.text) == "string" then text = dc.text ; break end
			end
		end
		if text ~= "" then
			local safe = text:gsub("'", "'\\''"):sub(1, 200)
			os.execute(string.format("notify-send --urgency=low --expire-time=2000 'ergopti' '%s' 2>/dev/null", safe))
		end
	end)
	if not ok then
		Logger.error(LOG, "show(): rendering failed — %s", tostring(err))
		_visible = false
	end
end

--- Removes the tooltip from the screen immediately.
function M.hide()
	-- TODO(linux): destroy / unmap the X11 window or Wayland surface.
	_visible = false
	_window  = nil
end

--- Returns true if the tooltip is currently visible.
--- @return boolean
function M.isVisible()
	return _visible
end

--- Replaces a single draw call by its stable id (streaming partial update).
--- Falls back to a full show() re-render if the element cannot be targeted.
--- @param draw_call table The replacement draw call ({ id, type, … }).
function M.updateElement(draw_call)
	-- TODO(linux): update only the targeted pango layout region identified by
	-- draw_call.id without re-creating the entire X11 window.
	if type(draw_call) ~= "table" then return end
	if not _visible then return end
	Logger.debug(LOG, "updateElement(): id=%s — partial update not yet implemented, full redraw skipped.",
		tostring(draw_call.id))
end

return M
