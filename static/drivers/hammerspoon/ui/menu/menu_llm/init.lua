--- ui/menu/menu_llm/init.lua

local M = {}

local hs           = hs
local llm_mod      = require("modules.llm")
local shortcut_ui  = require("ui.menu.shortcut_utils")
local Models       = require("ui.menu.menu_llm.models_manager")
local Profiles     = require("ui.menu.menu_llm.profiles_manager")
local Settings     = require("ui.menu.menu_llm.settings_manager")
local AppPickerLib = require("lib.app_picker")

local ok_arch, arch_str = pcall(hs.execute, "uname -m")
local is_apple_silicon = false
if ok_arch and type(arch_str) == "string" then
    is_apple_silicon = (arch_str:lower():match("arm64") or arch_str:lower():match("aarch64")) ~= nil
end

M.DEFAULT_STATE = {
    llm_enabled           = llm_mod.DEFAULT_STATE.llm_enabled,
    llm_use_mlx           = is_apple_silicon,
    llm_debounce          = llm_mod.DEFAULT_STATE.llm_debounce,
    llm_model             = llm_mod.DEFAULT_STATE.llm_model,
    llm_context_length    = llm_mod.DEFAULT_STATE.llm_context_length,
    llm_reset_on_nav      = llm_mod.DEFAULT_STATE.llm_reset_on_nav,
    llm_temperature       = llm_mod.DEFAULT_STATE.llm_temperature,
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
    llm_profile_shortcuts = {},
    llm_trigger_shortcut  = false,
    llm_after_hotstring   = false,
}

local function format_mod_string(m_str)
    if type(m_str) ~= "string" then return "⌃" end
    local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
    local res = ""
    for p in m_str:gmatch("[^+]+") do res = res .. (dict[p] or p) end
    return res == "" and "⌃" or res
end

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

function M.create(deps)
    if type(deps) ~= "table" then return {} end
    
    deps.active_tasks = deps.active_tasks or {}
    local state       = deps.state
    
    if state.llm_use_mlx == nil then state.llm_use_mlx = M.DEFAULT_STATE.llm_use_mlx end
    llm_mod.set_use_mlx(state.llm_use_mlx)

    local models_mgr   = Models.new(deps)
    local profiles_mgr = Profiles.new(deps, models_mgr)
    local settings_mgr = Settings.new(deps)
    local keymap       = deps.keymap
    local save_prefs   = deps.save_prefs
    local update_menu  = deps.update_menu

    if state.llm_num_predictions ~= nil and keymap and type(keymap.set_llm_num_predictions) == "function" then
        pcall(keymap.set_llm_num_predictions, state.llm_num_predictions)
    end
    if state.llm_max_words ~= nil and keymap and type(keymap.set_llm_max_words) == "function" then
        pcall(keymap.set_llm_max_words, state.llm_max_words)
    end

    local function switch_model(new_model)
        models_mgr.check_requirements(new_model, function()
            state.llm_model = new_model
            if keymap and type(keymap.set_llm_model) == "function" then
                pcall(keymap.set_llm_model, new_model)
            end

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
                    rec_profile = "raw"; rec_label = "●○○○ Raw — Aucun prompt, juste le contexte"
                elseif info.params < 4 then
                    rec_profile = "basic"; rec_label = "●●○○ Basique — Prédiction simple"
                elseif info.params < 7 then
                    rec_profile = "advanced"; rec_label = "●●●○ Avancé — Correction + Prédiction"
                else
                    rec_profile = "batch_advanced"
                    rec_label   = string.format("●●●● Batch Avancé — 1 req. avancée avec %d prédiction%s", current_preds, batch_suffix)
                end
            end

            local cur_profile = state.llm_active_profile or "basic"
            if cur_profile == "parallel" or cur_profile == "parallel_simple" then cur_profile = "basic" end
            if cur_profile == "batch" or cur_profile == "batch_simple" then cur_profile = "batch_advanced" end
            if cur_profile == "parallel_advanced" then cur_profile = "advanced" end
            if cur_profile == "base_completion" then cur_profile = "raw" end

            if cur_profile ~= rec_profile then
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
                    save_prefs(); update_menu()
                end)
            else
                state.llm_active_profile = cur_profile
                llm_mod.set_active_profile(cur_profile)
                save_prefs(); update_menu()
            end
        end)
    end

    local function build_models_selection()
        local menu = {}
        local installed = models_mgr.get_installed_models()
        local presets = models_mgr.get_presets()

        table.insert(menu, {
            title   = "Aucun modèle (Désactivé)",
            checked = (not state.llm_model or state.llm_model == ""),
            fn      = function() 
                state.llm_model = ""
                if keymap and type(keymap.set_llm_model) == "function" then pcall(keymap.set_llm_model, "") end
                save_prefs(); update_menu()
            end
        })
        table.insert(menu, { title = "-" })

        for _, group in ipairs(presets) do
            local sub = {}
            for _, m in ipairs(group.models or {}) do
                local m_name = m.name
                local info = models_mgr.get_model_info(m_name) or {}
                local ram = models_mgr.get_model_ram(m_name) or 0
                local is_inst = installed[m_name] or installed[m_name .. ":latest"]
                local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
                local params_str = (info.params and info.params > 0) and (" · " .. info.params) or ""
                local emojis_str = info.emojis or ""
                local title = string.format("%s%s%s (~%d Go RAM%sB)%s", is_inst and "🟢 " or "  ", m_name, type_str, math.floor(ram), params_str, emojis_str)

                local model_item = {
                    title   = title,
                    checked = (state.llm_model == m_name),
                    fn      = function() switch_model(m_name) end
                }
                -- Ajoute une option de suppression si le modèle est installé
                if is_inst then
                    model_item.menu = {
                        {
                            title = "🗑️ Supprimer ce modèle du cache",
                            fn = function()
                                local ok, choice = pcall(hs.dialog.blockAlert, "Supprimer le modèle ?", "Voulez-vous vraiment supprimer le modèle '" .. m_name .. "' du cache local ?", "Supprimer", "Annuler", "warning")
                                if ok and choice == "Supprimer" then
                                    models_mgr.delete_model(m_name)
                                end
                            end
                        }
                    }
                end
                table.insert(sub, model_item)
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
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then pcall(keymap.set_llm_num_predictions, i) end
                    save_prefs(); update_menu()
                end
            })
        end
        return m
    end

    local _llm_trigger_hk = nil
    local _llm_profile_hks = {}

    local function bind_hotkey(mods, key, callback)
        print(string.format("[LLM Hotkey] Tentative de bind: mods=%s, key=%s", 
            type(mods) == "table" and table.concat(mods, "+") or tostring(mods), 
            key or "nil"))
        local ok, hk = pcall(hs.hotkey.new, mods, key, callback)
        if ok and hk then
            hk:enable()
            print(string.format("[LLM Hotkey] ✓ Succès: hotkey créé et activé"))
            return hk
        else
            print(string.format("[LLM Hotkey] ✗ Erreur: ok=%s, hk=%s", tostring(ok), tostring(hk)))
            return nil
        end
    end

    local function trigger_prediction_with_profile(profile_id)
        if type(profile_id) ~= "string" or profile_id == "" then 
            print(string.format("[LLM Profile Trigger] Erreur: profile_id invalide: %s", tostring(profile_id)))
            return 
        end
        if not keymap or type(keymap.trigger_prediction) ~= "function" then 
            print("[LLM Profile Trigger] Erreur: keymap ou trigger_prediction non disponible")
            return 
        end

        print(string.format("[LLM Profile Trigger] Déclenchement prédiction avec profil '%s'", profile_id))
        
        -- Réinitialiser les prédictions en cours
        if type(keymap.reset_predictions) == "function" then
            pcall(keymap.reset_predictions)
            print("[LLM Profile Trigger] Prédictions en cours annulées")
        end
        
        local previous_profile = state.llm_active_profile or "basic"
        print(string.format("[LLM Profile Trigger] Ancien profil: %s → Nouveau: %s", previous_profile, profile_id))
        
        -- Récupérer le label du profil pour l'afficher dans la barre d'info
        local profile_label = profile_id
        for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
            if type(profile) == "table" and profile.id == profile_id and type(profile.label) == "string" then
                profile_label = profile.label
                break
            end
        end
        if profile_label == profile_id then
            for _, profile in ipairs(type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}) do
                if type(profile) == "table" and profile.id == profile_id and type(profile.label) == "string" then
                    profile_label = profile.label
                    break
                end
            end
        end
        
        llm_mod.set_active_profile(profile_id)
        pcall(keymap.trigger_prediction, true, profile_label)  -- true = force trigger, profile_label = nom du profil
        llm_mod.set_active_profile(previous_profile)
        
        print(string.format("[LLM Profile Trigger] Restauré au profil: %s", previous_profile))
    end

    local function apply_llm_shortcut(mods, key)
        if _llm_trigger_hk then pcall(function() _llm_trigger_hk:delete() end); _llm_trigger_hk = nil end

        local normalized = shortcut_ui.normalize_shortcut(mods, key, {"ctrl"})
        if normalized then
            state.llm_trigger_shortcut = { mods = normalized.mods, key = normalized.key }
            _llm_trigger_hk = bind_hotkey(normalized.mods, normalized.key, function()
                if keymap and type(keymap.trigger_prediction) == "function" then pcall(keymap.trigger_prediction, true) end
            end)
        else
            state.llm_trigger_shortcut = false
        end

        save_prefs(); update_menu()
    end

    local function apply_llm_profile_shortcut(profile_id, mods, key, opts)
        if type(profile_id) ~= "string" or profile_id == "" then return end
        if _llm_profile_hks[profile_id] then
            pcall(function() _llm_profile_hks[profile_id]:delete() end)
            _llm_profile_hks[profile_id] = nil
        end

        if type(state.llm_profile_shortcuts) ~= "table" then state.llm_profile_shortcuts = {} end

        local normalized = shortcut_ui.normalize_shortcut(mods, key, {"ctrl"})
        print(string.format("[LLM Profile Shortcut] apply_llm_profile_shortcut('%s', mods=%s, key=%s) → normalized=%s", 
            profile_id, 
            type(mods) == "table" and table.concat(mods, "+") or tostring(mods),
            key or "nil",
            normalized and (table.concat(normalized.mods, "+") .. "+" .. normalized.key) or "nil"
        ))
        
        if normalized then
            state.llm_profile_shortcuts[profile_id] = { mods = normalized.mods, key = normalized.key }
            local hk = bind_hotkey(normalized.mods, normalized.key, function()
                print(string.format("[LLM Profile Shortcut] Triggered: profile '%s'", profile_id))
                trigger_prediction_with_profile(profile_id)
            end)
            _llm_profile_hks[profile_id] = hk
            print(string.format("[LLM Profile Shortcut] Hotkey bound successfully: %s", hk and "YES" or "FAILED"))
        else
            state.llm_profile_shortcuts[profile_id] = nil
            print(string.format("[LLM Profile Shortcut] Raccourci désactivé pour '%s'", profile_id))
        end

        if not (type(opts) == "table" and opts.silent == true) then
            save_prefs(); update_menu()
        end
    end

    deps.apply_llm_profile_shortcut = apply_llm_profile_shortcut

    profiles_mgr = Profiles.new(deps, models_mgr)

    local check_startup

    local function build_item()
        local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
        local is_disabled = (not state.llm_enabled) or paused
        local main_menu = {}

        if is_apple_silicon then
            table.insert(main_menu, {
                title    = "🚀 Utiliser Apple MLX (suggestions ultra-rapides)",
                checked  = state.llm_use_mlx,
                disabled = paused or nil, -- DÉGRISE : Toujours cliquable même si IA éteinte
                fn       = not paused and function()
                    if state.llm_use_mlx then
                        state.llm_use_mlx = false
                        llm_mod.set_use_mlx(false)
                        if models_mgr.stop_mlx_server_if_needed then models_mgr.stop_mlx_server_if_needed() end
                        save_prefs(); update_menu()
                    else
                        local target_model = state.llm_model
                        if not target_model or target_model == "" or not models_mgr.get_mlx_repo(target_model) then
                            -- Ne pas forcer le check MLX si le modèle est vide, on l'active juste
                            state.llm_use_mlx = true
                            llm_mod.set_use_mlx(true)
                            save_prefs(); update_menu()
                            return
                        end
                        models_mgr.force_mlx_check(target_model, function()
                            state.llm_use_mlx = true
                            state.llm_model = target_model
                            llm_mod.set_use_mlx(true)
                            if keymap and type(keymap.set_llm_model) == "function" then pcall(keymap.set_llm_model, target_model) end
                            save_prefs(); update_menu()
                        end, function() end)
                    end
                end or nil
            })
        end

        local info = models_mgr.get_model_info(state.llm_model) or {}
        local ram = models_mgr.get_model_ram(state.llm_model) or 0
        local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
        local params_str = (info.params and info.params > 0) and (" · " .. info.params) or ""
        local emojis_str = info.emojis or ""
        
        local rich_model_title = "Modèle actif : "
        if not state.llm_model or state.llm_model == "" then
            rich_model_title = rich_model_title .. "Aucun"
        else
            rich_model_title = rich_model_title .. string.format("%s%s (~%d Go RAM%sB)%s", state.llm_model, type_str, math.floor(ram), params_str, emojis_str)
        end
        
        table.insert(main_menu, {
            title    = rich_model_title,
            disabled = paused or nil, -- DÉGRISE : Toujours cliquable même si IA éteinte
            menu     = build_models_selection()
        })

        if info and info.emojis and info.emojis:find("🧠💭") then
            table.insert(main_menu, { title = "   ↳ Info : Modèle thinking (réflexion masquée)", disabled = true })
        end

        table.insert(main_menu, { title = "-" })
        table.insert(main_menu, { title = "— COMPORTEMENT & PERFORMANCES —", disabled = true })

        local profiles_item = profiles_mgr.get_menu_item()
        profiles_item.disabled = is_disabled or nil
        table.insert(main_menu, profiles_item)

        table.insert(main_menu, { title = "Nombre de suggestions : " .. tostring(state.llm_num_predictions or 1), disabled = is_disabled or nil, menu = build_num_pred_menu() })
        if state.llm_num_predictions ~= llm_mod.DEFAULT_STATE.llm_num_predictions then
            table.insert(main_menu, {
                title    = "   ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_num_predictions) .. ")",
                disabled = is_disabled or nil,
                fn       = function()
                    state.llm_num_predictions = llm_mod.DEFAULT_STATE.llm_num_predictions
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then pcall(keymap.set_llm_num_predictions, state.llm_num_predictions) end
                    save_prefs(); update_menu()
                end
            })
        end
        
        local debounce_val = tonumber(state.llm_debounce) or llm_mod.DEFAULT_STATE.llm_debounce or 0.5
        local debounce_display = (debounce_val <= 0) and "Jamais" or (math.floor(debounce_val * 1000) .. " ms…")
        
        table.insert(main_menu, { title = "Temps d’attente avant suggestion : " .. debounce_display, disabled = is_disabled or nil, fn = settings_mgr.set_debounce })
        if state.llm_debounce ~= llm_mod.DEFAULT_STATE.llm_debounce then
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. math.floor((llm_mod.DEFAULT_STATE.llm_debounce or 0.5) * 1000) .. " ms)", disabled = is_disabled or nil, fn = settings_mgr.reset_debounce })
        end

        table.insert(main_menu, {
            title    = "Prédiction IA après expiration des bulles hotstrings",
            checked  = state.llm_after_hotstring,
            disabled = is_disabled or nil,
            fn       = not is_disabled and function()
                state.llm_after_hotstring = not state.llm_after_hotstring
                if keymap and type(keymap.set_llm_after_hotstring) == "function" then
                    pcall(keymap.set_llm_after_hotstring, state.llm_after_hotstring)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        local max_words_display = (state.llm_max_words and state.llm_max_words > 0) and tostring(state.llm_max_words) or "Illimité"
        table.insert(main_menu, { title = "Mots max par suggestion : " .. max_words_display, disabled = is_disabled or nil, fn = settings_mgr.set_max_words })
        if state.llm_max_words ~= llm_mod.DEFAULT_STATE.llm_max_words then
            local def_w_disp = (llm_mod.DEFAULT_STATE.llm_max_words and llm_mod.DEFAULT_STATE.llm_max_words > 0) and tostring(llm_mod.DEFAULT_STATE.llm_max_words) or "Illimité"
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. def_w_disp .. ")", disabled = is_disabled or nil, fn = settings_mgr.reset_max_words })
        end
        
        table.insert(main_menu, { title = "Température (Créativité) : " .. tostring(state.llm_temperature), disabled = is_disabled or nil, fn = settings_mgr.set_temperature })
        if state.llm_temperature ~= llm_mod.DEFAULT_STATE.llm_temperature then
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_temperature) .. ")", disabled = is_disabled or nil, fn = settings_mgr.reset_temperature })
        end

        table.insert(main_menu, { title = "-" })
        table.insert(main_menu, { title = "— CONTEXTE & EXCLUSIONS —", disabled = true })

        table.insert(main_menu, { title = "Taille du contexte : " .. tostring(state.llm_context_length) .. " derniers caractères", disabled = is_disabled or nil, fn = settings_mgr.set_context_length })
        if state.llm_context_length ~= llm_mod.DEFAULT_STATE.llm_context_length then
            table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_context_length) .. ")", disabled = is_disabled or nil, fn = settings_mgr.reset_context_length })
        end
        
        table.insert(main_menu, {
            title    = "Vider le contexte sur clic/navigation",
            checked  = state.llm_reset_on_nav,
            disabled = is_disabled or nil,
            fn       = function()
                state.llm_reset_on_nav = not state.llm_reset_on_nav
                if keymap and type(keymap.set_llm_reset_on_nav) == "function" then pcall(keymap.set_llm_reset_on_nav, state.llm_reset_on_nav) end
                save_prefs(); update_menu()
            end
        })

        local disabled_count = #(type(state.llm_disabled_apps) == "table" and state.llm_disabled_apps or {})
        local disabled_label = "Désactivé dans" .. (disabled_count > 0 and (" " .. disabled_count .. " application" .. (disabled_count > 1 and "s" or "")) or " ces applications")

        local exclusion_menu = AppPickerLib.build_menu(
            state.llm_disabled_apps,
            function(new_list)
                state.llm_disabled_apps = new_list
                if keymap and type(keymap.set_llm_disabled_apps) == "function" then pcall(keymap.set_llm_disabled_apps, new_list) end
                pcall(save_prefs); pcall(update_menu)
            end,
            "Exclure de la génération IA automatique…"
        )

        table.insert(main_menu, { title = disabled_label, disabled = is_disabled or nil, menu = exclusion_menu })
        table.insert(main_menu, { title = "-" })
        table.insert(main_menu, { title = "— INTERFACE & RACCOURCIS —", disabled = true })

        table.insert(main_menu, {
            title    = "Afficher la barre d’info (modèle et latence)",
            checked  = state.llm_show_info_bar,
            disabled = is_disabled or nil,
            fn       = function()
                state.llm_show_info_bar = not state.llm_show_info_bar
                if keymap and type(keymap.set_llm_show_info_bar) == "function" then pcall(keymap.set_llm_show_info_bar, state.llm_show_info_bar) end
                save_prefs(); update_menu()
            end
        })

        local nav_mods = hs.settings.get("llm_nav_modifiers")
        if nav_mods == nil then nav_mods = llm_mod.DEFAULT_STATE.llm_nav_modifiers end
        if keymap and type(keymap.set_llm_nav_modifiers) == "function" then pcall(keymap.set_llm_nav_modifiers, nav_mods) end
        
        local val_mods = hs.settings.get("llm_val_modifiers")
        if val_mods == nil then val_mods = llm_mod.DEFAULT_STATE.llm_val_modifiers end
        if keymap and type(keymap.set_llm_val_modifiers) == "function" then pcall(keymap.set_llm_val_modifiers, val_mods) end

        local num_preds_safe = tonumber(state.llm_num_predictions) or 1
        local nav_title = (num_preds_safe < 2) and "Modificateur navigation (↑/← et ↓/→) : Désactivé (1 suggestion)" or format_shortcut_title("Naviguer dans les suggestions (↑/← et ↓/→)", nav_mods, "Flèches seules", "Flèches")
        table.insert(main_menu, {
            title    = nav_title,
            disabled = (is_disabled or num_preds_safe < 2) or nil,
            menu     = settings_mgr.build_nav_modifier_menu()
        })

        local val_title = (num_preds_safe < 2) and "Modificateur sélection (chiffres) : Désactivé (1 suggestion)" or format_shortcut_title("Sélectionner la suggestion n° (" .. ((num_preds_safe == 10) and "1-0" or ("1-" .. num_preds_safe)) .. ")", val_mods, "Chiffres seuls", "Chiffres")
        table.insert(main_menu, {
            title    = val_title,
            disabled = (is_disabled or num_preds_safe < 2) or nil,
            menu     = settings_mgr.build_val_modifier_menu()
        })

        table.insert(main_menu, { title = "Indentation de la suggestion sélectionnée", disabled = is_disabled or nil, menu = settings_mgr.build_indent_menu() })

        local sc_label = shortcut_ui.shortcut_to_label(state.llm_trigger_shortcut, "Aucun")

        table.insert(main_menu, {
            title    = "Raccourci pour générer manuellement : " .. sc_label,
            disabled = is_disabled or nil,
            fn       = function()
                shortcut_ui.prompt_shortcut({
                    title = "Raccourci génération IA",
                    message = "Format : mods+touche  (ex : cmd+alt+p)\nMods disponibles : cmd, alt, ctrl, shift\nLaisser vide pour désactiver",
                    current_shortcut = state.llm_trigger_shortcut,
                    default_mods = {"ctrl"},
                    on_apply = apply_llm_shortcut,
                })
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
                    -- Si aucun modèle, on se contente d'allumer l'IA, l'utilisateur choisira son modèle après
                    if not state.llm_model or state.llm_model == "" then
                        toggle_state()
                    else
                        models_mgr.check_requirements(state.llm_model, toggle_state, nil)
                    end
                else
                    toggle_state()
                end
            end or nil,
            menu    = main_menu
        }
    end

    check_startup = function()
        if type(state.llm_trigger_shortcut) == "table" then
            apply_llm_shortcut(state.llm_trigger_shortcut.mods, state.llm_trigger_shortcut.key)
        end

        local valid_profile_ids = {}
        for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
            if type(profile) == "table" and type(profile.id) == "string" then
                valid_profile_ids[profile.id] = true
            end
        end
        for _, profile in ipairs(type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}) do
            if type(profile) == "table" and type(profile.id) == "string" then
                valid_profile_ids[profile.id] = true
            end
        end

        local profile_shortcuts = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts or {}
        local sc_count = 0
        for _ in pairs(profile_shortcuts) do sc_count = sc_count + 1 end
        print("[LLM Startup] Raccourcis de profils trouvés : " .. tostring(sc_count) .. " entrées")
        
        for profile_id, sc in pairs(profile_shortcuts) do
            local mods_str = (type(sc) == "table" and type(sc.mods) == "table") and table.concat(sc.mods, "+") or "nil"
            local key_str = (type(sc) == "table" and type(sc.key) == "string") and sc.key or "nil"
            print(string.format("[LLM Startup] Profil '%s' : mods=%s, key=%s", profile_id, mods_str, key_str))
            
            if valid_profile_ids[profile_id] and type(sc) == "table" then
                print(string.format("[LLM Startup] → Binding raccourci pour '%s'", profile_id))
                apply_llm_profile_shortcut(profile_id, sc.mods, sc.key, { silent = true })
            else
                print(string.format("[LLM Startup] → Suppression raccourci pour '%s' (profil invalide)", profile_id))
                apply_llm_profile_shortcut(profile_id, nil, nil, { silent = true })
            end
        end

        if not state.llm_enabled then return end
        
        local function disable_llm()
            state.llm_enabled = false
            if keymap and type(keymap.set_llm_enabled) == "function" then pcall(keymap.set_llm_enabled, false) end
            save_prefs(); update_menu()
        end

        if not state.llm_model or state.llm_model == "" then return end

        -- Pour MLX, on coupe les prédictions côté keymap jusqu'à ce que le serveur soit prêt
        -- (évite les HTTP -1 / Connection failed pendant le chargement du modèle)
        if state.llm_use_mlx and keymap and type(keymap.set_llm_enabled) == "function" then
            pcall(keymap.set_llm_enabled, false)
        end

        models_mgr.check_requirements(state.llm_model, function()
            -- Serveur prêt → on réactive les prédictions
            if state.llm_use_mlx and state.llm_enabled
                and keymap and type(keymap.set_llm_enabled) == "function" then
                pcall(keymap.set_llm_enabled, true)
            end
        end, disable_llm)
    end

    return { 
        build_item    = build_item, 
        check_startup = check_startup 
    }
end

return M
