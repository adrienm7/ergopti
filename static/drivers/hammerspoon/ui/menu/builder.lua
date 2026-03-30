--- ui/menu/builder.lua

--- ==============================================================================
--- MODULE: Menu Builder
--- DESCRIPTION:
--- Constructs the visual hierarchy of the macOS menubar.
---
--- FEATURES & RATIONALE:
--- 1. Stateless Rendering: Consumes the context and returns pure UI tables.
--- 2. Delegation: Relies on specific menu_* submodules for component building.
--- ==============================================================================

local M = {}
local hs = hs





-- ===================================
-- ===================================
-- ======= 1/ Menu Generation ========
-- ===================================
-- ===================================

--- Generates the complete items list for the Hammerspoon menubar.
--- @param ctx table The global UI context.
--- @param menu_mods table The loaded menu submodules.
--- @param actions table Callbacks for global system actions.
--- @return table The assembled menu structure.
function M.generate(ctx, menu_mods, actions)
    local items = {}
    
    table.insert(items, {
        title = hs.styledtext.new("Ergopti+", {
            font           = { name = "Helvetica-Bold", size = 16 },
            paragraphStyle = { alignment = "center" },
        }),
        fn = function() end,
    })
    table.insert(items, { title = "-" })

    if type(menu_mods.hotstrings) == "table" then
        if type(menu_mods.hotstrings.build_groups) == "function" then
            local ok, groups = pcall(menu_mods.hotstrings.build_groups, ctx)
            if ok and type(groups) == "table" then
                for _, it in ipairs(groups) do table.insert(items, it) end
            end
        end
        
        table.insert(items, { title = "-" })
        
        if type(menu_mods.hotstrings.build_management) == "function" then
            local ok, mgmt = pcall(menu_mods.hotstrings.build_management, ctx)
            if ok and mgmt then table.insert(items, mgmt) end
        end
        
        if type(menu_mods.hotstrings.build_personal) == "function" then
            local ok, pers = pcall(menu_mods.hotstrings.build_personal, ctx)
            if ok and pers then table.insert(items, pers) end
        end
        
        if type(menu_mods.hotstrings.build_custom) == "function" then
            local ok, cust = pcall(menu_mods.hotstrings.build_custom, ctx)
            if ok and cust then table.insert(items, cust) end
        end
    end

    table.insert(items, { title = "-" })
    
    if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_item) == "function" then
        local ok_b, llm_item = pcall(ctx.llm_handler.build_item)
        if ok_b and llm_item then table.insert(items, llm_item) end
    end
    
    if type(menu_mods.keylogger) == "table" and type(menu_mods.keylogger.build) == "function" then
        local ok, kl_item = pcall(menu_mods.keylogger.build, ctx)
        if ok and kl_item then table.insert(items, kl_item) end
    end

    table.insert(items, { title = "-" })
    
    if type(menu_mods.gestures) == "table" and type(menu_mods.gestures.build) == "function" then
        local ok, g_item = pcall(menu_mods.gestures.build, ctx)
        if ok and g_item then table.insert(items, g_item) end
    end
    
    if type(menu_mods.shortcuts) == "table" and type(menu_mods.shortcuts.build) == "function" then
        local ok, r_item = pcall(menu_mods.shortcuts.build, ctx)
        if ok and r_item then table.insert(items, r_item) end
    end

    -- Fix: Use the correct submodule for script control
    local script_control_mod = pcall(require, "ui.menu.menu_script_control") and require("ui.menu.menu_script_control") or nil
    if type(script_control_mod) == "table" and type(script_control_mod.build) == "function" then
        local ok, sc_item = pcall(script_control_mod.build, ctx)
        if ok and sc_item then table.insert(items, sc_item) end
    end

    table.insert(items, { title = "-" })
    table.insert(items, { title = "☑ Activer toutes les fonctionnalités", fn = actions.enable_all })
    table.insert(items, { title = "☐ Désactiver toutes les fonctionnalités", fn = actions.disable_all })
    
    table.insert(items, { title = "-" })
    table.insert(items, { title = "Console", fn = actions.open_console })
    table.insert(items, { title = "Ouvrir init.lua", fn = actions.open_init })
    table.insert(items, { title = "Préférences", fn = actions.open_prefs })
    table.insert(items, { title = "Recharger", fn = actions.reload })
    table.insert(items, { title = "Quitter", fn = actions.quit })

    return items
end

return M
