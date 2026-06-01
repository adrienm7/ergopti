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

local function load_touchdevice_module()
	local candidates = {
		"hs._asm.undocumented.touchdevice",
		"vendor.hs_asm.undocumented.touchdevice",
	}
	for _, module_name in ipairs(candidates) do
		local ok, module_ref = pcall(require, module_name)
		if ok and module_ref then
			Logger.info(LOG, "Touchdevice module loaded from '%s'.", module_name)
			return module_ref
		end
	end
	return nil
end

local touchdevice = load_touchdevice_module()

local Engine    = require("modules.gestures.engine")
local Actions   = require("modules.gestures.actions")
local Conflicts = require("modules.gestures.conflicts")





-- =======================================
--- =======================================
-- ======= 1/ Constants & Defaults =======
--- =======================================
-- =======================================

M.DEFAULT_GESTURES = {
	tap_2                = "none",
	tap_3                = "left_click_toggle",
	tap_4                = "app_window_previous",
	tap_5                = "none",

	swipe_3_horiz        = "none",
	swipe_4_horiz        = "none",
	swipe_5_horiz        = "none",

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

M.AXIS_SLOTS = {
	"swipe_3_horiz",
	"swipe_4_horiz",
	"swipe_5_horiz",
}





-- ====================================
--- ====================================
-- ======= 2/ Core Architecture =======
--- ====================================
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

-- Wake-from-sleep watcher. On some hardware (notably external Magic Trackpads
-- and after long sleeps), macOS tears down the multitouch subscription during
-- system sleep — frames never resume on wake even though our Lua-side watcher
-- still thinks it is attached. We re-create the device on systemDidWake /
-- screensDidUnlock to recover, mirroring the pattern BetterTouchTool uses.
_G.ERGOPTI_SLEEP_WATCHER = _G.ERGOPTI_SLEEP_WATCHER or nil
local sleep_watcher = _G.ERGOPTI_SLEEP_WATCHER

-- Vital: Permanent eventtap to keep the macOS gesture subsystem "awake".
-- Also serves as a wakeup signal: if a gesture-class event reaches the primer
-- but the touchdevice subscription has not yet delivered a frame, we know the
-- subscription is stale and trigger an emergency recycle in time to capture the
-- user's CURRENT gesture rather than waiting for the next discovery tick.
_G.ERGOPTI_GESTURE_PRIMER = _G.ERGOPTI_GESTURE_PRIMER or nil
local gesture_primer = _G.ERGOPTI_GESTURE_PRIMER

-- Debounce for primer-triggered emergency recycles
local last_emergency_recycle = 0

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
--- ==================================
-- ======= 3/ Device Watchers =======
--- ==================================
-- ==================================

-- Frame counters per device (for diagnostic heartbeat logging).
-- Reset whenever a device gets a fresh watcher via create_watcher.
local frame_counters = {}

--- Counts currently-registered watchers (diagnostic helper).
--- @return number Watcher count.
local function count_watchers()
	local n = 0
	for _ in pairs(touch_watchers) do n = n + 1 end
	return n
end

--- Safely invokes a method on the touchdevice object and stringifies the result.
--- Used by create_watcher to capture the device introspection methods even when
--- they are missing from older versions of the undocumented library.
--- @param dev table The touchdevice device object.
--- @param method_name string Name of the method to invoke.
--- @return string Stringified result, "no_method", or "err:<msg>".
local function safe_dev_call(dev, method_name)
	local m = dev[method_name]
	if type(m) ~= "function" then return "no_method" end
	local ok, val = pcall(m, dev)
	if not ok then return "err:" .. tostring(val) end
	return tostring(val)
end

--- Enumerates trackpad devices via the touchdevice library.
--- The actual API is `touchdevice.devices()` — `allDevices()` does not exist.
--- @return table List of device IDs (empty table on failure).
local function enumerate_devices()
	if not touchdevice then return {} end
	local ok, devices = pcall(touchdevice.devices)
	if not ok or type(devices) ~= "table" then
		Logger.error(LOG, "enumerate_devices: touchdevice.devices() failed (ok=%s, type=%s)", tostring(ok), type(devices))
		return {}
	end
	return devices
end

--- Safely creates a touch frame watcher for a specific device ID.
local function create_watcher(deviceID)
	Logger.info(LOG, "create_watcher: ENTRY deviceID=%s", tostring(deviceID))
	if not touchdevice then
		Logger.warn(LOG, "create_watcher: touchdevice unavailable, aborting")
		return
	end

	if touch_watchers[deviceID] then
		local ok, r = pcall(function() return touch_watchers[deviceID]:running() end)
		Logger.info(LOG, "create_watcher: existing watcher present (running=%s, pcall=%s)", tostring(r), tostring(ok))
		if ok and r then
			Logger.info(LOG, "create_watcher: existing watcher already running — keeping it")
			return
		end
		pcall(function() touch_watchers[deviceID]:stop() end)
		touch_watchers[deviceID] = nil
	end

	local ok_dev, dev = pcall(touchdevice.forDeviceID, deviceID)
	if not ok_dev or not dev then
		Logger.error(LOG, "create_watcher: touchdevice.forDeviceID FAILED (ok=%s, dev=%s)", tostring(ok_dev), tostring(dev))
		return
	end

	-- Dump device introspection: helps diagnose why frames don't flow.
	Logger.info(LOG, "create_watcher: device introspection — id=%s, builtin=%s, alive=%s, running=%s, MTHID=%s, driverReady=%s, productName=%s",
		safe_dev_call(dev, "deviceID"),
		safe_dev_call(dev, "builtin"),
		safe_dev_call(dev, "alive"),
		safe_dev_call(dev, "running"),
		safe_dev_call(dev, "MTHIDDevice"),
		safe_dev_call(dev, "driverReady"),
		safe_dev_call(dev, "productName"))

	-- Vital: Keep the device object alive to prevent GC!
	touch_devices[deviceID] = dev
	frame_counters[deviceID] = 0

	local FRAME_HEARTBEAT_EVERY = 120  -- Log every 120 frames (~2s at 60Hz)

	local w = dev:frameCallback(function(_, touches, _, _)
		frame_counters[deviceID] = (frame_counters[deviceID] or 0) + 1
		local fc = frame_counters[deviceID]
		-- Mark as active on very first frame received
		if not _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME and type(touches) == "table" and #touches > 0 then
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			local first = touches[1] or {}
			local pos = (first.absoluteVector or {}).position or {}
			Logger.success(LOG, "FIRST RAW TOUCH FRAME received! device=%s, frame#=%d, touches=%d, first_pos=(%.1f,%.1f).",
				tostring(deviceID), fc, #touches,
				tonumber(pos.x) or -1, tonumber(pos.y) or -1)
		end
		-- Heartbeat: confirms frames are still flowing
		if fc == 1 or fc % FRAME_HEARTBEAT_EVERY == 0 then
			Logger.debug(LOG, "frame#%d device=%s touches=%d", fc, tostring(deviceID),
				type(touches) == "table" and #touches or 0)
		end
		pcall(Engine.process_frame, touches)
	end)

	if not w then
		Logger.error(LOG, "create_watcher: frameCallback returned nil for device=%s", tostring(deviceID))
		return
	end

	if type(w.start) ~= "function" then
		Logger.error(LOG, "create_watcher: w:start is not a function for device=%s (w=%s)", tostring(deviceID), tostring(w))
		return
	end

	touch_watchers[deviceID] = w
	local ok_start, err_start = pcall(function() w:start() end)
	local ok_run, running = pcall(function() return w:running() end)
	local ok_alive, alive = pcall(function() return w:alive() end)
	Logger.info(LOG, "create_watcher: ATTACHED device=%s, start_pcall=%s, start_err=%s, running=%s, alive=%s",
		tostring(deviceID), tostring(ok_start), tostring(err_start),
		ok_run and tostring(running) or "err", ok_alive and tostring(alive) or "err")
end

--- Force-kills and restarts all watchers to reset HID states.
local function recycle_watchers()
	local before = count_watchers()
	Logger.info(LOG, "recycle_watchers: BEGIN (watchers_before=%d, first_frame=%s)",
		before, tostring(_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME))
	local stopped = 0
	for id, w in pairs(touch_watchers) do
		local ok = pcall(function() w:stop() end)
		Logger.debug(LOG, "  stopping watcher device=%s (pcall=%s)", tostring(id), tostring(ok))
		touch_watchers[id] = nil
		touch_devices[id] = nil
		frame_counters[id] = nil
		stopped = stopped + 1
	end

	local devices = enumerate_devices()
	if #devices == 0 then
		Logger.error(LOG, "  recycle_watchers: no devices found — gestures will not work")
	else
		Logger.info(LOG, "  recycle_watchers: found %d device(s) to attach", #devices)
		for i, id in ipairs(devices) do
			Logger.debug(LOG, "    device #%d: id=%s", i, tostring(id))
			pcall(create_watcher, id)
		end
	end
	Logger.info(LOG, "recycle_watchers: END (watchers_after=%d, stopped=%d)", count_watchers(), stopped)
end

--- Ensures all connected touch devices have active watchers.
local function ensure_watchers()
	if not touchdevice then return end
	for _, id in ipairs(enumerate_devices()) do
		local exists = touch_watchers[id]
		local running = false
		if exists then
			local ok_r, r = pcall(function() return exists:running() end)
			running = ok_r and r
		end
		if not exists or not running then
			Logger.info(LOG, "ensure_watchers: (re)creating watcher for device=%s (existed=%s, running=%s)",
				tostring(id), tostring(exists ~= nil), tostring(running))
			pcall(create_watcher, id)
		end
	end
end





-- =============================
--- =============================
-- ======= 4/ Public API =======
--- =============================
-- =============================

M.AX_NAMES           = Actions.AX_NAMES
M.SG_NAMES           = Actions.SG_NAMES
M.get_sg_names       = Actions.get_sg_names
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

-- Startup-phase timing.
--
-- DESIGN NOTE (definitive, after deep reverse-engineering audit of every
-- MultitouchSupport.framework symbol — see project_touchdevice_dormancy_is_kernel
-- memory): the macOS touchdevice subsystem CANNOT be activated from userspace
-- before the user's first physical touch. The streaming gate is in the kernel
-- driver (AppleMultitouchDriver / AppleHSSPIHIDDriver), which has no userspace
-- "force tick" entry point. MTDeviceStart only ARMS the callback path; the
-- sensor itself stays dormant until non-zero contact. Confirmed by 15+ years of
-- public RE across BetterTouchTool, FingerMgmt, OpenMultitouchSupport,
-- libpointing, Kivy mactouch — all accept the dormancy.
--
-- Empirical logs prove this: recycling at 2 s for 30 s produced 14 identical
-- "running=true, alive=false" introspections, and the first frame arrived
-- exactly when the user first touched (which happened to be at +27 s). The
-- recycles changed nothing.
--
-- So: recycle ONCE at +5 s as a safety net for a hypothetical dropped initial
-- attach, then stop. Once frames flow, the health-check loop runs every 30 s
-- for hot-plug recovery only. A wake-from-sleep watcher recreates the device
-- on resume (the BetterTouchTool pattern), since sleep DOES tear down the
-- subscription on some hardware.
local STARTUP_SAFETY_PROBE_SEC   = 5.0   -- One-shot retry at +5 s if no frame yet
local STARTUP_PHASE_TIMEOUT_SEC  = 30.0  -- Give up the aggressive phase after this
local HEALTH_CHECK_INTERVAL_SEC  = 30.0  -- Slow cadence once frames are flowing
-- Cooldown between primer-triggered emergency recycles, so a fast burst of
-- gesture events at the moment of the first user contact does not retrigger
-- the heavy recycle path several times in a row.
local EMERGENCY_RECYCLE_COOLDOWN = 1.0

-- Forward declarations: the startup and health-check loops reference each
-- other so the timer can swap modes once a frame arrives.
local start_health_check_loop
local start_startup_probe_loop

--- Schedules a single safety-net recycle at +STARTUP_SAFETY_PROBE_SEC if no
--- frame has been received by then, and arms a one-shot watcher for the very
--- first frame at which point we hand off to the slow health-check loop.
---
--- We do NOT keep recycling indefinitely: every empirical log run confirms
--- recycling does not influence when frames start (the kernel driver decides).
--- See project_touchdevice_dormancy_is_kernel memory for the full audit.
start_startup_probe_loop = function()
	local started_at = hs.timer.secondsSinceEpoch()
	if discovery_timer then pcall(function() discovery_timer:stop() end) end
	Logger.info(LOG, "ENTER startup phase — single safety probe scheduled at +%.1fs, watching for first frame",
		STARTUP_SAFETY_PROBE_SEC)

	-- Fast poll just to detect the first-frame moment so we can hand off to
	-- the health-check loop. The poll itself does no recycling.
	discovery_timer = hs.timer.doEvery(0.5, function()
		local elapsed = hs.timer.secondsSinceEpoch() - started_at
		if _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME then
			Logger.success(LOG, "Startup phase EXIT — first frame received after %.2fs.", elapsed)
			pcall(function() discovery_timer:stop() end)
			start_health_check_loop()
			return
		end
		if elapsed > STARTUP_PHASE_TIMEOUT_SEC then
			Logger.info(LOG, "Startup phase timeout (%.1fs) — switching to slow health-check (subsystem will wake on first physical touch).", elapsed)
			pcall(function() discovery_timer:stop() end)
			start_health_check_loop()
			return
		end
	end)

	-- One-shot safety recycle: in the rare case the very first attach was
	-- somehow dropped, give it ONE retry. Beyond that, recycling is futile.
	hs.timer.doAfter(STARTUP_SAFETY_PROBE_SEC, function()
		if _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME then return end
		Logger.info(LOG, "Safety-net recycle at +%.1fs (no frame yet) — one-shot, will not retry further",
			STARTUP_SAFETY_PROBE_SEC)
		kickstart_hid()
		recycle_watchers()
	end)
end

--- Runs the slow health-check loop once frames are flowing.
--- Reattaches any watcher that died (device sleep, cable disconnect, etc.).
--- If for some reason the frame stream stops entirely, we switch back to the
--- aggressive startup probe so recovery is fast.
start_health_check_loop = function()
	if discovery_timer then pcall(function() discovery_timer:stop() end) end
	Logger.info(LOG, "ENTER slow health-check loop (cadence=%.0fs)", HEALTH_CHECK_INTERVAL_SEC)
	discovery_timer = hs.timer.doEvery(HEALTH_CHECK_INTERVAL_SEC, function()
		if not _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME then
			-- Defensive: should not happen, but if we lost the stream entirely,
			-- restart the aggressive probe loop so the user is not stuck waiting.
			Logger.warn(LOG, "Health-check: frame stream lost — switching back to startup probe loop.")
			pcall(function() discovery_timer:stop() end)
			start_startup_probe_loop()
			return
		end
		Logger.debug(LOG, "Health-check tick (watchers=%d)", count_watchers())
		-- Reattach any watcher that stopped (device sleep, USB disconnect…)
		for id, w in pairs(touch_watchers) do
			local ok, r = pcall(function() return w:running() end)
			if not ok or not r then
				Logger.warn(LOG, "Health-check: restoring dead listener for device %s.", tostring(id))
				touch_watchers[id] = nil
				pcall(create_watcher, id)
			end
		end
		ensure_watchers()
	end)
end

--- Emergency-recycle the watchers when the primer eventtap sees a gesture
--- event before any frame has been received.  The primer fires synchronously
--- on the main thread; we defer the heavy recycle to the next tick so the
--- eventtap callback returns immediately.
--- @return boolean True if a recycle was scheduled, false if debounced.
local function schedule_emergency_recycle()
	local now = hs.timer.secondsSinceEpoch()
	if (now - last_emergency_recycle) < EMERGENCY_RECYCLE_COOLDOWN then
		Logger.debug(LOG, "schedule_emergency_recycle: DEBOUNCED (last fire was %.2fs ago)", now - last_emergency_recycle)
		return false
	end
	last_emergency_recycle = now
	Logger.warn(LOG, "schedule_emergency_recycle: SCHEDULED in 20ms (first_frame=%s, watchers=%d)",
		tostring(_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME), count_watchers())
	hs.timer.doAfter(0.02, function()
		if _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME then
			Logger.done(LOG, "Emergency recycle ABORTED — first frame arrived in the meantime.")
			return
		end
		Logger.warn(LOG, "EMERGENCY RECYCLE executing now (primer caught gesture event before any frame)")
		kickstart_hid()
		recycle_watchers()
	end)
	return true
end

--- Counter for primer events received (diagnostic).
local primer_event_count = 0
local primer_last_log_time = 0

--- Initializes and binds multi-touch listeners.
function M.start()
	Logger.start(LOG, "Starting gestures module…")
	Logger.info(LOG, "============== GESTURES STARTUP DIAGNOSTIC ==============")
	Logger.info(LOG, "Hammerspoon timestamp: %.3f", hs.timer.secondsSinceEpoch())
	Logger.info(LOG, "touchdevice module available: %s", tostring(touchdevice ~= nil))
	if not touchdevice then
		Logger.warn(LOG, "Touchdevice API is not available — gestures module disabled on this runtime.")
		return
	end

	-- Dump touchdevice top-level methods so we can spot missing APIs.
	local td_keys = {}
	for k in pairs(touchdevice) do td_keys[#td_keys + 1] = k end
	table.sort(td_keys)
	Logger.info(LOG, "touchdevice top-level keys (%d): %s", #td_keys, table.concat(td_keys, ", "))

	-- Enumerate devices before doing anything.
	local pre_devices = enumerate_devices()
	Logger.info(LOG, "touchdevice.devices() returned %d device(s) at startup", #pre_devices)
	for i, id in ipairs(pre_devices) do
		Logger.info(LOG, "  pre-init device #%d: id=%s", i, tostring(id))
	end

	CoreState.enabled = true
	_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = false
	last_emergency_recycle = 0
	primer_event_count = 0
	primer_last_log_time = 0

	-- 1. Pre-warm all lazy Hammerspoon modules so the first gesture fires fast.
	Logger.info(LOG, "STEP 1/4: pre-warming Hammerspoon dependencies…")
	prewarm_dependencies()

	-- 2. Prime the WindowServer HID routing tree by consuming gesture events.
	-- Without this consumer, the OS never initialises the gesture dispatch
	-- path and touchdevice frame callbacks silently go nowhere.
	-- The primer subscribes to ALL gesture-class event types so the OS fully
	-- initialises the dispatch path on first run, and serves a second purpose:
	-- when the primer sees a gesture event but no touchdevice frame has been
	-- received yet, the subscription is stale — we trigger an emergency recycle
	-- so the user's current gesture is captured rather than lost.
	Logger.info(LOG, "STEP 2/4: configuring gesture primer eventtap…")
	local ev = hs.eventtap.event.types
	if not gesture_primer then
		local types_to_watch = { ev.gesture, ev.scrollWheel }
		local extra_names = {"beginGesture", "endGesture", "swipe", "magnify", "rotate", "directTouch", "smartMagnify"}
		local added = { "gesture", "scrollWheel" }
		for _, name in ipairs(extra_names) do
			if ev[name] then
				table.insert(types_to_watch, ev[name])
				table.insert(added, name)
			else
				Logger.warn(LOG, "  primer event type '%s' is NOT in hs.eventtap.event.types (skipped)", name)
			end
		end
		Logger.info(LOG, "  primer subscribing to %d types: %s", #types_to_watch, table.concat(added, ", "))
		local ok_tap, new_tap = pcall(hs.eventtap.new, types_to_watch, function(event)
			local t = event:getType()
			primer_event_count = primer_event_count + 1
			-- Re-engage if macOS disabled our tap (slow callback or accessibility toggle)
			if t == ev.tapDisabledByTimeout or t == ev.tapDisabledByUserInput then
				Logger.warn(LOG, "PRIMER tap DISABLED by OS (type=%d) — re-engaging immediately", t)
				pcall(function() gesture_primer:start() end)
				return false
			end
			-- Throttled visibility: 5 events/sec max, so we see something is happening
			-- without flooding the log during normal use.
			local now = hs.timer.secondsSinceEpoch()
			if (now - primer_last_log_time) > 0.2 then
				primer_last_log_time = now
				Logger.debug(LOG, "PRIMER event#%d type=%d first_frame=%s",
					primer_event_count, t, tostring(_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME))
			end
			-- Wakeup signal: gesture-class event reached us but the touchdevice
			-- callback has not fired yet → the subscription is dormant. Recycle.
			if not _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME then
				Logger.warn(LOG, "PRIMER caught event#%d type=%d BEFORE any touchdevice frame — calling schedule_emergency_recycle()",
					primer_event_count, t)
				schedule_emergency_recycle()
			end
			return false
		end)
		if not ok_tap or not new_tap then
			Logger.error(LOG, "  hs.eventtap.new FAILED for primer (ok=%s, tap=%s)", tostring(ok_tap), tostring(new_tap))
		else
			gesture_primer = new_tap
			_G.ERGOPTI_GESTURE_PRIMER = gesture_primer
			local ok_start = pcall(function() gesture_primer:start() end)
			Logger.info(LOG, "  primer eventtap CREATED and started (start_pcall=%s)", tostring(ok_start))
		end
	else
		-- Reuse across module reloads, but make sure it is still alive
		local ok_start = pcall(function() gesture_primer:start() end)
		Logger.info(LOG, "  primer eventtap already exists — restarting (start_pcall=%s)", tostring(ok_start))
	end

	-- 3. Immediate first attachment attempt.
	Logger.info(LOG, "STEP 3/4: kickstart HID + first watcher recycle…")
	kickstart_hid()
	recycle_watchers()

	-- 4. Startup phase: a single safety-net recycle + first-frame detection.
	-- The previous burst/loop approach was futile — empirical logs show the
	-- kernel-side driver gates frame delivery on the first physical touch and
	-- no userspace recycling changes that. See project_touchdevice_dormancy
	-- memory for the full audit.
	Logger.info(LOG, "STEP 4/5: starting first-frame watcher…")
	start_startup_probe_loop()

	-- 5. Wake-from-sleep watcher (BetterTouchTool pattern). Sleep can silently
	-- tear down the multitouch subscription on some hardware; we re-create the
	-- device when the system or screens wake so frames resume reliably.
	Logger.info(LOG, "STEP 5/5: arming wake-from-sleep watcher…")
	if sleep_watcher then
		pcall(function() sleep_watcher:stop() end)
	end
	local ok_cw, cw_module = pcall(require, "hs.caffeinate.watcher")
	if ok_cw and cw_module then
		sleep_watcher = cw_module.new(function(event)
			if event == cw_module.systemDidWake or event == cw_module.screensDidUnlock then
				Logger.info(LOG, "Wake-from-sleep detected (event=%d) — recycling watchers", event)
				kickstart_hid()
				recycle_watchers()
			end
		end)
		_G.ERGOPTI_SLEEP_WATCHER = sleep_watcher
		pcall(function() sleep_watcher:start() end)
		Logger.info(LOG, "  wake-from-sleep watcher armed")
	else
		Logger.warn(LOG, "  hs.caffeinate.watcher unavailable — wake-from-sleep recovery disabled")
	end

	Logger.success(LOG, "============== gestures module startup COMPLETE — primer events so far: %d ==============", primer_event_count)
end

--- Dumps a complete snapshot of the gestures runtime state to the log.
--- Useful for diagnosing what the watchers, primer, and timers are doing
--- without having to add ad-hoc print statements.
function M.diagnose()
	Logger.info(LOG, "============== M.diagnose() snapshot ==============")
	Logger.info(LOG, "  first_frame_received: %s", tostring(_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME))
	Logger.info(LOG, "  CoreState.enabled:    %s", tostring(CoreState.enabled))
	Logger.info(LOG, "  primer alive:         %s", tostring(gesture_primer ~= nil))
	Logger.info(LOG, "  primer event count:   %d", primer_event_count)
	Logger.info(LOG, "  watchers count:       %d", count_watchers())
	for id, w in pairs(touch_watchers) do
		local ok_run, running = pcall(function() return w:running() end)
		local ok_alive, alive = pcall(function() return w:alive() end)
		local fc = frame_counters[id] or 0
		Logger.info(LOG, "    device=%s running=%s alive=%s frame_count=%d",
			tostring(id),
			ok_run and tostring(running) or "err",
			ok_alive and tostring(alive) or "err",
			fc)
	end
	local devices = enumerate_devices()
	Logger.info(LOG, "  currently visible devices (%d):", #devices)
	for i, id in ipairs(devices) do
		Logger.info(LOG, "    device #%d: id=%s, watched=%s", i, tostring(id), tostring(touch_watchers[id] ~= nil))
	end
	Logger.info(LOG, "============== end diagnose ==============")
end

return M
