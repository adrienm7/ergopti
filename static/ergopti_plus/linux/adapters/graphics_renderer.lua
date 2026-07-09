--- adapters/graphics_renderer.lua

--- ==============================================================================
--- MODULE: GraphicsRenderer Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the GraphicsRenderer port contract defined in
--- static/ergopti_plus/_shared/core/ports/GraphicsRenderer.spec.js. Provides
--- layered overlay windows backed by lgi (GTK + cairo) for the WPM widget and
--- metrics dashboard overlays.
---
--- When lgi is absent the adapter gracefully no-ops — every public method is
--- safe to call with pcall-wrapped GTK operations.
---
--- FEATURES & RATIONALE:
--- 1. lgi/cairo overlay: createWindow spawns a borderless, always-on-top GTK
---    window with a cairo drawing area. The caller's draw_fn receives a cairo
---    context and paints directly.
--- 2. Graceful no-op: when lgi/cairo is unavailable, createWindow returns
---    INVALID_HANDLE (0) and all methods are safe no-ops.
--- 3. Window pool: up to MAX_WINDOWS overlays tracked by integer handle.
--- 4. Pango text support: the draw_fn contract passes a {ctx, w, h} table so
---    callers can use cairo + PangoLayout for text rendering.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.graphics_renderer"

-- Sentinel returned on allocation failure so callers can branch on 0.
local INVALID_HANDLE = 0

-- =========================================
-- =========================================
-- ======= 1/ lgi Detection ================
-- =========================================
-- =========================================

-- Whether lgi + cairo + GTK are available.
local _renderer_available = false

-- lgi reference (stored after successful probe).
local _lgi = nil

-- cairo namespace (from lgi.cairo).
local _cairo = nil

-- GTK namespace (from lgi.Gtk).
local _Gtk = nil

--- Probes lgi for cairo + GTK availability. Called once on module load.
local function _probe()
	local ok, lgi = pcall(require, "lgi")
	if not ok then
		Logger.debug(LOG, "lgi not available — graphics rendering disabled.")
		return false
	end
	if not pcall(function() return lgi.cairo end) then
		Logger.debug(LOG, "lgi.cairo not available — graphics rendering disabled.")
		return false
	end
	if not pcall(function() return lgi.Gtk end) then
		Logger.debug(LOG, "lgi.Gtk not available — graphics rendering disabled.")
		return false
	end
	_lgi = lgi
	_cairo = lgi.cairo
	_Gtk = lgi.Gtk
	Logger.success(LOG, "lgi/cairo/GTK available — graphics overlay rendering enabled.")
	return true
end

_renderer_available = _probe()


-- =========================================
-- =========================================
-- ======= 2/ Window Pool ==================
-- =========================================
-- =========================================

--- Maximum number of concurrent overlay windows.
local MAX_WINDOWS = 8

--- Window pool: { [handle] = { window, drawing_area, surface, w, h } }
local _windows = {}

--- Next available handle (starts at 1, INVALID_HANDLE = 0).
local _next_handle = 1

--- Allocates a new handle and entry in the pool.
--- @return number Handle > 0, or INVALID_HANDLE if pool is full.
local function _alloc()
	if not _renderer_available then return INVALID_HANDLE end
	for _ = 1, MAX_WINDOWS do
		local h = _next_handle
		_next_handle = (_next_handle % MAX_WINDOWS) + 1
		if not _windows[h] then
			_windows[h] = {}
			return h
		end
	end
	Logger.warn(LOG, "Window pool exhausted (%d windows).", MAX_WINDOWS)
	return INVALID_HANDLE
end


-- =========================================
-- =========================================
-- ======= 3/ GTK Window Operations ========
-- =========================================
-- =========================================

--- Creates a borderless overlay GTK window with a cairo drawing area.
--- The window is positioned at (x, y) with size (w, h). When clickThrough
--- is true, input events pass through to the window underneath.
---
--- @param opts table { x, y, w, h, clickThrough?, alwaysOnTop? }
--- @return number Handle > 0, or INVALID_HANDLE on failure.
function M.createWindow(opts)
	if not _renderer_available then
		Logger.debug(LOG, "createWindow(): no native renderer — returning stub handle.")
		return INVALID_HANDLE
	end

	local options = type(opts) == "table" and opts or {}
	local x = tonumber(options.x) or 0
	local y = tonumber(options.y) or 0
	local w = tonumber(options.w) or 200
	local h = tonumber(options.h) or 100

	local handle = _alloc()
	if handle == INVALID_HANDLE then return INVALID_HANDLE end

	-- Use POPUP windows for overlay semantics: borderless, transient,
	-- and naturally above normal windows on most compositors.
	local window = _Gtk.Window({
		type            = _Gtk.WindowType.POPUP,
		decorated       = false,
		resizable       = false,
		skip_taskbar_hint = true,
		skip_pager_hint = true,
		accept_focus    = not options.clickThrough,
		app_paintable   = true,
	})

	window:set_default_size(w, h)
	window:move(x, y)

	-- If alwaysOnTop, set keep-above.
	if options.alwaysOnTop ~= false then
		pcall(function() window.keep_above = true end)
	end

	-- For click-through: make the window transparent to input.
	if options.clickThrough then
		pcall(function()
			-- Set input shape to an empty region so clicks pass through.
			local cairo_region = _cairo.Region.create()
			window:input_shape_combine_region(cairo_region)
			cairo_region:destroy()  -- Release local reference; GTK retained its own.
		end)
	end

	-- Create cairo drawing area.
	local drawing_area = _Gtk.DrawingArea()
	window:add(drawing_area)

	-- Connect the draw signal: caller's draw_fn gets a {ctx, w, h} table.
	drawing_area.on_draw = function(da, cr)
		local wref = _windows[handle]
		if not wref or not wref.draw_fn then return false end
		-- Wrap cairo context + dimensions in a table so the caller gets a
		-- platform-agnostic canvas-like object.
		local canvas = {
			ctx = cr,
			w   = wref.w or w,
			h   = wref.h or h,
		}
		local ok, err = pcall(wref.draw_fn, canvas)
		if not ok then
			Logger.error(LOG, "draw_fn for handle %d raised: %s", handle, tostring(err))
		end
		return false  -- propagate further
	end

	-- Clean up pool entry when the window is destroyed externally
	-- (e.g., window manager close, compositor teardown).
	window.on_destroy = function()
		_windows[handle] = nil
		Logger.debug(LOG, "Overlay window externally destroyed: handle=%d.", handle)
	end

	-- Store references.
	_windows[handle] = {
		window       = window,
		drawing_area = drawing_area,
		w = w,
		h = h,
	}

	Logger.debug(LOG, "Overlay window created: handle=%d pos=(%d,%d) size=%dx%d.",
		handle, x, y, w, h)

	-- Show if requested at creation time.
	window:show_all()

	return handle
end


--- Destroys an overlay window and releases its resources.
--- Safe to call with INVALID_HANDLE or an already-destroyed handle.
--- @param handle number Canvas handle from createWindow.
function M.destroyWindow(handle)
	if not handle or handle == INVALID_HANDLE then return end
	local wref = _windows[handle]
	if not wref then return end
	if wref.window then
		pcall(function() wref.window:destroy() end)
	end
	_windows[handle] = nil
	Logger.debug(LOG, "Overlay window destroyed: handle=%d.", handle)
end


--- Paints the canvas surface via a caller-supplied draw function.
--- The draw function is called by GTK on the next expose event. Call
--- queue_draw() on the drawing area to trigger a repaint.
---
--- @param handle number Canvas handle from createWindow.
--- @param draw_fn function Called as draw_fn({ctx, w, h}).
function M.drawBitmap(handle, draw_fn)
	if not handle or handle == INVALID_HANDLE then return end
	local wref = _windows[handle]
	if not wref then
		Logger.warn(LOG, "drawBitmap(): invalid handle %d.", handle)
		return
	end
	if type(draw_fn) ~= "function" then
		Logger.warn(LOG, "drawBitmap(): draw_fn is not a function.")
		return
	end

	wref.draw_fn = draw_fn

	-- Trigger an immediate repaint.
	if wref.drawing_area then
		pcall(function() wref.drawing_area:queue_draw() end)
	end
end


--- Makes the canvas visible.
--- @param handle number Canvas handle from createWindow.
function M.show(handle)
	if not handle or handle == INVALID_HANDLE then return end
	local wref = _windows[handle]
	if not wref or not wref.window then return end
	pcall(function() wref.window:show_all() end)
end


--- Hides the canvas.
--- @param handle number Canvas handle from createWindow.
function M.hide(handle)
	if not handle or handle == INVALID_HANDLE then return end
	local wref = _windows[handle]
	if not wref or not wref.window then return end
	pcall(function() wref.window:hide() end)
end


return M
