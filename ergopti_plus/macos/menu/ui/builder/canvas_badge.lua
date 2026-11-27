--- menu/ui/builder/canvas_badge.lua

--- ==============================================================================
--- MODULE: Canvas Badge
--- DESCRIPTION:
--- Creates the pill-shaped canvas element displayed in the macOS menu bar.
---
--- FEATURES & RATIONALE:
--- 1. Extracted from builder.lua so badge rendering is isolated from structural
---    menu assembly logic.
--- 2. Adapts pill appearance for light/dark mode and paused state.
--- 3. Centred On The Menu: NSMenu draws a row's image after the state column on
---    its left and keeps the submenu-arrow column on its right, so a pill
---    centred in its own image sat left of the menu's middle (field photo of
---    dev.178, 2026-11-24: about 30 % to 52 % of the menu's width). The pill is
---    centred on the whole menu width those columns frame (M.layout).
--- 4. Measured As Drawn: the image must span the real title column, so the
---    widest row is measured with the title the menu finally draws, the
---    shortcut hint of « Suspendre », « Recharger » and « Quitter » included
---    (prepend_to's drawn_titles). Measured without it, the title column was
---    about 37 points wider than the image, and a 62-point arrow column had
---    been calibrated to make up for that gap (field photo of v1.0.10,
---    2026-11-26: the pill stood about 11 points right of the middle).
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("core.logger.engine.logger")
local ManifestMenu = require("menu.engine.manifest_menu")
local LOG    = "canvas_badge"

--- The menu's native metrics, in points. `left` is the state (check mark)
--- column every row keeps before its title or image; `trailing` the inset
--- after the title column, widened by `submenu_arrow` once any root row opens
--- a submenu; `font` the row font size the root titles are measured in.
--- Calibrated on the v1.0.10 photo of 2026-11-26 (menu 1205 px wide, pill of
--- 74 points 320 px wide, 47 px right of the middle, so 11 points): with the
--- 62-point arrow column the pill moved 31 points right, and the unmeasured
--- hint of « ⏸︎ Suspendre    Opt droit + Entrée », about 37 points wider than
--- « 🌐 Dispositions et émulation », moved it about 18 points left. The right
--- columns therefore exceed the left one by 62 - 2 × 11 - 37 ≈ 3 points.
local MENU_COLUMNS = { left = 22, trailing = 22, submenu_arrow = 3, font = 14 }

-- The system font NSMenu draws its rows in.
local MENU_FONT_NAME = ".AppleSystemUIFont"

--- The menu's native metrics the badge geometry assumes, for the tests.
--- @return table columns { left, trailing, submenu_arrow, font }
function M.menu_columns() return MENU_COLUMNS end

--- The font of a root row's title, as hs.styledtext names a font: a styled
--- title (the tray's shortcut hints) must name it, or AppKit draws it in
--- Helvetica 12.
--- @return table font { name, size }
function M.menu_font() return { name = MENU_FONT_NAME, size = MENU_COLUMNS.font } end

-- The font the root rows are drawn in, nil for the system font: the rows take
-- the reading font after the root compositions (menu/ui/builder/reading_font.lua),
-- so the pill measures them in it. Set by the builder before each badge.
local row_font = nil

--- Names the font the next badge measures the root rows in.
--- @param font table|nil { name, size } (hs.styledtext), nil for the system font.
function M.measure_rows_in(font)
	row_font = font
end

-- The pill's padding around its text and the text size, in points.
local PILL_PAD_X, PILL_PAD_Y, PILL_TEXT_SIZE = 8, 10, 14
local pending_canvas = nil
local canvas_busy = false

--- Releases the exact canvas even when badge rendering failed.
--- @return boolean settled
local function release_canvas()
	if canvas_busy then return false end
	if not pending_canvas then return true end
	local canvas = pending_canvas
	canvas_busy = true
	local ok = pcall(function() canvas:delete() end)
	canvas_busy = false
	if not ok then
		Logger.error(LOG, "Canvas badge cleanup failed; exact canvas retained.")
		return false
	end
	if pending_canvas == canvas then pending_canvas = nil end
	return true
end





-- ==================================
-- ==================================
-- ======= 1/ Badge Rendering =======
-- ==================================
-- ==================================

--- Width of one root row's title in the menu font, nil for a separator, an
--- empty title (an image row) or a title that cannot be measured.
--- @param title any A string or an hs.styledtext.
--- @return number|nil width
local function title_width(title)
	if not ((type(title) == "string" and title ~= "-" and title ~= "") or type(title) == "userdata") then return nil end
	local font = row_font or M.menu_font()
	local ok, size = pcall(hs.drawing.getTextDrawingSize, title, { font = font.name, size = font.size })
	return ok and type(size) == "table" and type(size.w) == "number" and size.w or nil
end

--- Computes the badge image and the pill inside it so the pill sits in the
--- middle of the whole menu. The image starts after the left column and the
--- menu ends the trailing columns after the widest title or image, so the
--- pill's centre in the image is half of (image + trailing - left). The text
--- frame is the pill's own, so the caption is centred inside the pill.
--- @param widest number Widest root title, as the menu draws it, in points.
--- @param has_submenu boolean Whether a root row opens a submenu.
--- @param text_w number Width of the pill's text.
--- @return table geometry { canvas_w, pill_w, pill_h, pill_x, text_x, text_w }
function M.layout(widest, has_submenu, text_w)
	local columns = MENU_COLUMNS
	local trailing = columns.trailing + (has_submenu and columns.submenu_arrow or 0)
	local shift = trailing - columns.left
	local pill_w = math.ceil(text_w + (PILL_PAD_X * 2))
	local pill_h = PILL_TEXT_SIZE + (PILL_PAD_Y * 2)
	-- The image never narrows the title column the other rows need, and is wide
	-- enough to hold the pill at its shifted place when it is the widest row.
	local canvas_w = math.max(math.ceil(widest), pill_w + math.abs(shift))
	local pill_x = (canvas_w + shift - pill_w) / 2
	return { canvas_w = canvas_w, pill_w = pill_w, pill_h = pill_h, pill_x = pill_x, text_x = pill_x, text_w = pill_w }
end

--- Builds the pill badge menu item for the macOS menu bar title.
--- @param items table The items list to prepend the badge into (modified in place).
--- @param ctx table Menu context, used for ctx.paused and ctx.script_control.
--- @param on_click function Callback invoked when the badge is clicked.
--- @param drawn_titles table|nil Row -> the title the menu finally draws for it
---   when it differs from row.title (a shortcut hint row), so the image spans
---   the real title column.
function M.prepend_to(items, ctx, on_click, drawn_titles)
	if not release_canvas() then return false end
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
	local ok, size = pcall(hs.drawing.getTextDrawingSize, display_text, { font = "Helvetica-Bold", size = PILL_TEXT_SIZE })
	local text_w = ok and size and size.w or 80
	-- The widest root row, and whether the menu keeps its submenu-arrow column
	local widest, has_submenu = 0, false
	for _, item in ipairs(items) do
		if item.menu ~= nil then has_submenu = true end
		local drawn = type(drawn_titles) == "table" and drawn_titles[item] or nil
		local width = title_width(drawn ~= nil and drawn or item.title)
		if width and width > widest then widest = width end
	end
	local geometry = M.layout(widest, has_submenu, text_w)
	local canvas_w, pill_w, pill_h, pill_x = geometry.canvas_w, geometry.pill_w, geometry.pill_h, geometry.pill_x
	local text_x, text_box_w = geometry.text_x, geometry.text_w
	local pad_y = PILL_PAD_Y

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
	if not canvas_obj then return false end
	pending_canvas = canvas_obj
	canvas_busy = true

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

	local rendered, img = xpcall(function()
		canvas_obj:appendElements(
			rect_elem,
			{
				type          = "text",
				text          = display_text,
				textColor     = text_color,
				textAlignment = "center",
				textSize      = PILL_TEXT_SIZE,
				textFont      = "Helvetica-Bold",
				-- Adjust Y slightly (pad_y - 2) to account for font baseline rendering
				frame         = { x = text_x, y = pad_y - 2, w = text_box_w, h = pill_h }
			}
		)

		Logger.debug(LOG, "Canvas badge built (canvas_w=%d pill_w=%d paused=%s).", canvas_w, pill_w, tostring(paused))

		return canvas_obj:imageFromCanvas()
	end, debug.traceback)
	canvas_busy = false
	-- Release the NSWindow handle immediately; the image is already captured
	if not release_canvas() then return false end
	if not rendered or not img then
		Logger.error(LOG, "Canvas badge rendering failed: %s.", tostring(img))
		return false
	end
	-- The pill is an image with an empty title, which VoiceOver reads as
	-- nothing: the tooltip carries its text (state and pause action) in words.
	local badge = {
		title = "",
		image = img,
		tooltip = display_text,
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
