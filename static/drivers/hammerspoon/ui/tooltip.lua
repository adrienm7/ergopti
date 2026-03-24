-- ui/tooltip.lua
local M = {}

local ok_bridge, vscode_bridge = pcall(require, "lib.vscode_bridge")
if not ok_bridge then vscode_bridge = nil end

-- ─────────────────────────────────────────────────────────
-- 1. CANVAS (5 éléments statiques pré-alloués = Zéro Lag)
-- ─────────────────────────────────────────────────────────
local canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
canvas:level(hs.canvas.windowLevels.cursor)
canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
canvas:appendElements(
    { type = "rectangle", action = "fill", fillColor = { white = 0.10, alpha = 0.97 }, roundedRectRadii = { xRadius = 7, yRadius = 7 } },
    { type = "text" },      -- [2] Prédictions
    { type = "rectangle" }, -- [3] Séparateur pleine largeur
    { type = "text" },      -- [4] Raccourcis (Hint) OU Combinaison (Hint + Info)
    { type = "text" }       -- [5] Info Bar (Temps) si non combinée
)

-- ─────────────────────────────────────────────────────────
-- 2. ÉTAT ET ÉCOUTEURS D'ÉVÉNEMENTS
-- ─────────────────────────────────────────────────────────
local _state = {
    raw_predictions = {},
    current_index   = 1,
    on_navigate     = nil,
    info_bar        = nil,
    shortcut_mod    = "ctrl",
    indent          = 0,
    fixed_width     = nil,
}

local _watchers = {}

local function stop_watchers()
    for _, w in ipairs(_watchers) do w:stop() end
    _watchers = {}
end

local function start_watchers()
    stop_watchers()
    
    local evTypes = hs.eventtap.event.types
    
    -- Fermer la bulle au mouvement de souris ou au clic
    local w_mouse = hs.eventtap.new({evTypes.mouseMoved, evTypes.leftMouseDown, evTypes.rightMouseDown, evTypes.scrollWheel}, function(e)
        M.hide()
        return false
    end)
    w_mouse:start()
    table.insert(_watchers, w_mouse)

    -- Fermer la bulle à la frappe d'une touche "normale"
    local w_key = hs.eventtap.new({evTypes.keyDown}, function(e)
        local kc = e:getKeyCode()
        
        if kc == 48 or kc == 36 then return false end -- Tab & Entrée gérés dans keymap.lua
        if kc >= 123 and kc <= 126 then return false end -- Flèches ignorées
        
        local flags = e:getFlags()
        local mod = _state.shortcut_mod or "ctrl"
        if flags[mod] then
            -- Tolérance stricte pour les touches numériques avec le bon modificateur
            if (kc >= 18 and kc <= 29) then return false end
        end
        
        -- On ignore les pressions pures sur des touches modificatrices
        if kc == 54 or kc == 55 or kc == 56 or kc == 58 or kc == 59 or kc == 60 then
            return false
        end
        
        M.hide()
        return false
    end)
    w_key:start()
    table.insert(_watchers, w_key)
end

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
            local b = focused:parameterizedAttributeValue("AXBoundsForRange", { location = range.location, length = 0 })
            if b and type(b) == "table" and b.x and b.y and b.h and b.h > 0 and b.h < 80 then return { x = b.x, y = b.y, h = b.h, type = "caret" } end
        end
        local ln = focused:attributeValue("AXInsertionPointLineNumber")
        if ln then
            local lr = focused:parameterizedAttributeValue("AXRangeForLine", ln)
            if lr then
                local b = focused:parameterizedAttributeValue("AXBoundsForRange", lr)
                if b and b.h and b.h > 0 and b.h < 80 then return { x = b.x, y = b.y, h = b.h, type = "caret" } end
            end
        end
        local f = focused:attributeValue("AXFrame")
        if f and f.x and f.y and f.w and f.h then return { x = f.x + f.w / 2, y = f.y + f.h, h = 0, type = "input_box" } end
        return nil
    end)
    if ax_ok and pos then return pos end

    local win = hs.window.focusedWindow()
    if win then
        local ok, f = pcall(function() return win:frame() end)
        if ok and f then return { x = f.x + f.w / 2, y = f.y + f.h - 40, h = 0, type = "window" } end
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
local SIZE_INFO = 10 

local C_BG       = { white = 0.10, alpha = 1.0 }

local C_CORR_SEL = { red = 0.25, green = 0.90, blue = 0.40, alpha = 1.0 }
local C_UNCH_SEL = { white = 0.60, alpha = 1.0 }
local C_NW_SEL   = { red = 1.00, green = 0.62, blue = 0.10, alpha = 1.0 }

local C_UNSELECTED_GRAY = { white = 0.50, alpha = 1.0 }

local C_CURSOR   = { red = 0.98, green = 0.88, blue = 0.22, alpha = 1.0 }
local C_CMD_SEL  = { red = 0.95, green = 0.58, blue = 0.08, alpha = 0.75 }
local C_CMD_DIM  = { white = 0.45, alpha = 1.0 }
local C_HINT     = { white = 0.40, alpha = 1.0 }
local C_INFO_BAR = { white = 0.30, alpha = 1.0 } 
local C_SEP      = { white = 1.00, alpha = 0.09 }
local C_SEP_INFO = { white = 1.00, alpha = 0.06 }
local C_INVIS    = { white = 0.00, alpha = 0.00 }

local MOD_SYMBOL = { cmd = "⌘", ctrl = "⌃", alt = "⌥", shift = "⇧" }

-- ─────────────────────────────────────────────────────────
-- 5. CONSTRUCTION D'UNE LIGNE
-- ─────────────────────────────────────────────────────────

local function append_seg(result, s, color, is_bold)
    if not s or s == "" then return result end
    local fn  = is_bold and FONT_BOLD or FONT
    local seg = hs.styledtext.new(s, { font = { name = fn, size = SIZE_MAIN }, color = color })
    return result and (result .. seg) or seg
end

local function build_line(pred, is_sel, total_preds)
    local result   = nil
    local chunks   = pred.chunks
    local nw       = pred.nw or ""
    local has_corr = pred.has_corrections

    local bold_diff = (not is_sel) and (total_preds > 1) and has_corr

    local first_done = false
    local function clean_first(s)
        if not first_done and s and s ~= "" then
            s = s:gsub("^%s+", "")
            if s ~= "" then first_done = true end
        end
        return s
    end

    if chunks and #chunks > 0 then
        for _, chunk in ipairs(chunks) do
            local s = clean_first(chunk.text)
            if s and s ~= "" then
                if chunk.type == "insert" then
                    local color = is_sel and C_CORR_SEL or C_UNSELECTED_GRAY
                    result = append_seg(result, s, color, bold_diff)
                else -- "equal"
                    local color = is_sel and C_UNCH_SEL or C_UNSELECTED_GRAY
                    result = append_seg(result, s, color, false)
                end
            end
        end
    end

    local s_nw = clean_first(nw)
    if s_nw and s_nw ~= "" then
        local color = is_sel and C_NW_SEL or C_UNSELECTED_GRAY
        result = append_seg(result, s_nw, color, bold_diff)
    end

    return result
end

-- ─────────────────────────────────────────────────────────
-- 6. ASSEMBLAGE BLOCS
-- ─────────────────────────────────────────────────────────

local function assemble_blocks(raw_preds, current_index, info_bar, shortcut_mod, indent)
    local n = #raw_preds
    if n == 0 then return { preds = hs.styledtext.new("") } end

    indent = math.max(0, math.min(5, math.floor(tonumber(indent) or 0)))
    local ind_str = string.rep(" ", indent)

    local PREFIX_SEL, PREFIX_OTHER

    if n == 1 then
        PREFIX_SEL   = ind_str .. "✨ "
        PREFIX_OTHER = ""
    elseif indent == 0 then
        PREFIX_SEL   = "✨ "
        PREFIX_OTHER = "  " -- Cas spécial : on ajoute 2 espaces pour aligner sous l'emoji ✨
    else
        PREFIX_SEL   = ind_str .. "✨ "
        PREFIX_OTHER = ind_str
    end

    local mod_sym = MOD_SYMBOL[shortcut_mod or "ctrl"] or "⌃"

    local result = nil
    local gap    = hs.styledtext.new("\n", { font = { name = FONT, size = 3 }, color = C_INVIS })

    for i, pred in ipairs(raw_preds) do
        local is_sel = (i == current_index)

        local prefix = hs.styledtext.new(is_sel and PREFIX_SEL or PREFIX_OTHER, {
            font  = { name = FONT, size = SIZE_MAIN }, color = is_sel and C_CURSOR or C_BG,
        })

        local body = build_line(pred, is_sel, n)
        if not body then
            body = hs.styledtext.new("…", { font = { name = FONT, size = SIZE_MAIN, traits = { italic = true } }, color = C_UNSELECTED_GRAY })
        end

        local cmd_str = ""
        if n > 1 then
            if i <= 9 then cmd_str = "   " .. mod_sym .. i
            elseif i == 10 then cmd_str = "   " .. mod_sym .. "0"
            end
        end

        local line
        if cmd_str ~= "" then
            local cmd_seg = hs.styledtext.new(cmd_str, { font = { name = FONT, size = SIZE_HINT }, color = is_sel and C_CMD_SEL or C_CMD_DIM })
            line = prefix .. body .. cmd_seg
        else
            line = prefix .. body
        end

        result = result and (result .. gap .. line) or line
    end

    local SP = "      " -- 6 espaces mathématiques
    
    local hint_st
    if n > 1 then
        hint_st = hs.styledtext.new(
            "⇧G+Tab ◀" .. SP .. "Tab = accepter" .. SP .. "▶ ⇧D+Tab",
            { font = { name = FONT, size = SIZE_HINT }, color = C_HINT, paragraphStyle = { alignment = "center" } }
        )
    else
        hint_st = hs.styledtext.new("Tab pour accepter", { font = { name = FONT, size = SIZE_HINT }, color = C_HINT, paragraphStyle = { alignment = "center" } })
    end

    local info_st = nil
    if info_bar and info_bar ~= "" then
        info_bar = info_bar:gsub("%s*·%s*", " — ⏱️ ")
        info_st = hs.styledtext.new(info_bar, { font = { name = FONT, size = SIZE_INFO }, color = C_INFO_BAR, paragraphStyle = { alignment = "center" } })
    end

    return { preds = result, hint_st = hint_st, info_st = info_st, SP = SP }
end

-- ─────────────────────────────────────────────────────────
-- 7. RENDU DYNAMIQUE
-- ─────────────────────────────────────────────────────────
local function render(blocks)
    local PAD_X = 14
    local PAD_Y =  7
    
    local sz_preds = {w=0, h=0}
    if type(blocks) == "userdata" then
        sz_preds = canvas:minimumTextSize(2, blocks)
        blocks = { preds = blocks }
    else
        sz_preds = canvas:minimumTextSize(2, blocks.preds)
    end

    local hint_st = blocks.hint_st
    local info_st = blocks.info_st
    local SP = blocks.SP or "      "

    local sz_hint = hint_st and canvas:minimumTextSize(2, hint_st) or {w=0, h=0}
    local sz_info = info_st and canvas:minimumTextSize(2, info_st) or {w=0, h=0}

    local max_w = _state.fixed_width or sz_preds.w
    local is_combined = false
    local combined_st = nil

    if info_st and hint_st then
        local sep_st = hs.styledtext.new(SP .. "|" .. SP, { font = { name = FONT, size = SIZE_HINT }, color = C_SEP })
        
        combined_st = hs.styledtext.new("") .. hint_st .. sep_st .. info_st
        combined_st = combined_st:setStyle({ paragraphStyle = { alignment = "center" } }, 1, #combined_st)
        
        local sz_comb = canvas:minimumTextSize(2, combined_st)
        if sz_comb.w <= max_w then
            is_combined = true
        end
    end

    local w = max_w + PAD_X * 2
    local cur_y = PAD_Y

    -- [2] Texte principal
    canvas[2].text  = blocks.preds
    canvas[2].frame = { x = PAD_X, y = cur_y, w = max_w, h = sz_preds.h }
    cur_y = cur_y + sz_preds.h + 8

    -- [3] Ligne Séparatrice à 100% de la largeur
    if hint_st or info_st then
        canvas[3].action    = "fill"
        canvas[3].fillColor = C_SEP
        canvas[3].frame     = { x = 0, y = cur_y, w = w, h = 1 }
        cur_y = cur_y + 8
    else
        canvas[3].action = "skip"
    end

    -- [4] et [5] Textes Hint / Info
    if is_combined then
        local sz_comb = canvas:minimumTextSize(2, combined_st)
        canvas[4].action = "fill"
        canvas[4].text   = combined_st
        canvas[4].frame  = { x = 0, y = cur_y, w = w, h = sz_comb.h }
        cur_y = cur_y + sz_comb.h + 8
        canvas[5].action = "skip"
    else
        if hint_st then
            canvas[4].action = "fill"
            canvas[4].text   = hint_st
            canvas[4].frame  = { x = 0, y = cur_y, w = w, h = sz_hint.h }
            cur_y = cur_y + sz_hint.h + (info_st and 4 or 8)
        else
            canvas[4].action = "skip"
        end

        if info_st then
            canvas[5].action = "fill"
            canvas[5].text   = info_st
            canvas[5].frame  = { x = 0, y = cur_y, w = w, h = sz_info.h }
            cur_y = cur_y + sz_info.h + 8
        else
            canvas[5].action = "skip"
        end
    end

    local h = cur_y - 8 + PAD_Y

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
        canvas:show()
        start_watchers()
    end)
    if not ok then hs.printf("[ui/tooltip] render error: %s", tostring(err)) end
end

-- ─────────────────────────────────────────────────────────
-- 8. API PUBLIQUE
-- ─────────────────────────────────────────────────────────

function M.hide()
    canvas:hide()
    stop_watchers()
    _state.raw_predictions = {}
    _state.current_index   = 1
    _state.info_bar        = nil
    _state.fixed_width     = nil
end

function M.set_navigate_callback(fn) _state.on_navigate = fn end
function M.get_current_index()       return _state.current_index end

function M.navigate(delta)
    local n = #_state.raw_predictions
    if n < 2 then return end
    _state.current_index = ((_state.current_index - 1 + delta) % n) + 1
    render(assemble_blocks(_state.raw_predictions, _state.current_index, _state.info_bar, _state.shortcut_mod, _state.indent))
    if _state.on_navigate then pcall(_state.on_navigate, _state.current_index) end
end

function M.show_predictions(predictions, current_index, enabled, info_bar, shortcut_mod, indent)
    if not enabled then return end
    if not predictions or #predictions == 0 then M.hide(); return end
    current_index = math.max(1, math.min(current_index, #predictions))
    _state.raw_predictions = predictions
    _state.current_index   = current_index
    _state.info_bar        = (info_bar and info_bar ~= "") and info_bar or nil
    _state.shortcut_mod    = shortcut_mod or "ctrl"
    _state.indent          = math.max(0, math.min(5, math.floor(tonumber(indent) or 0)))

    local max_width = 0
    for i = 1, #predictions do
        local b = assemble_blocks(predictions, i, _state.info_bar, _state.shortcut_mod, _state.indent)
        local w_preds = canvas:minimumTextSize(2, b.preds).w
        
        local sz_hint = b.hint_st and canvas:minimumTextSize(2, b.hint_st) or {w=0}
        local sz_info = b.info_st and canvas:minimumTextSize(2, b.info_st) or {w=0}
        
        local w_final = w_preds
        if b.info_st and b.hint_st then
            local SP = b.SP or "      "
            local sep_st = hs.styledtext.new(SP .. "|" .. SP, { font = { name = FONT, size = SIZE_HINT } })
            local combined_st = hs.styledtext.new("") .. b.hint_st .. sep_st .. b.info_st
            local sz_comb = canvas:minimumTextSize(2, combined_st)
            
            if sz_comb.w > w_preds then
                w_final = math.max(w_preds, sz_hint.w, sz_info.w)
            end
        else
            w_final = math.max(w_preds, sz_hint.w, sz_info.w)
        end
        
        if w_final > max_width then max_width = w_final end
    end
    _state.fixed_width = max_width

    render(assemble_blocks(predictions, current_index, _state.info_bar, _state.shortcut_mod, _state.indent))
end

function M.show(content, is_llm, enabled)
    if not enabled then return end
    if content == nil or content == "" then M.hide(); return end
    _state.raw_predictions = {}
    _state.current_index   = 1
    _state.info_bar        = nil
    _state.fixed_width     = nil
    
    local styled
    if type(content) == "userdata" then
        styled = content
    else
        styled = hs.styledtext.new(tostring(content), {
            font  = { name = FONT, size = SIZE_MAIN, traits = is_llm and { italic = true } or {} },
            color = is_llm and { white = 0.80, alpha = 1.0 } or { white = 1.00, alpha = 1.0 },
        })
    end
    render(styled)
end

function M.make_diff_styled(chunks, nw, tc_fallback)
    local fake = { chunks = chunks, nw = nw or "", has_corrections = true }
    return build_line(fake, true, 1)
end

return M
