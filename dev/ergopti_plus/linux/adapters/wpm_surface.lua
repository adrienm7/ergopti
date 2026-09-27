--- adapters/wpm_surface.lua

--- ==============================================================================
--- MODULE: WPM Widget Surface (Linux)
--- DESCRIPTION:
--- The floating typing-speed widget's window: a small undecorated GTK window,
--- always above, painted with cairo from a frame the shared model computed, and
--- dragged where the user wants it.
---
--- FEATURES & RATIONALE:
--- 1. Draws a frame, decides nothing. The pill's colours, its text, the graph's
---    curve and when to show are _shared/lua/wpm_widget/model.lua's; this file
---    only turns a frame into pixels, so macOS and Linux cannot drift apart on
---    anything but the pixels.
--- 2. Its own window. It used to call a `show_widget` the preview renderer
---    never had, and its stop() hid the preview bubble — the two surfaces share
---    nothing, and now share no window either.
--- 3. Never takes focus. A popup window, focus refused, so a click or a drag on
---    the widget cannot steal the keystroke the user is in the middle of.
--- 4. Dragged by hand. A popup window has no window manager to move it, so the
---    drag is followed here, and the place is handed back to the widget, which
---    keeps it.
--- 5. Degrades to nothing. Without lgi, GTK or a display, is_available() is
---    false and every call is a no-op.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.wpm_surface"

-- Pango works in its own units; a pixel size is multiplied by this to get them.
local PANGO_SCALE = 1024

-- GTK_WINDOW_POPUP: no decoration, no taskbar entry, placed where it is told.
local GTK_WINDOW_POPUP = 1

-- The widget's font family. Sizes and weights are the canon's.
local FONT_FAMILY = "Sans"

-- The mouse button that drags the widget.
local PRIMARY_BUTTON = 1




-- ==============================================
-- ==============================================
-- ======= 1/ Binding ===========================
-- ==============================================
-- ==============================================

-- nil until probed; false when this machine cannot draw.
local _gtk = nil
local _window = nil
local _frame = nil
local _drag = nil
local _on_moved = nil

--- Binds lgi and the GTK namespaces, or records that it cannot.
--- @return table|nil
local function bind()
	if _gtk ~= nil then return _gtk or nil end
	_gtk = false
	local ok_lgi, lgi = pcall(require, "lgi")
	if not ok_lgi or type(lgi) ~= "table" then
		Logger.info(LOG, "lgi is not installed — no WPM widget on this machine.")
		return nil
	end
	local ok, bound = pcall(function()
		return {
			Gtk = lgi.require("Gtk", "3.0"),
			Gdk = lgi.require("Gdk", "3.0"),
			cairo = lgi.cairo,
			Pango = lgi.require("Pango"),
			PangoCairo = lgi.require("PangoCairo"),
		}
	end)
	if not ok or type(bound) ~= "table" then
		Logger.warn(LOG, "GTK 3 could not be bound through lgi — no WPM widget.")
		return nil
	end
	_gtk = bound
	return _gtk
end

--- Test seam: forces the binding without touching a library.
--- @param value table|false|nil
function M._set_binding_for_test(value)
	_gtk = value
end

--- Whether the widget can be drawn at all.
--- @return boolean
function M.is_available()
	return bind() ~= nil
end




-- ==============================================
-- ==============================================
-- ======= 2/ Painting ==========================
-- ==============================================
-- ==============================================

--- "#rrggbb" → r, g, b in 0..1.
local function channels(hex)
	local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then error("not a #rrggbb colour: " .. tostring(hex)) end
	return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

local function set_colour(cr, hex, alpha)
	local r, g, b = channels(hex)
	cr:set_source_rgba(r, g, b, alpha)
end

local function rounded_rect(cr, x, y, w, h, radius)
	local pi = math.pi
	cr:new_sub_path()
	cr:arc(x + w - radius, y + radius,     radius, -pi / 2, 0)
	cr:arc(x + w - radius, y + h - radius, radius, 0,       pi / 2)
	cr:arc(x + radius,     y + h - radius, radius, pi / 2,  pi)
	cr:arc(x + radius,     y + radius,     radius, pi,      3 * pi / 2)
	cr:close_path()
end

--- Draws `text` centred in the box (x, y, w, h), `px` pixels high.
local function centred_text(cr, g, text, px, x, y, w, h)
	local layout = g.PangoCairo.create_layout(cr)
	-- Greyscale edges: subpixel antialiasing assumes an opaque background in a
	-- known pixel order, and paints colour fringes on a translucent pill.
	local options = g.cairo.FontOptions.create()
	options:set_antialias("GRAY")
	g.PangoCairo.context_set_font_options(layout:get_context(), options)
	layout:context_changed()
	local description = g.Pango.FontDescription.from_string(FONT_FAMILY)
	description:set_absolute_size(px * PANGO_SCALE)
	layout:set_font_description(description)
	layout:set_text(text, -1)
	local _, logical = layout:get_pixel_extents()
	cr:move_to(x + (w - logical.width) / 2, y + (h - logical.height) / 2)
	g.PangoCairo.show_layout(cr, layout)
end

local function paint_compact(cr, g, f)
	rounded_rect(cr, 0, 0, f.width, f.height, f.radius)
	cr:clip()
	set_colour(cr, f.background, f.alpha)
	cr:paint()
	set_colour(cr, f.strip, f.alpha)
	cr:rectangle(0, f.strip_y, f.width, f.height_unit)
	cr:fill()
	set_colour(cr, f.text, f.number_alpha)
	centred_text(cr, g, f.number, f.number_font_size, 0, 0, f.width, f.height_number)
	set_colour(cr, f.text, f.unit_alpha)
	centred_text(cr, g, f.unit, f.unit_font_size, 0, f.strip_y, f.width, f.height_unit)
end

local function paint_graph(cr, g, f)
	rounded_rect(cr, 0, 0, f.width, f.height, f.radius)
	set_colour(cr, f.background, f.background_alpha)
	cr:fill_preserve()
	set_colour(cr, f.border, f.border_alpha)
	cr:set_line_width(f.border_width)
	cr:stroke()
	if #f.points > 0 then
		cr:move_to(f.padding, f.bottom)
		for _, point in ipairs(f.points) do cr:line_to(point.x, point.y) end
		cr:line_to(f.width - f.padding, f.bottom)
		cr:close_path()
		set_colour(cr, f.line, f.fill_alpha)
		cr:fill()
		for index, point in ipairs(f.points) do
			if index == 1 then cr:move_to(point.x, point.y) else cr:line_to(point.x, point.y) end
		end
		set_colour(cr, f.line, f.line_alpha)
		cr:set_line_width(f.line_width)
		cr:stroke()
	end
	set_colour(cr, f.text, 1)
	centred_text(cr, g, f.label, f.text_size, 0, f.padding, f.width, f.text_size + 6)
end

--- Paints the current frame. Exposed for the live test, which paints into an
--- image surface and reads the pixels back.
--- @param cr userdata Cairo context.
--- @param frame table From the shared model.
function M.paint(cr, frame)
	local g = bind()
	if not g then return end
	-- Transparent first, so the corners outside the rounded path show the desktop.
	cr:set_operator("SOURCE")
	cr:set_source_rgba(0, 0, 0, 0)
	cr:paint()
	cr:set_operator("OVER")
	if frame.mode == "graph" then paint_graph(cr, g, frame) else paint_compact(cr, g, frame) end
end




-- ==============================================
-- ==============================================
-- ======= 3/ The window ========================
-- ==============================================
-- ==============================================

local function on_press(window, event)
	if event.button ~= PRIMARY_BUTTON then return false end
	local x, y = window:get_position()
	_drag = { mouse_x = event.x_root, mouse_y = event.y_root, x = x, y = y }
	return true
end

local function on_motion(window, event)
	if not _drag then return false end
	window:move(math.floor(_drag.x + event.x_root - _drag.mouse_x + 0.5),
		math.floor(_drag.y + event.y_root - _drag.mouse_y + 0.5))
	return true
end

local function on_release(window, event)
	if not _drag or event.button ~= PRIMARY_BUTTON then return false end
	_drag = nil
	local x, y = window:get_position()
	if type(_on_moved) == "function" then
		local ok, err = pcall(_on_moved, x, y)
		if not ok then Logger.error(LOG, "The moved-widget handler failed: %s.", tostring(err)) end
	end
	return true
end

--- Creates the window, once.
local function ensure_window()
	local g = bind()
	if not g then return nil end
	if _window then return _window end
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
	window:add_events(g.Gdk.EventMask.BUTTON_PRESS_MASK + g.Gdk.EventMask.BUTTON_RELEASE_MASK
		+ g.Gdk.EventMask.POINTER_MOTION_MASK)
	window.on_draw = function(_, cr)
		if _frame then
			local ok, err = pcall(M.paint, cr, _frame)
			if not ok then Logger.error(LOG, "Painting the widget failed: %s.", tostring(err)) end
		end
		return true
	end
	window.on_button_press_event = on_press
	window.on_motion_notify_event = on_motion
	window.on_button_release_event = on_release
	_window = window
	return _window
end

--- Shows `frame` with its top-left corner at (x, y). A drag in progress keeps
--- the window where the user holds it.
--- @param frame table From the shared model.
--- @param x number
--- @param y number
--- @return boolean
function M.draw(frame, x, y)
	local window = ensure_window()
	if not window then return false end
	_frame = frame
	window:resize(frame.width, frame.height)
	if not _drag then window:move(math.floor(x + 0.5), math.floor(y + 0.5)) end
	if not window:get_visible() then window:show_all() end
	window:queue_draw()
	return true
end

--- Hides the widget.
function M.hide()
	_drag = nil
	if _window then pcall(function() _window:hide() end) end
end

--- @return boolean
function M.is_visible()
	if not _window then return false end
	local ok, visible = pcall(function() return _window:get_visible() end)
	return ok and visible == true
end

--- The window's top-left corner, or nil when there is none.
--- @return number|nil x, number|nil y
function M.position()
	if not _window then return nil end
	return _window:get_position()
end

--- Whether the user is dragging the widget now.
--- @return boolean
function M.is_dragging()
	return _drag ~= nil
end

--- Registers what runs when the user drops the widget somewhere.
--- @param fn function|nil (x, y)
function M.on_moved(fn)
	_on_moved = fn
end

--- The primary monitor's geometry.
--- @return table|nil { x, y, w, h }
function M.screen_frame()
	local g = bind()
	if not g then return nil end
	local ok, rect = pcall(function()
		local display = g.Gdk.Display.get_default()
		local monitor = display:get_primary_monitor() or display:get_monitor(0)
		return monitor:get_geometry()
	end)
	if not ok or not rect then return nil end
	return { x = rect.x, y = rect.y, w = rect.width, h = rect.height }
end

--- Where the pointer is, or nil when the display will not say.
--- @return number|nil x, number|nil y
function M.pointer_position()
	local g = bind()
	if not g then return nil end
	local ok, x, y = pcall(function()
		local pointer = g.Gdk.Display.get_default():get_default_seat():get_pointer()
		local _, px, py = pointer:get_position()
		return px, py
	end)
	if not ok then return nil end
	return x, y
end

--- Destroys the window.
function M.destroy()
	if _window then pcall(function() _window:destroy() end) end
	_window = nil
	_frame = nil
	_drag = nil
end

return M
