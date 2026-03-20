-- ui/tooltip.lua
-- Floating tooltip rendered near the text caret.
-- Public API:  tooltip.show(content, is_llm, enabled)
--              tooltip.hide()

local M = {}

local ok_bridge, vscode_bridge = pcall(require, "lib.vscode_bridge")
if not ok_bridge then vscode_bridge = nil end

-- =====================================
-- =====================================
-- =====================================
-- ========== 1. CANVAS SETUP ==========
-- =====================================
-- =====================================
-- =====================================

local canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
canvas:level(hs.canvas.windowLevels.cursor)
canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
canvas:appendElements(
    {   -- [1] Background rounded rectangle
        type             = "rectangle",
        action           = "fill",
        fillColor        = { white = 0.15, alpha = 0.90 },
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
    },
    {   -- [2] Text layer
        type = "text",
        text = "",
    }
)

-- =========================================
-- =========================================
-- =========================================
-- ========== 2. ANCHOR DETECTION ==========
-- =========================================
-- =========================================
-- =========================================

-- Priority: VSCode bridge → AX caret → AX line → AX frame → window fallback.
---@return table|nil  { x, y, h, type } or nil
local function resolve_anchor()
    -- =================================
-- ======= 2.1 VSCode Bridge =======
-- =================================
    if vscode_bridge and vscode_bridge.is_vscode() then
        local ok, pos = pcall(vscode_bridge.estimate_position)
        if ok and pos then return pos end
    end

-- ===========================================
-- ======= 2.2 macOS Accessibility API =======
-- ===========================================
    local ax_ok, pos = pcall(function()
        local ax      = require("hs.axuielement")
        local focused = ax.systemWideElement():attributeValue("AXFocusedUIElement")
        if not focused then return nil end

        local range = focused:attributeValue("AXSelectedTextRange")
        if range then
            local b = focused:parameterizedAttributeValue(
                "AXBoundsForRange", { location = range.location, length = 0 })
            if b and type(b) == "table"
                and b.x and b.y and b.h and b.h > 0 and b.h < 80 then
                return { x = b.x, y = b.y, h = b.h, type = "caret" }
            end
        end

        local ln = focused:attributeValue("AXInsertionPointLineNumber")
        if ln then
            local lr = focused:parameterizedAttributeValue("AXRangeForLine", ln)
            if lr then
                local b = focused:parameterizedAttributeValue("AXBoundsForRange", lr)
                if b and b.h and b.h > 0 and b.h < 80 then
                    return { x = b.x, y = b.y, h = b.h, type = "caret" }
                end
            end
        end

        local f = focused:attributeValue("AXFrame")
        if f and f.x and f.y and f.w and f.h then
            return { x = f.x + f.w / 2, y = f.y + f.h, h = 0, type = "input_box" }
        end
        return nil
    end)

    if ax_ok and pos then return pos end

-- ===================================
-- ======= 2.3 Window Fallback =======
-- ===================================
    local win = hs.window.focusedWindow()
    if win then
        local f = win:frame()
        return { x = f.x + f.w / 2, y = f.y + f.h - 40, h = 0, type = "window" }
    end
    return nil
end

-- ===================================
-- ===================================
-- ===================================
-- ========== 3. PUBLIC API ==========
-- ===================================
-- ===================================
-- ===================================

--- Hide the tooltip immediately.
function M.hide()
    canvas:hide()
end

--- Display the tooltip near the current text cursor.
---@param content  string|userdata
---@param is_llm   boolean
---@param enabled  boolean
function M.show(content, is_llm, enabled)
    if not enabled then return end
    if content == nil or content == "" then M.hide(); return end

    -- ===== 3.1 Styled Text =====
    local styled
    if type(content) == "userdata" then
        styled = content
    else
        styled = hs.styledtext.new(tostring(content), {
            font  = { name = ".AppleSystemUIFont", size = 14,
                      traits = is_llm and { italic = true } or {} },
            color = is_llm and { white = 0.7, alpha = 1.0 }
                           or  { white = 1.0, alpha = 1.0 },
        })
    end

    -- ===== 3.2 Size & Position =====
    local sz           = canvas:minimumTextSize(2, styled)
    local pad_x, pad_y = 12, 6
    local w            = sz.w + pad_x * 2
    local h_           = sz.h + pad_y * 2

    local anchor = resolve_anchor()
    local fw     = hs.window.focusedWindow()
    local screen = (fw and fw:screen() or hs.screen.mainScreen()):frame()

    local px, py
    if anchor then
        if anchor.type == "caret" then
            px = anchor.x + 15
            py = anchor.y + anchor.h + 18
        else
            px = anchor.x - w / 2
            py = anchor.y + 5
            if py + h_ > screen.y + screen.h then py = anchor.y - h_ - 5 end
        end
    else
        px = screen.x + (screen.w - w) / 2
        py = screen.y + screen.h - h_ - 5
    end

    local margin = 5
    px = math.max(screen.x + margin, math.min(px, screen.x + screen.w - w  - margin))
    py = math.max(screen.y + margin, math.min(py, screen.y + screen.h - h_ - margin))

    -- ===== 3.3 Render =====
    local ok, err = pcall(function()
        canvas:frame({ x = px, y = py, w = w, h = h_ })
        canvas[2].frame = { x = pad_x, y = pad_y, w = sz.w, h = sz.h }
        canvas[2].text  = styled
        canvas:show()
    end)
    if not ok then
        hs.printf("[ui/tooltip] render error: %s", tostring(err))
    end
end

return M
