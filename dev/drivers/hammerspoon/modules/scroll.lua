local utils = require("lib.utils")
local gestures = require("modules.gestures")

local M = {}

-- `leftCommandPhysical` is true while the Karabiner layer key is held.
-- This script expects Karabiner to emit the `F19` keycode for the layer.
-- We detect that low-level keycode and do not rely on modifier flags.
local leftCommandPhysical = false
local f19_keycode = hs.keycodes.map["f19"]

-- Listen for F19 keyDown/keyUp and set `leftCommandPhysical` while held.
local physicalOptionTap = hs.eventtap.new({hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp}, function(event)
    local kc = event:getKeyCode()
    if kc == f19_keycode then
        if event:getType() == hs.eventtap.event.types.keyDown then
            if gestures.isLeftClickPressed() then gestures.forceCleanup() end
            leftCommandPhysical = true
        else
            leftCommandPhysical = false
        end
    end
    return false
end)

-- Handle scrollWheel events only when the Karabiner layer (F19) is active.
-- `leftCommandPhysical` is the canonical indicator of the layer.
local scrollZoom = hs.eventtap.new({hs.eventtap.event.types.scrollWheel}, function(event)
    local flags = event:getFlags()
    local scrollY = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)

    -- React only when the physical layer key (F19) is active.
    if leftCommandPhysical then
        if gestures.isLeftClickPressed() then gestures.forceCleanup() end
        if scrollY > 0 then
            for i=1, math.max(1, math.floor(scrollY)) do
                hs.eventtap.event.newSystemKeyEvent("SOUND_UP", true):post()
                hs.eventtap.event.newSystemKeyEvent("SOUND_UP", false):post()
            end
        elseif scrollY < 0 then
            for i=1, math.max(1, math.floor(-scrollY)) do
                hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", true):post()
                hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", false):post()
            end
        end
        return true
    end

    return false
end)

function M.start()
    pcall(function() physicalOptionTap:start() end)
    pcall(function() scrollZoom:start() end)
    utils.debugLog("scroll: event taps started")
end

function M.stop()
    pcall(function() physicalOptionTap:stop() end)
    pcall(function() scrollZoom:stop() end)
    leftCommandPhysical = false
    utils.debugLog("scroll: event taps stopped")
end

return M
