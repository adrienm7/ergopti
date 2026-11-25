--- hotstrings/ui/menu/status.lua

--- ==============================================================================
--- MODULE: Hotstrings Title Status
--- DESCRIPTION:
--- Decides the status dot of the Hotstrings title (maintainer, 2026-11-25):
--- red while a typing event tap of the keymap engine stays disabled after the
--- watchdog's restart, so the hotstrings are dead although every switch reads
--- on. No dot otherwise: the title of a working feature stays as it was.
---
--- FEATURES & RATIONALE:
--- 1. Read Only: the input is the engine's in-memory record of the taps it
---    could not re-enable (hotstrings/engine/expander/init.lua taps_down); a
---    watch calls it every second, so it never observes the system.
--- 2. Same Dot As Tap-Holds: the glyph is the shared manifest's health_dot
---    (menu/ui/title_status.lua), as on the AI and Tap-Holds titles; no dot
---    while Ergopti is paused, like them.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")

local LOG = "hotstrings.ui.menu.status"

-- A key of the manifest's health_dot (menu.toml), as the AI and Tap-Holds
-- titles return it; the title test checks it draws the red glyph.
local unreachable = "unreachable"

--- The status the Hotstrings title shows.
--- @param keymap table|nil The keymap engine (hotstrings/engine/expander).
--- @param paused boolean Whether Ergopti is paused.
--- @return string|nil status "unreachable" while a typing tap is down; nil draws no dot.
function M.read(keymap, paused)
	if paused == true or type(keymap) ~= "table" or type(keymap.taps_down) ~= "function" then return nil end
	local ok, down = pcall(keymap.taps_down)
	if not ok then
		Logger.error(LOG, "The keymap event tap outage could not be read: %s.", tostring(down))
		return nil
	end
	if type(down) == "table" and #down > 0 then return unreachable end
	return nil
end

return M
