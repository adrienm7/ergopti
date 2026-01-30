-- What this script does:
-- 1) Three-finger tap to toggle selection mode (click-and-drag)
-- 2) Three-finger gestures for tab navigation
-- 3) Change volume with left Option + scroll

local Swipe3 = hs.loadSpoon("Swipe")
local current_id_3f, threshold_horizontal, threshold_vertical
local HORIZONTAL_DEFAULT = 0.02 -- 2% of the trackpad width for left/right
local VERTICAL_DEFAULT = 0.08   -- 8% of the trackpad height for up/down

threshold_horizontal = HORIZONTAL_DEFAULT
threshold_vertical = VERTICAL_DEFAULT

-- Three-finger tap for selection toggle using touchdevice
local touchdevice = require("hs._asm.undocumented.touchdevice")
local leftClickPressed = false
local mouseEventTap = nil

-- Tap-detection state
local _touchStartTime = nil
local _tapStartPoint = nil
local _tapEndPoint = nil
local _maybeTap = false
local _tapDelta = 2.0 -- tolerance for movement to still consider a tap
local _lastDebugTime = 0

-- Keep references to touchdevice watchers to avoid garbage collection
local touch_watchers = {}

local function debugLog(...)
    local args = {...}
    for i=1,#args do args[i] = tostring(args[i]) end
    local msg = table.concat(args, " ")
    pcall(function()
        hs.console.printStyledtext("[tp] " .. os.date("%H:%M:%S") .. " " .. msg)
    end)
end

-- forceCleanup: stop mouseEventTap and reset state
local function forceCleanup()
    debugLog("forceCleanup: start mouseEventTap=", tostring(mouseEventTap), "leftClickPressed=", tostring(leftClickPressed))
    if mouseEventTap then
        debugLog("forceCleanup: stopping mouseEventTap")
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
    _maybeTap = false
end

-- toggleSelection: emulate left mouse down and start an eventtap to convert move->drag
local function toggleSelection()
    debugLog("toggleSelection: activating")
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
            -- For mouseMoved, do not swallow the event (return false)
            return false
        end)
    pcall(function() mouseEventTap:start() end)
    debugLog("toggleSelection: mouseEventTap started")
end

-- Create a touchdevice watcher for a deviceID
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

    local watcher = touchdevice.forDeviceID(deviceID):frameCallback(function(_, touches, _, _)
        local ok, err = pcall(function()
            local nFingers = #touches
            local now = hs.timer.secondsSinceEpoch()

            if touch_watchers[deviceID] then touch_watchers[deviceID].lastSeen = now end

            if nFingers == 0 then
                if _tapStartPoint and _tapEndPoint and _maybeTap then
                    local delta = math.abs(_tapStartPoint.x - _tapEndPoint.x) + math.abs(_tapStartPoint.y - _tapEndPoint.y)
                    if delta < _tapDelta then
                        debugLog("watcher:", deviceID, "detected 3-finger tap (delta=", delta, ") -> toggleSelection")
                        toggleSelection()
                    end
                end
                _touchStartTime = nil
                _tapStartPoint = nil
                _tapEndPoint = nil
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

            if nFingers == 3 then
                local xAvg = (touches[1].absoluteVector.position.x + touches[2].absoluteVector.position.x + touches[3].absoluteVector.position.x) / 3
                local yAvg = (touches[1].absoluteVector.position.y + touches[2].absoluteVector.position.y + touches[3].absoluteVector.position.y) / 3

                if _maybeTap and not _tapStartPoint then
                    _tapStartPoint = { x = xAvg, y = yAvg }
                    debugLog("watcher:", deviceID, "tap start at", xAvg, yAvg)
                end
                if _maybeTap then
                    _tapEndPoint = { x = xAvg, y = yAvg }
                    if (now - (_lastDebugTime or 0)) > 2 then
                        _lastDebugTime = now
                        debugLog("watcher:", deviceID, "tap update at", xAvg, yAvg)
                    end
                end
            elseif nFingers > 3 then
                _maybeTap = false
                _tapStartPoint = nil
                _tapEndPoint = nil
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
    debugLog("created watcher for", deviceID)
end

local function ensure_watchers()
    for _, deviceID in ipairs(touchdevice.devices()) do
        pcall(function() create_watcher(deviceID) end)
    end
end

-- Supervisor: restart watchers if they stop or if no frames seen recently
hs.timer.doEvery(3, function()
    for id, entry in pairs(touch_watchers) do
        local ok, running = pcall(function() return entry.watcher and entry.watcher:isRunning() end)
        local age = 9999
        if entry.lastSeen then age = hs.timer.secondsSinceEpoch() - entry.lastSeen end
        if not ok or not running or age > 2 then
            debugLog("supervisor: restarting watcher", id, "running=", tostring(running), "age=", age)
            pcall(function()
                if entry.watcher then pcall(function() entry.watcher:stop() end) end
                touch_watchers[id] = nil
                create_watcher(id)
            end)
        end
    end
    pcall(ensure_watchers)
end)

-- Periodic status logger
hs.timer.doEvery(5, function()
    local running = 0
    for id, w in pairs(touch_watchers) do
        local ok, r = pcall(function() return w and w.watcher and w.watcher:isRunning() end)
        if ok and r then running = running + 1 end
    end
    debugLog("status: watchers=", running, ", leftClickPressed=", tostring(leftClickPressed), ", mouseEventTap=", tostring(mouseEventTap ~= nil))
end)

-- Start watchers at load
ensure_watchers()

-- Three-finger swipe handling (Spoon)
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

-- Physical left Option forwarded by Karabiner as F19
local leftOptionPhysical = false
local f19_keycode = hs.keycodes.map["f19"] or 80

local physicalOptionTap = hs.eventtap.new({hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp}, function(event)
    local kc = event:getKeyCode()
    if kc == f19_keycode then
        if event:getType() == hs.eventtap.event.types.keyDown then
            if leftClickPressed then forceCleanup() end
            leftOptionPhysical = true
        else
            leftOptionPhysical = false
        end
    end
    return false
end):start()

-- Scroll handler: with cmd -> zoom, with leftOptionPhysical -> volume
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

    if leftOptionPhysical then
        if leftClickPressed then forceCleanup() end
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
end):start()
