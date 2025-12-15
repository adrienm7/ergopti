
-- Three-finger gestures for tab navigation
local Swipe3 = hs.loadSpoon("Swipe")
local current_id_3f, threshold_horizontal, threshold_vertical
local HORIZONTAL_DEFAULT = 0.02 -- 2% for left/right
local VERTICAL_DEFAULT = 0.07   -- 7% for up/down

threshold_horizontal = HORIZONTAL_DEFAULT
threshold_vertical = VERTICAL_DEFAULT

-- Three-finger tap for selection toggle using touchdevice
local touchdevice = require("hs._asm.undocumented.touchdevice")
local rightClickPressed = false

-- Function to toggle selection mode
local function toggleSelection()
    local pos = hs.mouse.absolutePosition()
    local currentButtons = hs.eventtap.checkMouseButtons()
    local isButtonDown = currentButtons and currentButtons.left
    
    -- Sync state with actual mouse state
    if isButtonDown and not rightClickPressed then
        rightClickPressed = true
        return
    elseif not isButtonDown and rightClickPressed then
        rightClickPressed = false
    end
    
    -- Toggle
    if not rightClickPressed then
        rightClickPressed = true
        hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, pos):post()
        hs.alert.show("🖱️ Sélection ACTIVÉE", 1)
    else
        hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pos):post()
        rightClickPressed = false
        hs.alert.show("🖱️ Sélection DÉSACTIVÉE", 1)
    end
end

-- Setup touch device watchers for 3-finger tap detection
local _fingers = 3
local _touchStartTime = nil
local _middleclickPoint = nil
local _middleclickPoint2 = nil
local _maybeMiddleClick = false
local _tapDelta = 2.0

for _, deviceID in ipairs(touchdevice.devices()) do
    touchdevice.forDeviceID(deviceID):frameCallback(function(_, touches, _, _)
        local nFingers = #touches

        if nFingers == 0 then
            if _middleclickPoint and _middleclickPoint2 then
                local delta = math.abs(_middleclickPoint.x - _middleclickPoint2.x) +
                              math.abs(_middleclickPoint.y - _middleclickPoint2.y)
                if delta < _tapDelta then
                    toggleSelection()
                end
            end
            _touchStartTime = nil
            _middleclickPoint = nil
            _middleclickPoint2 = nil
        elseif nFingers > 0 and not _touchStartTime then
            _touchStartTime = hs.timer.secondsSinceEpoch()
            _maybeMiddleClick = true
        elseif _maybeMiddleClick and (hs.timer.secondsSinceEpoch() - _touchStartTime > 0.5) then
            _maybeMiddleClick = false
            _middleclickPoint = nil
            _middleclickPoint2 = nil
        end

        if nFingers > _fingers then
            _maybeMiddleClick = false
            _middleclickPoint = nil
            _middleclickPoint2 = nil
        elseif nFingers == _fingers then
            local xAvg = (touches[1].absoluteVector.position.x +
                         touches[2].absoluteVector.position.x +
                         touches[3].absoluteVector.position.x) / 3
            local yAvg = (touches[1].absoluteVector.position.y +
                         touches[2].absoluteVector.position.y +
                         touches[3].absoluteVector.position.y) / 3

            if _maybeMiddleClick then
                _middleclickPoint = { x = xAvg, y = yAvg }
                _middleclickPoint2 = { x = xAvg, y = yAvg }
                _maybeMiddleClick = false
            else
                _middleclickPoint2 = { x = xAvg, y = yAvg }
            end
        end
    end):start()
end

Swipe3:start(3, function(direction, distance, id)
    if id == current_id_3f then
        local threshold = (direction == "left" or direction == "right") and threshold_horizontal or threshold_vertical
        if distance > threshold then
             -- To only trigger once per swipe
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
