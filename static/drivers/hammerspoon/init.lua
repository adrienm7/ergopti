
-- Three-finger gestures for tab navigation
local Swipe3 = hs.loadSpoon("Swipe")
local current_id_3f, threshold_horizontal, threshold_vertical
local HORIZONTAL_DEFAULT = 0.02 -- 2% for left/right
local VERTICAL_DEFAULT = 0.07   -- 7% for up/down

threshold_horizontal = HORIZONTAL_DEFAULT
threshold_vertical = VERTICAL_DEFAULT

-- Three-finger tap for selection toggle using touchdevice
local touchdevice = require("hs._asm.undocumented.touchdevice")
local leftClickPressed = false
local mouseEventTap = nil

-- Function to force cleanup of selection state
local function forceCleanup()
	if mouseEventTap then
		pcall(function() mouseEventTap:stop() end)
		mouseEventTap = nil
	end
	leftClickPressed = false
end

-- Timer to periodically check and cleanup stuck state
hs.timer.doEvery(5, function()
	if leftClickPressed and not mouseEventTap then
		-- State is inconsistent, force cleanup
		forceCleanup()
	end
end)

-- Function to toggle selection mode
local function toggleSelection()
	-- Force cleanup first to ensure clean state
	forceCleanup()
	
	local pos = hs.mouse.absolutePosition()
	
	-- hs.alert.show("🖱️ TAP DÉTECTÉ - Sélection ACTIVÉE", 1)

	-- Activate selection mode
	leftClickPressed = true
	
	-- Post initial mouseDown event
	hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, pos):post()
	
	-- Create eventtap to intercept mouse events
	mouseEventTap = hs.eventtap.new({
		hs.eventtap.event.types.mouseMoved,
		hs.eventtap.event.types.leftMouseDragged,
		hs.eventtap.event.types.leftMouseUp
	}, function(event)
		local eventType = event:getType()
		
		-- Convert mouseMoved to leftMouseDragged while selection is active
		if eventType == hs.eventtap.event.types.mouseMoved then
			local newPos = event:location()
			local dragEvent = hs.eventtap.event.newMouseEvent(
				hs.eventtap.event.types.leftMouseDragged,
				newPos
			)
			dragEvent:post()
			return true -- Delete original mouseMoved event
		end
		
		-- If real leftMouseUp is detected, deactivate selection mode
		if eventType == hs.eventtap.event.types.leftMouseUp then
			-- hs.alert.show("🖱️ Sélection DÉSACTIVÉE", 0.5)
			forceCleanup()
			return false -- Let the mouseUp event propagate
		end
		
		return false -- Let other events propagate
	end):start()
end

-- Setup touch device watchers for 3-finger tap detection
local _touchStartTime = nil
local _tapStartPoint = nil
local _tapEndPoint = nil
local _maybeTap = false
local _tapDelta = 2.0
local _lastDebugTime = 0

for _, deviceID in ipairs(touchdevice.devices()) do
    touchdevice.forDeviceID(deviceID):frameCallback(function(_, touches, _, _)
        local nFingers = #touches
        local now = hs.timer.secondsSinceEpoch()

        if nFingers == 0 then
            -- Fingers lifted - check if it was a tap
            if _tapStartPoint and _tapEndPoint then
                local delta = math.abs(_tapStartPoint.x - _tapEndPoint.x) +
                              math.abs(_tapStartPoint.y - _tapEndPoint.y)
                if _maybeTap and delta < _tapDelta then
                    toggleSelection()
                end
            end
            _touchStartTime = nil
            _tapStartPoint = nil
            _tapEndPoint = nil
            _maybeTap = false
        elseif nFingers > 0 and not _touchStartTime then
            _touchStartTime = now
            _maybeTap = true
        elseif _touchStartTime and _maybeTap and (now - _touchStartTime > 0.5) then
            -- Too long to be a tap
            _maybeTap = false
            _tapStartPoint = nil
            _tapEndPoint = nil
        end

        if nFingers == 3 then
            local xAvg = (touches[1].absoluteVector.position.x +
                         touches[2].absoluteVector.position.x +
                         touches[3].absoluteVector.position.x) / 3
            local yAvg = (touches[1].absoluteVector.position.y +
                         touches[2].absoluteVector.position.y +
                         touches[3].absoluteVector.position.y) / 3

            if _maybeTap and not _tapStartPoint then
                _tapStartPoint = { x = xAvg, y = yAvg }
            end
            if _maybeTap then
                _tapEndPoint = { x = xAvg, y = yAvg }
            end
        elseif nFingers > 3 then
            -- More than 3 fingers - cancel tap detection
            _maybeTap = false
            _tapStartPoint = nil
            _tapEndPoint = nil
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

-- Cmd + Scroll for zoom/dezoom
local scrollZoom = hs.eventtap.new({hs.eventtap.event.types.scrollWheel}, function(event)
    local flags = event:getFlags()
    
    -- Check if cmd key is pressed
    if flags.cmd then
        local scrollY = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
        
        if scrollY > 0 then
            -- Scroll up = zoom in
            hs.eventtap.keyStroke({"cmd"}, "pad+", 0)
        elseif scrollY < 0 then
            -- Scroll down = zoom out
            hs.eventtap.keyStroke({"cmd"}, "pad-", 0)
        end
        
        return true -- Consume the event
    end
    
    return false -- Let the event through
end):start()
