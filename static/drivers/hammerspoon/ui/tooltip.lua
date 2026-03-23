-- ui/tooltip.lua
local M = {}

local ok_bridge, vscode_bridge = pcall(require, "lib.vscode_bridge")
if not ok_bridge then vscode_bridge = nil end

-- ─────────────────────────────────────────────────────────
-- 1. CANVAS
-- ─────────────────────────────────────────────────────────
local canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
canvas:level(hs.canvas.windowLevels.cursor)
canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
canvas:appendElements(
    { type = "rectangle", action = "fill",
      fillColor = { white = 0.10, alpha = 0.97 },
      roundedRectRadii = { xRadius = 7, yRadius = 7 } },
    { type = "text", text = "" }
)

-- ─────────────────────────────────────────────────────────
-- 2. ÉTAT
-- ─────────────────────────────────────────────────────────
local _state = {
    raw_predictions = {},
    current_index   = 1,
    on_navigate     = nil,
    model_name      = nil,
    indent          = 0,
}

-- ─────────────────────────────────────────────────────────
-- 3. ANCHOR
-- ─────────────────────────────────────────────────────────
local function resolve_anchor()
    if vscode_bridge and vscode_bridge.is_vscode() then
        local ok, pos = pcall(vscode_bridge.estimate_position)
        if ok and pos then return pos end
    end
    local ax_ok, pos = pcall(function()
        local ax      = require("hs.axuielement")
        local focused = ax.systemWideElement():attributeValue("AXFocusedUIElement")
        if not focused then return nil end
        local range = focused:attributeValue("AXSelectedTextRange")
        if range then
            local b = focused:parameterizedAttributeValue(
                "AXBoundsForRange", { location = range.location, length = 0 })
            if b and type(b) == "table" and b.x and b.y and b.h and b.h > 0 and b.h < 80 then
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

    local win = hs.window.focusedWindow()
    if win then
        local ok, f = pcall(function() return win:frame() end)
        if ok and f then
            return { x = f.x + f.w / 2, y = f.y + f.h - 40, h = 0, type = "window" }
        end
    end
    return nil
end

-- ─────────────────────────────────────────────────────────
-- 4. COULEURS & POLICES
-- ─────────────────────────────────────────────────────────
local FONT      = ".AppleSystemUIFont"
local FONT_BOLD = ".AppleSystemUIFontBold"
local SIZE_MAIN = 14
local SIZE_HINT = 11

local C_BG       = { white = 0.10, alpha = 1.0 }

local C_CORR_SEL = { red = 0.25, green = 0.90, blue = 0.40, alpha = 1.0 }
local C_UNCH_SEL = { white = 0.60, alpha = 1.0 }
local C_NW_SEL   = { red = 1.00, green = 0.62, blue = 0.10, alpha = 1.0 }

local C_UNSELECTED_GRAY = { white = 0.50, alpha = 1.0 }

local C_CURSOR   = { red = 0.98, green = 0.88, blue = 0.22, alpha = 1.0 }
local C_CMD_SEL  = { red = 0.95, green = 0.58, blue = 0.08, alpha = 0.75 }
local C_CMD_DIM  = { white = 0.45, alpha = 1.0 }
local C_HINT     = { white = 0.40, alpha = 1.0 }
local C_MODEL    = { white = 0.32, alpha = 1.0 }
local C_SEP      = { white = 1.00, alpha = 0.09 }
local C_INVIS    = { white = 0.00, alpha = 0.00 }

-- ─────────────────────────────────────────────────────────
-- 5. CONSTRUCTION D'UNE LIGNE
-- ─────────────────────────────────────────────────────────

local function append_seg(result, s, color, is_bold)
    if not s or s == "" then return result end
    local fn  = is_bold and FONT_BOLD or FONT
    local seg = hs.styledtext.new(s, {
        font  = { name = fn, size = SIZE_MAIN },
        color = color,
    })
    return result and (result .. seg) or seg
end

local function build_line(pred, is_sel)
    local result   = nil
    local chunks   = pred.chunks
    local nw       = pred.nw or ""
    local tc_part  = pred.tc_part or ""
    local has_corr = pred.has_corrections

    if chunks and #chunks > 0 then
        -- Trouver le premier et le dernier chunk "insert".
        -- On n'affiche QUE ce qui est entre ces deux bornes (incluses) :
        --   • "equal" en tête  → ignoré (texte déjà tapé, inchangé)
        --   • "insert" + "equal" du milieu → affiché (correction + contexte entre corrections)
        --   • "equal" en queue → ignoré (texte déjà tapé après la correction)
        local first_insert, last_insert = nil, nil
        for i = 1, #chunks do
            if chunks[i].type == "insert" then
                if not first_insert then first_insert = i end
                last_insert = i
            end
        end

        if first_insert then
            for i = first_insert, last_insert do
                local chunk = chunks[i]
                local s = chunk.text
                if s and s ~= "" then
                    if chunk.type == "insert" then
                        local color = is_sel and C_CORR_SEL or C_UNSELECTED_GRAY
                        local bold  = (not is_sel) and has_corr
                        result = append_seg(result, s, color, bold)
                    else -- equal entre deux corrections
                        local color = is_sel and C_UNCH_SEL or C_UNSELECTED_GRAY
                        result = append_seg(result, s, color, false)
                    end
                end
            end
        end
    end

    if not result and tc_part ~= "" then
        local color = is_sel and C_CORR_SEL or C_UNSELECTED_GRAY
        local bold  = (not is_sel) and has_corr
        result = append_seg(result, tc_part, color, bold)
    end

    if nw ~= "" then
        local color = is_sel and C_NW_SEL or C_UNSELECTED_GRAY
        local bold  = (not is_sel) and has_corr
        result = append_seg(result, nw, color, bold)
    end

    return result
end

-- ─────────────────────────────────────────────────────────
-- 6. ASSEMBLAGE CANVAS
-- ─────────────────────────────────────────────────────────

local function assemble(raw_preds, current_index, model_name, indent)
    local n = #raw_preds
    if n == 0 then return hs.styledtext.new("") end

    indent = math.max(0, math.min(5, math.floor(tonumber(indent) or 0)))
    local ind_str = string.rep(" ", indent)

    local PREFIX_SEL   = ind_str .. "✨"
    local PREFIX_OTHER = string.rep(" ", 5)
    if indent > 0 then PREFIX_OTHER = "" end

    local result = nil
    local gap    = hs.styledtext.new("\n", {
        font  = { name = FONT, size = 3 },
        color = C_INVIS,
    })

    for i, pred in ipairs(raw_preds) do
        local is_sel = (i == current_index)

        local prefix = hs.styledtext.new(is_sel and PREFIX_SEL or PREFIX_OTHER, {
            font  = { name = FONT, size = SIZE_MAIN },
            color = is_sel and C_CURSOR or C_BG,
        })

        local body = build_line(pred, is_sel)
        if not body then
            body = hs.styledtext.new("…", {
                font  = { name = FONT, size = SIZE_MAIN, traits = { italic = true } },
                color = C_UNSELECTED_GRAY,
            })
        end

        local cmd_str
        if     i <= 9  then cmd_str = "   ⌘" .. i
        elseif i == 10 then cmd_str = "   ⌘0"
        else                cmd_str = ""
        end

        local line
        if cmd_str ~= "" then
            local cmd_seg = hs.styledtext.new(cmd_str, {
                font  = { name = FONT, size = SIZE_HINT },
                color = is_sel and C_CMD_SEL or C_CMD_DIM,
            })
            line = prefix .. body .. cmd_seg
        else
            line = prefix .. body
        end

        result = result and (result .. gap .. line) or line
    end

    if n > 1 then
        local sep = hs.styledtext.new("\n" .. string.rep("─", 34), {
            font  = { name = FONT, size = 8 },
            color = C_SEP,
        })
        local hint = hs.styledtext.new(
            "\n  ⇧G+Tab ◀   Tab = accepter   ▶ ⇧D+Tab",
            { font = { name = FONT, size = SIZE_HINT }, color = C_HINT }
        )
        result = result .. sep .. hint
    else
        result = result .. hs.styledtext.new("    Tab pour accepter", {
            font  = { name = FONT, size = SIZE_HINT }, color = C_HINT,
        })
    end

    if model_name and model_name ~= "" then
        result = result .. hs.styledtext.new("   — " .. model_name, {
            font  = { name = FONT, size = SIZE_HINT }, color = C_MODEL,
        })
    end

    return result
end

-- ─────────────────────────────────────────────────────────
-- 7. RENDU
-- ─────────────────────────────────────────────────────────
local function render(styled)
    local PAD_X = 14
    local PAD_Y =  7
    local sz = canvas:minimumTextSize(2, styled)
    local w  = sz.w + PAD_X * 2
    local h  = sz.h + PAD_Y * 2

    local anchor = resolve_anchor()
    local fw     = hs.window.focusedWindow()
    local scr    = nil
    if fw then pcall(function() scr = fw:screen() end) end
    local screen = (scr or hs.screen.mainScreen()):frame()

    local px, py
    if anchor then
        if anchor.type == "caret" then
            px = anchor.x + 15
            py = anchor.y + anchor.h + 18
        else
            px = anchor.x - w / 2
            py = anchor.y + 5
            if py + h > screen.y + screen.h then py = anchor.y - h - 5 end
        end
    else
        px = screen.x + (screen.w - w) / 2
        py = screen.y + screen.h - h - 5
    end

    local margin = 5
    px = math.max(screen.x + margin, math.min(px, screen.x + screen.w - w  - margin))
    py = math.max(screen.y + margin, math.min(py, screen.y + screen.h - h  - margin))

    local ok, err = pcall(function()
        canvas:frame({ x = px, y = py, w = w, h = h })
        canvas[2].frame = { x = PAD_X, y = PAD_Y, w = sz.w, h = sz.h }
        canvas[2].text  = styled
        canvas:show()
    end)
    if not ok then hs.printf("[ui/tooltip] render error: %s", tostring(err)) end
end

-- ─────────────────────────────────────────────────────────
-- 8. API PUBLIQUE
-- ─────────────────────────────────────────────────────────

function M.hide()
    canvas:hide()
    _state.raw_predictions = {}
    _state.current_index   = 1
    _state.model_name      = nil
end

function M.set_navigate_callback(fn) _state.on_navigate = fn end
function M.get_current_index()       return _state.current_index end

function M.navigate(delta)
    local n = #_state.raw_predictions
    if n < 2 then return end
    _state.current_index = ((_state.current_index - 1 + delta) % n) + 1
    render(assemble(_state.raw_predictions, _state.current_index, _state.model_name, _state.indent))
    if _state.on_navigate then pcall(_state.on_navigate, _state.current_index) end
end

function M.show_predictions(predictions, current_index, enabled, model_name, indent)
    if not enabled then return end
    if not predictions or #predictions == 0 then M.hide(); return end
    current_index = math.max(1, math.min(current_index, #predictions))
    _state.raw_predictions = predictions
    _state.current_index   = current_index
    _state.model_name      = model_name or nil
    _state.indent          = math.max(0, math.min(5, math.floor(tonumber(indent) or 0)))

    render(assemble(predictions, current_index, _state.model_name, _state.indent))
end

function M.show(content, is_llm, enabled)
    if not enabled then return end
    if content == nil or content == "" then M.hide(); return end
    _state.raw_predictions = {}
    _state.current_index   = 1
    _state.model_name      = nil
    local styled
    if type(content) == "userdata" then
        styled = content
    else
        styled = hs.styledtext.new(tostring(content), {
            font  = { name = FONT, size = SIZE_MAIN,
                      traits = is_llm and { italic = true } or {} },
            color = is_llm and { white = 0.80, alpha = 1.0 }
                            or  { white = 1.00, alpha = 1.0 },
        })
    end
    render(styled)
end

function M.make_diff_styled(chunks, nw, tc_fallback)
    local fake = { chunks = chunks, nw = nw or "", tc_part = tc_fallback or "",
                   deletes = (tc_fallback and tc_fallback ~= "") and 1 or 0,
                   has_corrections = true }
    return build_line(fake, true)
end

return M
