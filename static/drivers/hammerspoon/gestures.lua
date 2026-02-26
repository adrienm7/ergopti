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
local Swipe4 = nil
local current_id_4f, threshold_horizontal_4
local Swipe5 = nil
local current_id_5f, threshold_horizontal_5
local HORIZONTAL_DEFAULT = 0.04
local VERTICAL_DEFAULT = 0.12

threshold_horizontal = HORIZONTAL_DEFAULT
threshold_vertical = VERTICAL_DEFAULT
threshold_horizontal_4 = HORIZONTAL_DEFAULT
threshold_horizontal_5 = HORIZONTAL_DEFAULT

-- Feature flags for gestures (can be toggled at runtime)
local feature_flags = {
    tap_selection = true,
    tap_lookup = true,
    -- split swipe into four directions
    swipe_left = true,
    swipe_right = true,
    swipe_up = true,
    swipe_down = true,
    -- 4-finger swipes: switch windows within the same app (left/right)
    swipe4_left = true,
    swipe4_right = true,
    -- 5-finger swipes: switch windows within the same app (left/right)
    swipe5_left = true,
    swipe5_right = true,
}

local function perform_swipe4(direction)
    if direction == "left" then
        if feature_flags.swipe4_left then
            pcall(function() hs.alert.show("Geste 4 doigts : gauche (Bureau précédent)", 1.0) end)
            utils.debugLog("gestures: perform_swipe4 left -> send Ctrl+Left")
            -- try high-level keyStroke first
            local ok = pcall(function() hs.eventtap.keyStroke({"ctrl"}, "left", 0) end)
            if not ok then
                -- fallback to low-level key events
                pcall(function()
                    local kc = hs.keycodes.map["left"]
                    hs.eventtap.event.newKeyEvent({"ctrl"}, kc, true):post()
                    hs.timer.usleep(10000)
                    hs.eventtap.event.newKeyEvent({"ctrl"}, kc, false):post()
                end)
            end
        end
    elseif direction == "right" then
        if feature_flags.swipe4_right then
            pcall(function() hs.alert.show("Geste 4 doigts : droite (Bureau suivant)", 1.0) end)
            utils.debugLog("gestures: perform_swipe4 right -> send Ctrl+Right")
            local ok = pcall(function() hs.eventtap.keyStroke({"ctrl"}, "right", 0) end)
            if not ok then
                pcall(function()
                    local kc = hs.keycodes.map["right"]
                    hs.eventtap.event.newKeyEvent({"ctrl"}, kc, true):post()
                    hs.timer.usleep(10000)
                    hs.eventtap.event.newKeyEvent({"ctrl"}, kc, false):post()
                end)
            end
        end
    end
end

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
                                if feature_flags.tap_selection then toggleSelection() end
                            elseif _tapFingerCount == 4 then
                                utils.debugLog("watcher:", deviceID, "detected 4-finger tap (delta=", delta, ") -> triggerLookup")
                                if feature_flags.tap_lookup then triggerLookup() end
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
                -- Fallback: detect horizontal 4-finger swipes via touch frames
                if nFingers == 4 then
                    local prev = touch_watchers[deviceID].swipe4_prev or {x = xAvg, t = 0}
                    local dx = xAvg - prev.x
                    local elapsed = now - (touch_watchers[deviceID].swipe4_last or 0)
                    if math.abs(dx) > threshold_horizontal_4 and elapsed > 0.4 then
                        local dir = dx < 0 and "left" or "right"
                        utils.debugLog("watcher:", deviceID, "detected fallback 4-finger swipe", dir, "dx=", dx)
                        perform_swipe4(dir)
                        touch_watchers[deviceID].swipe4_last = now
                    end
                    touch_watchers[deviceID].swipe4_prev = { x = xAvg, t = now }
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
    Swipe4 = sp
    Swipe5 = sp
    -- 3-finger swipe handler (existing behaviour)
    Swipe3:start(3, function(direction, distance, id)
        if id == current_id_3f then
            local threshold = (direction == "left" or direction == "right") and threshold_horizontal or threshold_vertical
            if distance > threshold then
                threshold_horizontal = math.huge
                threshold_vertical = math.huge
                if direction == "left" then
                    if feature_flags.swipe_left then
                        hs.eventtap.keyStroke({"ctrl", "shift"}, "tab")
                    end
                elseif direction == "right" then
                    if feature_flags.swipe_right then
                        hs.eventtap.keyStroke({"ctrl"}, "tab")
                    end
                elseif direction == "up" then
                    if feature_flags.swipe_up then
                        hs.eventtap.keyStroke({"cmd"}, "t")
                    end
                elseif direction == "down" then
                    if feature_flags.swipe_down then
                        hs.eventtap.keyStroke({"cmd"}, "w")
                    end
                end
            end
        else
            current_id_3f = id
            threshold_horizontal = HORIZONTAL_DEFAULT
            threshold_vertical = VERTICAL_DEFAULT
        end
    end)
    -- 4-finger swipe handler: switch windows of the same frontmost application (left/right)
    Swipe4:start(4, function(direction, distance, id)
        if id == current_id_4f then
            local threshold = (direction == "left" or direction == "right") and threshold_horizontal_4 or math.huge
            if distance > threshold then
                threshold_horizontal_4 = math.huge
                if direction == "left" then
                    perform_swipe4("left")
                elseif direction == "right" then
                    perform_swipe4("right")
                end
            end
        else
            current_id_4f = id
            threshold_horizontal_4 = HORIZONTAL_DEFAULT
        end
    end)
    -- 5-finger swipe handler: switch windows of the same frontmost application (left/right)
    Swipe5:start(5, function(direction, distance, id)
        if id == current_id_5f then
            local threshold = (direction == "left" or direction == "right") and threshold_horizontal_5 or math.huge
            if distance > threshold then
                threshold_horizontal_5 = math.huge
                if direction == "left" then
                    if feature_flags.swipe5_left then
                        pcall(function() hs.alert.show("Geste 5 doigts : gauche", 1.0) end)
                        utils.debugLog("gestures: detected 5-finger swipe left - focus previous window in app")
                        -- switch to previous window of the same app
                        local app = hs.application.frontmostApplication()
                        if app then
                            local wins = {}
                            for _, w in ipairs(app:allWindows()) do
                                if w:isStandard() and w:isVisible() then table.insert(wins, w) end
                            end
                            if #wins > 1 then
                                local front = hs.window.frontmostWindow()
                                local idx = 1
                                for i, w in ipairs(wins) do if front and w:id() == front:id() then idx = i; break end end
                                local nextIdx = idx - 1
                                if nextIdx < 1 then nextIdx = #wins end
                                local target = wins[nextIdx]
                                if target then target:focus() end
                            end
                        end
                    end
                elseif direction == "right" then
                    if feature_flags.swipe5_right then
                        pcall(function() hs.alert.show("Geste 5 doigts : droite", 1.0) end)
                        utils.debugLog("gestures: detected 5-finger swipe right - focus next window in app")
                        -- switch to next window of the same app
                        local app = hs.application.frontmostApplication()
                        if app then
                            local wins = {}
                            for _, w in ipairs(app:allWindows()) do
                                if w:isStandard() and w:isVisible() then table.insert(wins, w) end
                            end
                            if #wins > 1 then
                                local front = hs.window.frontmostWindow()
                                local idx = 1
                                for i, w in ipairs(wins) do if front and w:id() == front:id() then idx = i; break end end
                                local nextIdx = idx + 1
                                if nextIdx > #wins then nextIdx = 1 end
                                local target = wins[nextIdx]
                                if target then target:focus() end
                            end
                        end
                    end
                end
            end
        else
            current_id_5f = id
            threshold_horizontal_5 = HORIZONTAL_DEFAULT
        end
    end)
    utils.debugLog("gestures: swipe started")
end

local function stop_swipe()
    if Swipe3 and Swipe3.stop then
        pcall(function() Swipe3:stop() end)
    end
    Swipe3 = nil
    if Swipe4 and Swipe4.stop then
        pcall(function() Swipe4:stop() end)
    end
    Swipe4 = nil
    if Swipe5 and Swipe5.stop then
        pcall(function() Swipe5:stop() end)
    end
    Swipe5 = nil
    utils.debugLog("gestures: swipe stopped")
end

function M.start()
    ensure_watchers()
    start_supervisor()
    start_status_logger()
    if feature_flags.swipe_left or feature_flags.swipe_right or feature_flags.swipe_up or feature_flags.swipe_down or feature_flags.swipe4_left or feature_flags.swipe4_right or feature_flags.swipe5_left or feature_flags.swipe5_right then
        start_swipe()
    end
end

-- Enable a specific gesture feature at runtime
function M.enable(name)
    if name == "all" then
        feature_flags.tap_selection = true
        feature_flags.tap_lookup = true
        feature_flags.swipe_left = true
        feature_flags.swipe_right = true
        feature_flags.swipe_up = true
        feature_flags.swipe_down = true
        feature_flags.swipe4_left = true
        feature_flags.swipe4_right = true
        feature_flags.swipe5_left = true
        feature_flags.swipe5_right = true
        start_swipe()
        return
    end

    if name == "swipe" then
        feature_flags.swipe_left = true
        feature_flags.swipe_right = true
        feature_flags.swipe_up = true
        feature_flags.swipe_down = true
        start_swipe()
        return
    end

    if name == "swipe5" then
        feature_flags.swipe5_left = true
        feature_flags.swipe5_right = true
        start_swipe()
        return
    end
    if name == "swipe4" then
        feature_flags.swipe4_left = true
        feature_flags.swipe4_right = true
        start_swipe()
        return
    end
    if name == "swipe_left" or name == "swipe_right" or name == "swipe_up" or name == "swipe_down" or name == "swipe4_left" or name == "swipe4_right" or name == "swipe5_left" or name == "swipe5_right" then
        feature_flags[name] = true
        -- ensure swipe subsystem is running
        if not Swipe3 then start_swipe() end
        return
    end

    if name == "tap_selection" then
        feature_flags.tap_selection = true
    elseif name == "tap_lookup" then
        feature_flags.tap_lookup = true
    end
end

-- Disable a specific gesture feature at runtime
function M.disable(name)
    if name == "all" then
        feature_flags.tap_selection = false
        feature_flags.tap_lookup = false
        feature_flags.swipe_left = false
        feature_flags.swipe_right = false
        feature_flags.swipe_up = false
        feature_flags.swipe_down = false
        feature_flags.swipe4_left = false
        feature_flags.swipe4_right = false
        feature_flags.swipe5_left = false
        feature_flags.swipe5_right = false
        stop_swipe()
        return
    end

    if name == "swipe" then
        feature_flags.swipe_left = false
        feature_flags.swipe_right = false
        feature_flags.swipe_up = false
        feature_flags.swipe_down = false
        stop_swipe()
        return
    end

    if name == "swipe5" then
        feature_flags.swipe5_left = false
        feature_flags.swipe5_right = false
        stop_swipe()
        return
    end

    if name == "swipe4" then
        feature_flags.swipe4_left = false
        feature_flags.swipe4_right = false
        stop_swipe()
        return
    end

    if name == "swipe_left" or name == "swipe_right" or name == "swipe_up" or name == "swipe_down" or name == "swipe4_left" or name == "swipe4_right" or name == "swipe5_left" or name == "swipe5_right" then
        feature_flags[name] = false
        -- if no swipe directions left enabled, stop the swipe subsystem
        if not (feature_flags.swipe_left or feature_flags.swipe_right or feature_flags.swipe_up or feature_flags.swipe_down or feature_flags.swipe4_left or feature_flags.swipe4_right or feature_flags.swipe5_left or feature_flags.swipe5_right) then
            stop_swipe()
        end
        return
    end

    if name == "tap_selection" then
        feature_flags.tap_selection = false
    elseif name == "tap_lookup" then
        feature_flags.tap_lookup = false
    end
end

function M.is_enabled(name)
    return feature_flags[name] == true
end

M.forceCleanup = forceCleanup
M.toggleSelection = toggleSelection
M.triggerLookup = triggerLookup
M.isLeftClickPressed = function() return leftClickPressed end

return M
