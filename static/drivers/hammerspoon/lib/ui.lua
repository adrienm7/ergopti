-- ui.lua
local M = {}
local vscode_bridge = require("lib.vscode_bridge")

local preview_canvas = hs.canvas.new({x = 0, y = 0, w = 0, h = 0})
preview_canvas:level(hs.canvas.windowLevels.cursor) 
preview_canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

preview_canvas:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = {white = 0.15, alpha = 0.90}, 
    roundedRectRadii = {xRadius = 6, yRadius = 6},
}, {
    type = "text",
    text = "",
})

local function getBestUIAnchor()
    if vscode_bridge and vscode_bridge.is_vscode() then
        local pos = vscode_bridge.estimate_position()
        if pos then return pos end
    end

    local success, pos = pcall(function()
        local ax = require("hs.axuielement")
        local focused = ax.systemWideElement():attributeValue("AXFocusedUIElement")
        if not focused then return nil end

        local range = focused:attributeValue("AXSelectedTextRange")
        if range then
            local bounds = focused:parameterizedAttributeValue("AXBoundsForRange", { location = range.location, length = 0 })
            if bounds and type(bounds) == "table" and bounds.x and bounds.y and bounds.h and bounds.h > 0 and bounds.h < 80 then
                return { x = bounds.x, y = bounds.y, h = bounds.h, type = "caret" }
            end
        end

        local line_num = focused:attributeValue("AXInsertionPointLineNumber")
        if line_num then
            local line_range = focused:parameterizedAttributeValue("AXRangeForLine", line_num)
            if line_range then
                local bounds = focused:parameterizedAttributeValue("AXBoundsForRange", line_range)
                if bounds and bounds.h and bounds.h > 0 and bounds.h < 80 then
                    return { x = bounds.x, y = bounds.y, h = bounds.h, type = "caret" }
                end
            end
        end

        local frame = focused:attributeValue("AXFrame")
        if frame and frame.x and frame.y and frame.w and frame.h then
            return { x = frame.x + frame.w / 2, y = frame.y + frame.h, h = 0, type = "input_box" }
        end
        return nil
    end)
    
    if success and pos then return pos end

    local win = hs.window.focusedWindow()
    if win then
        local wf = win:frame()
        return { x = wf.x + wf.w / 2, y = wf.y + wf.h - 40, h = 0, type = "window" }
    end

    return nil
end

function M.hide_preview()
    if preview_canvas then preview_canvas:hide() end
end

function M.show_custom_preview(display_text, is_llm, enabled)
    if not enabled then return end

    local styledText
    if type(display_text) == "userdata" then
        styledText = display_text
    else
        styledText = hs.styledtext.new(display_text, {
            font = {name = ".AppleSystemUIFont", size = 14, traits = is_llm and {italic=true} or {}},
            color = is_llm and {white = 0.7, alpha = 1.0} or {white = 1.0, alpha = 1.0}
        })
    end
    
    local size = preview_canvas:minimumTextSize(2, styledText)
    local padding_x, padding_y = 12, 6
    local w, h = size.w + (padding_x * 2), size.h + (padding_y * 2)

    local pos_x, pos_y
    local anchor = getBestUIAnchor()
    local fw = hs.window.focusedWindow()
    local screen = fw and fw:screen():frame() or hs.screen.mainScreen():frame()
    
    if anchor then
        if anchor.type == "caret" then
            pos_x, pos_y = anchor.x + 15, anchor.y + anchor.h + 18
        else
            pos_x, pos_y = anchor.x - (w / 2), anchor.y + 5
            if pos_y + h > screen.y + screen.h then pos_y = anchor.y - h - 5 end
        end
    else
        pos_x = screen.x + (screen.w / 2) - (w / 2)
        pos_y = screen.y + screen.h - h - 5 
    end

    -- Keep within screen bounds
    if pos_x + w > screen.x + screen.w then pos_x = screen.x + screen.w - w - 5 end
    if pos_x < screen.x then pos_x = screen.x + 5 end
    if pos_y + h > screen.y + screen.h then pos_y = screen.y + screen.h - h - 5 end

    pcall(function()
        preview_canvas:frame({ x = pos_x, y = pos_y, w = w, h = h })
        preview_canvas[2].frame = { x = padding_x, y = padding_y, w = size.w, h = size.h }
        preview_canvas[2].text = styledText
        preview_canvas:show()
    end)
end

return M
