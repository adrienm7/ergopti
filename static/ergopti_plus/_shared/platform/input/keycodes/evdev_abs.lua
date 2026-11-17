--- _shared/platform/input/keycodes/evdev_abs.lua

--- ==============================================================================
--- MODULE: evdev Absolute Axis Registry (Shared)
--- DESCRIPTION:
--- The Linux kernel's absolute-axis codes (linux/input-event-codes.h) and the
--- slot bound a multitouch state read accepts, for the readers that rebuild a
--- touchpad's state after the kernel dropped events (EVIOCGABS, EVIOCGMTSLOTS).
---
--- FEATURES & RATIONALE:
--- 1. Single source (Rule A): the codes and the slot bound live here, beside
---    the evdev keycode loader, not typed in a driver.
--- 2. Pure: numeric constants and predicates only, no platform runtime.
--- ==============================================================================

local M = {}





-- =========================================
-- =========================================
-- ======= 1/ Axis Codes And Bounds ========
-- =========================================
-- =========================================

--- ABS_MAX: the last absolute-axis code.
M.LAST_CODE = 0x3f

--- ABS_MT_SLOT .. ABS_MT_TOOL_Y: the axes a multitouch slot holds. ABS_MT_SLOT
--- itself selects the slot and is not read per slot.
M.MT_SLOT = 0x2f
M.MT_LAST = 0x3d

--- No touchpad reports more slots than this: a larger ABS_MT_SLOT maximum is a
--- corrupt answer, not a buffer to allocate.
M.MT_SLOT_BOUND = 64





-- ===================================
-- ===================================
-- ======= 2/ Predicates =============
-- ===================================
-- ===================================

--- Whether a value is an integer absolute-axis code.
--- @param code any
--- @return boolean
function M.is_axis(code)
	return type(code) == "number" and code >= 0 and code <= M.LAST_CODE and code % 1 == 0
end

--- Whether a value is an axis EVIOCGMTSLOTS reads per slot.
--- @param code any
--- @return boolean
function M.is_slot_axis(code)
	return type(code) == "number" and code > M.MT_SLOT and code <= M.MT_LAST and code % 1 == 0
end

--- Whether a value is a slot count a multitouch state read may ask for.
--- @param count any
--- @return boolean
function M.is_slot_count(count)
	return type(count) == "number" and count >= 1 and count <= M.MT_SLOT_BOUND and count % 1 == 0
end

return M
