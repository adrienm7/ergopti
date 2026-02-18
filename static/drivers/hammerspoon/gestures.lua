local utils = require("utils")
local touchdevice = require("hs._asm.undocumented.touchdevice")

local M = {}

-- Internal state (from previous touchpad/swipe)
local leftClickPressed = false
local mouseEventTap = nil

local _touchStartTime = nil
local _tapStartPoint = nil
local _tapEndPoint = nil
local _maybeTap = false
local _tapFingerCount = nil
local _tapDelta = 2.0
local _lastDebugTime = 0

local touch_watchers = {}

-- Swipe defaults
local Swipe3 = nil
local current_id_3f, threshold_horizontal, threshold_vertical
local HORIZONTAL_DEFAULT = 0.04
local VERTICAL_DEFAULT = 0.12

threshold_horizontal = HORIZONTAL_DEFAULT
threshold_vertical = VERTICAL_DEFAULT

local function forceCleanup()
    utils.debugLog("forceCleanup: start mouseEventTap=", tostring(mouseEventTap), "leftClickPressed=", tostring(leftClickPressed))
    if mouseEventTap then
        utils.debugLog("forceCleanup: stopping mouseEventTap")
        pcall(function() mouseEventTap:stop() end)
        mouseEventTap = nil
    end
    pcall(function()
        if leftClickPressed then
            local pos = hs.mouse.absolutePosition()
            hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pos):post()
        end
        local pos = hs.mouse.absolutePosition()
        hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.mouseMoved, pos):post()
    end)
    leftClickPressed = false
    _touchStartTime = nil
    _tapStartPoint = nil
    _tapEndPoint = nil
    _tapFingerCount = nil
    _maybeTap = false
end

local function toggleSelection()
    utils.debugLog("toggleSelection: activating")
    if leftClickPressed then
        forceCleanup()
        return
    end
    local pos = hs.mouse.absolutePosition()
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, pos):post()
    leftClickPressed = true

    mouseEventTap = hs.eventtap.new({hs.eventtap.event.types.mouseMoved,
                                     hs.eventtap.event.types.leftMouseDragged,
                                     hs.eventtap.event.types.leftMouseUp},
        function(e)
            local t = e:getType()
            if t == hs.eventtap.event.types.leftMouseDragged then
                local p = e:location()
                hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDragged, p):post()
                return true
            elseif t == hs.eventtap.event.types.leftMouseUp then
                hs.timer.doAfter(0, function() forceCleanup() end)
                return true
            end
            return false
        end)
    pcall(function() mouseEventTap:start() end)
    utils.debugLog("toggleSelection: mouseEventTap started")
end

local function triggerLookup()
    utils.debugLog("triggerLookup: activating")
    pcall(function() hs.eventtap.keyStroke({"ctrl", "cmd"}, "d", 0) end)
end

local function create_watcher(deviceID)
    if touch_watchers[deviceID] and touch_watchers[deviceID].watcher then
        local ok, running = pcall(function() return touch_watchers[deviceID].watcher:isRunning() end)
        if ok and running then return end
    end
    if touch_watchers[deviceID] and touch_watchers[deviceID].watcher then
        pcall(function() touch_watchers[deviceID].watcher:stop() end)
        touch_watchers[deviceID] = nil
    end
    local lastSeen = hs.timer.secondsSinceEpoch()
    local lastNFingers = nil
    local stableFrames = 0
    local watcher = touchdevice.forDeviceID(deviceID):frameCallback(function(_, touches, _, _)
        local ok, err = pcall(function()
            local nFingers = #touches
            if lastNFingers ~= nFingers then
                utils.debugLog("watcher:", deviceID, "nFingers=", nFingers)
                lastNFingers = nFingers
                stableFrames = 1
            else
                stableFrames = stableFrames + 1
            end
            local now = hs.timer.secondsSinceEpoch()
            if touch_watchers[deviceID] then touch_watchers[deviceID].lastSeen = now end

            if nFingers == 0 then
                if _tapStartPoint and _tapEndPoint and _maybeTap and _tapFingerCount then
                    local delta = math.abs(_tapStartPoint.x - _tapEndPoint.x) + math.abs(_tapStartPoint.y - _tapEndPoint.y)
                    if delta < _tapDelta then
                        if _tapFingerCount == 3 then
                            utils.debugLog("watcher:", deviceID, "detected 3-finger tap (delta=", delta, ") -> toggleSelection")
                            toggleSelection()
                        elseif _tapFingerCount == 4 then
                            utils.debugLog("watcher:", deviceID, "detected 4-finger tap (delta=", delta, ") -> triggerLookup")
                            triggerLookup()
                        end
                    end
                end
                _touchStartTime = nil
                _tapStartPoint = nil
                _tapEndPoint = nil
                _tapFingerCount = nil
                _maybeTap = false
                return
            end

            if nFingers > 0 and not _touchStartTime then
                _touchStartTime = now
                _maybeTap = true
            elseif _touchStartTime and _maybeTap and (now - _touchStartTime > 0.5) then
                _maybeTap = false
                _tapStartPoint = nil
                _tapEndPoint = nil
            end

            if (nFingers == 3 or nFingers == 4) and stableFrames >= 2 then
                local xSum, ySum = 0, 0
                for i=1,#touches do
                    xSum = xSum + touches[i].absoluteVector.position.x
                    ySum = ySum + touches[i].absoluteVector.position.y
                end
                local xAvg = xSum / #touches
                local yAvg = ySum / #touches

                if _maybeTap and not _tapStartPoint then
                    _tapStartPoint = { x = xAvg, y = yAvg }
                    _tapFingerCount = nFingers
                    utils.debugLog("watcher:", deviceID, "tap start at", xAvg, yAvg, "fingers=", _tapFingerCount, "stableFrames=", stableFrames)
                end
                if _maybeTap then
                    _tapEndPoint = { x = xAvg, y = yAvg }
                    if (now - (_lastDebugTime or 0)) > 2 then
                        _lastDebugTime = now
                        utils.debugLog("watcher:", deviceID, "tap update at", xAvg, yAvg)
                    end
                end
            elseif nFingers > 4 then
                _maybeTap = false
                _tapStartPoint = nil
                _tapEndPoint = nil
                _tapFingerCount = nil
            end
        end)
        if not ok then
            hs.timer.doAfter(0, function()
                hs.alert.show("touchdevice callback error: " .. tostring(err), 3)
            end)
        end
    end)

    touch_watchers[deviceID] = { watcher = watcher, lastSeen = lastSeen }
    pcall(function() watcher:start() end)
    utils.debugLog("created watcher for", deviceID)
end

local function ensure_watchers()
    for _, deviceID in ipairs(touchdevice.devices()) do
        pcall(function() create_watcher(deviceID) end)
    end
end

local function start_supervisor()
    hs.timer.doEvery(3, function()
        for id, entry in pairs(touch_watchers) do
            local ok, running = pcall(function() return entry.watcher and entry.watcher:isRunning() end)
            local age = 9999
            if entry.lastSeen then age = hs.timer.secondsSinceEpoch() - entry.lastSeen end
            if not ok or not running or age > 2 then
                utils.debugLog("supervisor: restarting watcher", id, "running=", tostring(running), "age=", age)
                pcall(function()
                    if entry.watcher then pcall(function() entry.watcher:stop() end) end
                    touch_watchers[id] = nil
                    create_watcher(id)
                end)
            end
        end
        pcall(ensure_watchers)
    end)
end

local function start_status_logger()
    hs.timer.doEvery(5, function()
        local running = 0
        for id, w in pairs(touch_watchers) do
            local ok, r = pcall(function() return w and w.watcher and w.watcher:isRunning() end)
            if ok and r then running = running + 1 end
        end
        utils.debugLog("status: watchers=", running, ", leftClickPressed=", tostring(leftClickPressed), ", mouseEventTap=", tostring(mouseEventTap ~= nil))
    end)
end

-- Swipe handling (Spoon). Try to load but don't hard-fail if problem.
local function start_swipe()
    local ok, sp = pcall(function() return hs.loadSpoon("Swipe") end)
    if not ok or not sp then
        utils.debugLog("gestures: Swipe spoon not available, swipe gestures disabled")
        return
    end
    Swipe3 = sp
    Swipe3:start(3, function(direction, distance, id)
        if id == current_id_3f then
            local threshold = (direction == "left" or direction == "right") and threshold_horizontal or threshold_vertical
            if distance > threshold then
                threshold_horizontal = math.huge
                threshold_vertical = math.huge
                if direction == "left" then
                    hs.eventtap.keyStroke({"ctrl", "shift"}, "tab")
                elseif direction == "right" then
                    hs.eventtap.keyStroke({"ctrl"}, "tab")
                elseif direction == "up" then
                    hs.eventtap.keyStroke({"cmd"}, "t")
                elseif direction == "down" then
                    hs.eventtap.keyStroke({"cmd"}, "w")
                end
            end
        else
            current_id_3f = id
            threshold_horizontal = HORIZONTAL_DEFAULT
            threshold_vertical = VERTICAL_DEFAULT
        end
    end)
    utils.debugLog("gestures: swipe started")
end

function M.start()
    ensure_watchers()
    start_supervisor()
    start_status_logger()
    start_swipe()
end

M.forceCleanup = forceCleanup
M.toggleSelection = toggleSelection
M.triggerLookup = triggerLookup
M.isLeftClickPressed = function() return leftClickPressed end

return M
