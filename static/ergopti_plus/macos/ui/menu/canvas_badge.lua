--- ui/menu/canvas_badge.lua

--- ==============================================================================
--- MODULE: Canvas Badge
--- DESCRIPTION:
--- Creates the pill-shaped canvas element displayed in the macOS menu bar.
---
--- FEATURES & RATIONALE:
--- 1. Extracted from builder.lua so badge rendering is isolated from structural
---    menu assembly logic.
--- 2. Adapts pill appearance for light/dark mode and paused state.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("infra.logger")
local ManifestMenu = require("infra.manifest_menu")
local LOG    = "canvas_badge"





-- ==================================
-- ==================================
-- ======= 1/ Badge Rendering =======
-- ==================================
-- ==================================

--- Builds the pill badge menu item for the macOS menu bar title.
--- @param items table The items list to prepend the badge into (modified in place).
--- @param ctx table Menu context, used for ctx.paused and ctx.script_control.
--- @param on_click function Callback invoked when the badge is clicked.
function M.prepend_to(items, ctx, on_click)
	local paused = ctx and ctx.paused
	local frame = ManifestMenu.template_rows("macos_canvas_badge_frame", {}, {
		["macos_badge_is_paused"] = function() return not not paused end,
		["macos_badge_is_active"] = function() return not paused end,
	}, {})
	if type(frame) ~= "table" or #frame ~= 2 or type(frame[1].label) ~= "string"
		or frame[1].label == "" or frame[2].separator ~= true then
		Logger.error(LOG, "Declared canvas badge presentation refused.")
		return false
	end
	local compose = ManifestMenu.native_composition("macos_canvas_badge_root")
	if type(compose) ~= "function" then
		Logger.error(LOG, "Declared canvas badge root composition refused.")
		return false
	end
	local display_text = frame[1].label
	-- Calculate the required canvas width based on the longest root menu item
	local max_text_width = 0
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title ~= "-" then
			local ok_s, size_s = pcall(hs.drawing.getTextDrawingSize, item.title, { font = ".AppleSystemUIFont", size = 14 })
			if ok_s and type(size_s) == "table" and size_s.w then
				local extra_width = (item.menu ~= nil) and 15 or 0
				if (size_s.w + extra_width) > max_text_width then
					max_text_width = size_s.w + extra_width
				end
			end
		end
	end

	-- Create a transparent canvas that spans the available menu width to force centering
	local canvas_w = math.ceil(max_text_width)

	local ok, size = pcall(hs.drawing.getTextDrawingSize, display_text, { font = "Helvetica-Bold", size = 14 })
	local text_w = ok and size and size.w or 80

	-- Configure perfectly balanced padding for the pill
	local pad_x = 8
	local pad_y = 10
	local pill_w = math.ceil(text_w + (pad_x * 2))
	local pill_h = 14 + (pad_y * 2)

	-- Mathematically center the pill horizontally inside the transparent canvas
	local pill_x = (canvas_w - pill_w + 2 * pad_x) / 2

	local is_dark = hs.host.interfaceStyle() == "Dark"
	local bg_color   = is_dark and { white = 1 } or { white = 0.15 }
	local text_color = is_dark and { white = 0.1 } or { white = 1 }
	local menu_bg    = is_dark and { white = 0 } or { white = 1 }

	-- By default the pill uses bg_color; when paused we fill with the
	-- menubar background and add a thin border using a contrasting text color
	local rect_fill = bg_color
	local rect_stroke = nil
	local rect_stroke_w = nil
	if paused then
		-- Fill with the menubar background so the pill blends in
		rect_fill = menu_bg
		-- Border/text should match the visible text color: white in Dark, black in Light
		rect_stroke = is_dark and { white = 1 } or { white = 0 }
		text_color = rect_stroke
		rect_stroke_w = 1
	end

	local canvas_obj = hs.canvas.new({ x = 0, y = 0, w = canvas_w, h = pill_h })

	local rect_elem = {
		type             = "rectangle",
		action           = rect_stroke and "strokeAndFill" or "fill",
		fillColor        = rect_fill,
		roundedRectRadii = { xRadius = 8, yRadius = 8 },
		frame            = { x = pill_x, y = 0, w = pill_w, h = pill_h }
	}
	if rect_stroke then
		rect_elem.strokeColor = rect_stroke
		rect_elem.strokeWidth = rect_stroke_w
	end

	canvas_obj:appendElements(
		rect_elem,
		{
			type          = "text",
			text          = display_text,
			textColor     = text_color,
			textAlignment = "center",
			textSize      = 14,
			textFont      = "Helvetica-Bold",
			-- Adjust Y slightly (pad_y - 2) to account for font baseline rendering
			frame         = { x = pill_x, y = pad_y - 2, w = pill_w, h = pill_h }
		}
	)

	Logger.debug(LOG, "Canvas badge built (canvas_w=%d pill_w=%d paused=%s).", canvas_w, pill_w, tostring(paused))

	local img = canvas_obj:imageFromCanvas()
	-- Release the NSWindow handle immediately; the image is already captured
	canvas_obj:delete()
	local badge = {
		title = "",
		image = img,
		fn    = on_click,
	}
	local boundary = { title = frame[2].separator and "-" }
	-- These are completed native objects; the declared frame owns their placement.
	if compose({ badge = { badge }, boundary = { boundary }, body = items }) ~= true then
		Logger.error(LOG, "Completed canvas badge root publication refused.")
		return false
	end
end

return M
