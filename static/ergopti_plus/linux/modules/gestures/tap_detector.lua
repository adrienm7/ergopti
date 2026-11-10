--- modules/gestures/tap_detector.lua

--- ==============================================================================
--- MODULE: Touchpad Tap-To-Click Detector
--- DESCRIPTION:
--- Tells which touches of a touchpad libinput turns into a click when the
--- desktop's tap-to-click is on. The kernel never reports that click: libinput
--- synthesises it above evdev, so the daemon, which reads the evdev node
--- without a grab, sees only the touch. Windows and macOS count a tap-to-click
--- with the clicks because their hooks see the synthesised button; the Linux
--- metrics re-derive it from the touch with libinput's own rules.
---
--- FEATURES & RATIONALE (src/evdev-mt-touchpad-tap.c, libinput 1.x):
--- 1. A tap is one, two or three fingers that land and leave without any of
---    them moving more than TAP_MOVE_THRESHOLD_MM from where it landed, the
---    whole touch released within TAP_TIMEOUT_MS of the LAST finger landing
---    (libinput re-arms its tap timer on every touch-down).
--- 2. A fourth finger, a finger landing after another lifted, a physical
---    button press, or the timer running out kills the tap (DEAD and HOLD
---    states): none of those touches is a click.
--- 3. Tap-and-drag adds no click: the press the first tap produced is the one
---    the drag holds, and the dragging touch moves or outlasts the timer, so
---    it is never a tap itself. A double tap is two taps, two clicks.
--- 4. Motion is judged in millimetres from the pad's resolution. A pad that
---    reports none gets libinput's own default size (69 x 50 mm,
---    tp_init_default_resolution), so the threshold means what libinput uses.
---    While the kernel counts more fingers than the pad has slots, libinput
---    cannot tell which finger moved and ignores motion; so does this.
--- 5. Only a touchpad taps: a source becomes one when it reports a
---    finger-count key (BTN_TOOL_FINGER to BTN_TOOL_QUINTTAP), which
---    touchscreens and tablets do not.
--- 6. Pure: decoded evdev events in, a finger count out. Which button that
---    count is, and whether the desktop taps at all, belong to the caller.
---
--- WHAT IS NOT REPRODUCED:
--- libinput's palm and thumb rejection and its disable-while-typing timer
--- discard some touches before the tap machine sees them; both need the
--- keyboard stream and per-model hwdb quirks this module does not have.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ libinput constants ===============
-- =============================================
-- =============================================

-- DEFAULT_TAP_TIMEOUT_PERIOD and DEFAULT_TAP_MOVE_THRESHOLD of
-- evdev-mt-touchpad-tap.c: libinput's own values, not tunables of this project.
M.TAP_TIMEOUT_MS = 180
M.TAP_MOVE_THRESHOLD_MM = 1.3
-- The most fingers libinput turns into a tap (TOUCH_3).
M.MAX_TAP_FINGERS = 3

-- The size libinput assumes for a touchpad that reports no resolution.
M.DEFAULT_WIDTH_MM = 69
M.DEFAULT_HEIGHT_MM = 50

-- Event types and codes, from include/uapi/linux/input-event-codes.h.
local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local SYN_REPORT, SYN_DROPPED = 0, 3
local ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2f, 0x35, 0x36, 0x39
local BTN_TOUCH = 0x14a
-- BTN_TOOL_QUINTTAP sits out of sequence (0x148), as in mt_decoder.
local FINGER_COUNT_CODES = { [0x145] = 1, [0x14d] = 2, [0x14e] = 3, [0x14f] = 4, [0x148] = 5 }
-- A physical button of the pad (a clickpad's or a pad with buttons) kills the tap.
local BUTTON_FIRST, BUTTON_LAST = 0x110, 0x117

--- Device units per millimetre of each axis, libinput's way.
--- @param axes table { x = { minimum, maximum, resolution }, y = { ... } }
--- @return number|nil units_x, number|nil units_y
function M.units_per_mm(axes)
	if type(axes) ~= "table" or type(axes.x) ~= "table" or type(axes.y) ~= "table" then return nil end
	local function axis(info, size_mm)
		local resolution = tonumber(info.resolution)
		if resolution and resolution > 0 then return resolution end
		local minimum, maximum = tonumber(info.minimum), tonumber(info.maximum)
		if not (minimum and maximum) or maximum <= minimum then return nil end
		return (maximum - minimum) / size_mm
	end
	local x, y = axis(axes.x, M.DEFAULT_WIDTH_MM), axis(axes.y, M.DEFAULT_HEIGHT_MM)
	if not (x and y) then return nil end
	return x, y
end




-- =============================================
-- =============================================
-- ======= 2/ The tap machine ==================
-- =============================================
-- =============================================

--- Creates a detector for one touchpad.
--- @param opts table { units_x, units_y } device units per millimetre.
--- @return table detector { feed(event) -> fingers|nil, is_touchpad(), reset() }
function M.new(opts)
	assert(type(opts) == "table", "a tap detector needs the pad's scale")
	local units_x, units_y = tonumber(opts.units_x), tonumber(opts.units_y)
	assert(units_x and units_x > 0 and units_y and units_y > 0,
		"a tap detector needs the pad's units per millimetre")

	local detector = {}
	local touchpad = false
	local slots, current_slot = {}, 0
	local tool_count = 0
	local dropping = false
	-- The touch in progress: nil while every finger is up.
	local touch = nil

	local function clear_touch() touch = nil end

	--- Live contacts, and whether any of them moved past the threshold.
	local function contacts()
		local count, moved = 0, false
		for _, slot in pairs(slots) do
			if slot.id and slot.id >= 0 then
				count = count + 1
				if slot.origin_x and slot.x and slot.y then
					local dx = (slot.x - slot.origin_x) / units_x
					local dy = (slot.y - slot.origin_y) / units_y
					if math.sqrt(dx * dx + dy * dy) > M.TAP_MOVE_THRESHOLD_MM then moved = true end
				end
			end
		end
		return count, moved
	end

	--- Closes one frame and returns the tap it completed, if any.
	--- @param at_ms number The frame's kernel time.
	--- @return integer|nil fingers
	local function close_frame(at_ms)
		for _, slot in pairs(slots) do
			if slot.id and slot.id >= 0 and not slot.origin_x and slot.x and slot.y then
				slot.origin_x, slot.origin_y = slot.x, slot.y
			end
		end
		local live, moved = contacts()
		-- The kernel's count covers fingers the pad cannot position.
		local fingers = math.max(live, tool_count)
		if fingers == 0 then
			local done = touch
			clear_touch()
			if not done or done.dead then return nil end
			if at_ms - done.last_land_ms > M.TAP_TIMEOUT_MS then return nil end
			return done.peak
		end
		if not touch then
			touch = { peak = 0, down = 0, last_land_ms = at_ms, lifted = false, dead = false }
		end
		if touch.dead then return nil end
		if fingers > touch.down then
			-- A finger landing after one lifted is TOUCH_2_HOLD, not a tap.
			if touch.lifted then touch.dead = true; return nil end
			touch.last_land_ms = at_ms
		elseif fingers < touch.down then
			touch.lifted = true
		end
		touch.down = fingers
		if fingers > touch.peak then touch.peak = fingers end
		if touch.peak > M.MAX_TAP_FINGERS then touch.dead = true; return nil end
		if at_ms - touch.last_land_ms > M.TAP_TIMEOUT_MS then touch.dead = true; return nil end
		-- More fingers than positioned contacts: libinput ignores the motion.
		if moved and tool_count <= live then touch.dead = true end
		return nil
	end

	--- Feeds one decoded event.
	--- @param event table { type, code, value, timestamp_us }
	--- @return integer|nil fingers The finger count of a completed tap.
	function detector.feed(event)
		local etype, code, value = event.type, event.code, event.value
		if etype == EV_SYN and code == SYN_DROPPED then
			-- event-codes.rst: the packet is lost through the next SYN_REPORT, and
			-- no touch that straddles it may become a tap.
			slots, current_slot, tool_count = {}, 0, 0
			clear_touch()
			dropping = true
			return nil
		end
		if dropping then
			if etype == EV_SYN and code == SYN_REPORT then dropping = false end
			return nil
		end
		if etype == EV_ABS then
			if code == ABS_MT_SLOT then
				current_slot = value
				return nil
			end
			local slot = slots[current_slot]
			if not slot then slot = {}; slots[current_slot] = slot end
			if code == ABS_MT_TRACKING_ID then
				slot.id = value
				-- A new contact measures its motion from where it lands.
				slot.origin_x, slot.origin_y = nil, nil
			elseif code == ABS_MT_POSITION_X then
				slot.x = value
			elseif code == ABS_MT_POSITION_Y then
				slot.y = value
			end
			return nil
		end
		if etype == EV_KEY then
			local reported = FINGER_COUNT_CODES[code]
			if reported then
				touchpad = true
				if value == 1 then tool_count = reported
				elseif value == 0 and tool_count == reported then tool_count = 0 end
			elseif code >= BUTTON_FIRST and code <= BUTTON_LAST and value == 1 and touch then
				touch.dead = true
			elseif code == BTN_TOUCH and value == 0 then
				tool_count = 0
			end
			return nil
		end
		if etype == EV_SYN and code == SYN_REPORT then
			if not touchpad then return nil end
			local stamp = event.timestamp_us
			assert(type(stamp) == "number" and stamp > 0, "a touchpad frame needs its kernel time")
			return close_frame(stamp / 1000)
		end
		return nil
	end

	--- Whether this source has shown itself a touchpad.
	--- @return boolean
	function detector.is_touchpad()
		return touchpad
	end

	--- Forgets the touch in progress (the device closed or collection stopped).
	function detector.reset()
		slots, current_slot, tool_count, dropping = {}, 0, 0, false
		clear_touch()
	end

	return detector
end




-- =============================================
-- =============================================
-- ======= 3/ The button a tap is ==============
-- =============================================
-- =============================================

-- libinput's two tap button maps: LIBINPUT_CONFIG_TAP_MAP_LRM (the default)
-- and LIBINPUT_CONFIG_TAP_MAP_LMR.
M.MAP_LRM = "lrm"
M.MAP_LMR = "lmr"

local BUTTONS = {
	[M.MAP_LRM] = { "left", "right", "middle" },
	[M.MAP_LMR] = { "left", "middle", "right" },
}

--- The button a tap of this many fingers clicks under a button map.
--- @param fingers integer 1 to 3.
--- @param map string M.MAP_LRM or M.MAP_LMR.
--- @return string button "left", "right" or "middle"
function M.button_for(fingers, map)
	local buttons = assert(BUTTONS[map], "unknown tap button map: " .. tostring(map))
	return assert(buttons[fingers], "a tap has one to three fingers")
end

return M
