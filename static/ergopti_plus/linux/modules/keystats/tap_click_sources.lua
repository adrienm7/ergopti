--- modules/keystats/tap_click_sources.lua

--- ==============================================================================
--- MODULE: Tap-To-Click Sources (Linux)
--- DESCRIPTION:
--- Gives the metrics what counting a touchpad's tap-to-click needs: which
--- device a pointer source is (its event node, its evdev name and its scale
--- in units per millimetre) and the desktop's tap setting for it.
---
--- FEATURES & RATIONALE:
--- 1. The source is the keyboard hook's reader slot: the evdev reader knows
---    its device node, the node's sysfs entry its name, and EVIOCGABS its
---    axes. Nothing forks here; the setting reader is the only one that does.
--- 2. Its own module because the daemon's main() is at LuaJIT's 60-upvalue
---    limit: binding here costs it no new upvalue.
--- ==============================================================================

local M = {}

local Reader = require("platform.input.evdev_reader")
local Finder = require("modules.gestures.touchpad_finder")
local TapDetector = require("modules.gestures.tap_detector")
local Setting = require("adapters.tap_to_click_setting")

--- Reads a device node's evdev name from sysfs.
--- @param path string "/dev/input/eventN"
--- @return string|nil name
local function device_name(path)
	local node = path:match("/(event%d+)$")
	if not node then return nil end
	local file = io.open("/sys/class/input/" .. node .. "/device/name", "rb")
	if not file then return nil end
	local name = file:read("*l")
	file:close()
	return name
end

--- Describes one pointer source as a touch device.
--- @param source string The keyboard hook's reader slot.
--- @return table|nil device { path, name, units_x, units_y }, string|nil reason
function M.describe(source)
	local path = Reader.device_path(source)
	if type(path) ~= "string" then return nil, "the reader knows no device node for it" end
	local units_x, units_y = TapDetector.units_per_mm(Finder.read_axes(path))
	if not units_x then return nil, path .. " reports no multitouch axis range" end
	return { path = path, name = device_name(path), units_x = units_x, units_y = units_y }, nil
end

--- Binds the sources into the metrics.
--- @param keystats table The keystats module.
--- @param now_ms function Monotonic milliseconds.
function M.bind(keystats, now_ms)
	assert(type(keystats) == "table" and type(keystats.bind_touchpads) == "function", "keystats must take touchpads")
	keystats.bind_touchpads(M.describe, Setting.read, now_ms)
end

return M
