--- modules/gestures/init.lua

--- ==============================================================================
--- MODULE: Multitouch Gestures Core
--- DESCRIPTION:
--- Utilizes the undocumented macOS touchdevice API to capture raw trackpad
--- inputs. Coordinates the mathematical engine with the action registry to map
--- multi-finger taps and swipes to system actions.
---
--- FEATURES & RATIONALE:
--- 1. Undocumented API: Subscribes to the raw OS touch frame callback loop.
--- 2. Module Delegation: Offloads math calculations and conflict resolution.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")
local LOG           = "gestures"

local ok_td, touchdevice = pcall(require, "hs._asm.undocumented.touchdevice")
if not ok_td then touchdevice = nil end

local Engine    = require("modules.gestures.engine")
local Actions   = require("modules.gestures.actions")
local Conflicts = require("modules.gestures.conflicts")





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

M.DEFAULT_GESTURES = {
	tap_2                = "none",
	tap_3                = "left_click_toggle",
	tap_4                = "app_window_previous",
	tap_5                = "none",

	swipe_2_left         = "none",
	swipe_2_right        = "none",
	swipe_2_up           = "none",
	swipe_2_down         = "none",
	swipe_2_left_up      = "none",
	swipe_2_right_up     = "none",
	swipe_2_left_down    = "none",
	swipe_2_right_down   = "none",

	swipe_3_left         = "word_prev",
	swipe_3_right        = "word_next",
	swipe_3_up           = "tab_prev",
	swipe_3_down         = "tab_next",
	swipe_3_left_up      = "none",
	swipe_3_right_up     = "none",
	swipe_3_left_down    = "none",
	swipe_3_right_down   = "none",

	swipe_4_left         = "space_prev",
	swipe_4_right        = "space_next",
	swipe_4_up           = "mission_control",
	swipe_4_down         = "app_expose",
	swipe_4_left_up      = "none",
	swipe_4_right_up     = "none",
	swipe_4_left_down    = "none",
	swipe_4_right_down   = "none",

	swipe_5_left         = "win_prev",
	swipe_5_right        = "win_next",
	swipe_5_up           = "doc_start",
	swipe_5_down         = "doc_end",
	swipe_5_left_up      = "none",
	swipe_5_right_up     = "none",
	swipe_5_left_down    = "none",
	swipe_5_right_down   = "none",
}

M.DEFAULT_MODES = {
}

-- Default sensitivity (step) for incremental mode
M.DEFAULT_SENSITIVITY = 3.5

M.DEFAULT_STATE = {
	gestures = false,
	modes = {},
	sensitivities = {},
	space_wrap = true,
}

-- Initialize modes and sensitivities
for k, v in pairs(M.DEFAULT_GESTURES) do
	if k:match("swipe") then
		M.DEFAULT_STATE.modes[k] = "x1"
		local isIncremental = k:match("swipe_3_left") or k:match("swipe_3_right") or k:match("swipe_3_up") or k:match("swipe_3_down")
			or k:match("swipe_5_left") or k:match("swipe_5_right")
		if isIncremental then M.DEFAULT_STATE.modes[k] = "incremental" end
		M.DEFAULT_STATE.sensitivities[k] = M.DEFAULT_SENSITIVITY
	end
end

M.SINGLE_SLOTS = {
	"tap_2", "tap_3", "tap_4", "tap_5",
	"swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down",
	"swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down",
	"swipe_3_left", "swipe_3_right", "swipe_3_up", "swipe_3_down",
	"swipe_3_left_up", "swipe_3_right_up", "swipe_3_left_down", "swipe_3_right_down",
	"swipe_4_left", "swipe_4_right", "swipe_4_up", "swipe_4_down",
	"swipe_4_left_up", "swipe_4_right_up", "swipe_4_left_down", "swipe_4_right_down",
	"swipe_5_left", "swipe_5_right", "swipe_5_up", "swipe_5_down",
	"swipe_5_left_up", "swipe_5_right_up", "swipe_5_left_down", "swipe_5_right_down",
}

M.AXIS_SLOTS = {}





-- ====================================
-- ====================================
-- ======= 2/ Core Architecture =======
-- ====================================
-- ====================================

local CoreState = {
	enabled        = true,
	ga             = {},
	modes          = {},
	sensitivities  = {},
	space_wrap     = true
}

-- Initialize active actions with defaults
for k, v in pairs(M.DEFAULT_GESTURES) do CoreState.ga[k] = v end
for k, v in pairs(M.DEFAULT_STATE.modes) do CoreState.modes[k] = v end
for k, v in pairs(M.DEFAULT_STATE.sensitivities) do CoreState.sensitivities[k] = v end
CoreState.space_wrap = M.DEFAULT_STATE.space_wrap

-- Initialize Engine and Actions dependencies
Actions.init(CoreState)
Engine.init(CoreState, Actions)

-- Prevent garbage collection by storing both device objects and watchers globally.
_G.ERGOPTI_TOUCH_DEVICES = _G.ERGOPTI_TOUCH_DEVICES or {}
_G.ERGOPTI_TOUCH_WATCHERS = _G.ERGOPTI_TOUCH_WATCHERS or {}
local touch_devices  = _G.ERGOPTI_TOUCH_DEVICES
local touch_watchers = _G.ERGOPTI_TOUCH_WATCHERS

-- Global discovery timer and event loop primer
local discovery_timer = nil

-- Vital: Permanent eventtap to keep the macOS gesture subsystem "awake".
_G.ERGOPTI_GESTURE_PRIMER = _G.ERGOPTI_GESTURE_PRIMER or nil
local gesture_primer = _G.ERGOPTI_GESTURE_PRIMER

-- Track if we've actually received any data yet (reset on start)
_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = false

--- Force-loads all dependencies used by the actions module to prevent
--- lazy-loading delays during the first gesture.
local function prewarm_dependencies()
	Logger.debug(LOG, "Pre-warming gesture dependencies…")
	local modules = {
		"hs.window", "hs.spaces", "hs.eventtap", "hs.mouse", 
		"hs.asapplescript", "hs.layout", "hs.timer", "hs.canvas"
	}
	for _, mod in ipairs(modules) do pcall(require, mod) end
	pcall(function() Actions.init(CoreState) end)
	pcall(function() Engine.init(CoreState, Actions) end)
end

--- Aggressive kickstart of the system HID subsystem.
--- Flooding the event loop with minor interactions can force macOS to
--- wake up dormant HID dispatch queues.
local function kickstart_hid()
	pcall(function()
		-- Minor mouse move (using 1px to ensure OS doesn't round to 0)
		local pos = hs.mouse.absolutePosition()
		hs.mouse.absolutePosition({x = pos.x + 1, y = pos.y + 1})
		hs.mouse.absolutePosition(pos)
		
		-- Synthetic scroll wheel events (HID-level wakeup)
		hs.eventtap.event.newScrollWheelEvent({0, 0}, {}, "pixel"):post()
		
		-- Poll focused window (IOKit activity)
		hs.window.focusedWindow()
	end)
end





-- ==================================
-- ==================================
-- ======= 3/ Device Watchers =======
-- ==================================
-- ==================================

--- Safely creates a touch frame watcher for a specific device ID.
local function create_watcher(deviceID)
	if not touchdevice then return end
	
	if touch_watchers[deviceID] then
		local ok, r = pcall(function() return touch_watchers[deviceID]:isRunning() end)
		if ok and r then return end
		pcall(function() touch_watchers[deviceID]:stop() end)
		touch_watchers[deviceID] = nil
	end
	
	local ok_dev, dev = pcall(touchdevice.forDeviceID, deviceID)
	if not ok_dev or not dev then return end
	
	-- Vital: Keep the device object alive to prevent GC!
	touch_devices[deviceID] = dev
	
	local w = dev:frameCallback(function(_, touches, _, _)
		-- Mark as active on very first frame received
		if not _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME and type(touches) == "table" and #touches > 0 then
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			Logger.success(LOG, "First raw touch frame received! Module is now fully operational.")
		end
		pcall(Engine.process_frame, touches)
	end)
	
	if w and type(w.start) == "function" then
		touch_watchers[deviceID] = w
		pcall(function() w:start() end)
		Logger.info(LOG, string.format("Trackpad watcher ATTACHED and STARTED for device: %s.", tostring(deviceID)))
	end
end

--- Force-kills and restarts all watchers to reset HID states.
local function recycle_watchers()
	Logger.debug(LOG, "Force-recycling trackpad watchers (Startup Kickstart)…")
	for id, w in pairs(touch_watchers) do
		pcall(function() w:stop() end)
		touch_watchers[id] = nil
		touch_devices[id] = nil
	end
	
	local ok, devices = pcall(touchdevice.allDevices)
	if not ok or type(devices) ~= "table" then
		ok, devices = pcall(touchdevice.devices)
	end

	if ok and type(devices) == "table" then
		for _, id in ipairs(devices) do pcall(create_watcher, id) end
	end
end

--- Ensures all connected touch devices have active watchers.
local function ensure_watchers()
	if not touchdevice then return end
	local ok, devices = pcall(touchdevice.allDevices)
	if not ok or type(devices) ~= "table" then
		ok, devices = pcall(touchdevice.devices)
	end
	if ok and type(devices) == "table" then
		for _, id in ipairs(devices) do 
			if not touch_watchers[id] or not touch_watchers[id]:isRunning() then
				pcall(create_watcher, id) 
			end
		end
	end
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

M.AX_NAMES           = Actions.AX_NAMES
M.SG_NAMES           = Actions.SG_NAMES
M.get_action_label   = Actions.get_label
M.forceCleanup       = Actions.force_cleanup
M.toggleRightClick   = Actions.toggle_right_click
M.triggerLookup      = Actions.trigger_lookup
M.isRightClickHeld   = Actions.is_right_click_held
M.on_action_changed  = Conflicts.on_action_changed

function M.apply_all_overrides()    Conflicts.apply_all_overrides(CoreState.ga) end
function M.restore_all_overrides()  Conflicts.restore_all_overrides()           end
function M.get_action(slot)         return CoreState.ga[slot]                   end
function M.set_action(slot, action) CoreState.ga[slot] = action                 end
function M.get_mode(slot)           return CoreState.modes[slot] or "x1"        end
function M.set_mode(slot, mode)     CoreState.modes[slot] = mode                end
function M.get_sensitivity(slot)    return CoreState.sensitivities[slot] or M.DEFAULT_SENSITIVITY end
function M.set_sensitivity(slot, s) CoreState.sensitivities[slot] = s           end
function M.get_space_wrap()         return CoreState.space_wrap                 end
function M.set_space_wrap(wrap)     CoreState.space_wrap = wrap                 end

function M.get_all_actions()
	local t = {}
	for k, v in pairs(CoreState.ga) do t[k] = v end
	return t
end
function M.get_all_modes()
	local t = {}
	for k, v in pairs(CoreState.modes) do t[k] = v end
	return t
end
function M.get_all_sensitivities()
	local t = {}
	for k, v in pairs(CoreState.sensitivities) do t[k] = v end
	return t
end

function M.enable_all()  CoreState.enabled = true  end
function M.disable_all() CoreState.enabled = false end
function M.enable(name)  if name == "all" then CoreState.enabled = true  end end
function M.disable(name) if name == "all" then CoreState.enabled = false end end
function M.is_enabled()  return CoreState.enabled end

--- Initializes and binds multi-touch listeners.
function M.start()
	Logger.debug(LOG, "Starting gestures module…")
	if not touchdevice then
		Logger.warn(LOG, "Touchdevice API is not available — gestures module disabled.")
		return
	end
	
	CoreState.enabled = true
	_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = false
	
	-- 1. Pre-warm dependencies
	prewarm_dependencies()
	
	-- 2. Prime the event loop with a Gesture Stream consumer.
	-- This forces the WindowServer to initialize HID routing trees immediately.
	if not gesture_primer then
		local ev = hs.eventtap.event.types
		gesture_primer = hs.eventtap.new({ ev.gesture, ev.scrollWheel }, function() return false end)
		_G.ERGOPTI_GESTURE_PRIMER = gesture_primer
		pcall(function() gesture_primer:start() end)
	end
	
	-- 3. Initial aggressive attachment
	kickstart_hid()
	recycle_watchers()
	
	-- 4. Kickstart & Health Check Loop
	-- Forcefully wakes up the HID subsystem every 0.5s until the first frame is confirmed.
	-- This bypasses the 10s IOKit "Idle-to-Active" transition lag.
	if discovery_timer then discovery_timer:stop() end
	
	discovery_timer = hs.timer.doEvery(0.5, function()
		if not _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME then
			Logger.debug(LOG, "Gestures still dormant — Kickstarting HID…")
			kickstart_hid()
			ensure_watchers()
		else
			-- Once active, switch to a slow health-check monitoring (every 20s)
			if discovery_timer:nextTrigger() < 5 then
				Logger.success(LOG, "Transitioning to background monitoring.")
				discovery_timer:setNextTrigger(20)
			end
			
			-- Health check: Restore dead watchers
			for id, w in pairs(touch_watchers) do
				local ok, r = pcall(function() return w:isRunning() end)
				if not ok or not r then
					Logger.warn(LOG, "Restoring dead listener for device " .. tostring(id))
					touch_watchers[id] = nil
					pcall(create_watcher, id)
				end
			end
			ensure_watchers()
		end
	end)
	
	Logger.info(LOG, "Gestures module started (Kickstart loop active).")
end

return M
