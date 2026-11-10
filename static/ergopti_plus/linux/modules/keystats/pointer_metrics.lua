--- modules/keystats/pointer_metrics.lua

--- ==============================================================================
--- MODULE: Pointer Metrics (Linux)
--- DESCRIPTION:
--- Turns the evdev reports of the observed pointers into the three mouse
--- columns of events_typing: clicks, wheel turns and distance travelled. macOS
--- fills the same columns from its event tap and a cursor poll; Linux had the
--- columns and wrote zeroes.
---
--- FEATURES & RATIONALE:
--- 1. Clicks are left and right button presses, the two macOS counts. A
---    finger contact (BTN_TOUCH) is a touch, not a click. A touchpad
---    tap-to-click is synthesised by libinput above the kernel and never
---    reaches evdev as a button, while Windows and macOS count it with the
---    clicks: the touchpad's contacts go through tap_detector, libinput's tap
---    rules, and a tap whose button is left or right counts as one click,
---    only while the desktop has tap-to-click on (tap_to_click_setting). An
---    unreadable setting counts no tap and availability says why.
--- 2. A wheel turn is one REL_WHEEL or REL_HWHEEL report. The high-resolution
---    axes repeat the same turn in finer units and would count it twice.
--- 3. Distance is in screen pixels, the unit Windows (cursor positions) and
---    macOS (absolute position polls) store. An evdev frame that moved the
---    pointer triggers a read of the cursor position, at most once every
---    POSITION_SAMPLE_MS, and the straight line from the previous read is
---    credited. The REL_X/REL_Y device units are never credited: they precede
---    the desktop's acceleration and summed beside pixels they would make the
---    column mean two things. Without a cursor position (Wayland grants no
---    global one) the distance is not measured; availability() says why.
--- ==============================================================================

local M = {}

local EvdevCodes = require("infra.evdev_codes")
local InputEvent = require("infra.input_event")
local Logger = require("logger.shim")
local TapDetector = require("modules.gestures.tap_detector")

local LOG = "keystats.pointer_metrics"

-- The buttons counted as a click, as on macOS (leftMouseDown, rightMouseDown)
local CLICK_BUTTONS = { [EvdevCodes.BTN_LEFT] = true, [EvdevCodes.BTN_RIGHT] = true }

-- The buttons a tap counts as a click: the clicks above, never a middle tap
local TAP_CLICK_BUTTONS = { left = true, right = true }

-- The wheel axes counted as one scroll per report
local SCROLL_AXES = { [InputEvent.REL_WHEEL] = true, [InputEvent.REL_HWHEEL] = true }

-- Shortest interval between two cursor reads during a movement: a 60 Hz frame,
-- the resolution at which a straight line between reads stays the travelled path.
M.POSITION_SAMPLE_MS = 16

-- The kinds the keyboard hook reports a pointer event as
M.KIND_PRESS  = "press"
M.KIND_MOTION = "motion"
M.KIND_FRAME  = "frame"
M.KIND_RESET  = "reset"
M.KIND_DROPPED = "dropped"
-- A touch report of a touchpad or touchscreen: an EV_ABS axis (codes below
-- 0x100) or a BTN_DIGI key (BTN_TOUCH, BTN_TOOL_*), down or up.
M.KIND_CONTACT = "contact"

-- The kinds above, for validation
local KINDS = { [M.KIND_PRESS] = true, [M.KIND_MOTION] = true, [M.KIND_FRAME] = true,
	[M.KIND_RESET] = true, [M.KIND_DROPPED] = true, [M.KIND_CONTACT] = true }

-- How long one tap setting answer is reused while its touchpad is in use,
-- and how long an untouched pad goes before it is no longer re-read: a fork
-- every few seconds while tapping, none while the pad rests.
M.TAP_SETTING_READ_INTERVAL_MS = 5000
M.TAP_SETTING_IDLE_MS = 60000

-- The first EV_KEY code: a contact code below it is an EV_ABS axis.
local FIRST_KEY_CODE = 0x100
-- SYN_DROPPED, include/uapi/linux/input-event-codes.h: the kernel lost events.
local SYN_DROPPED = 3




-- ===============================
-- ===============================
-- ======= 1/ Tracker ============
-- ===============================
-- ===============================

--- Creates a tracker of pointer streams. Each device keeps its own open frame
--- until SYN_REPORT; queue loss discards the frame through the next SYN_REPORT.
--- @return table tracker { observe(kind, code, value) }
function M.new()
	local tracker = {}
	local frames, dropping, default_source = {}, {}, {}
	local fractions, fraction_database, fraction_device = {}, nil, nil
	-- The cursor position source: read() -> x, y | nil, reason; clock() -> ms.
	local position = { read = nil, clock = nil, x = nil, y = nil, at = nil, reason = nil }
	-- The touchpad sources: describe(source) -> device | nil, reason;
	-- read_setting(device) -> setting; clock() -> ms. One pad per source.
	local touch = { describe = nil, read_setting = nil, clock = nil }
	local pads = {}

	--- Binds the screen-pixel position source, or unbinds it with the reason
	--- the distance cannot be measured.
	--- @param read function|nil Returns x, y in screen pixels, or nil, reason.
	--- @param clock function|nil Monotonic milliseconds.
	--- @param reason string|nil Why there is no source when read is nil.
	function tracker.bind_position(read, clock, reason)
		assert(read == nil or (type(read) == "function" and type(clock) == "function"),
			"a pointer position source needs its clock")
		position = { read = read, clock = clock, x = nil, y = nil, at = nil, reason = read == nil and reason or nil }
	end

	--- Binds what the tap-to-click count needs, or unbinds it.
	--- @param describe function|nil (source) -> { path, name, units_x, units_y } | nil, reason
	--- @param read_setting function|nil (device) -> tap_to_click_setting answer
	--- @param clock function|nil Monotonic milliseconds.
	function tracker.bind_touchpads(describe, read_setting, clock)
		assert(describe == nil or (type(describe) == "function" and type(read_setting) == "function"
			and type(clock) == "function"), "the tap count needs a device description, a setting reader and a clock")
		touch = { describe = describe, read_setting = read_setting, clock = clock }
		pads = {}
	end

	--- Reads one pad's setting now and logs what changed.
	local function read_setting(pad)
		local setting = touch.read_setting(pad.device)
		assert(type(setting) == "table" and type(setting.known) == "boolean", "a tap setting answer says whether it is known")
		local previous = pad.setting
		pad.setting, pad.read_at = setting, touch.clock()
		local summary = setting.known and string.format("%s, %s map (%s)", setting.enabled and "on" or "off",
			tostring(setting.map), tostring(setting.source)) or ("unknown: " .. tostring(setting.detail))
		local before = previous and (previous.known and string.format("%s, %s map (%s)", previous.enabled and "on" or "off",
			tostring(previous.map), tostring(previous.source)) or ("unknown: " .. tostring(previous.detail)))
		if summary ~= before then
			if setting.known then Logger.info(LOG, "Tap-to-click on %s: %s.", pad.device.path, summary)
			else Logger.warn(LOG, "Tap-to-click on %s is %s; its taps are not counted.", pad.device.path, summary) end
		end
	end

	--- The pad of a source, described on its first contact.
	--- @param create boolean True for a contact: a mouse never becomes a pad.
	local function pad_of(key, create)
		local pad = pads[key]
		if pad or not create or not touch.describe then return pad end
		local device, reason = touch.describe(key)
		if not device then
			pad = { unavailable = reason or "the source is not described" }
			Logger.warn(LOG, "Touch source %s cannot count taps: %s.", tostring(key), pad.unavailable)
		else
			pad = { device = device, detector = TapDetector.new({ units_x = device.units_x, units_y = device.units_y }) }
		end
		pads[key] = pad
		return pad
	end

	--- Re-reads the settings of the pads in use whose answer is due. Called
	--- from the daemon's periodic tick, never from the input callback.
	function tracker.refresh_tap_settings()
		if not touch.clock then return end
		local now = touch.clock()
		for _, pad in pairs(pads) do
			if pad.detector and pad.detector.is_touchpad() and pad.active_at
				and now - pad.active_at <= M.TAP_SETTING_IDLE_MS
				and (not pad.read_at or now - pad.read_at >= M.TAP_SETTING_READ_INTERVAL_MS) then
				read_setting(pad)
			end
		end
	end

	--- Whether the touchpad taps are counted, for the menu.
	--- @return table { measured = boolean, reason = string|nil }
	function tracker.tap_click_availability()
		for _, pad in pairs(pads) do
			if pad.detector and pad.detector.is_touchpad() and pad.setting and not pad.setting.known then
				return { measured = false, reason = pad.setting.reason }
			end
		end
		return { measured = true }
	end

	--- Feeds one report to the source's tap detector.
	--- @param key any The source.
	--- @param event table A decoded evdev event.
	--- @param create boolean|nil True when the report may make the source a pad.
	--- @return integer|nil clicks 1 when the report completed a counted tap.
	local function feed_pad(key, event, create)
		local pad = pad_of(key, create == true)
		if not pad or not pad.detector then return nil end
		if event.type == InputEvent.EV_SYN and event.code == InputEvent.SYN_REPORT
			and not (type(event.timestamp_us) == "number" and event.timestamp_us > 0) then
			-- A tap is a matter of milliseconds: without the kernel's stamp the
			-- pad cannot be timed, and nothing it does is counted as a tap.
			pads[key] = { unavailable = "its frames carry no kernel time" }
			Logger.error(LOG, "Touch source %s reports frames without a kernel time; its taps are not counted.", tostring(key))
			return nil
		end
		local fingers = pad.detector.feed(event)
		if pad.detector.is_touchpad() and event.type ~= InputEvent.EV_SYN then pad.active_at = touch.clock() end
		if not fingers then return nil end
		-- The first tap of a pad pays its first read; later ones use the tick's.
		if not pad.setting then read_setting(pad) end
		local setting = pad.setting
		if not setting.known or not setting.enabled then return nil end
		if not TAP_CLICK_BUTTONS[TapDetector.button_for(fingers, setting.map)] then return nil end
		return 1
	end

	--- Whether the distance is measured, and in which unit.
	--- @return table { measured = boolean, unit = "px"|nil, reason = string|nil }
	function tracker.availability()
		if position.read then return { measured = true, unit = "px" } end
		return { measured = false, reason = position.reason or "no cursor position source" }
	end

	--- The screen distance since the previous cursor read, when one is due.
	local function travelled()
		if not position.read then return 0 end
		local now = position.clock()
		if position.at and now - position.at < M.POSITION_SAMPLE_MS then return 0 end
		local x, y = position.read()
		position.at = now
		if type(x) ~= "number" or type(y) ~= "number" then
			-- A refused read seeds afresh: no line is drawn across the gap.
			position.x, position.y = nil, nil
			return 0
		end
		local distance = 0
		if position.x then
			local dx, dy = x - position.x, y - position.y
			distance = math.sqrt(dx * dx + dy * dy)
		end
		position.x, position.y = x, y
		return distance
	end

	--- A new storage owner must not inherit another database's remainder.
	function tracker.bind_fractions(database, device)
		if database ~= fraction_database or device ~= fraction_device then
			fractions = {}
			fraction_database, fraction_device = database, device
		end
	end

	--- Copies committed sub-unit distance by day and application. The flush
	--- owner publishes a successor only after the matching SQLite COMMIT.
	function tracker.snapshot_fractions()
		local copy = {}
		for date, apps in pairs(fractions) do
			copy[date] = {}
			for app, value in pairs(apps) do copy[date][app] = value end
		end
		return copy
	end

	--- Discard empty entries without losing a remainder for a delayed old day.
	function tracker.commit_fractions(value)
		for date, apps in pairs(value) do
			for app, remainder in pairs(apps) do
				if remainder == 0 then apps[app] = nil end
			end
			if next(apps) == nil then value[date] = nil end
		end
		fractions = value
	end

	--- Forgets uncommitted movement without admitting a dropped packet.
	function tracker.discard_frames()
		frames = {}
	end

	--- Forgets the cursor position: the next read seeds afresh, so travel made
	--- while collection is closed is never credited.
	function tracker.forget_position()
		position.x, position.y, position.at = nil, nil, nil
	end

	--- Reads the cursor now without crediting the travel since the previous
	--- read: a focus change starts the next application's path where it gets
	--- the pointer, as discarding the open frame did for device units.
	function tracker.reseed()
		if not position.read then return end
		position.at = position.clock()
		local x, y = position.read()
		if type(x) == "number" and type(y) == "number" then position.x, position.y = x, y
		else position.x, position.y = nil, nil end
	end

	--- Observes one pointer report and returns what it adds to the metrics.
	--- @param kind string "press", "motion", "frame", "dropped" or "reset".
	--- @param code integer evdev code of the report.
	--- @param value integer evdev value of the report.
	--- @param source any|nil Identity of the pointer producing this frame.
	--- @param at_us number|nil Kernel time of a frame, in microseconds.
	--- @return table|nil delta { clicks, scrolls, distance } or nil when it adds nothing.
	function tracker.observe(kind, code, value, source, at_us)
		assert(KINDS[kind], "unknown pointer event kind: " .. tostring(kind))
		local key = source or default_source
		if kind == M.KIND_RESET then
			frames[key], dropping[key], pads[key] = nil, nil, nil
			return nil
		end
		-- The tap detector keeps its own packet-loss state from the same reports.
		local tap_clicks = nil
		if kind == M.KIND_CONTACT then
			feed_pad(key, { type = code < FIRST_KEY_CODE and InputEvent.EV_ABS or InputEvent.EV_KEY, code = code, value = value }, true)
			return nil
		elseif kind == M.KIND_DROPPED then
			feed_pad(key, { type = InputEvent.EV_SYN, code = SYN_DROPPED, value = 0 })
		elseif kind == M.KIND_FRAME then
			tap_clicks = feed_pad(key, { type = InputEvent.EV_SYN, code = InputEvent.SYN_REPORT, value = 0, timestamp_us = at_us })
		elseif kind == M.KIND_PRESS and InputEvent.is_pointer_button(code) then
			-- A physical button pressed during a touch is no tap (libinput DEAD).
			feed_pad(key, { type = InputEvent.EV_KEY, code = code, value = 1 })
		end
		if kind == M.KIND_DROPPED then
			frames[key], dropping[key] = nil, true
			return nil
		end
		if dropping[key] then
			if kind == M.KIND_FRAME then dropping[key] = nil end
			return nil
		end
		if kind == M.KIND_PRESS then
			if CLICK_BUTTONS[code] then return { clicks = 1, scrolls = 0, distance = 0 } end
			return nil
		end
		if kind == M.KIND_MOTION then
			if SCROLL_AXES[code] then return { clicks = 0, scrolls = 1, distance = 0 } end
			assert(type(value) == "number", "a pointer motion report needs its evdev value")
			if code == InputEvent.REL_X or code == InputEvent.REL_Y then
				local frame = frames[key] or { dx = 0, dy = 0 }
				frames[key] = frame
				if code == InputEvent.REL_X then frame.dx = frame.dx + value else frame.dy = frame.dy + value end
			end
			return nil
		end
		local frame = frames[key]
		frames[key] = nil
		local distance = 0
		if frame and (frame.dx ~= 0 or frame.dy ~= 0) then distance = travelled() end
		if distance <= 0 and not tap_clicks then return nil end
		return { clicks = tap_clicks or 0, scrolls = 0, distance = math.max(distance, 0) }
	end

	return tracker
end

return M
