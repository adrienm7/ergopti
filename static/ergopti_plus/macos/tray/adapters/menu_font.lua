--- tray/adapters/menu_font.lua

--- ==============================================================================
--- MODULE: Tray Menu Font Adapter (Hammerspoon)
--- DESCRIPTION:
--- Draws the tray menu's titles in a reading font (script.reading_font) by
--- turning each plain title into an hs.styledtext in that face, at the size of
--- the system's menu font. hs.menubar takes a styled title as the item's
--- attributed title, which AppKit draws as given: it no longer greys a disabled
--- row itself, so a disabled row's title carries the disabled text colour, and
--- every title carries the label colour, a dynamic system colour that follows
--- the light and dark appearance.
---
--- FEATURES & RATIONALE:
--- 1. Only the text changes: check marks, submenu arrows and the row's state
---    belong to the NSMenuItem, not to its title, so they stay native. The
---    status dots (🔴/🟡) are characters of the title; AppKit draws them from
---    the emoji font as it does any glyph the face lacks (the bundled faces
---    are a Latin subset, so other scripts fall back the same way).
--- 2. Styled titles compose: a shortcut hint row (menu/ui/builder/
---    shortcut_hint.lua) keeps its grey hint span and takes the face. Left as
---    they are: separators and the header pill (an image row, empty title).
--- 3. Fail loudly: a face AppKit does not know (the launcher could not
---    register it) or a missing system menu font size is an error returned by
---    font_attributes() to the caller, which logs it; no title changes then.
--- ==============================================================================

local M = {}

local hs = hs

-- Dynamic system colours, resolved by AppKit at draw time for the appearance.
local LABEL_COLOR    = { list = "System", name = "labelColor" }
local DISABLED_COLOR = { list = "System", name = "disabledControlTextColor" }

--- Reads a file's bytes.
--- @param path string Absolute path.
--- @return string|nil bytes Nil when the file cannot be read.
function M.read_file(path)
	local ok, handle = pcall(io.open, path, "rb")
	if not ok or not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

--- The point size of the system's menu font.
--- @return number|nil size
local function menu_font_size()
	local fonts = hs.styledtext.defaultFonts
	local menu = type(fonts) == "table" and fonts.menu or nil
	if type(menu) ~= "table" or type(menu.size) ~= "number" or menu.size <= 0 then return nil end
	return menu.size
end

--- The font attributes of a face at the system menu size.
--- @param postscript string The face's PostScript name (menu_faces.json).
--- @return table|nil font { name, size }, nil when refused.
--- @return string|nil error Why the face cannot be drawn.
function M.font_attributes(postscript)
	if hs.styledtext.validFont(postscript) ~= true then
		return nil, "AppKit knows no font " .. tostring(postscript) .. " (the launcher registers it for the session)"
	end
	local size = menu_font_size()
	if size == nil then return nil, "hs.styledtext.defaultFonts gives no menu font size" end
	return { name = postscript, size = size }, nil
end

--- Restyles, in place, every title of a menu tree in one face: a plain title
--- becomes styled text in the label (or disabled) colour, a styled title (a
--- shortcut hint row) takes the face and keeps its own colours.
--- @param items table The hs.menubar rows, submenus under `menu`.
--- @param font table { name, size } from font_attributes().
--- @return integer|nil count Titles restyled, nil when refused.
--- @return string|nil error Why nothing was restyled.
function M.restyle(items, font)
	if type(items) ~= "table" then return nil, "the menu tree is not a table" end
	if type(font) ~= "table" or type(font.name) ~= "string" or type(font.size) ~= "number" then
		return nil, "no font to draw the menu in"
	end
	local enabled = { font = font, color = LABEL_COLOR }
	local disabled = { font = font, color = DISABLED_COLOR }
	local count = 0
	local function walk(rows)
		for _, row in ipairs(rows) do
			if type(row) == "table" then
				local title = row.title
				if type(title) == "string" and title ~= "" and title ~= "-" then
					row.title = hs.styledtext.new(title, row.disabled == true and disabled or enabled)
					count = count + 1
				elseif type(title) == "userdata" or (type(title) == "table" and type(title.setStyle) == "function") then
					-- setStyle merges: the spans keep their colours, the font is replaced.
					row.title = title:setStyle({ font = font })
					count = count + 1
				end
				if type(row.menu) == "table" then walk(row.menu) end
			end
		end
	end
	walk(items)
	return count, nil
end

return M
