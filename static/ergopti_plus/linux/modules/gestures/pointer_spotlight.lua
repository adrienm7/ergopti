--- modules/gestures/pointer_spotlight.lua

--- ==============================================================================
--- MODULE: Pointer Spotlight (Linux, X11)
--- DESCRIPTION:
--- `spotlight_mouse` on an X11 session: a yellow ring around the pointer and a
--- red × at the centre of every other monitor, dismissed after a few seconds or
--- as soon as the pointer moves, as Windows and macOS show it.
---
--- WHY X11 ONLY:
--- Wayland gives no client the global pointer position nor a window placed at
--- screen coordinates, so the ring could not follow the pointer. The action
--- requires `session:x11` in the shared catalogue, as center_mouse does.
---
--- FEATURES & RATIONALE:
--- 1. Pure plan: which shape goes where is a function of the RandR monitors and
---    the pointer, so the tests drive it without a display.
--- 2. One spotlight at a time: a second request replaces the first, its timers
---    cancelled before the new shapes are drawn.
--- 3. Dismissal follows Windows: a move of more than 5 px, polled after a short
---    arming delay, or the duration, whichever comes first.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "gestures.pointer_spotlight"

-- The overlay's look and timing. Windows (ui/spotlight/init.ahk) and macOS
-- (modules/shortcuts/actions/system_mouse.lua) hold the same values.
M.STYLE = {
	ring_radius = 60, stroke = 6, padding = 12, fill_alpha = 0.40, stroke_alpha = 0.9,
	cross_arm_half = 60, cross_arm_width = 14,
	ring_color = { red = 1, green = 0.85, blue = 0 },
	cross_color = { red = 0.9, green = 0.1, blue = 0.05 },
}
M.DURATION_S = 5
M.DISMISS_MOVE_PX = 5
-- A pointer warp just before the spotlight must not dismiss it at once.
M.ARM_DELAY_S = 0.05
M.POLL_S = 0.05

local _deps = {
	overlay = function() return require("adapters.spotlight_overlay") end,
	scheduler = function() return require("core.events.timer_scheduler") end,
}
local _active = nil




-- ===============================================
-- ===============================================
-- ======= 1/ Plan ===============================
-- ===============================================
-- ===============================================

--- The shapes for a pointer on a set of monitors.
--- @param monitors table From pointer_warp.parse_monitors.
--- @param x number Pointer x.
--- @param y number Pointer y.
--- @return table shapes { { kind, x, y, size, style } }; the ring first.
function M.plan(monitors, x, y)
	local Warp = require("modules.gestures.pointer_warp")
	local style = M.STYLE
	local shapes = { { kind = "ring", x = x, y = y, size = (style.ring_radius + style.padding) * 2, style = style } }
	local holder = Warp.monitor_at(monitors, x, y)
	for index, monitor in ipairs(monitors) do
		if index ~= holder then
			local cx, cy = Warp.centre(monitor)
			shapes[#shapes + 1] = { kind = "cross", x = cx, y = cy,
				size = (style.cross_arm_half + style.padding) * 2, style = style }
		end
	end
	return shapes
end

--- Whether the pointer moved far enough from where the spotlight started.
--- @return boolean
function M.moved(x0, y0, x, y)
	return math.abs(x - x0) > M.DISMISS_MOVE_PX or math.abs(y - y0) > M.DISMISS_MOVE_PX
end




-- ===============================================
-- ===============================================
-- ======= 2/ Lifetime ===========================
-- ===============================================
-- ===============================================

--- Removes the shown spotlight and its timers.
function M.dismiss()
	local active = _active
	if not active then return end
	_active = nil
	local scheduler = _deps.scheduler()
	if active.timeout then scheduler.cancel(active.timeout) end
	if active.arm then scheduler.cancel(active.arm) end
	if active.poll then scheduler.cancel(active.poll) end
	active.overlay.hide()
end

--- Whether a spotlight is shown.
--- @return boolean
function M.is_active()
	return _active ~= nil
end

--- spotlight_mouse: the ring around the pointer, a cross on the other monitors.
function M.spotlight_mouse()
	M.dismiss()
	local Warp = require("modules.gestures.pointer_warp")
	local monitors, x, y = Warp.read_state("spotlight_mouse")
	if not monitors then return end
	local overlay = _deps.overlay()
	if not overlay.is_available() then
		Logger.error(LOG, "spotlight_mouse: GTK 3 through lgi is needed to draw the overlay.")
		return
	end
	if not overlay.show(M.plan(monitors, x, y)) then return end
	local scheduler = _deps.scheduler()
	local active = { overlay = overlay }
	_active = active
	active.timeout = scheduler.after(M.DURATION_S, function()
		if _active == active then M.dismiss() end
	end)
	active.arm = scheduler.after(M.ARM_DELAY_S, function()
		if _active ~= active then return end
		active.arm = nil
		local x0, y0 = overlay.pointer()
		if not x0 then return end
		active.poll = scheduler.every(M.POLL_S, function()
			if _active ~= active then return end
			local px, py = overlay.pointer()
			if px and M.moved(x0, y0, px, py) then M.dismiss() end
		end)
	end)
	Logger.info(LOG, "Spotlight shown at %d,%d on %d monitor(s).", x, y, #monitors)
end

--- Test seam: replaces the overlay and scheduler owners.
--- @param overrides table|nil { overlay = fn, scheduler = fn }; nil restores.
function M._set_deps_for_test(overrides)
	M.dismiss()
	_deps = {
		overlay = overrides and overrides.overlay or function() return require("adapters.spotlight_overlay") end,
		scheduler = overrides and overrides.scheduler or function() return require("core.events.timer_scheduler") end,
	}
end

return M
