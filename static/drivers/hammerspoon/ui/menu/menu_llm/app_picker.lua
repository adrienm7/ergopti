-- ui/menu/menu_llm/app_picker.lua

-- ===========================================================================
-- LLM App Picker Sub-module.
--
-- Logic for discovering installed applications and managing the exclusion
-- list (apps where LLM predictions should be disabled).
-- Uses hs.chooser for a searchable selection interface.
-- ===========================================================================

local M = {}





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





-- =====================================
-- =====================================
-- ======= 2/ Menu Construction ========
-- =====================================
-- =====================================

--- Builds the exclusion list submenu
--- @param state table Shared menu state
--- @param save_prefs function Callback to persist changes
--- @param update_menu function Callback to refresh the UI
--- @param keymap table Reference to the keymap engine
--- @return table The menu structure
local function build_exclusion_menu(state, save_prefs, update_menu, keymap)
    local apps = type(state.llm_disabled_apps) == "table" and state.llm_disabled_apps or {}
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
                    table.remove(state.llm_disabled_apps, idx)
                    if keymap and type(keymap.set_llm_disabled_apps) == "function" then
                        pcall(keymap.set_llm_disabled_apps, state.llm_disabled_apps)
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
                    if type(state.llm_disabled_apps) ~= "table" then state.llm_disabled_apps = {} end
                    
                    for _, a in ipairs(state.llm_disabled_apps) do
                        if type(a) == "table" and a.appPath == choice.appPath then return end
                    end
                    
                    table.insert(state.llm_disabled_apps, {
                        name = choice.text, appPath = choice.appPath, bundleID = choice.bundleID,
                    })
                    
                    if keymap and type(keymap.set_llm_disabled_apps) == "function" then
                        pcall(keymap.set_llm_disabled_apps, state.llm_disabled_apps)
                    end
                    pcall(save_prefs)
                    pcall(update_menu)
                end)
                
                chooser:placeholderText("Rechercher une application…")
                chooser:choices(choices)
                chooser:bgDark(false)
                chooser:show()
            end)
        end,
    })
    
    return menu
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

function M.new(deps)
    local obj = { deps = deps }

    --- Builds the main "Disabled in..." menu item
    function obj.get_menu_item()
        local disabled_count = #(type(deps.state.llm_disabled_apps) == "table" and deps.state.llm_disabled_apps or {})
        local label = "Désactivé dans" .. (disabled_count > 0 and (" " .. disabled_count .. " application" .. (disabled_count > 1 and "s" or "")) or " ces applications")
        
        return {
            title = label,
            menu  = build_exclusion_menu(deps.state, deps.save_prefs, deps.update_menu, deps.keymap)
        }
    end

    return obj
end

return M
