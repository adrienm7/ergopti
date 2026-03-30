--- ui/menu/menu_script_control.lua

--- ==============================================================================
--- MODULE: Menu Script Control
--- DESCRIPTION:
--- Builds the script control sub-menu for the Hammerspoon tray menu.
--- ==============================================================================

local M = {}
local hs = hs
local shortcuts_mod = require("modules.shortcuts")





-- ===================================
-- ===================================
-- ======= 1/ Default State ==========
-- ===================================
-- ===================================

M.DEFAULT_STATE = {
    script_control_enabled   = shortcuts_mod.DEFAULT_STATE.script_control_enabled,
    script_control_shortcuts = shortcuts_mod.DEFAULT_STATE.script_control_shortcuts,
    ahk_source_path          = shortcuts_mod.DEFAULT_STATE.ahk_source_path,
}





-- ===================================
-- ===================================
-- ======= 2/ Menu Construction ======
-- ===================================
-- ===================================

--- Builds the script control sub-menu.
--- @param ctx table Context.
--- @return table|nil
function M.build(ctx)
    local sc_module = ctx.script_control
    if not sc_module then return nil end

    local state      = ctx.state
    local paused     = ctx.paused
    local actions    = type(sc_module.ACTIONS) == "table" and sc_module.ACTIONS or {}
    local act_labels = type(sc_module.ACTION_LABELS) == "table" and sc_module.ACTION_LABELS or {}
    local enabled    = state.script_control_enabled

    local function get_label(act)
        local lbl = act_labels[act] or act
        return lbl
    end

    local function key_submenu(keyname)
        local current = state.script_control_shortcuts[keyname] or "none"
        local sub = {}
        for _, act in ipairs(actions) do
            table.insert(sub, {
                title    = get_label(act),
                checked  = ((current == act) and not paused) or nil,
                disabled = not enabled or paused or nil,
                fn       = (enabled and not paused) and (function(a) return function()
                    state.script_control_shortcuts[keyname] = a
                    if type(sc_module.set_shortcut_action) == "function" then pcall(sc_module.set_shortcut_action, keyname, a) end
                    ctx.save_prefs()
                    ctx.updateMenu()
                end end)(act) or nil,
            })
        end
        return sub
    end

    local cur_return = state.script_control_shortcuts.return_key or "none"
    local cur_back   = state.script_control_shortcuts.backspace  or "none"
    
    return {
        title   = "Contrôle du script",
        checked = (enabled and not paused) or nil,
        fn      = function()
            state.script_control_enabled = not state.script_control_enabled
            if type(sc_module.set_shortcut_action) == "function" then
                if state.script_control_enabled then
                    pcall(sc_module.set_shortcut_action, "return_key", state.script_control_shortcuts.return_key)
                    pcall(sc_module.set_shortcut_action, "backspace",  state.script_control_shortcuts.backspace)
                else
                    pcall(sc_module.set_shortcut_action, "return_key", "none")
                    pcall(sc_module.set_shortcut_action, "backspace",  "none")
                end
            end
            ctx.save_prefs()
            ctx.notify_feature("Contrôle du script", state.script_control_enabled)
            ctx.updateMenu()
        end,
        menu = {
            { title = "Option droite + ↩ : " .. get_label(cur_return),
               disabled = not enabled or paused or nil, menu = key_submenu("return_key") },
            { title = "Option droite + ⌫ : " .. get_label(cur_back),
               disabled = not enabled or paused or nil, menu = key_submenu("backspace") },
            { title = "-" },
            { title    = "Chemin du AHK…",
               disabled = paused or nil,
               fn       = not paused and function()
                local ok_p, btn, path = pcall(hs.dialog.textPrompt, "Script AHK",
                    "Chemin du fichier AHK source :",
                    state.ahk_source_path, "OK", "Annuler")
                if ok_p and btn == "OK" and type(path) == "string" then
                    state.ahk_source_path = path
                    ctx.save_prefs()
                    ctx.updateMenu()
                end
               end or nil },
        },
    }
end

return M
