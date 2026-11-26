--- menu/ui/builder/reading_font.lua

--- ==============================================================================
--- MODULE: Tray Menu Reading Font
--- DESCRIPTION:
--- Draws the tray menu in the reading font chosen in Configuration >
--- Accessibility (script.reading_font), as the app's windows are (maintainer
--- decision 2026-11-24). The builder asks font() once per build, hands it to
--- the header pill (canvas_badge.measure_rows_in), so the pill measures the
--- root titles in the face they take, and hands the finished tree to apply()
--- last, after the root compositions (which admit string titles only) and the
--- shortcut hints.
---
--- FEATURES & RATIONALE:
--- 1. The default font changes nothing: font() is nil and the titles stay as
---    built, drawn by AppKit in the system menu font with its own disabled grey.
--- 2. One face per font, from _shared/ui/fonts/menu_faces.json
---    (reading_preferences.menu_face), which the launcher registers for the
---    login session (MenuFontRegistration.swift) before it starts this runtime.
--- 3. Composes with styled titles: a shortcut hint row keeps its grey hint
---    span and takes the face (tray/adapters/menu_font.lua).
--- 4. Follows a change: a saved choice marks the menu dirty and rebuilds it
---    (menu/ui/init.lua set_reading_preference), and every build reads the
---    current choice.
--- 5. A face that cannot be named or drawn is logged as an error and the menu
---    keeps the system font: the menu stays usable and the log says why.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Paths = require("core.fs.engine.paths")

local LOG = "menu.reading_font"

--- The font attributes the titles take for the current reading font.
--- @param deps table|nil Test seams: { font, fonts_dir, read_file, adapter }.
--- @return table|nil font { name, size } (hs.styledtext), nil for the default font or a refused face.
function M.font(deps)
	deps = deps or {}
	local Reading = require("core.ui.engine.webview.reading_preferences")
	local adapter = deps.adapter or require("tray.adapters.menu_font")
	local font = deps.font or require("core.ui.engine.webview.reading_font").get()
	if font == "default" then return nil end
	local face, err = Reading.menu_face(font, deps.fonts_dir or Paths.shared("ui/fonts"), deps.read_file or adapter.read_file)
	if face == nil then
		Logger.error(LOG, "The tray menu keeps the system font: %s.", tostring(err))
		return nil
	end
	local attributes, why = adapter.font_attributes(face.postscript)
	if attributes == nil then
		Logger.error(LOG, "The tray menu keeps the system font: %s.", tostring(why))
		return nil
	end
	return attributes
end

--- Restyles a finished menu tree in the reading font.
--- @param items table The rendered hs.menubar rows.
--- @param deps table|nil Test seams, as font() takes them, or { font_attributes }.
--- @return integer|nil count Titles restyled (0 for the default font), nil on an error.
function M.apply(items, deps)
	deps = deps or {}
	local attributes = deps.font_attributes or M.font(deps)
	if attributes == nil then return 0 end
	local adapter = deps.adapter or require("tray.adapters.menu_font")
	local count, why = adapter.restyle(items, attributes)
	if count == nil then
		Logger.error(LOG, "The tray menu keeps the system font: %s.", tostring(why))
		return nil
	end
	Logger.debug(LOG, "Tray menu drawn in %s (%d title(s)).", tostring(attributes.name), count)
	return count
end

return M
