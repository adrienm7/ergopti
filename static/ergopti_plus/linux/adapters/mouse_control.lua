--- linux/adapters/mouse_control.lua

--- ==============================================================================
--- MODULE: MouseControl Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the MouseControl port contract defined in
--- static/ergopti_plus/shared/ports/MouseControl.spec.js. Wraps xdotool and
--- xrandr to move the cursor and query monitor geometry without coupling domain
--- modules to platform-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. Return-zero-object: getPos() and getMonitorBounds() always return a table
---    with numeric fields so callers never need nil-guards.
--- 2. Silent no-op: setPos() silently ignores errors per the port contract.
--- 3. xrandr for geometry: provides accurate multi-monitor geometry without
---    requiring a compositor-specific protocol extension.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.mouse_control"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Moves the mouse cursor to an absolute screen position.
--- @param x number Horizontal coordinate in pixels.
--- @param y number Vertical coordinate in pixels.
function M.setPos(x, y)
	pcall(function()
		os.execute(string.format(
			"xdotool mousemove %d %d 2>/dev/null",
			math.floor(tonumber(x) or 0),
			math.floor(tonumber(y) or 0)))
	end)
end

--- Returns the current absolute cursor position.
--- @return table { x: number, y: number }
function M.getPos()
	local ok, result = pcall(function()
		local fh = io.popen("xdotool getmouselocation 2>/dev/null", "r")
		if not fh then return { x = 0, y = 0 } end
		local out = fh:read("*a")
		fh:close()
		-- Output format: "x:123 y:456 screen:0 window:789"
		local x = tonumber(out:match("x:(%d+)")) or 0
		local y = tonumber(out:match("y:(%d+)")) or 0
		return { x = x, y = y }
	end)
	if not ok then
		Logger.error(LOG, "getPos(): error — %s", tostring(result))
		return { x = 0, y = 0 }
	end
	return type(result) == "table" and result or { x = 0, y = 0 }
end

--- Returns the total number of monitors attached to the system.
--- @return number Monitor count (>= 1 on healthy system, 0 on error).
function M.getMonitorCount()
	local ok, result = pcall(function()
		local fh = io.popen("xrandr --listmonitors 2>/dev/null | head -1", "r")
		if not fh then return 0 end
		local out = fh:read("*a")
		fh:close()
		-- First line: "Monitors: N"
		return tonumber(out:match("(%d+)")) or 0
	end)
	if not ok then
		Logger.error(LOG, "getMonitorCount(): error — %s", tostring(result))
		return 0
	end
	return type(result) == "number" and result or 0
end

--- Returns the bounding rectangle of monitor n (1-indexed).
--- @param n number Monitor index, starting at 1.
--- @return table { left: number, top: number, right: number, bottom: number }
function M.getMonitorBounds(n)
	local empty = { left = 0, top = 0, right = 0, bottom = 0 }
	local ok, result = pcall(function()
		local fh = io.popen("xrandr --listmonitors 2>/dev/null", "r")
		if not fh then return empty end
		local lines = {}
		for line in fh:lines() do lines[#lines + 1] = line end
		fh:close()
		-- Lines 2+ are monitors: " 0: +*HDMI-1 1920/527x1080/296+0+0  HDMI-1"
		local monitor_line = lines[(tonumber(n) or 1) + 1]
		if not monitor_line then return empty end
		-- Pattern: WxH+X+Y
		local w, h, x, y = monitor_line:match("(%d+)/[^x]+x(%d+)/[^+]+%+(%d+)%+(%d+)")
		w = tonumber(w) or 0
		h = tonumber(h) or 0
		x = tonumber(x) or 0
		y = tonumber(y) or 0
		return { left = x, top = y, right = x + w, bottom = y + h }
	end)
	if not ok then
		Logger.error(LOG, "getMonitorBounds(): error — %s", tostring(result))
		return empty
	end
	return type(result) == "table" and result or empty
end

return M
