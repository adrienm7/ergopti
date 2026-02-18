local utils = require("utils")
local gestures = require("gestures")

local M = {}

local leftCommandPhysical = false
local f19_keycode = hs.keycodes.map["f19"] or hs.keycodes.map["leftcmd"] or hs.keycodes.map["cmd"]

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

local scrollZoom = hs.eventtap.new({hs.eventtap.event.types.scrollWheel}, function(event)
    local flags = event:getFlags()
    local scrollY = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)

    if flags.cmd then
        if scrollY > 0 then
            hs.eventtap.keyStroke({"cmd"}, "pad+", 0)
        elseif scrollY < 0 then
            hs.eventtap.keyStroke({"cmd"}, "pad-", 0)
        end
        return true
    end

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

return M
