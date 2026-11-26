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
--- 3. Unchecked Focus: red too, with its own greyed reason, while the front
---    application has left the focused element unreadable for
---    text_automation_notice_after_ms, so hotstrings follow the window mode
---    without the password-field check (maintainer, 2026-11-25: « Oui, comme
---    Linux »). A focus change passes through that mode for a moment on a Mac
---    that works, so only a lasting one is named, never in a notification.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Timings = require("core.timing.engine.timings")

local LOG = "hotstrings.ui.menu.status"

-- How long the window mode must hold before the title names it, shared with
-- the Linux tray row (constants.toml [privacy]).
local NOTICE_AFTER_NS = Timings.ms("privacy", "text_automation_notice_after_ms") * 1e6

-- A key of the manifest's health_dot (menu.toml), as the AI and Tap-Holds
-- titles return it; the title test checks it draws the red glyph.
local unreachable = "unreachable"

--- The conditions the Hotstrings submenu names, in its row order.
--- @param keymap table|nil The keymap engine (hotstrings/engine/expander).
--- @param paused boolean Whether Ergopti is paused.
--- @param now_ns number|nil Monotonic nanoseconds (a test seam).
--- @return table conditions "taps_down" and "focus_unchecked" while they hold.
function M.conditions(keymap, paused, now_ns)
	local conditions = {}
	if paused == true or type(keymap) ~= "table" then return conditions end
	if type(keymap.taps_down) == "function" then
		local ok, down = pcall(keymap.taps_down)
		if not ok then
			Logger.error(LOG, "The keymap event tap outage could not be read: %s.", tostring(down))
		elseif type(down) == "table" and #down > 0 then
			conditions[#conditions + 1] = "taps_down"
		end
	end
	if type(keymap.text_automation_state) == "function" then
		local ok, mode, _reason, since_ns = pcall(keymap.text_automation_state)
		if not ok then
			Logger.error(LOG, "The text automation mode could not be read: %s.", tostring(mode))
		elseif mode == "window" and type(since_ns) == "number"
			-- Resolved at use: a test drives the clock through a scheduler double
			and (now_ns or require("core.events.timer_scheduler").now_ns()) - since_ns >= NOTICE_AFTER_NS then
			conditions[#conditions + 1] = "focus_unchecked"
		end
	end
	return conditions
end

--- The status the Hotstrings title shows.
--- @param keymap table|nil The keymap engine (hotstrings/engine/expander).
--- @param paused boolean Whether Ergopti is paused.
--- @param now_ns number|nil Monotonic nanoseconds (a test seam).
--- @return string|nil status "unreachable" while a condition holds; nil draws no dot.
--- @return string|nil signature The conditions joined, so a watch repaints when they change.
function M.read(keymap, paused, now_ns)
	local conditions = M.conditions(keymap, paused, now_ns)
	if #conditions == 0 then return nil, nil end
	return unreachable, table.concat(conditions, ",")
end

return M
