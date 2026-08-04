--- adapters/graphics_renderer.lua

--- ==============================================================================
--- MODULE: GraphicsRenderer Adapter (Linux)
--- DESCRIPTION:
--- Draws the preview tooltip: an undecorated, click-through GTK window with a
--- cairo-painted rounded panel and Pango-measured text.
---
--- WHY GTK AND CAIRO RATHER THAN A WEBVIEW:
--- The driver already embeds WebKit2GTK for its settings windows, and a tooltip
--- is not a settings window. It appears on a keystroke, must be measured before
--- it is placed (the layout maths needs the panel's size to clamp it on screen),
--- must never take focus, and must never eat a click. A WebView gives none of
--- those cheaply and costs a page load per preview.
---
--- WHY IT IS AN ADAPTER AND NOT A UI MODULE:
--- Everything here is the OS drawing surface. What to draw — which candidates,
--- in what order, dimmed or not — is ui/tooltip/preview.lua, and the geometry
--- and colours are shared with the other two drivers. This file knows about
--- cairo and knows nothing about hotstrings.
---
--- FEATURES & RATIONALE:
--- 1. Measured, then placed. Pango reports the text extents, the panel size
---    follows from them, and only then does the shared layout decide where the
---    window goes — so the clamp has a real size to clamp.
--- 2. Click-through and focus-free. An input region of zero area makes the
---    window transparent to the pointer; accept-focus and focus-on-map are off,
---    so a preview cannot steal the keystroke that produced it.
--- 3. Degrades to nothing. Without lgi, GTK or a display, is_available() is
---    false and every call is a no-op. A driver whose expansions work must not
---    stop working because it cannot draw a hint about them.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Tint = require("tooltip.tint")
local Layout = require("tooltip.layout")

local LOG = "adapters.graphics_renderer"

-- Pango works in its own units; a point size is multiplied by this to get them.
local PANGO_SCALE = 1024

-- The window type that gets no decoration, no taskbar entry and stays above.
-- "popup" in GTK terms; the enum value is GTK_WINDOW_POPUP.
local GTK_WINDOW_POPUP = 1




-- ==============================================
-- ==============================================
-- ======= 1/ Binding ===========================
-- ==============================================
-- ==============================================

-- nil until probed; false when this machine cannot draw.
local _gtk = nil

-- The live window and its cached drawing state.
local _window = nil
local _surface_rows = nil
local _style = nil
local _size = { w = 0, h = 0 }

--- Binds lgi and the GTK namespaces, or records that it cannot.
--- @return table|nil { lgi, Gtk, Gdk, cairo, Pango, PangoCairo }
local function bind()
	if _gtk ~= nil then return _gtk or nil end
	_gtk = false

	local ok_lgi, lgi = pcall(require, "lgi")
	if not ok_lgi or type(lgi) ~= "table" then
		Logger.info(LOG, "lgi is not installed — no tooltip preview on this machine.")
		return nil
	end

	local ok, bound = pcall(function()
		return {
			lgi        = lgi,
			Gtk        = lgi.require("Gtk", "3.0"),
			Gdk        = lgi.require("Gdk", "3.0"),
			cairo      = lgi.cairo,
			Pango      = lgi.require("Pango"),
			PangoCairo = lgi.require("PangoCairo"),
		}
	end)
	if not ok or type(bound) ~= "table" then
		Logger.warn(LOG, "GTK 3 could not be bound through lgi — no tooltip preview.")
		return nil
	end

	_gtk = bound
	Logger.debug(LOG, "Tooltip renderer bound (lgi + GTK 3).")
	return _gtk
end

--- Test seam: forces the binding without touching a library.
--- @param value table|false|nil
function M._set_binding_for_test(value)
	_gtk = value
end

--- Whether a preview can be drawn at all.
--- @return boolean
function M.is_available()
	return bind() ~= nil
end




-- ==============================================
-- ==============================================
-- ======= 2/ Measuring =========================
-- ==============================================
-- ==============================================

--- Measures one row of text with Pango.
---
--- Measurement has to happen before placement: the shared layout clamps the
--- panel inside the screen, and it cannot do that without the panel's size. A
--- renderer that drew first and measured after would place every tooltip using
--- the PREVIOUS one's dimensions.
--- @param layout userdata A Pango layout.
--- @param text string
--- @param font string
--- @param size number Point size.
--- @return number width, number height
local function measure(layout, text, font, size)
	local g = bind()
	local description = g.Pango.FontDescription.from_string(font)
	description:set_size(size * PANGO_SCALE)
	layout:set_font_description(description)
	layout:set_text(text, -1)
	local w, h = layout:get_pixel_size()
	return w, h
end

--- Computes the panel size for a set of rows.
---
--- @param rows table Array of { text, label }.
--- @param style table From ui/tooltip/config.lua.
--- @param pango_layout userdata
--- @return table { w, h }, table Per-row metrics.
function M.measure_rows(rows, style, pango_layout)
	local g = bind()
	if not g then return { w = 0, h = 0 }, {} end

	local metrics = {}
	local widest, total_height = 0, 0

	for i, row in ipairs(rows) do
		local text_w, text_h = measure(pango_layout, row.text or "", style.fonts.main, style.sizes.main)
		local label_w, label_h = 0, 0
		if row.label and row.label ~= "" then
			label_w, label_h = measure(pango_layout, row.label, style.fonts.main, style.sizes.hint)
		end

		-- The label is right-aligned on the same line, so the row is as wide as
		-- both plus the gap between them — not as wide as the wider of the two.
		local row_w = text_w + (label_w > 0 and (style.layout.label_gap + label_w) or 0)
		local row_h = math.max(text_h, label_h)

		metrics[i] = { text_w = text_w, text_h = text_h, label_w = label_w, height = row_h }
		widest = math.max(widest, row_w)
		total_height = total_height + row_h
		if i < #rows then total_height = total_height + style.layout.line_spacing end
	end

	return {
		w = widest + style.layout.pad_x * 2,
		h = total_height + style.layout.pad_y * 2,
	}, metrics
end




-- ==============================================
-- ==============================================
-- ======= 3/ Drawing ===========================
-- ==============================================
-- ==============================================

--- Traces a rounded rectangle onto a cairo context.
--- @param cr userdata Cairo context.
--- @param w number
--- @param h number
--- @param radius number
local function rounded_rect(cr, w, h, radius)
	local pi = math.pi
	cr:new_sub_path()
	cr:arc(w - radius, radius,     radius, -pi / 2, 0)
	cr:arc(w - radius, h - radius, radius, 0,       pi / 2)
	cr:arc(radius,     h - radius, radius, pi / 2,  pi)
	cr:arc(radius,     radius,     radius, pi,      3 * pi / 2)
	cr:close_path()
end

--- Paints the panel and its rows.
--- @param cr userdata Cairo context.
--- @param rows table
--- @param metrics table
--- @param style table
--- @param size table { w, h }
--- @param background table { red, green, blue, alpha }
local function paint(cr, rows, metrics, style, size, background)
	local g = bind()

	-- Transparent first, so the corners outside the rounded path are not black
	-- squares on a compositor that honours alpha.
	cr:set_operator("SOURCE")
	cr:set_source_rgba(0, 0, 0, 0)
	cr:paint()
	cr:set_operator("OVER")

	rounded_rect(cr, size.w, size.h, style.layout.corner_radius)
	cr:set_source_rgba(background.red, background.green, background.blue,
		background.alpha * style.colors.canvas_alpha)
	cr:fill_preserve()

	local border = style.colors.border_white
	cr:set_source_rgba(border, border, border, style.colors.border_alpha)
	cr:set_line_width(1)
	cr:stroke()

	local pango_layout = g.PangoCairo.create_layout(cr)
	local y = style.layout.pad_y

	for i, row in ipairs(rows) do
		local m = metrics[i]
		-- A dimmed row is one the engine will not fire — a candidate whose
		-- category is off, or one a higher-priority mapping beats. Showing it
		-- greyed rather than hiding it is what tells the user WHY nothing
		-- happened.
		local alpha = row.dimmed and 0.45 or 1.0

		local description = g.Pango.FontDescription.from_string(style.fonts.main)
		description:set_size(style.sizes.main * PANGO_SCALE)
		pango_layout:set_font_description(description)
		pango_layout:set_text(row.text or "", -1)

		cr:set_source_rgba(1, 1, 1, alpha)
		cr:move_to(style.layout.pad_x, y)
		g.PangoCairo.show_layout(cr, pango_layout)

		if row.struck then
			-- Struck through, not omitted: a replacement the engine will refuse is
			-- more useful shown crossed out than absent, because absent looks like
			-- the driver failing to notice it.
			cr:set_line_width(1)
			cr:move_to(style.layout.pad_x, y + m.text_h / 2)
			cr:line_to(style.layout.pad_x + m.text_w, y + m.text_h / 2)
			cr:stroke()
		end

		if row.label and row.label ~= "" then
			local label_description = g.Pango.FontDescription.from_string(style.fonts.main)
			label_description:set_size(style.sizes.hint * PANGO_SCALE)
			pango_layout:set_font_description(label_description)
			pango_layout:set_text(row.label, -1)
			cr:set_source_rgba(1, 1, 1, alpha * 0.6)
			-- Right-aligned against the panel's inner edge, which is what makes a
			-- column of triggers readable down the right-hand side.
			cr:move_to(size.w - style.layout.pad_x - m.label_w, y)
			g.PangoCairo.show_layout(cr, pango_layout)
		end

		y = y + m.height + style.layout.line_spacing
	end
end




-- ==============================================
-- ==============================================
-- ======= 4/ The window ========================
-- ==============================================
-- ==============================================

--- Creates the popup window, once.
--- @return userdata|nil
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
	-- A preview that took focus would swallow the next keystroke — the one the
	-- user is in the middle of typing, which is what produced the preview.
	window:set_accept_focus(false)
	window:set_focus_on_map(false)

	local screen = window:get_screen()
	local visual = screen:get_rgba_visual()
	if visual then window:set_visual(visual) end

	window.on_draw = function(_, cr)
		if _surface_rows and _style then
			paint(cr, _surface_rows.rows, _surface_rows.metrics, _style, _size, _surface_rows.background)
		end
		return true
	end

	_window = window
	return _window
end

--- Makes the window transparent to the pointer.
---
--- An empty input region rather than a hit-test callback: the region is set once
--- and costs nothing per event, and a callback would be asked on every motion
--- event that crosses the tooltip.
--- @param window userdata
local function make_click_through(window)
	local g = bind()
	local ok = pcall(function()
		local region = g.cairo.Region.create()
		window:get_window():input_shape_combine_region(region, 0, 0)
	end)
	if not ok then
		Logger.debug(LOG, "Click-through could not be set — the preview will absorb clicks.")
	end
end




-- ==============================================
-- ==============================================
-- ======= 5/ Public API ========================
-- ==============================================
-- ==============================================

--- Shows the preview.
---
--- @param rows table Array of { text, label?, dimmed?, struck? }.
--- @param opts table
---   style table         From ui/tooltip/config.lua.
---   accent table|nil    { red, green, blue } category accent, or nil.
---   anchor table|nil    { type, x, y, h } from the anchoring cascade.
---   screen table        { x, y, w, h } the frame to clamp within.
--- @return boolean True when something was drawn.
function M.show(rows, opts)
	local g = bind()
	if not g or type(rows) ~= "table" or #rows == 0 then return false end

	local window = ensure_window()
	if not window then return false end

	_style = opts.style
	local pango_layout = g.PangoCairo.create_layout(
		g.cairo.Context.create(g.cairo.ImageSurface.create("ARGB32", 1, 1)))

	local size, metrics = M.measure_rows(rows, _style, pango_layout)
	_size = size

	local background = Tint.mix(opts.accent, {
		lightness  = _style.tint.lightness,
		saturation = _style.tint.saturation,
		alpha      = _style.colors.bg_alpha,
		neutral    = {
			red = _style.colors.bg.red, green = _style.colors.bg.green,
			blue = _style.colors.bg.blue, alpha = _style.colors.bg_alpha,
		},
	})

	_surface_rows = { rows = rows, metrics = metrics, background = background }

	local position = Layout.compute_position(opts.anchor, size, opts.screen, {
		caret_offset_x  = _style.positioning.caret_offset_x,
		caret_offset_y  = _style.positioning.caret_offset_y,
		window_offset_y = _style.positioning.window_offset_y,
		screen_margin   = _style.layout.screen_margin,
	})

	window:resize(math.floor(size.w + 0.5), math.floor(size.h + 0.5))
	window:move(math.floor(position.x + 0.5), math.floor(position.y + 0.5))
	window:show_all()
	make_click_through(window)
	window:queue_draw()
	return true
end

--- Hides the preview.
function M.hide()
	if _window then pcall(function() _window:hide() end) end
end

--- @return boolean True when a preview is on screen.
function M.is_visible()
	if not _window then return false end
	local ok, visible = pcall(function() return _window:get_visible() end)
	return ok and visible == true
end

--- Destroys the window.
function M.destroy()
	if not _window then return end
	pcall(function() _window:destroy() end)
	_window = nil
	_surface_rows = nil
end

return M
