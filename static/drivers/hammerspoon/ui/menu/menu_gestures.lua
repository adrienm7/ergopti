-- ui/menu/menu_gestures.lua

local M = {}
local hs = hs

local SLOT_LABELS = {
    tap_3         = "Tap 3 doigts",
    tap_4         = "Tap 4 doigts",
    tap_5         = "Tap 5 doigts",
    swipe_2_diag  = "Swipe 2 doigts ↖/↘",
    swipe_3_horiz = "Swipe 3 doigts ←/→",
    swipe_3_diag  = "Swipe 3 doigts ↖/↘",
    swipe_3_up    = "Swipe 3 doigts ↑",
    swipe_3_down  = "Swipe 3 doigts ↓",
    swipe_4_horiz = "Swipe 4 doigts ←/→",
    swipe_4_diag  = "Swipe 4 doigts ↖/↘",
    swipe_4_up    = "Swipe 4 doigts ↑",
    swipe_4_down  = "Swipe 4 doigts ↓",
    swipe_5_horiz = "Swipe 5 doigts ←/→",
    swipe_5_diag  = "Swipe 5 doigts ↖/↘",
    swipe_5_up    = "Swipe 5 doigts ↑",
    swipe_5_down  = "Swipe 5 doigts ↓",
}

function M.build(ctx)
    local gestures = ctx.gestures
    if not gestures then return nil end

    local state  = ctx.state
    local paused = ctx.paused

    local item = {
        title   = "Gestes",
        checked = (state.gestures and not paused) or nil,
        fn      = function()
            state.gestures = not state.gestures
            if gestures then
                if state.gestures then 
                    if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end 
                else 
                    if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end 
                end
            end
            ctx.save_prefs()
            ctx.notify_feature("Gestes", state.gestures)
            ctx.updateMenu()
        end,
    }

    local function slotItem(slot, isAxis)
        local current   = type(gestures.get_action) == "function" and gestures.get_action(slot) or nil
        local slotLbl   = SLOT_LABELS[slot] or slot
        local actionLbl = type(gestures.get_action_label) == "function" and gestures.get_action_label(current) or "Inconnu"
        local names     = isAxis and gestures.AX_NAMES or gestures.SG_NAMES
        local submenu   = {}
        
        if type(names) == "table" then
            for _, aname in ipairs(names) do
                table.insert(submenu, {
                    title    = type(gestures.get_action_label) == "function" and gestures.get_action_label(aname) or aname,
                    checked  = ((current == aname) and not paused) or nil,
                    disabled = not state.gestures or paused or nil,
                    fn       = (state.gestures and not paused) and (function(a) return function()
                        if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, a) end
                        local conflict = type(gestures.on_action_changed) == "function" and gestures.on_action_changed(slot, a) or nil
                        ctx.save_prefs()
                        ctx.updateMenu()
                        if type(conflict) == "table" then
                            hs.timer.doAfter(0.3, function()
                                pcall(hs.focus)
                                local ok_c, clicked = pcall(hs.dialog.blockAlert,
                                    "⚠️  Conflit potentiel", conflict.msg or "",
                                    "Ouvrir Réglages", "Plus tard", "warning")
                                if ok_c and clicked == "Ouvrir Réglages" then
                                    pcall(hs.execute, string.format("open \"%s\"", conflict.url or ""))
                                end
                            end)
                        end
                    end end)(aname) or nil,
                })
            end
        end
        return {
            title    = slotLbl .. " : " .. actionLbl,
            disabled = not state.gestures or paused or nil,
            menu     = submenu,
        }
    end

    local function section(slots, isAxis)
        local its = {}
        for _, slot in ipairs(slots) do table.insert(its, slotItem(slot, isAxis)) end
        return its
    end

    local gm = {}
    table.insert(gm, slotItem("swipe_2_diag", true)); table.insert(gm, { title = "-" })
    table.insert(gm, slotItem("tap_3", false))
    for _, it in ipairs(section({"swipe_3_horiz","swipe_3_diag"}, true))  do table.insert(gm, it) end
    for _, it in ipairs(section({"swipe_3_up",   "swipe_3_down"}, false)) do table.insert(gm, it) end
    table.insert(gm, { title = "-" })
    table.insert(gm, slotItem("tap_4", false))
    for _, it in ipairs(section({"swipe_4_horiz","swipe_4_diag"}, true))  do table.insert(gm, it) end
    for _, it in ipairs(section({"swipe_4_up",   "swipe_4_down"}, false)) do table.insert(gm, it) end
    table.insert(gm, { title = "-" })
    table.insert(gm, slotItem("tap_5", false))
    for _, it in ipairs(section({"swipe_5_horiz","swipe_5_diag"}, true))  do table.insert(gm, it) end
    for _, it in ipairs(section({"swipe_5_up",   "swipe_5_down"}, false)) do table.insert(gm, it) end
    
    item.menu = gm
    return item
end

return M
