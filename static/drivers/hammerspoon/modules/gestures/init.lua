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

local hs = hs
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
    tap_3         = "none",
    tap_4         = "none",
    tap_5         = "none",
    swipe_2_diag  = "none",
    swipe_3_horiz = "none",
    swipe_3_diag  = "none",
    swipe_3_up    = "none",
    swipe_3_down  = "none",
    swipe_4_horiz = "none",
    swipe_4_diag  = "none",
    swipe_4_up    = "none",
    swipe_4_down  = "none",
    swipe_5_horiz = "none",
    swipe_5_diag  = "none",
    swipe_5_up    = "none",
    swipe_5_down  = "none",
}

M.DEFAULT_STATE = {
    gestures = true
}

M.AXIS_SLOTS = {
    "swipe_2_diag",
    "swipe_3_horiz", "swipe_3_diag",
    "swipe_4_horiz", "swipe_4_diag",
    "swipe_5_horiz", "swipe_5_diag",
}

M.SINGLE_SLOTS = {
    "tap_3", "tap_4", "tap_5",
    "swipe_3_up", "swipe_3_down",
    "swipe_4_up", "swipe_4_down",
    "swipe_5_up", "swipe_5_down",
}





-- ====================================
-- ====================================
-- ======= 2/ Core Architecture =======
-- ====================================
-- ====================================

local CoreState = {
    enabled        = true,
    ga             = {},
    natural_scroll = false
}

-- Initialize active actions with defaults
for k, v in pairs(M.DEFAULT_GESTURES) do
    CoreState.ga[k] = v
end

-- Initialize Engine dependencies
Engine.init(CoreState, Actions)

local touch_watchers = {}

--- Determines natural scroll setting from macOS.
local function readNaturalScroll()
    local ok, out = pcall(hs.execute, "defaults read -g com.apple.swipescrolldirection 2>/dev/null")
    return ok and type(out) == "string" and out:match("1") ~= nil
end





-- ==================================
-- ==================================
-- ======= 3/ Device Watchers =======
-- ==================================
-- ==================================

local function create_watcher(deviceID)
    if not touchdevice then return end
    
    if touch_watchers[deviceID] then
        local ok, r = pcall(function() return touch_watchers[deviceID]:isRunning() end)
        if ok and r then return end
        pcall(function() touch_watchers[deviceID]:stop() end)
    end
    
    local ok_dev, dev = pcall(touchdevice.forDeviceID, deviceID)
    if not ok_dev or not dev then return end
    
    local w = dev:frameCallback(function(_, touches, _, _)
        pcall(Engine.process_frame, touches)
    end)
    
    touch_watchers[deviceID] = w
    if w and type(w.start) == "function" then
        pcall(function() w:start() end)
        if type(notifications.debugLog) == "function" then
            pcall(notifications.debugLog, "watcher created for device", deviceID)
        end
    end
end

local function ensure_watchers()
    if not touchdevice then return end
    local ok, devices = pcall(touchdevice.devices)
    if ok and type(devices) == "table" then
        for _, id in ipairs(devices) do pcall(create_watcher, id) end
    end
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

-- Expose UI dependencies
M.AX_NAMES           = Actions.AX_NAMES
M.SG_NAMES           = Actions.SG_NAMES
M.get_action_label   = Actions.get_label
M.forceCleanup       = Actions.force_cleanup
M.toggleSelection    = Actions.toggle_selection
M.triggerLookup      = Actions.trigger_lookup
M.isLeftClickPressed = Actions.is_left_click_pressed

-- Expose Conflict management
M.on_action_changed = Conflicts.on_action_changed

function M.apply_all_overrides()
    Conflicts.apply_all_overrides(CoreState.ga)
end

function M.get_action(slot)         return CoreState.ga[slot] end
function M.set_action(slot, action) CoreState.ga[slot] = action end

function M.get_all_actions()
    local t = {}
    for k, v in pairs(CoreState.ga) do t[k] = v end
    return t
end

function M.enable_all()  CoreState.enabled = true  end
function M.disable_all() CoreState.enabled = false end

function M.enable(name)  if name == "all" then CoreState.enabled = true  end end
function M.disable(name) if name == "all" then CoreState.enabled = false end end
function M.is_enabled()  return CoreState.enabled end

--- Initializes and binds multi-touch listeners.
function M.start()
    if not touchdevice then
        Logger.warn(LOG, "Module touchdevice non disponible — gestes désactivés")
        return
    end
    
    CoreState.enabled = true
    CoreState.natural_scroll = readNaturalScroll()
    pcall(ensure_watchers)
    
    -- Health check timer to restore dead device hooks
    hs.timer.doEvery(5, function()
        for id, w in pairs(touch_watchers) do
            local ok, r = pcall(function() return w:isRunning() end)
            if not ok or not r then
                touch_watchers[id] = nil
                pcall(create_watcher, id)
            end
        end
        pcall(ensure_watchers)
    end)
end

return M
