--- adapters/spotlight_overlay.lua

--- ==============================================================================
--- MODULE: Pointer Spotlight Overlay (Linux, X11)
--- DESCRIPTION:
--- Draws the shapes of `spotlight_mouse`: undecorated, click-through GTK popup
--- windows painted with cairo, a yellow ring around the pointer and a red ×
--- at the centre of every other monitor, as the Windows (GDI+) and macOS
--- (hs.canvas) overlays draw them.
---
--- FEATURES & RATIONALE:
--- 1. One window per shape, sized to the shape: a full-monitor window would
---    need a compositor for its transparent area and would cover the desktop.
--- 2. Click-through and focus-free: an empty input region and no focus on map,
---    so the overlay never takes the click or the key that dismisses it.
---    Without a compositor the window is shaped to the painted pixels.
--- 3. The pointer is read in-process (GDK seat pointer), so the dismissal poll
---    starts no command per tick.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.spotlight_overlay"

-- GTK_WINDOW_POPUP: no decoration, no taskbar entry, above other windows.
local GTK_WINDOW_POPUP = 1

local _gtk = nil
local _windows = {}




-- ===============================================
-- ===============================================
-- ======= 1/ Binding ============================
-- ===============================================
-- ===============================================

--- Binds lgi and GTK 3 once.
--- @return table|nil { Gtk, Gdk, cairo }
local function bind()
	if _gtk ~= nil then return _gtk or nil end
	_gtk = false
	local ok, bound = pcall(function()
		local lgi = require("lgi")
		return { Gtk = lgi.require("Gtk", "3.0"), Gdk = lgi.require("Gdk", "3.0"), cairo = lgi.cairo }
	end)
	if not ok or type(bound) ~= "table" then
		Logger.warn(LOG, "GTK 3 could not be bound through lgi: no pointer spotlight.")
		return nil
	end
	_gtk = bound
	return _gtk
end

--- Whether the overlay can be drawn.
--- @return boolean
function M.is_available()
	return bind() ~= nil
end




-- ===============================================
-- ===============================================
-- ======= 2/ Painting ===========================
-- ===============================================
-- ===============================================

--- Paints one shape into its window.
--- @param cr userdata cairo context.
--- @param shape table { kind = "ring"|"cross", size, style }
local function paint(cr, shape)
	local style, centre = shape.style, shape.size / 2
	cr:set_operator("SOURCE")
	cr:set_source_rgba(0, 0, 0, 0)
	cr:paint()
	cr:set_operator("OVER")
	local colour = shape.kind == "ring" and style.ring_color or style.cross_color
	if shape.kind == "ring" then
		cr:arc(centre, centre, style.ring_radius, 0, 2 * math.pi)
	else
		-- Two bars rotated by 45°, each arm_half long on both sides of the centre.
		cr:translate(centre, centre)
		cr:rotate(math.pi / 4)
		local half, width = style.cross_arm_half, style.cross_arm_width / 2
		cr:rectangle(-half, -width, half * 2, width * 2)
		cr:rectangle(-width, -half, width * 2, half * 2)
	end
	cr:set_source_rgba(colour.red, colour.green, colour.blue, style.fill_alpha)
	cr:fill_preserve()
	cr:set_source_rgba(colour.red, colour.green, colour.blue, style.stroke_alpha)
	cr:set_line_width(style.stroke)
	cr:stroke()
end

--- Opens one shape's window centred on a point.
--- @param g table Binding.
--- @param shape table
--- @return userdata|nil window
local function open_window(g, shape)
	local window = g.Gtk.Window({ type = GTK_WINDOW_POPUP })
	window:set_app_paintable(true)
	window:set_decorated(false)
	window:set_skip_taskbar_hint(true)
	window:set_skip_pager_hint(true)
	window:set_keep_above(true)
	window:set_accept_focus(false)
	window:set_focus_on_map(false)
	local visual = window:get_screen():get_rgba_visual()
	if visual then window:set_visual(visual) end
	window.on_draw = function(_, cr)
		paint(cr, shape)
		return true
	end
	window:resize(shape.size, shape.size)
	window:move(math.floor(shape.x - shape.size / 2), math.floor(shape.y - shape.size / 2))
	window:show_all()
	window:get_window():input_shape_combine_region(g.cairo.Region.create(), 0, 0)
	-- Without a compositor the transparent corners would paint opaque: the
	-- window is cut to the shape's mostly opaque pixels, so the translucent
	-- fill, which needs a compositor, gives way to the stroke alone.
	if not window:get_screen():is_composited() then
		local surface = g.cairo.ImageSurface.create("ARGB32", shape.size, shape.size)
		paint(g.cairo.Context.create(surface), shape)
		window:get_window():shape_combine_region(g.Gdk.cairo_region_create_from_surface(surface), 0, 0)
	end
	window:queue_draw()
	return window
end




-- ===============================================
-- ===============================================
-- ======= 3/ Public API =========================
-- ===============================================
-- ===============================================

--- Shows the shapes, replacing any shown before.
--- @param shapes table Array of { kind, x, y, size, style }.
--- @return boolean shown
function M.show(shapes)
	M.hide()
	local g = bind()
	if not g then return false end
	local ok, err = pcall(function()
		for _, shape in ipairs(shapes) do _windows[#_windows + 1] = open_window(g, shape) end
	end)
	if not ok then
		Logger.error(LOG, "The spotlight overlay could not be drawn: %s.", tostring(err))
		M.hide()
		return false
	end
	return true
end

--- Removes every shape.
function M.hide()
	local windows = _windows
	_windows = {}
	for _, window in ipairs(windows) do pcall(function() window:destroy() end) end
end

--- The pointer position, read from the GDK seat.
--- @return number|nil x
--- @return number|nil y
function M.pointer()
	local g = bind()
	if not g then return nil, nil end
	local ok, x, y = pcall(function()
		local _, px, py = g.Gdk.Display.get_default():get_default_seat():get_pointer():get_position()
		return px, py
	end)
	if not ok then return nil, nil end
	return x, y
end

return M
