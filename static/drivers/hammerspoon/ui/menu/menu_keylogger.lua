-- ui/menu/menu_keylogger.lua

-- ===========================================================================
-- Keylogger Menu UI Module.
--
-- Orchestrates the Keylogger & Metrics submenu.
-- Handles the security warning dialogs and calls the keylogger module.
-- ===========================================================================

local M = {}

local hs = hs





-- ========================================
-- ========================================
-- ======= 1/ Application Discovery =======
-- ========================================
-- ========================================

--- Scans the system for installed applications
--- @return table A list of choices for hs.chooser
local function discover_apps()
    local cmd = "find /Applications \"$HOME/Applications\" -maxdepth 2 -name \"*.app\" -not -name \".*\" 2>/dev/null | sort"
    local ok, raw = pcall(hs.execute, cmd)
    if not ok or type(raw) ~= "string" then return {} end
    
    local choices, seen = {}, {}
    for app_path in raw:gmatch("[^\n]+") do
        local name = app_path:match("([^/]+)%.app$")
        if name and not seen[app_path] then
            seen[app_path] = true
            local info = hs.application.infoForBundlePath(app_path)
            local bid  = type(info) == "table" and info.CFBundleIdentifier or nil
            local icon = nil
            
            if bid then
                local ok_img, img = pcall(hs.image.imageFromAppBundle, bid)
                if ok_img and img then
                    pcall(function() img:setSize({w=18, h=18}) end)
                    icon = img
                end
            end
            
            table.insert(choices, {
                text     = name, 
                subText  = app_path, 
                image    = icon,
                bundleID = bid, 
                appPath  = app_path,
            })
        end
    end
    
    table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
    return choices
end

--- Builds the exclusion list submenu
local function build_exclusion_menu(ctx)
    local state       = ctx.state
    local save_prefs  = ctx.save_prefs
    local update_menu = ctx.updateMenu
    local Keylogger   = require("modules.keylogger")

    local apps = type(state.keylogger_disabled_apps) == "table" and state.keylogger_disabled_apps or {}
    local menu = {}
    
    for i, app in ipairs(apps) do
        if type(app) == "table" then
            local icon = nil
            if app.bundleID then
                local ok, img = pcall(hs.image.imageFromAppBundle, app.bundleID)
                if ok and img then 
                    pcall(function() img:setSize({w=16, h=16}) end)
                    icon = img 
                end
            end
            
            local idx = i
            local styled = hs.styledtext.new(
                (app.name or "?") .. "\t✗",
                { paragraphStyle = { tabStops = {{location = 260, alignment = "right"}} } }
            )
            
            table.insert(menu, {
                title = styled, 
                image = icon,
                fn    = function()
                    table.remove(state.keylogger_disabled_apps, idx)
                    if type(Keylogger.set_disabled_apps) == "function" then
                        pcall(Keylogger.set_disabled_apps, state.keylogger_disabled_apps)
                    end
                    pcall(save_prefs)
                    pcall(update_menu)
                end,
            })
        end
    end
    
    if #menu > 0 then table.insert(menu, {title = "-"}) end
    
    table.insert(menu, {
        title = "+ Ajouter une application…",
        fn    = function()
            hs.timer.doAfter(0.1, function()
                local choices = discover_apps()
                local chooser = hs.chooser.new(function(choice)
                    if not choice then return end
                    if type(state.keylogger_disabled_apps) ~= "table" then state.keylogger_disabled_apps = {} end
                    
                    for _, a in ipairs(state.keylogger_disabled_apps) do
                        if type(a) == "table" and a.appPath == choice.appPath then return end
                    end
                    
                    table.insert(state.keylogger_disabled_apps, {
                        name = choice.text, appPath = choice.appPath, bundleID = choice.bundleID,
                    })
                    
                    if type(Keylogger.set_disabled_apps) == "function" then
                        pcall(Keylogger.set_disabled_apps, state.keylogger_disabled_apps)
                    end
                    pcall(save_prefs)
                    pcall(update_menu)
                end)
                
                chooser:placeholderText("Exclure des métriques de frappe…")
                chooser:choices(choices)
                chooser:bgDark(false)
                chooser:show()
            end)
        end,
    })
    
    return menu
end





-- ==============================
-- ==============================
-- ======= 2/ Factory API =======
-- ==============================
-- ==============================

--- Builds the Keylogger menu item
--- @param ctx table Context containing state, updateMenu, save_prefs, etc.
--- @return table The menu definition table
function M.build(ctx)
    local state          = ctx.state
    local save_prefs     = ctx.save_prefs
    local updateMenu     = ctx.updateMenu
    local script_control = ctx.script_control

    local menu = {}
    
    table.insert(menu, {
        title    = "📊 Afficher les métriques de frappe",
        disabled = not state.keylogger_enabled,
        fn       = function() 
            local Keylogger = require("modules.keylogger")
            Keylogger.show_metrics()
        end
    })

    table.insert(menu, { title = "-" })

    local disabled_count = #(type(state.keylogger_disabled_apps) == "table" and state.keylogger_disabled_apps or {})
    local label = "Désactivé dans" .. (disabled_count > 0 and (" " .. disabled_count .. " application" .. (disabled_count > 1 and "s" or "")) or " ces applications")
    
    table.insert(menu, {
        title = label,
        menu  = build_exclusion_menu(ctx)
    })

    return {
        title   = "Métriques de frappe",
        checked = state.keylogger_enabled,
        fn      = function()
            if not state.keylogger_enabled then
                local warnMsg = "ATTENTION : Vous êtes sur le point d'activer le keylogger.\n\n" ..
                                "Il enregistre vos frappes au clavier à la milliseconde près.\n" ..
                                "Ces logs sont stockés en clair dans le dossier Hammerspoon.\n\n" ..
                                "Il est fortement recommandé de mettre le script en PAUSE lors de la saisie de mots de passe ou de données sensibles."
                local res = hs.dialog.blockAlert("Avertissement de Sécurité", warnMsg, "Activer", "Annuler", "warning")
                if res ~= "Activer" then return end
            end
            
            state.keylogger_enabled = not state.keylogger_enabled
            
            local Keylogger = require("modules.keylogger")
            if state.keylogger_enabled then
                if type(Keylogger.set_disabled_apps) == "function" then
                    Keylogger.set_disabled_apps(state.keylogger_disabled_apps or {})
                end
                Keylogger.start(script_control)
            else
                Keylogger.stop()
            end

            save_prefs()
            updateMenu()
        end,
        menu = menu
    }
end

return M
