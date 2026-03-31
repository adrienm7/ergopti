--- ui/menu/menu_llm/init.lua

--- ==============================================================================
--- MODULE: Menu LLM
--- DESCRIPTION:
--- Orchestrates the Artificial Intelligence submenu by aggregating logic from:
---   - models_manager.lua   (Ollama, metadata, and installs)
---   - profiles_manager.lua (Prompt strategies and Editor)
---   - settings_manager.lua (Numeric configs and Dialogs)
--- ==============================================================================

local M = {}

local hs           = hs
local llm_mod      = require("modules.llm")

-- Sub-modules import
local Models       = require("ui.menu.menu_llm.models_manager")
local Profiles     = require("ui.menu.menu_llm.profiles_manager")
local Settings     = require("ui.menu.menu_llm.settings_manager")
local AppPickerLib = require("lib.app_picker")





-- ===================================
-- ===================================
-- ======= 1/ Default State ==========
-- ===================================
-- ===================================

M.DEFAULT_STATE = {
    llm_enabled           = llm_mod.DEFAULT_STATE.llm_enabled,
    llm_debounce          = llm_mod.DEFAULT_STATE.llm_debounce,
    llm_model             = llm_mod.DEFAULT_STATE.llm_model,
    llm_context_length    = llm_mod.DEFAULT_STATE.llm_context_length,
    llm_reset_on_nav      = llm_mod.DEFAULT_STATE.llm_reset_on_nav,
    llm_temperature       = llm_mod.DEFAULT_STATE.llm_temperature,
    llm_max_predict       = llm_mod.DEFAULT_STATE.llm_max_predict,
    llm_num_predictions   = llm_mod.DEFAULT_STATE.llm_num_predictions,
    llm_arrow_nav_enabled = llm_mod.DEFAULT_STATE.llm_arrow_nav_enabled,
    llm_nav_modifiers     = llm_mod.DEFAULT_STATE.llm_nav_modifiers,
    llm_show_info_bar     = llm_mod.DEFAULT_STATE.llm_show_info_bar,
    llm_val_modifiers     = llm_mod.DEFAULT_STATE.llm_val_modifiers,
    llm_pred_indent       = llm_mod.DEFAULT_STATE.llm_pred_indent,
    llm_active_profile    = llm_mod.DEFAULT_STATE.llm_active_profile,
    llm_user_models       = {},
    llm_disabled_apps     = {},
    llm_user_profiles     = {},
    llm_trigger_shortcut  = false,
}





-- ====================================
-- ====================================
-- ======= 2/ Constants & Utils =======
-- ====================================
-- ====================================

--- Formats a raw modifier string into visual macOS symbols for the menu.
--- @param m_str string Modifier string (e.g. "cmd+shift").
--- @return string Formatted symbols.
local function format_mod_string(m_str)
    if type(m_str) ~= "string" then return "⌃" end
    local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
    local res = ""
    for p in m_str:gmatch("[^+]+") do res = res .. (dict[p] or p) end
    return res == "" and "⌃" or res
end

--- Helper to generate dynamic titles for shortcut menus.
--- @param action string The action label (e.g. "Naviguer").
--- @param mods table Array of modifiers.
--- @param none_label string Text to display if no modifiers are required.
--- @param mod_label string Text to display next to the modifier symbol.
--- @return string The combined title.
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
-- ======= 3/ Factory API =======
-- ==============================
-- ==============================

--- Creates the LLM menu handler.
--- @param deps table Global project dependencies (state, keymap, etc.).
--- @return table The build_item and check_startup interface.
function M.create(deps)
    if type(deps) ~= "table" then return {} end
    
    -- Initialize specialized managers
    local models_mgr   = Models.new(deps)
    local profiles_mgr = Profiles.new(deps, models_mgr)
    local settings_mgr = Settings.new(deps)

    local state        = deps.state
    local keymap       = deps.keymap
    local save_prefs   = deps.save_prefs
    local update_menu  = deps.update_menu

    if state.llm_num_predictions ~= nil and keymap and type(keymap.set_llm_num_predictions) == "function" then
        pcall(keymap.set_llm_num_predictions, state.llm_num_predictions)
    end
    if state.llm_max_words ~= nil and keymap and type(keymap.set_llm_max_words) == "function" then
        pcall(keymap.set_llm_max_words, state.llm_max_words)
    end



    -- =====================================
    -- ===== 3.1) Model Switcher Logic =====
    -- =====================================

    --- Handles model selection and intelligent profile recommendation prompting.
    --- @param new_model string The identifier of the chosen model.
    local function switch_model(new_model)
        models_mgr.check_requirements(new_model, function()
            state.llm_model = new_model
            if keymap and type(keymap.set_llm_model) == "function" then
                pcall(keymap.set_llm_model, new_model)
            end

            -- Strategy Recommendation based on model type and size
            -- Failsafe default object to prevent indexing nil
            local info = models_mgr.get_model_info(new_model) or {}
            local rec_profile = "basic"
            local rec_label   = "●●○○ Basique — Prédiction simple"
            
            local current_preds = tonumber(state.llm_num_predictions) or 1
            local batch_suffix = current_preds > 1 and "s" or ""

            if info.type == "completion" then
                rec_profile = "raw"
                rec_label   = "●○○○ Raw — Aucun prompt, juste le contexte"
            elseif info.params and info.params > 0 then
                if info.params < 2 then
                    rec_profile = "raw"
                    rec_label   = "●○○○ Raw — Aucun prompt, juste le contexte"
                elseif info.params < 4 then
                    rec_profile = "basic"
                    rec_label   = "●●○○ Basique — Prédiction simple"
                elseif info.params < 7 then
                    rec_profile = "advanced"
                    rec_label   = "●●●○ Avancé — Correction + Prédiction"
                else
                    rec_profile = "batch_advanced"
                    rec_label   = string.format("●●●● Batch Avancé — 1 req. avancée avec %d prédiction%s", current_preds, batch_suffix)
                end
            end

            local cur_profile = state.llm_active_profile or "basic"
            
            -- Auto-migrate legacy profiles to maintain compatibility
            if cur_profile == "parallel" or cur_profile == "parallel_simple" then cur_profile = "basic" end
            if cur_profile == "batch" or cur_profile == "batch_simple" then cur_profile = "batch_advanced" end
            if cur_profile == "parallel_advanced" then cur_profile = "advanced" end
            if cur_profile == "base_completion" then cur_profile = "raw" end

            if cur_profile ~= rec_profile then
                -- Prompt user to accept the recommended profile
                hs.timer.doAfter(0.1, function()
                    pcall(hs.focus)
                    local msg = string.format("Le modèle '%s' est optimisé pour le profil de prompt :\n\n%s\n\nVoulez-vous basculer sur ce profil ?", new_model, rec_label)
                    local ok, choice = pcall(hs.dialog.blockAlert, "Changement de modèle", msg, "Oui (Recommandé)", "Non (Garder l'actuel)", "informational")
                    
                    if ok and choice == "Oui (Recommandé)" then
                        state.llm_active_profile = rec_profile
                        llm_mod.set_active_profile(rec_profile)
                    else
                        state.llm_active_profile = cur_profile
                        llm_mod.set_active_profile(cur_profile)
                    end
                    save_prefs()
                    update_menu()
                end)
            else
                state.llm_active_profile = cur_profile
                llm_mod.set_active_profile(cur_profile)
                save_prefs()
                update_menu()
            end
        end)
    end



    -- ====================================
    -- ===== 3.2) Sub-menu Builders =======
    -- ====================================

    --- Constructs the model selection sub-menu mapping presets to options.
    --- @return table The list of model menu items.
    local function build_models_selection()
        local menu = {}
        local installed = models_mgr.get_installed_models()
        local presets = models_mgr.get_presets()

        for _, group in ipairs(presets) do
            local sub = {}
            for _, m in ipairs(group.models or {}) do
                local m_name = m.name
                
                -- Failsafe extraction to prevent crashes if the local cache is incomplete
                local info = models_mgr.get_model_info(m_name) or {}
                local ram = models_mgr.get_model_ram(m_name) or 0
                
                -- Format the different elements for the UI
                local is_inst = installed[m_name] or installed[m_name .. ":latest"]
                local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
                local params_str = (info.params and info.params > 0) and (" · " .. info.params) or ""
                local emojis_str = info.emojis or ""

                -- Recreate the exact rich title formatting
                local title = string.format("%s%s%s (~%d Go RAM%sB)%s",
                    is_inst and "🟢 " or "  ",
                    m_name, type_str, ram, params_str, emojis_str)

                table.insert(sub, {
                    title   = title,
                    checked = (state.llm_model == m_name),
                    fn      = function() switch_model(m_name) end
                })
            end
            table.insert(menu, { title = group.label, menu = sub })
        end
        return menu
    end

    --- Constructs the parallel prediction array sub-menu.
    --- @return table The list of prediction array menu items.
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
    -- ======= 3.3) Main Menu Item =======
    -- ===================================
    -- ===================================

    local _llm_trigger_hk = nil

    --- Binds the global hotkey to manually trigger LLM prediction.
    local function apply_llm_shortcut(mods, key)
        if _llm_trigger_hk then pcall(function() _llm_trigger_hk:delete() end); _llm_trigger_hk = nil end
        if mods and key then
            state.llm_trigger_shortcut = { mods = mods, key = key }
            local ok, hk = pcall(hs.hotkey.new, mods, key, function()
                if keymap and type(keymap.trigger_prediction) == "function" then pcall(keymap.trigger_prediction) end
            end)
            if ok and hk then _llm_trigger_hk = hk; hk:enable() end
        else
            state.llm_trigger_shortcut = false
        end
        save_prefs(); update_menu()
    end

    --- Core builder for the entire Artificial Intelligence menu tree.
    --- @return table The root menu item structure.
    local function build_item()
        local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
        local main_menu = {}

        -- --- 1. MODEL & INSTALLATION ---
        
        -- Safe extraction for the currently selected model
        local info = models_mgr.get_model_info(state.llm_model) or {}
        local ram = models_mgr.get_model_ram(state.llm_model) or 0
        local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
        local params_str = (info.params and info.params > 0) and (" · " .. info.params) or ""
        local emojis_str = info.emojis or ""
        
        local rich_model_title = string.format("Modèle actif : %s%s (~%d Go RAM%sB)%s",
            tostring(state.llm_model), type_str, ram, params_str, emojis_str)
        
        table.insert(main_menu, {
            title    = rich_model_title,
            disabled = paused or nil,
            menu     = build_models_selection()
        })

        if info and info.emojis and info.emojis:find("🧠💭") then
            table.insert(main_menu, { title = "   ↳ Info : Modèle thinking (réflexion masquée)", disabled = true })
        end

        table.insert(main_menu, { title = "-" })

        -- --- 2. PERFORMANCE & STRATEGY ---
        table.insert(main_menu, { title = "— COMPORTEMENT & PERFORMANCES —", disabled = true })

        table.insert(main_menu, { title = "Nombre de suggestions : " .. tostring(state.llm_num_predictions or 1), menu = build_num_pred_menu() })
        if state.llm_num_predictions ~= llm_mod.DEFAULT_STATE.llm_num_predictions then
            table.insert(main_menu, {
                title = "   ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_num_predictions) .. ")",
                fn    = function()
                    state.llm_num_predictions = llm_mod.DEFAULT_STATE.llm_num_predictions
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then pcall(keymap.set_llm_num_predictions, state.llm_num_predictions) end
                    save_prefs(); update_menu()
                end
            })
        end
        
        -- --- PROFILES SUBMENU CONSTRUCTION ---
        table.insert(main_menu, profiles_mgr.get_menu_item())
        
        local debounce_val = tonumber(state.llm_debounce) or llm_mod.DEFAULT_STATE.llm_debounce or 0.5
        local debounce_display = (debounce_val < 0) and "Jamais" or (math.floor(debounce_val * 1000) .. " ms…")
        
        table.insert(main_menu, { title = "Temps d’attente avant suggestion : " .. debounce_display, fn = settings_mgr.set_debounce })
        if state.llm_debounce ~= llm_mod.DEFAULT_STATE.llm_debounce then
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. math.floor((llm_mod.DEFAULT_STATE.llm_debounce or 0.5) * 1000) .. " ms)", fn = settings_mgr.reset_debounce })
        end

        table.insert(main_menu, { title = "Tokens max générés : " .. tostring(state.llm_max_predict), fn = settings_mgr.set_max_predict })
        if state.llm_max_predict ~= llm_mod.DEFAULT_STATE.llm_max_predict then
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_max_predict) .. ")", fn = settings_mgr.reset_max_predict })
        end
        
        local max_words_display = (state.llm_max_words and state.llm_max_words > 0) and tostring(state.llm_max_words) or "Illimité"
        table.insert(main_menu, { title = "Mots max par suggestion : " .. max_words_display, fn = settings_mgr.set_max_words })
        if state.llm_max_words ~= llm_mod.DEFAULT_STATE.llm_max_words then
            local def_w_disp = (llm_mod.DEFAULT_STATE.llm_max_words and llm_mod.DEFAULT_STATE.llm_max_words > 0) and tostring(llm_mod.DEFAULT_STATE.llm_max_words) or "Illimité"
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. def_w_disp .. ")", fn = settings_mgr.reset_max_words })
        end
        
        table.insert(main_menu, { title = "Température (Créativité) : " .. tostring(state.llm_temperature), fn = settings_mgr.set_temperature })
        if state.llm_temperature ~= llm_mod.DEFAULT_STATE.llm_temperature then
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_temperature) .. ")", fn = settings_mgr.reset_temperature })
        end

        table.insert(main_menu, { title = "-" })

        -- --- 3. CONTEXT & EXCLUSIONS ---
        table.insert(main_menu, { title = "— CONTEXTE & EXCLUSIONS —", disabled = true })

        table.insert(main_menu, { title = "Taille du contexte : " .. tostring(state.llm_context_length) .. " derniers caractères", fn = settings_mgr.set_context_length })
        if state.llm_context_length ~= llm_mod.DEFAULT_STATE.llm_context_length then
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_context_length) .. ")", fn = settings_mgr.reset_context_length })
        end
        
        table.insert(main_menu, {
            title   = "Vider le contexte sur clic/navigation",
            checked = state.llm_reset_on_nav,
            fn      = function()
                state.llm_reset_on_nav = not state.llm_reset_on_nav
                if keymap and type(keymap.set_llm_reset_on_nav) == "function" then pcall(keymap.set_llm_reset_on_nav, state.llm_reset_on_nav) end
                save_prefs(); update_menu()
            end
        })

        -- Directly build the AppPicker exclusion menu item here
        local disabled_count = #(type(state.llm_disabled_apps) == "table" and state.llm_disabled_apps or {})
        local disabled_label = "Désactivé dans" .. (disabled_count > 0 and (" " .. disabled_count .. " application" .. (disabled_count > 1 and "s" or "")) or " ces applications")

        table.insert(main_menu, {
            title = disabled_label,
            menu  = AppPickerLib.build_menu(
                state.llm_disabled_apps,
                function(new_list)
                    state.llm_disabled_apps = new_list
                    if keymap and type(keymap.set_llm_disabled_apps) == "function" then
                        pcall(keymap.set_llm_disabled_apps, new_list)
                    end
                    pcall(save_prefs)
                    pcall(update_menu)
                end,
                "Exclure de la génération IA automatique…"
            )
        })

        table.insert(main_menu, { title = "-" })

        -- --- 4. INTERFACE & RACCOURCIS ---
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

        table.insert(main_menu, { title = "Indentation de la suggestion sélectionnée", menu = settings_mgr.build_indent_menu() })

        -- Retrieve configurations and synchronize them with keymap.lua
        local nav_mods = hs.settings.get("llm_nav_modifiers")
        if nav_mods == nil then nav_mods = llm_mod.DEFAULT_STATE.llm_nav_modifiers end
        if keymap and type(keymap.set_llm_nav_modifiers) == "function" then pcall(keymap.set_llm_nav_modifiers, nav_mods) end
        
        local val_mods = hs.settings.get("llm_val_modifiers")
        if val_mods == nil then val_mods = llm_mod.DEFAULT_STATE.llm_val_modifiers end
        if keymap and type(keymap.set_llm_val_modifiers) == "function" then pcall(keymap.set_llm_val_modifiers, val_mods) end

        -- Formatting dynamic titles
        local num_preds_safe = tonumber(state.llm_num_predictions) or 1
        local nav_title = ""
        if num_preds_safe < 2 then
            nav_title = "Modificateur navigation (↑/← et ↓/→) : Désactivé (1 suggestion)"
        else
            nav_title = format_shortcut_title("Naviguer dans les suggestions (↑/← et ↓/→)", nav_mods, "Flèches seules", "Flèches")
        end

        table.insert(main_menu, {
            title    = nav_title,
            disabled = (num_preds_safe < 2),
            menu     = settings_mgr.build_nav_modifier_menu()
        })

        local val_title = ""
        if num_preds_safe < 2 then
            val_title = "Modificateur sélection (chiffres) : Désactivé (1 suggestion)"
        else
            local range_str = (num_preds_safe == 10) and "1-0" or ("1-" .. num_preds_safe)
            val_title = format_shortcut_title("Sélectionner la suggestion n° (" .. range_str .. ")", val_mods, "Chiffres seuls", "Chiffres")
        end

        table.insert(main_menu, {
            title    = val_title,
            disabled = (num_preds_safe < 2),
            menu     = settings_mgr.build_val_modifier_menu()
        })

        local sc_label = "Aucun"
        if type(state.llm_trigger_shortcut) == "table" then
            local mods_cap = {}
            for _, m in ipairs(state.llm_trigger_shortcut.mods or {}) do
                table.insert(mods_cap, m:sub(1,1):upper() .. m:sub(2))
            end
            local mods_str = table.concat(mods_cap, "+")
            sc_label = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.llm_trigger_shortcut.key or "")
        end

        table.insert(main_menu, {
            title = "Raccourci pour générer manuellement : " .. sc_label,
            fn = function()
                local current_str = ""
                if type(state.llm_trigger_shortcut) == "table" then
                    current_str = table.concat(state.llm_trigger_shortcut.mods or {}, "+") .. "+" .. (state.llm_trigger_shortcut.key or "")
                end
                local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
                    "Raccourci génération IA",
                    "Format : mods+touche  (ex : cmd+alt+p)\nMods disponibles : cmd, alt, ctrl, shift\nLaisser vide pour désactiver",
                    current_str, "OK", "Annuler"
                )
                if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
                raw = raw:match("^%s*(.-)%s*$"):lower()
                if raw == "" then apply_llm_shortcut(nil, nil); return end
                local parts = {}
                for part in raw:gmatch("[^+]+") do table.insert(parts, part) end
                if #parts < 1 then return end
                local key  = parts[#parts]
                local mods = {}
                for i = 1, #parts - 1 do
                    local m = parts[i]
                    if m == "option" then m = "alt" end
                    table.insert(mods, m)
                end
                if #mods == 0 then mods = {"ctrl"} end
                apply_llm_shortcut(mods, key)
            end
        })

        return {
            title   = "Intelligence Artificielle ✨",
            checked = (state.llm_enabled and not paused) or nil,
            fn      = not paused and function()
                local function toggle_state()
                    state.llm_enabled = not state.llm_enabled
                    if keymap and type(keymap.set_llm_enabled) == "function" then pcall(keymap.set_llm_enabled, state.llm_enabled) end
                    save_prefs(); update_menu()
                    pcall(function() hs.notify.new({title = state.llm_enabled and "🟢 ACTIVÉ" or "🔴 DÉSACTIVÉ", informativeText = "Suggestions IA"}):send() end)
                end

                if not state.llm_enabled then
                    -- Turning ON: Check if the model is downloaded first (triggers RAM/Disk dialog if needed)
                    models_mgr.check_requirements(state.llm_model, toggle_state, nil)
                else
                    -- Turning OFF: Just disable it
                    toggle_state()
                end
            end or nil,
            menu    = main_menu
        }
    end

    --- Startup check logic to ensure Ollama is available if LLM is enabled
    local function check_startup()
        if type(state.llm_trigger_shortcut) == "table" then
            apply_llm_shortcut(state.llm_trigger_shortcut.mods, state.llm_trigger_shortcut.key)
        end

        if not state.llm_enabled then return end
        
        local function disable_llm()
            state.llm_enabled = false
            if keymap and type(keymap.set_llm_enabled) == "function" then pcall(keymap.set_llm_enabled, false) end
            save_prefs(); update_menu()
        end

        -- Verify model. Prompts with RAM/Disk UI if missing.
        models_mgr.check_requirements(state.llm_model, function() 
            -- Model is ready, nothing to do.
        end, disable_llm)
    end

    return { 
        build_item    = build_item, 
        check_startup = check_startup 
    }
end

return M
