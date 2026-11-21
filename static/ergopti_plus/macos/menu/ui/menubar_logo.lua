--- menu/ui/menubar_logo.lua

--- ==============================================================================
--- MODULE: Menu-bar Logo Choice
--- DESCRIPTION:
--- Chooses the logo file the menu-bar item draws for a variant and a pause
--- state, and the tooltip that names the item.
---
--- FEATURES & RATIONALE:
--- 1. One file per state. A missing disabled logo used to be drawn as the
---    running logo, so a paused driver looked running, and a missing logo was
---    drawn as the title « 🔧 », with nothing in the log (TRAY-05). A missing
---    file is now reported to the caller, which logs it once, draws the warning
---    sign and says in the tooltip that the file is missing.
--- 2. Pure: the file probe is passed in, so the choice is tested without a disk.
--- ==============================================================================

local M = {}

--- The title drawn in place of a missing logo, a sign rather than words: the
--- tooltip carries the translated explanation.
M.MISSING_TITLE = "⚠︎"

-- The logo of each [ui] menubar_icon variant, by pause state, under static/img/logo.
local FILES = {
	v1 = { active = "logo_simple.png", paused = "logo_simple_disabled.png" },
	v2 = { active = "logo_white.png",  paused = "logo_black.png" },
}




-- ==================================
-- ==================================
-- ======= 1/ Choice ================
-- ==================================
-- ==================================

--- The logo file of a variant and a pause state.
--- @param logo_dir string The logo directory, ending with a slash.
--- @param variant string A [ui] menubar_icon variant ("v1" or "v2").
--- @param paused boolean Whether the driver is paused.
--- @param exists function Returns true when a path names a readable file.
--- @return string|nil path The logo to draw, nil when its file is missing.
--- @return string|nil missing The missing file, nil when the logo is drawn.
function M.choose(logo_dir, variant, paused, exists)
	local files = FILES[variant]
	if files == nil then error("unknown menu-bar icon variant '" .. tostring(variant) .. "'", 2) end
	local path = logo_dir .. (paused and files.paused or files.active)
	if exists(path) then return path, nil end
	return nil, path
end

--- The locale key of the tooltip naming the item.
--- @param paused boolean Whether the driver is paused.
--- @param missing boolean Whether the state's logo file is missing.
--- @return string
function M.tooltip_key(paused, missing)
	if missing then
		return paused and "accessibility.tray_tip_paused_icon_missing" or "accessibility.tray_tip_icon_missing"
	end
	return paused and "accessibility.tray_tip_paused" or "accessibility.tray_tip"
end

--- Whether a path names a file that can be opened for reading.
--- @param path string
--- @return boolean
function M.file_exists(path)
	local handle = io.open(path, "r")
	if handle == nil then return false end
	handle:close()
	return true
end

return M
