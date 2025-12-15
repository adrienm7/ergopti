
-- Three-finger gestures for tab navigation
local Swipe3 = hs.loadSpoon("Swipe")
local current_id_3f, threshold_horizontal, threshold_vertical
local HORIZONTAL_DEFAULT = 0.02 -- 2% for left/right
local VERTICAL_DEFAULT = 0.05   -- 5% for up/down

threshold_horizontal = HORIZONTAL_DEFAULT
threshold_vertical = VERTICAL_DEFAULT

-- Three-finger tap for selection toggle using touchdevice
local touchdevice = require("hs._asm.undocumented.touchdevice")
local rightClickPressed = false

-- Function to toggle selection mode
local function toggleSelection()
    local pos = hs.mouse.absolutePosition()
    
    -- Check current mouse button state using hs.eventtap
    local currentButtons = hs.eventtap.checkMouseButtons()
    local isButtonDown = currentButtons and currentButtons.left
    
    -- Sync our state with actual mouse state
    if isButtonDown and not rightClickPressed then
        -- Mouse is already down but we don't know about it
        rightClickPressed = true
        return
    elseif not isButtonDown and rightClickPressed then
        -- Mouse is up but we think it's down
        rightClickPressed = false
    end
    
    -- Now do the toggle
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
local _attachedDeviceCallbacks = {}
local _touchStartTime = nil
local _middleclickPoint = nil
local _middleclickPoint2 = nil
local _maybeMiddleClick = false
local _tapDelta = 2.0 -- threshold for tap detection (maximum tolerance)

-- Debug: check detected devices
local devices = touchdevice.devices()
hs.alert.show("Détecté " .. #devices .. " devices", 2)
print("Touchdevice detected devices:", hs.inspect(devices))

for _, v in ipairs(devices) do
    print("Setting up callback for device:", v)
    table.insert(
        _attachedDeviceCallbacks,
        touchdevice.forDeviceID(v):frameCallback(function(_, touches, _, _)
            local nFingers = #touches
            
            -- Debug: afficher le nombre de doigts détectés
            if nFingers >= 3 then
                print("DEBUG: " .. nFingers .. " doigts détectés")
            end

            if nFingers == 0 then
                if _middleclickPoint and _middleclickPoint2 then
                    local delta = math.abs(_middleclickPoint.x - _middleclickPoint2.x) +
                                  math.abs(_middleclickPoint.y - _middleclickPoint2.y)
                    print("DEBUG: Delta calculé = " .. delta .. " (seuil = " .. _tapDelta .. ")")
                    if delta < _tapDelta then
                        hs.alert.show("👆 TAP 3 doigts détecté!", 1)
                        toggleSelection()
                    else
                        print("DEBUG: Delta trop grand, pas un tap")
                    end
                end
                _touchStartTime    = nil
                _middleclickPoint  = nil
                _middleclickPoint2 = nil
            elseif nFingers > 0 and not _touchStartTime then
                _touchStartTime   = hs.timer.secondsSinceEpoch()
                _maybeMiddleClick = true
                _middleclickPoint = { x = 0, y = 0 }
            elseif _maybeMiddleClick then
                local elapsedTime = hs.timer.secondsSinceEpoch() - _touchStartTime
                if elapsedTime > .5 then
                    _maybeMiddleClick  = false
                    _middleclickPoint  = nil
                    _middleclickPoint2 = nil
                end
            end

            if nFingers > _fingers then
                _maybeMiddleClick  = false
                _middleclickPoint  = nil
                _middleclickPoint2 = nil
            elseif nFingers == _fingers then
                -- Calculate average position of 3 fingers (normalized 0-1 coordinates)
                local xAggregate = (touches[1].absoluteVector.position.x +
                                   touches[2].absoluteVector.position.x +
                                   touches[3].absoluteVector.position.x) / 3
                local yAggregate = (touches[1].absoluteVector.position.y +
                                   touches[2].absoluteVector.position.y +
                                   touches[3].absoluteVector.position.y) / 3

                if _maybeMiddleClick then
                    _middleclickPoint  = { x = xAggregate, y = yAggregate }
                    _middleclickPoint2 = { x = xAggregate, y = yAggregate }
                    _maybeMiddleClick  = false
                    print("DEBUG: Position initiale enregistrée: x=" .. xAggregate .. ", y=" .. yAggregate)
                else
                    _middleclickPoint2 = { x = xAggregate, y = yAggregate }
                end
            end
        end):start()
    )
end

hs.alert.show("Hammerspoon chargé - Tap 3 doigts activé", 1)

-- Hotkey: Ctrl+Option+Cmd+T to toggle selection (backup method)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "T", toggleSelection)

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
