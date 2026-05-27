--- adapters/graphics_renderer.lua

--- ==============================================================================
--- MODULE: GraphicsRenderer Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the GraphicsRenderer port contract defined in
--- static/ergopti_plus/shared/ports/GraphicsRenderer.spec.js. Wraps hs.canvas to
--- create and manage layered native windows for overlay graphics without
--- coupling domain modules to the hs.canvas API.
---
--- FEATURES & RATIONALE:
--- 1. Log-and-return-zero on failure: createWindow() returns 0 rather than nil
---    so callers can always do a truthiness check without risking a nil index.
--- 2. Click-through: canvases are created with ignoresMouseEvents = true by
---    default so overlays never intercept user input.
--- 3. Defensive pcall: all hs.canvas calls are wrapped to prevent crashes from
---    propagating into domain modules.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.graphics_renderer"

-- Sentinel returned on allocation failure so callers can branch on 0.
local INVALID_HANDLE = 0




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Allocates a native layered canvas window.
--- @param opts table { x, y, w, h, clickThrough?, alwaysOnTop? }
--- @return userdata|number Canvas handle, or 0 on failure.
function M.createWindow(opts)
	local ok, result = pcall(function()
		local o = type(opts) == "table" and opts or {}
		local x = tonumber(o.x) or 0
		local y = tonumber(o.y) or 0
		local w = tonumber(o.w) or 100
		local h = tonumber(o.h) or 100
		local canvas = hs.canvas.new({ x = x, y = y, w = w, h = h })
		if not canvas then return INVALID_HANDLE end
		canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
		canvas:level(hs.canvas.windowLevels.overlay)
		if o.clickThrough ~= false then
			canvas:ignoresMouseEvents(true)
		end
		if o.alwaysOnTop ~= false then
			canvas:level(hs.canvas.windowLevels.floating)
		end
		return canvas
	end)
	if not ok then
		Logger.error(LOG, "createWindow(): failed — %s", tostring(result))
		return INVALID_HANDLE
	end
	return result or INVALID_HANDLE
end

--- Releases the canvas and all associated resources.
--- @param handle userdata|number Canvas handle from createWindow, or 0.
function M.destroyWindow(handle)
	if not handle or handle == INVALID_HANDLE then return end
	pcall(function()
		handle:delete()
	end)
end

--- Paints the canvas surface via a caller-supplied draw function.
--- @param handle userdata|number Canvas handle from createWindow, or 0.
--- @param draw_fn function Called as draw_fn(canvas).
function M.drawBitmap(handle, draw_fn)
	if not handle or handle == INVALID_HANDLE then return end
	local ok, err = pcall(function()
		if type(draw_fn) == "function" then
			draw_fn(handle)
		end
	end)
	if not ok then
		Logger.error(LOG, "drawBitmap(): draw function raised — %s", tostring(err))
	end
end

--- Makes the canvas visible without stealing focus.
--- @param handle userdata|number Canvas handle from createWindow, or 0.
function M.show(handle)
	if not handle or handle == INVALID_HANDLE then return end
	pcall(function() handle:show() end)
end

--- Hides the canvas.
--- @param handle userdata|number Canvas handle from createWindow, or 0.
function M.hide(handle)
	if not handle or handle == INVALID_HANDLE then return end
	pcall(function() handle:hide() end)
end

return M
