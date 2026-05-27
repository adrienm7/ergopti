--- adapters/mouse_control.lua

--- ==============================================================================
--- MODULE: MouseControl Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the MouseControl port contract defined in
--- static/ergopti_plus/shared/ports/MouseControl.spec.js. Wraps hs.mouse and
--- hs.screen to move the cursor and query monitor geometry without coupling
--- domain modules to hs APIs.
---
--- FEATURES & RATIONALE:
--- 1. Return-zero-object: getPos() and getMonitorBounds() always return a table
---    with numeric fields so callers never need nil-guards.
--- 2. Silent no-op: setPos() silently ignores errors per the port contract.
--- 3. Defensive pcall: all hs calls are wrapped to prevent propagation.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

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
		hs.mouse.absolutePosition({ x = tonumber(x) or 0, y = tonumber(y) or 0 })
	end)
end

--- Returns the current absolute cursor position.
--- @return table { x: number, y: number }
function M.getPos()
	local ok, result = pcall(function()
		local pos = hs.mouse.absolutePosition()
		if type(pos) == "table" then
			return { x = tonumber(pos.x) or 0, y = tonumber(pos.y) or 0 }
		end
		return { x = 0, y = 0 }
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
		local screens = hs.screen.allScreens()
		return type(screens) == "table" and #screens or 0
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
		local screens = hs.screen.allScreens()
		if type(screens) ~= "table" then return empty end
		local screen = screens[tonumber(n) or 1]
		if not screen then return empty end
		local frame = screen:fullFrame()
		if type(frame) ~= "table" then return empty end
		return {
			left   = tonumber(frame.x) or 0,
			top    = tonumber(frame.y) or 0,
			right  = (tonumber(frame.x) or 0) + (tonumber(frame.w) or 0),
			bottom = (tonumber(frame.y) or 0) + (tonumber(frame.h) or 0),
		}
	end)
	if not ok then
		Logger.error(LOG, "getMonitorBounds(): error — %s", tostring(result))
		return empty
	end
	return type(result) == "table" and result or empty
end

return M
