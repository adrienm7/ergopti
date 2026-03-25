-- ui/menu_llm/init.lua

-- ===========================================================================
-- LLM Menu UI Module (Main Coordinator).
--
-- Orchestrates the Artificial Intelligence submenu by aggregating logic from:
--   - models_manager.lua   (Ollama, metadata, and installs)
--   - profiles_manager.lua (Prompt strategies and Editor)
--   - settings_manager.lua (Numeric configs and Dialogs)
--   - app_picker.lua       (Application exclusions)
-- ===========================================================================

local M = {}

local hs       = hs
local llm_mod  = require("modules.llm")

-- Sub-modules import
local Models   = require("ui.menu_llm.models_manager")
local Profiles = require("ui.menu_llm.profiles_manager")
local Settings = require("ui.menu_llm.settings_manager")
local Apps     = require("ui.menu_llm.app_picker")





-- ====================================
-- ====================================
-- ======= 1/ Constants & Utils =======
-- ====================================
-- ====================================

--- Formats a raw modifier string into visual macOS symbols for the menu
--- @param m_str string Modifier string (e.g. "cmd+shift")
--- @return string Formatted symbols
local function format_mod_string(m_str)
    if type(m_str) ~= "string" then return "⌃" end
    local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
    local res = ""
    for p in m_str:gmatch("[^+]+") do res = res .. (dict[p] or p) end
    return res == "" and "⌃" or res
end

--- Helper to generate dynamic titles for shortcut menus
--- @param action string The action label (e.g. "Naviguer")
--- @param mods table Array of modifiers
--- @param none_label string Text to display if no modifiers are required
--- @param mod_label string Text to display next to the modifier symbol
--- @return string The combined title
local function format_shortcut_title(action, mods, none_label, mod_label)
    if not mods or (#mods == 1 and mods[1] == "none") then
        return action .. " : Désactivé"
    elseif #mods == 0 then
        return action .. " : " .. none_label
    else
        local sym = format_mod_string(table.concat(mods, "+"))
        return action .. " : " .. sym .. " " .. mod_label
    end
end





-- ==============================
-- ==============================
-- ======= 2/ Factory API =======
-- ==============================
-- ==============================

--- Creates the LLM menu handler
--- @param deps table Global project dependencies (state, keymap, etc.)
--- @return table The build_item and check_startup interface
function M.create(deps)
    if type(deps) ~= "table" then return {} end
    
    -- Initialize specialized managers
    local models_mgr   = Models.new(deps)
    local profiles_mgr = Profiles.new(deps)
    local settings_mgr = Settings.new(deps)
    local apps_mgr     = Apps.new(deps)

    local state        = deps.state
    local keymap       = deps.keymap
    local save_prefs   = deps.save_prefs
    local update_menu  = deps.update_menu
    local update_icon  = deps.update_icon



    -- =====================================
    -- ===== 2.1) Model Switcher Logic =====
    -- =====================================

    local function switch_model(new_model)
        models_mgr.check_requirements(new_model, function()
            state.llm_model = new_model
            if keymap and type(keymap.set_llm_model) == "function" then
                pcall(keymap.set_llm_model, new_model)
            end

            -- Automatic Strategy Adjustment based on model type
            local info = models_mgr.get_model_info(new_model)
            if info.type == "completion" then
                state.llm_active_profile = "base_completion"
            else
                state.llm_active_profile = (info.params > 10) and "batch_simple" or "parallel_simple"
            end
            
            llm_mod.active_profile_id = state.llm_active_profile
            save_prefs()
            update_menu()
        end)
    end



    -- ====================================
    -- ===== 2.2) Sub-menu Builders =======
    -- ====================================

    local function build_models_selection()
        local menu = {}
        local installed = models_mgr.get_installed_models()
        local presets = models_mgr.get_presets()

        for _, group in ipairs(presets) do
            local sub = {}
            for _, m in ipairs(group.models or {}) do
                table.insert(sub, {
                    title   = (installed[m.name] and "🟢 " or "  ") .. m.name .. " (" .. m.params .. ")",
                    checked = (state.llm_model == m.name),
                    fn      = function() switch_model(m.name) end
                })
            end
            table.insert(menu, { title = group.label, menu = sub })
        end
        return menu
    end

    local function build_num_pred_menu()
        local m = {}
        for i = 1, 10 do
            table.insert(m, {
                title   = i .. " suggestion" .. (i > 1 and "s" or ""),
                checked = (state.llm_num_predictions == i),
                fn      = function()
                    state.llm_num_predictions = i
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then
                        pcall(keymap.set_llm_num_predictions, i)
                    end
                    save_prefs(); update_menu()
                end
            })
        end
        return m
    end



    -- ===================================
    -- ===================================
    -- ======= 3/ Main Menu Item =========
    -- ===================================
    -- ===================================

    local function build_item()
        local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
        local main_menu = {}

        -- --- 1. MODEL & INSTALLATION ---
        local is_thinking = llm_mod.is_thinking_model(state.llm_model)
        local model_badge = is_thinking and " 🧠💭" or (llm_mod.is_small_model(state.llm_model) and " ⚡" or "")
        
        table.insert(main_menu, {
            title    = "Modèle actif : " .. tostring(state.llm_model) .. model_badge,
            disabled = paused or nil,
            menu     = build_models_selection()
        })

        if is_thinking then
            table.insert(main_menu, { title = "   ↳ Info : Modèle thinking (réflexion masquée)", disabled = true })
        end

        table.insert(main_menu, { title = "-" })

        -- --- 2. PERFORMANCE & STRATEGY ---
        table.insert(main_menu, { title = "— COMPORTEMENT & PERFORMANCES —", disabled = true })

        table.insert(main_menu, { title = "Nombre de suggestions : " .. state.llm_num_predictions, menu = build_num_pred_menu() })
        table.insert(main_menu, profiles_mgr.get_menu_item())
        
        table.insert(main_menu, { title = "Délai d’inactivité : " .. math.floor(state.llm_debounce * 1000) .. " ms…", fn = settings_mgr.set_debounce })
        table.insert(main_menu, { title = "Tokens max générés : " .. state.llm_max_predict, fn = settings_mgr.set_max_predict })
        table.insert(main_menu, { title = "Température (Créativité) : " .. state.llm_temperature, fn = settings_mgr.set_temperature })

        table.insert(main_menu, { title = "-" })

        -- --- 3. CONTEXT & EXCLUSIONS ---
        table.insert(main_menu, { title = "— CONTEXTE & EXCLUSIONS —", disabled = true })

        table.insert(main_menu, { title = "Taille du contexte : " .. state.llm_context_length .. " derniers caractères", fn = settings_mgr.set_context_length })
        
        table.insert(main_menu, {
            title   = "Vider le contexte sur clic/navigation",
            checked = state.llm_reset_on_nav,
            fn      = function()
                state.llm_reset_on_nav = not state.llm_reset_on_nav
                if keymap and type(keymap.set_llm_reset_on_nav) == "function" then pcall(keymap.set_llm_reset_on_nav, state.llm_reset_on_nav) end
                save_prefs(); update_menu()
            end
        })

        table.insert(main_menu, apps_mgr.get_menu_item())

        table.insert(main_menu, { title = "-" })

        -- --- 4. INTERFACE & SHORTCUTS ---
        table.insert(main_menu, { title = "— INTERFACE & RACCOURCIS —", disabled = true })

        table.insert(main_menu, {
            title   = "Afficher la barre d’info (modèle et latence)",
            checked = state.llm_show_info_bar,
            fn      = function()
                state.llm_show_info_bar = not state.llm_show_info_bar
                if keymap and type(keymap.set_llm_show_info_bar) == "function" then pcall(keymap.set_llm_show_info_bar, state.llm_show_info_bar) end
                save_prefs(); update_menu()
            end
        })

        -- Retrieve configurations and synchronize them with keymap.lua
        local nav_mods = hs.settings.get("llm_nav_modifiers")
        if nav_mods == nil then nav_mods = keymap and keymap.llm_nav_modifiers_default or {} end
        if keymap and type(keymap.set_llm_nav_modifiers) == "function" then pcall(keymap.set_llm_nav_modifiers, nav_mods) end
        
        local val_mods = hs.settings.get("llm_val_modifiers")
        if val_mods == nil then val_mods = keymap and keymap.llm_val_modifiers_default or {"alt"} end
        if keymap and type(keymap.set_llm_val_modifiers) == "function" then pcall(keymap.set_llm_val_modifiers, val_mods) end

        -- Formatting dynamic titles
        local nav_title = ""
        if state.llm_num_predictions < 2 then
            nav_title = "Modificateur navigation (↑/← et ↓/→) : Désactivé (1 suggestion)"
        else
            nav_title = format_shortcut_title("Naviguer dans les suggestions (↑/← et ↓/→)", nav_mods, "Flèches seules", "Flèches")
        end

        table.insert(main_menu, {
            title    = nav_title,
            disabled = (state.llm_num_predictions < 2),
            menu     = settings_mgr.build_nav_modifier_menu()
        })

        local val_title = ""
        if state.llm_num_predictions < 2 then
            val_title = "Modificateur sélection (chiffres) : Désactivé (1 suggestion)"
        else
            local range_str = (state.llm_num_predictions == 10) and "1-0" or ("1-" .. state.llm_num_predictions)
            val_title = format_shortcut_title("Sélectionner la suggestion n° (" .. range_str .. ")", val_mods, "Chiffres seuls", "Chiffres")
        end

        table.insert(main_menu, {
            title    = val_title,
            disabled = (state.llm_num_predictions < 2),
            menu     = settings_mgr.build_val_modifier_menu()
        })

        table.insert(main_menu, { title = "Indentation automatique", menu = settings_mgr.build_indent_menu() })

        return {
            title   = "Intelligence Artificielle",
            checked = (state.llm_enabled and not paused) or nil,
            fn      = function()
                state.llm_enabled = not state.llm_enabled
                if keymap and type(keymap.set_llm_enabled) == "function" then pcall(keymap.set_llm_enabled, state.llm_enabled) end
                save_prefs(); update_menu()
            end,
            menu    = main_menu
        }
    end

    --- Startup check logic to ensure Ollama is available if LLM is enabled
    local function check_startup()
        if not state.llm_enabled then return end
        llm_mod.check_availability(state.llm_model, nil, function(needs_ollama)
            hs.timer.doAfter(1, function()
                pcall(hs.focus)
                local msg = needs_ollama and "Ollama n’est pas lancé ou installé." or "Le modèle actif n’est pas téléchargé."
                local choice = hs.dialog.blockAlert("IA non prête", msg .. "\nSouhaitez-vous résoudre ce problème ?", "Oui", "Plus tard")
                if choice == "Oui" then
                    if needs_ollama then pcall(hs.execute, "open /Applications/Ollama.app")
                    else models_mgr.pull_model(state.llm_model, deps) end
                end
            end)
        end)
    end

    return { 
        build_item    = build_item, 
        check_startup = check_startup 
    }
end

return M
