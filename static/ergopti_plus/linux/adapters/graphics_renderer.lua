--- linux/adapters/graphics_renderer.lua

--- ==============================================================================
--- MODULE: GraphicsRenderer Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the GraphicsRenderer port contract defined in
--- static/ergopti_plus/shared/ports/GraphicsRenderer.spec.js. Provides a
--- minimal overlay-window interface backed by a yad/zenity child process for
--- simple graphics, or a no-op stub when neither tool is available.
---
--- FEATURES & RATIONALE:
--- 1. Graceful no-op: graphics rendering is not a hard requirement for the
---    hotstring or keylogger core features; all methods are safe no-ops when
---    the optional renderer backend is absent.
--- 2. Log-and-return-zero on failure: createWindow() returns 0 (INVALID_HANDLE)
---    rather than nil so callers can always do a truthiness check.
--- 3. Defensive pcall: all OS calls are wrapped to prevent propagation.
---
--- NOTE: Full overlay graphics (WPM widget, metrics overlay) require a
--- compositor-aware renderer (e.g. GTK4 + layer-shell-protocol). The current
--- implementation provides the contract surface with safe no-ops; a future
--- contributor can replace _backend_create() with a proper native renderer
--- without touching any domain module.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.graphics_renderer"

-- Sentinel returned on allocation failure so callers can branch on 0.
local INVALID_HANDLE = 0

-- No native overlay renderer is wired on Linux yet.
local _renderer_available = false




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Allocates a native layered canvas window.
--- Returns INVALID_HANDLE (0) on Linux until a native renderer is wired.
--- @param opts table { x, y, w, h, clickThrough?, alwaysOnTop? }
--- @return number 0 (no-op stub)
function M.createWindow(opts)
	if not _renderer_available then
		Logger.debug(LOG, "createWindow(): no native renderer available on Linux — returning stub handle.")
		return INVALID_HANDLE
	end
	return INVALID_HANDLE
end

--- Releases a canvas and its resources.
--- @param handle number Canvas handle from createWindow, or 0.
function M.destroyWindow(handle)
	if not handle or handle == INVALID_HANDLE then return end
	-- No-op: handle is always INVALID_HANDLE on current Linux stub
end

--- Paints the canvas surface via a caller-supplied draw function.
--- @param handle number Canvas handle from createWindow, or 0.
--- @param draw_fn function Called as draw_fn(canvas).
function M.drawBitmap(handle, draw_fn)
	if not handle or handle == INVALID_HANDLE then return end
	-- No-op: handle is always INVALID_HANDLE on current Linux stub
end

--- Makes the canvas visible.
--- @param handle number Canvas handle from createWindow, or 0.
function M.show(handle)
	if not handle or handle == INVALID_HANDLE then return end
end

--- Hides the canvas.
--- @param handle number Canvas handle from createWindow, or 0.
function M.hide(handle)
	if not handle or handle == INVALID_HANDLE then return end
end

return M
