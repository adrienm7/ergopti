
-- Three-finger gestures for tab navigation

local Swipe3 = hs.loadSpoon("Swipe")
local current_id_3f, threshold_horizontal, threshold_vertical
local HORIZONTAL_DEFAULT = 0.02 -- 2% for left/right
local VERTICAL_DEFAULT = 0.05   -- 5% for up/down

threshold_horizontal = HORIZONTAL_DEFAULT
threshold_vertical = VERTICAL_DEFAULT
Swipe3:start(3, function(direction, distance, id)
    if id == current_id_3f then
        local threshold = (direction == "left" or direction == "right") and threshold_horizontal or threshold_vertical
        if distance > threshold then
             -- To only trigger once per swipe
            threshold_horizontal = math.huge
            threshold_vertical = math.huge
            if direction == "left" then
                -- hs.notify.show("Swipe", "Gesture detected", "Previous tab (Ctrl+Shift+Tab)")
                hs.eventtap.keyStroke({"ctrl", "shift"}, "tab")
            elseif direction == "right" then
                -- hs.notify.show("Swipe", "Gesture detected", "Next tab (Ctrl+Tab)")
                hs.eventtap.keyStroke({"ctrl"}, "tab")
            elseif direction == "up" then
                -- hs.notify.show("Swipe", "Gesture detected", "New tab (Cmd+T)")
                hs.eventtap.keyStroke({"cmd"}, "t")
            elseif direction == "down" then
                -- hs.notify.show("Swipe", "Gesture detected", "Close tab (Cmd+W)")
                hs.eventtap.keyStroke({"cmd"}, "w")
            end
        end
    else
        current_id_3f = id
        threshold_horizontal = HORIZONTAL_DEFAULT
        threshold_vertical = VERTICAL_DEFAULT
    end
end)
