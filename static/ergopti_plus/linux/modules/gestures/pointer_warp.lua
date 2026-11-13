--- modules/gestures/pointer_warp.lua

--- ==============================================================================
--- MODULE: Pointer Warp (Linux, X11)
--- DESCRIPTION:
--- `center_mouse` and `teleport_mouse` on an X11 session: the pointer moves to
--- the centre of the monitor under it, or to the centre of the next monitor,
--- as Windows and macOS move it. The monitors come from RandR
--- (`xrandr --listactivemonitors`), the pointer from `xdotool getmouselocation`
--- and the move is `xdotool mousemove`.
---
--- WHY X11 ONLY:
--- Wayland gives no client a global pointer position or a way to move the
--- pointer, and under XWayland xdotool only moves the X11 pointer copy. The
--- actions require `session:x11` in the shared catalogue, so the picker greys
--- them under Wayland with their reason, and the handler refuses there too.
---
--- FEATURES & RATIONALE:
--- 1. Pure geometry: parsing and target selection are functions of the tools'
---    text, so the tests drive them without a display.
--- 2. Monitor order: RandR's list order, the order macOS's screen list and the
---    Windows monitor enumeration cycle through; the last wraps to the first.
--- 3. Nothing to do is said: with a single monitor teleport shows the shared
---    "no other monitor" notice, as macOS does.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ShellRunner = require("core.process.adapters.shell_runner")

local LOG = "gestures.pointer_warp"

--- The notice teleport shows when there is no other monitor to go to.
M.NO_OTHER_MONITOR_KEY = "shortcuts.no_other_monitor"

M.MONITORS_COMMAND = "xrandr --listactivemonitors 2>/dev/null"
M.LOCATION_COMMAND = "xdotool getmouselocation --shell 2>/dev/null"





-- ==========================
-- ==========================
-- ======= 1/ Parsing =======
-- ==========================
-- ==========================

--- Reads the active monitors from `xrandr --listactivemonitors`.
--- A line reads ` 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1`.
--- @param text string The command's output.
--- @return table monitors { { name, x, y, w, h } } in RandR order.
function M.parse_monitors(text)
	local monitors = {}
	if type(text) ~= "string" then return monitors end
	for line in text:gmatch("[^\n]+") do
		local w, h, x, y = line:match("^%s*%d+:%s+%S+%s+(%d+)/%d+x(%d+)/%d+([+-]%d+)([+-]%d+)")
		if w then
			monitors[#monitors + 1] = {
				name = line:match("(%S+)%s*$"),
				x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h),
			}
		end
	end
	return monitors
end

--- Reads the pointer position from `xdotool getmouselocation --shell`.
--- @param text string The command's output (X=…, Y=… lines).
--- @return number|nil x
--- @return number|nil y
function M.parse_location(text)
	if type(text) ~= "string" then return nil, nil end
	local x, y = text:match("X=(%-?%d+)"), text:match("Y=(%-?%d+)")
	return tonumber(x), tonumber(y)
end





-- ===========================
-- ===========================
-- ======= 2/ Geometry =======
-- ===========================
-- ===========================

--- The index of the monitor holding a point.
--- @param monitors table From parse_monitors.
--- @param x number
--- @param y number
--- @return integer|nil index
function M.monitor_at(monitors, x, y)
	for index, m in ipairs(monitors) do
		if x >= m.x and x < m.x + m.w and y >= m.y and y < m.y + m.h then return index end
	end
	return nil
end

--- The centre of a monitor, in whole pixels.
--- @param monitor table
--- @return integer x
--- @return integer y
function M.centre(monitor)
	return monitor.x + math.floor(monitor.w / 2), monitor.y + math.floor(monitor.h / 2)
end

--- Where center_mouse sends the pointer.
--- @return integer|nil x Nil when no monitor holds the pointer.
--- @return integer|nil y
function M.center_target(monitors, x, y)
	local index = M.monitor_at(monitors, x, y)
	if not index then return nil, nil end
	return M.centre(monitors[index])
end

--- Where teleport_mouse sends the pointer: the next monitor's centre.
--- @return integer|string|nil x The x, "single" with one monitor, nil when unknown.
--- @return integer|nil y
function M.teleport_target(monitors, x, y)
	if #monitors < 2 then return #monitors == 1 and "single" or nil, nil end
	local index = M.monitor_at(monitors, x, y) or 0
	return M.centre(monitors[(index % #monitors) + 1])
end





-- ===========================
-- ===========================
-- ======= 3/ Handlers =======
-- ===========================
-- ===========================

--- Reads the monitors and the pointer, or says why not.
--- @param action string For the log.
--- @return table|nil monitors
--- @return number|nil x
--- @return number|nil y
function M.read_state(action)
	if require("infra.display_server").is_wayland() then
		Logger.error(LOG, "%s: a Wayland session lets no program move the pointer.", action)
		return nil
	end
	local monitors = M.parse_monitors(ShellRunner.exec(M.MONITORS_COMMAND))
	if #monitors == 0 then
		Logger.error(LOG, "%s: RandR listed no active monitor (is xrandr installed?).", action)
		return nil
	end
	local x, y = M.parse_location(ShellRunner.exec(M.LOCATION_COMMAND))
	if not x then
		Logger.error(LOG, "%s: the pointer position could not be read (is xdotool installed?).", action)
		return nil
	end
	return monitors, x, y
end

--- The move command for a target.
--- @return string
function M.move_command(x, y)
	return string.format("xdotool mousemove %d %d", x, y)
end

--- center_mouse: the centre of the monitor under the pointer.
--- @param deps table The executor's { run_background }.
function M.center_mouse(deps)
	local monitors, x, y = M.read_state("center_mouse")
	if not monitors then return end
	local cx, cy = M.center_target(monitors, x, y)
	if not cx then
		Logger.error(LOG, "center_mouse: no monitor holds the pointer at %d,%d.", x, y)
		return
	end
	deps.run_background(M.move_command(cx, cy))
	Logger.info(LOG, "Pointer centred at %d,%d.", cx, cy)
end

--- teleport_mouse: the centre of the next monitor, wrapping to the first.
--- @param deps table The executor's { run_background, notify }.
function M.teleport_mouse(deps)
	local monitors, x, y = M.read_state("teleport_mouse")
	if not monitors then return end
	local tx, ty = M.teleport_target(monitors, x, y)
	if tx == "single" then
		deps.notify(M.NO_OTHER_MONITOR_KEY)
		Logger.info(LOG, "teleport_mouse: single monitor — nothing to do.")
		return
	end
	deps.run_background(M.move_command(tx, ty))
	Logger.info(LOG, "Pointer teleported to %d,%d.", tx, ty)
end

return M
