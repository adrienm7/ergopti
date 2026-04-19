--- ui/menu/menu_llm/init.lua

--- ==============================================================================
--- MODULE: Menu LLM
--- DESCRIPTION:
--- Builds and manages the LLM system tray menu and logic bindings.
---
--- FEATURES & RATIONALE:
--- 1. Backend Agnostic: Switches gracefully between MLX and Ollama.
--- 2. Dynamic UI: Reads models from JSON configuration to build menus.
--- ==============================================================================

local M = {}

local hs            = hs
local llm_mod       = require("modules.llm")
local shortcut_ui   = require("ui.menu.shortcut_utils")
local Logger        = require("lib.logger")
local notifications = require("lib.notifications")
local Models        = require("ui.menu.menu_llm.models_manager")
local Profiles      = require("ui.menu.menu_llm.profiles_manager")
local Settings      = require("ui.menu.menu_llm.settings_manager")
local AppPickerLib  = require("lib.app_picker")

local LOG = "menu_llm"

-- Holds the active models manager so M.stop_mlx_server() can reach it from any context
-- (e.g., the Hammerspoon shutdown callback) without requiring a reference chain.
local _active_models_mgr = nil

local MODEL_ADVANCED_PARAMS_THRESHOLD_B = 2
local MODEL_BATCH_PARAMS_THRESHOLD_B = 4

local PROFILE_POWER_RAW = 0
local PROFILE_POWER_BASIC = 1
local PROFILE_POWER_ADVANCED = 2
local PROFILE_POWER_BATCH_ADVANCED = 3
local PROFILE_POWER_BATCH = 2
local PROFILE_POWER_PARALLEL = 1

local PROFILE_POWER_LEVELS = {
    raw = PROFILE_POWER_RAW,
    basic = PROFILE_POWER_BASIC,
    advanced = PROFILE_POWER_ADVANCED,
    batch_advanced = PROFILE_POWER_BATCH_ADVANCED,
    batch = PROFILE_POWER_BATCH,
    parallel = PROFILE_POWER_PARALLEL,
}

local function normalize_profile_power_key(profile_id)
    if type(profile_id) ~= "string" then return "basic" end
    if profile_id == "raw" or profile_id == "base_completion" then return "raw" end
    if profile_id == "basic" then return "basic" end
    if profile_id == "advanced" then return "advanced" end
    if profile_id == "batch_advanced" then return "batch_advanced" end
    if profile_id == "batch" or profile_id:match("^batch_") then return "batch" end
    if profile_id == "parallel" or profile_id:match("^parallel_") then return "parallel" end
    return "basic"
end

-- Detect Apple Silicon via filesystem check (no shell spawn needed:
-- Homebrew on ARM installs to /opt/homebrew, Intel uses /usr/local)
local is_apple_silicon = hs.fs.attributes("/opt/homebrew", "mode") == "directory"

M.DEFAULT_STATE = {
    llm_enabled           = llm_mod.DEFAULT_STATE.llm_enabled,
    llm_backend           = is_apple_silicon and "mlx" or "ollama",
    llm_debounce          = llm_mod.DEFAULT_STATE.llm_debounce,
    llm_model             = llm_mod.DEFAULT_STATE.llm_model,
    llm_model_ollama      = llm_mod.DEFAULT_STATE.llm_model_ollama,
    llm_model_mlx         = llm_mod.DEFAULT_STATE.llm_model_mlx,
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
    llm_disabled_apps          = {},
    llm_url_bar_filter_enabled        = true,
    llm_secure_field_filter_enabled   = true,
    llm_user_profiles     = {},
    llm_profile_shortcuts = {},
    llm_trigger_shortcut  = false,
    llm_after_hotstring   = false,
    llm_auto_raise_temp   = llm_mod.DEFAULT_STATE.llm_auto_raise_temp,
    llm_min_words         = llm_mod.DEFAULT_STATE.llm_min_words,
    llm_streaming           = llm_mod.DEFAULT_STATE.llm_streaming,
    llm_streaming_multi     = llm_mod.DEFAULT_STATE.llm_streaming_multi,
    llm_instant_on_word_end = llm_mod.DEFAULT_STATE.llm_instant_on_word_end,
}





-- Cached result of the last async server health check.
-- nil = not yet checked, true = server responded, false = server unreachable.
local _llm_health_status = nil

--- Fires an async health probe against the active backend.
--- Updates _llm_health_status and calls refresh_fn() when the result arrives.
--- @param backend string "mlx" or "ollama".
--- @param refresh_fn function Called with no args after the result is stored.
local function probe_llm_health(backend, refresh_fn)
	local url = (backend == "ollama")
		and "http://127.0.0.1:11434/api/version"
		or  "http://127.0.0.1:8080/v1/models"

	hs.http.asyncGet(url, {}, function(status)
		-- Any HTTP response (even 4xx) means the server is reachable
		_llm_health_status = (type(status) == "number" and status > 0)
		if type(refresh_fn) == "function" then pcall(refresh_fn) end
	end)
end


--- Stops the MLX server process if one is currently running.
--- Safe to call even when no server is active or before M.create() has been called.
--- Intended for the Hammerspoon shutdown callback to prevent orphaned Python processes.
function M.stop_mlx_server()
	if _active_models_mgr and type(_active_models_mgr.stop_mlx_server_if_needed) == "function" then
		pcall(_active_models_mgr.stop_mlx_server_if_needed)
	end
end




-- =================================
-- =================================
-- ======= 1/ Helper Methods =======
-- =================================
-- =================================

local function format_mod_string(m_str)
    if type(m_str) ~= "string" then return "⌃" end
    local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
    local res = ""
    for p in m_str:gmatch("[^+]+") do res = res .. (dict[p] or p) end
    return res == "" and "⌃" or res
end



-- ==========================================
-- ===== 1.1) Shortcut Title Formatting =====
-- ==========================================

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





-- ===============================
-- ===============================
-- ======= 2/ Main Factory =======
-- ===============================
-- ===============================

function M.create(deps)
    if type(deps) ~= "table" then return {} end
    
    deps.active_tasks = deps.active_tasks or {}
    local state       = deps.state
    
    -- Migration logic for older configs
    if state.llm_use_mlx ~= nil then
        state.llm_backend = state.llm_use_mlx and "mlx" or "ollama"
        state.llm_use_mlx = nil
    end
    if state.llm_backend == nil then 
        state.llm_backend = M.DEFAULT_STATE.llm_backend 
    end
    llm_mod.set_backend(state.llm_backend)

    local models_mgr   = Models.new(deps)
    -- Register the manager so M.stop_mlx_server() can reach it from the shutdown callback
    _active_models_mgr = models_mgr

    --- Calculates the raw power level of a model based on its size.
    local function get_effective_model_params(info)
        if type(info) ~= "table" then return 0, false, 0, 0 end

        local total_params = tonumber(info.params_total) or tonumber(info.params) or 0
        local active_params = tonumber(info.params_active) or total_params
        if active_params <= 0 then active_params = total_params end

        local is_moe = info.is_moe == true or (total_params > 0 and active_params > 0 and active_params < total_params)
        local effective_params = is_moe and active_params or total_params

        return effective_params, is_moe, active_params, total_params
    end

    local function build_model_name_set(presets)
        local names = {}
        if type(presets) ~= "table" then return names end
        for _, provider in ipairs(presets) do
            for _, family in ipairs(provider.families or {}) do
                for _, m in ipairs(family.models or {}) do
                    local n = m and m.name
                    if type(n) == "string" and n ~= "" then names[n:lower()] = true end
                end
            end
        end
        return names
    end

    local function infer_completion_from_name_pairs(model_name)
        if type(model_name) ~= "string" or model_name == "" then return nil end
        local presets = models_mgr.get_presets()
        local names = build_model_name_set(presets)
        local name_l = model_name:lower()

        local base_no_it = name_l:gsub("[-_]it$", "")
        if base_no_it ~= name_l and names[base_no_it] then
            return false
        end
        if names[name_l .. "-it"] or names[name_l .. "_it"] then
            return true
        end

        local base_no_base = name_l:gsub("[-_]base$", "")
        if base_no_base ~= name_l and names[base_no_base] then
            return true
        end
        if names[name_l .. "-base"] or names[name_l .. "_base"] then
            return false
        end

        return nil
    end

    local function get_normalized_active_profile_id()
        local profile_id = state.llm_active_profile or "basic"
        if profile_id == "parallel" or profile_id == "parallel_simple" then return "basic" end
        if profile_id == "batch" or profile_id == "batch_simple" then return "batch_advanced" end
        if profile_id == "parallel_advanced" then return "advanced" end
        if profile_id == "base_completion" then return "raw" end
        return profile_id
    end

    --- Calculates the raw power level of a model based on its size.
    local function get_model_power_level(model_name)
        if type(model_name) ~= "string" or model_name == "" then return PROFILE_POWER_BASIC end
        
        local info = models_mgr.get_model_info(model_name) or {}
        local effective_params, _, _, _ = get_effective_model_params(info)
        local inferred_completion = infer_completion_from_name_pairs(model_name)
        local is_completion_model = (inferred_completion ~= nil) and inferred_completion or (info.type == "completion")
        
        -- Power levels: raw=0, basic=1, advanced=2, batch_advanced=3
        if is_completion_model then
            return PROFILE_POWER_RAW
        elseif effective_params > 0 then
            if effective_params >= MODEL_BATCH_PARAMS_THRESHOLD_B then
                return PROFILE_POWER_BATCH_ADVANCED
            elseif effective_params >= MODEL_ADVANCED_PARAMS_THRESHOLD_B then
                return PROFILE_POWER_ADVANCED
            else
                return PROFILE_POWER_BASIC
            end
        end
        
        return PROFILE_POWER_BASIC
    end
    
    -- Resolve display model name to actual backend names on startup
    if type(state.llm_model) == "string" and state.llm_model ~= "" then
        -- Reverse-lookup: if llm_model is an actual backend name (e.g. 'gemma-4-e4b-it-mxfp4'), resolve to display name
        local presets_startup = models_mgr.get_presets()
        local display_name = state.llm_model
        if type(presets_startup) == "table" then
            for _, provider in ipairs(presets_startup) do
                for _, family in ipairs(provider.families or {}) do
                    for _, m in ipairs(family.models or {}) do
                        local m_display = m.name or m.repo
                        if type(m_display) == "string" then
                            local actual = models_mgr.get_actual_model_name(m_display)
                            if actual == state.llm_model and m_display ~= state.llm_model then
                                display_name = m_display  -- llm_model was a backend name; use its display name
                            end
                        end
                    end
                end
            end
        end
        if display_name ~= state.llm_model then
            Logger.debug(LOG, string.format("Correcting model name on startup (backend->display): '%s' -> '%s'", state.llm_model, display_name))
            state.llm_model = display_name
        end

        local actual_name = models_mgr.get_actual_model_name(display_name)
        Logger.debug(LOG, string.format("Resolving model name on startup: '%s' -> '%s'", display_name, actual_name))
        if state.llm_backend == "mlx" then
            state.llm_model_mlx = display_name
            llm_mod.set_llm_model_mlx(actual_name)
        else
            state.llm_model_ollama = display_name
            llm_mod.set_llm_model_ollama(actual_name)
        end
        -- Notify keymap of display name immediately, before regular sync overwrites it
        if type(deps.keymap) == "table" and type(deps.keymap.set_llm_display_model_name) == "function" then
            pcall(deps.keymap.set_llm_display_model_name, display_name)
        end

        -- Also cache the model power level for instant access
        state.llm_model_power = get_model_power_level(display_name)
        Logger.debug(LOG, string.format("Model power on startup: %d", state.llm_model_power))
    end
    local profiles_mgr = Profiles.new(deps, models_mgr)
    local settings_mgr = Settings.new(deps)
    local keymap       = deps.keymap
    local save_prefs   = deps.save_prefs
    local update_menu  = deps.update_menu
    local req_token    = 0

    local function guarded_check_requirements(model_name, on_ok, on_fail, opts)
        req_token = req_token + 1
        local my_token = req_token
        models_mgr.check_requirements(model_name, function(...)
            if my_token ~= req_token then
                Logger.debug(LOG, string.format("Obsolete check_requirements callback ignored (model=%s)", tostring(model_name)))
                return
            end
            if type(on_ok) == "function" then on_ok(...) end
        end, function(...)
            if my_token ~= req_token then
                Logger.debug(LOG, string.format("Obsolete check_requirements cancel ignored (model=%s)", tostring(model_name)))
                return
            end
            if type(on_fail) == "function" then on_fail(...) end
        end, opts)
    end

    if state.llm_num_predictions ~= nil and keymap and type(keymap.set_llm_num_predictions) == "function" then
        pcall(keymap.set_llm_num_predictions, state.llm_num_predictions)
    end
    if state.llm_max_words ~= nil and keymap and type(keymap.set_llm_max_words) == "function" then
        pcall(keymap.set_llm_max_words, state.llm_max_words)
    end
    if state.llm_min_words ~= nil and keymap and type(keymap.set_llm_min_words) == "function" then
        pcall(keymap.set_llm_min_words, state.llm_min_words)
    end
    if state.llm_streaming ~= nil and keymap and type(keymap.set_llm_streaming) == "function" then
        pcall(keymap.set_llm_streaming, state.llm_streaming)
    end
    if state.llm_streaming_multi ~= nil and keymap and type(keymap.set_llm_streaming_multi) == "function" then
        pcall(keymap.set_llm_streaming_multi, state.llm_streaming_multi)
    end


    -- ======================================
    -- ===== 2.1) Model Switching Logic =====
    -- ======================================

    --- Calculates the recommended profile and power level for a model.
    local function get_recommended_profile_info(model_name)
        if type(model_name) ~= "string" or model_name == "" then return "basic", PROFILE_POWER_BASIC end

        local info = models_mgr.get_model_info(model_name) or {}
        local effective_params, _, _, _ = get_effective_model_params(info)
        local inferred_completion = infer_completion_from_name_pairs(model_name)
        local is_completion_model = (inferred_completion ~= nil) and inferred_completion or (info.type == "completion")
        local rec_profile = "basic"

        if is_completion_model then
            rec_profile = "raw"
        elseif effective_params > 0 then
            if effective_params >= MODEL_BATCH_PARAMS_THRESHOLD_B then
                rec_profile = "batch_advanced"
            elseif effective_params >= MODEL_ADVANCED_PARAMS_THRESHOLD_B then
                rec_profile = "advanced"
            else
                rec_profile = "basic"
            end
        end

        return rec_profile, PROFILE_POWER_LEVELS[rec_profile] or PROFILE_POWER_BASIC
    end

    --- Gets a human-readable label for a profile.
    local function get_profile_label(profile_id)
        local current_preds = tonumber(state.llm_num_predictions) or 1
        local batch_suffix = current_preds > 1 and "s" or ""
        
        local labels = {
            raw = "○○○ Raw — Aucun prompt, juste le contexte",
            basic = "●○○ Basique — Prédiction simple",
            advanced = "●●○ Avancé — Correction + Prédiction",
            batch_advanced = string.format("●●● Batch Avancé — 1 req. avancée avec %d prédiction%s", current_preds, batch_suffix),
            parallel_simple = "●○○ Basique — Prédiction simple",
            parallel = "●○○ Basique — Prédiction simple",
            batch_simple = "●○○ Basique — Prédiction simple",
            batch = string.format("●●● Batch Avancé — 1 req. avancée avec %d prédiction%s", current_preds, batch_suffix),
            parallel_advanced = "●●○ Avancé — Correction + Prédiction",
            base_completion = "○○○ Raw — Aucun prompt, juste le contexte",
        }
        return labels[profile_id] or tostring(profile_id)
    end

    local function get_display_model_name(model_name, presets)
        if type(model_name) ~= "string" or model_name == "" then return model_name end
        presets = type(presets) == "table" and presets or models_mgr.get_presets()
        if type(presets) ~= "table" then return model_name end

        for _, provider in ipairs(presets) do
            for _, family in ipairs(provider.families or {}) do
                for _, m in ipairs(family.models or {}) do
                    local display_name = m.name or m.repo
                    if type(display_name) == "string" then
                        if display_name == model_name then return display_name end
                        local actual_name = models_mgr.get_actual_model_name(display_name)
                        if actual_name == model_name then return display_name end
                    end
                end
            end
        end

        return model_name
    end

    --- Checks if a profile is too powerful for the model and shows a non-blocking warning.
    local function check_profile_power_mismatch(selected_profile_id, model_name)
        -- Use already-calculated model power (set when model was selected)
        local model_power = tonumber(state.llm_model_power) or PROFILE_POWER_BASIC
        local selected_power = PROFILE_POWER_LEVELS[normalize_profile_power_key(selected_profile_id)] or PROFILE_POWER_BASIC

        Logger.debug(LOG, string.format("Checking profile power mismatch: selected=%d vs model=%d", selected_power, model_power))
        
        -- Only warn if selected profile is significantly more powerful than model
        if selected_power > model_power + 1 then
            local rec_profile, _ = get_recommended_profile_info(model_name)
            local rec_label = get_profile_label(rec_profile)
            local selected_label = get_profile_label(selected_profile_id)
            local msg = string.format(
                "⚠️  Profil puissant\n\n" ..
                "Recommandé:  %s\n" ..
                "Sélectionné:  %s\n\n" ..
                "Le modèle peut ne pas être assez puissant.",
                rec_label, selected_label
            )
            -- Non-blocking alert that disappears after 3 seconds
            hs.alert(msg, 3)
        end
    end

    --- Changes the active profile and checks for power mismatch warnings.
    --- @param profile_id string The profile ID to activate.
    local function set_llm_profile(profile_id)
        if type(profile_id) ~= "string" then return end
        state.llm_active_profile = profile_id
        llm_mod.set_active_profile(profile_id)
        -- Check if selected profile is too powerful for current model
        check_profile_power_mismatch(profile_id, state.llm_model)
        save_prefs(); update_menu()
    end

    deps.set_llm_profile = set_llm_profile

    local function apply_recommended_prompt_profile(model_name, opts)
        if type(model_name) ~= "string" or model_name == "" then return end
        opts = type(opts) == "table" and opts or {}
        local force_dialog = opts.force_dialog == true

        local rec_profile, _ = get_recommended_profile_info(model_name)
        local rec_label = get_profile_label(rec_profile)
        local model_info = models_mgr.get_model_info(model_name) or {}
        local inferred_completion = infer_completion_from_name_pairs(model_name)
        local is_completion_model = (inferred_completion ~= nil) and inferred_completion or (model_info.type == "completion")
        local _, is_moe, active_params, total_params = get_effective_model_params(model_info)
        local display_model_name = get_display_model_name(model_name)
        local power_desc
        if is_completion_model then
            power_desc = "Profil de puissance détecté : complétion brute"
        elseif is_moe and active_params > 0 and total_params > 0 then
            power_desc = string.format("Puissance détectée (MoE) : %gB actifs / %gB total", active_params, total_params)
        elseif active_params > 0 then
            power_desc = string.format("Puissance détectée : %gB", active_params)
        else
            power_desc = "Puissance détectée : inconnue"
        end

        local cur_profile = get_normalized_active_profile_id()
        local cur_label = get_profile_label(cur_profile)

        Logger.debug(LOG, string.format("Recommended profile: %s (currently: %s)", rec_profile, cur_profile))
        if cur_profile ~= rec_profile then
            -- Completion models have a single correct profile (no prompt wrapper at all).
            -- Silently switch without prompting the user — no ambiguity, no decision to make.
            if is_completion_model then
                Logger.info(LOG, string.format("Completion model detected: silently switching profile %s → %s.", cur_profile, rec_profile))
                state.llm_active_profile = rec_profile
                llm_mod.set_active_profile(rec_profile)
                save_prefs(); update_menu()
            else
                local title = type(opts.dialog_title) == "string" and opts.dialog_title or "Changement de modèle"
                Logger.debug(LOG, "Displaying profile suggestion dialog…")
                pcall(hs.focus)
                local msg = string.format(
                    "Modèle : %s\n%s\n\nPrompt actuel :\n%s\n\nPrompt conseillé :\n%s\n\nValider pour appliquer le prompt conseillé.",
                    display_model_name, power_desc, cur_label, rec_label
                )
                local ok, choice = pcall(hs.dialog.blockAlert, title, msg, "Valider", "Annuler", "informational")
                Logger.debug(LOG, string.format("Dialog response: %s, choice=%s", tostring(ok), tostring(choice)))
                if ok and choice == "Valider" then
                    Logger.info(LOG, string.format("Profile changed to %s (dialog accepted).", rec_profile))
                    state.llm_active_profile = rec_profile
                    llm_mod.set_active_profile(rec_profile)
                    save_prefs(); update_menu()
                else
                    Logger.info(LOG, string.format("Profile kept at %s (dialog refused).", cur_profile))
                    state.llm_active_profile = cur_profile
                    llm_mod.set_active_profile(cur_profile)
                end
            end
        elseif force_dialog then
            local title = type(opts.dialog_title) == "string" and opts.dialog_title or "Profil recommandé"
            pcall(hs.focus)
            local msg = string.format(
                "Modèle : %s\n%s\n\nPrompt actuel :\n%s\n\nPrompt conseillé :\n%s\n\nCe profil est déjà adapté à ce modèle.",
                display_model_name, power_desc, cur_label, rec_label
            )
            pcall(hs.dialog.blockAlert, title, msg, "Valider", "Annuler", "informational")
        else
            Logger.debug(LOG, "Recommended profile is already the current profile.")
        end
    end

    deps.apply_recommended_prompt_profile = function(opts)
        apply_recommended_prompt_profile(state.llm_model, opts)
    end

    local function switch_model(new_model)
        Logger.debug(LOG, string.format("Executing switch_model('%s')…", new_model or "nil"))

        -- For MLX backend, lock predictions while the server restarts — the old process
        -- is killed immediately but weights can take 60–90 s to reload. Without the lock
        -- every debounced request fires against a dead port, the user sees no feedback,
        -- and repeated silent failures make the switch appear broken.
        local mlx_was_enabled = state.llm_backend == "mlx" and state.llm_enabled
        if mlx_was_enabled and keymap and type(keymap.set_llm_enabled) == "function" then
            Logger.debug(LOG, "MLX model switch: locking predictions during server restart.")
            pcall(keymap.set_llm_enabled, false)
        end

        local function unlock_predictions()
            if mlx_was_enabled and keymap and type(keymap.set_llm_enabled) == "function" then
                Logger.debug(LOG, "MLX model switch: predictions unlocked.")
                pcall(keymap.set_llm_enabled, true)
            end
        end

        guarded_check_requirements(new_model, function()
            Logger.info(LOG, string.format("Model successfully switched to %s.", new_model))
            state.llm_model = new_model

            -- Calculate and store model power level for instant access
            local model_power = get_model_power_level(new_model)
            state.llm_model_power = model_power
            Logger.debug(LOG, string.format("Model power cached: %d", model_power))

            -- Resolve display name to actual backend model name and persist per backend
            local actual_backend_name = models_mgr.get_actual_model_name(new_model)
            if state.llm_backend == "mlx" then
                state.llm_model_mlx = new_model
                llm_mod.set_llm_model_mlx(actual_backend_name)
                Logger.debug(LOG, string.format("Actual MLX model: %s -> %s", new_model, actual_backend_name))
            else
                state.llm_model_ollama = new_model
                llm_mod.set_llm_model_ollama(actual_backend_name)
                Logger.debug(LOG, string.format("Actual Ollama model: %s -> %s", new_model, actual_backend_name))
            end

            if keymap and type(keymap.set_llm_model) == "function" then
                local ok = pcall(keymap.set_llm_model, actual_backend_name)
                Logger.debug(LOG, string.format("keymap.set_llm_model() execution -> %s", tostring(ok)))
            else
                Logger.warn(LOG, "keymap.set_llm_model is unavailable.")
            end

            if keymap and type(keymap.set_llm_display_model_name) == "function" then
                pcall(keymap.set_llm_display_model_name, new_model)
            end

            -- Always persist and refresh the menu so the active model is visible immediately
            save_prefs(); update_menu()
            unlock_predictions()
            apply_recommended_prompt_profile(new_model, { dialog_title = "Changement de modèle" })
        end, function()
            -- Requirements check failed (model not installed, cancelled, etc.) — restore
            -- predictions with the previously running model so the user is not left stranded
            Logger.warn(LOG, string.format("switch_model('%s') failed — restoring predictions.", tostring(new_model)))
            unlock_predictions()
        end)
    end



    -- ======================================
    -- ===== 2.2) Dynamic Menu Builders =====
    -- ======================================

    local function build_models_selection()
        Logger.debug(LOG, "Building models selection menu…")
        local menu = {}
        local installed = models_mgr.get_installed_models()
        Logger.debug(LOG, string.format("Installed models detected: %d", installed and (function() local c=0 for _ in pairs(installed) do c=c+1 end return c end)() or 0))
        local presets = models_mgr.get_presets()
        local active_backend = state.llm_backend
        local active_display_model = get_display_model_name(state.llm_model, presets)

        local config_file = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
        config_file = config_file:match("^(.*)/ui/") or "./"
        config_file = config_file .. "config.json"
        local has_hf_token = false
        
        local fh = io.open(config_file, "r")
        if fh then
            local raw = fh:read("*a"); fh:close()
            local ok, cfg = pcall(hs.json.decode, raw)
            if ok and type(cfg) == "table" and type(cfg.hf_token) == "string" and cfg.hf_token ~= "" then
                has_hf_token = true
            end
        end

        table.insert(menu, {
            title   = "Aucun modèle (Désactivé)",
            checked = (not state.llm_model or state.llm_model == ""),
            fn      = function() 
                Logger.info(LOG, "Switching model to None (disabled).")
                state.llm_model = ""
                if keymap and type(keymap.set_llm_model) == "function" then 
                    local ok = pcall(keymap.set_llm_model, "")
                    Logger.debug(LOG, string.format("keymap.set_llm_model('') execution -> %s", tostring(ok)))
                end
                save_prefs(); update_menu()
            end
        })

        -- Reset to backend-specific default model
        local backend_default_raw = (active_backend == "mlx") and M.DEFAULT_STATE.llm_model_mlx or M.DEFAULT_STATE.llm_model_ollama
        local backend_default = get_display_model_name(backend_default_raw, presets)
        if backend_default and backend_default ~= "" then
            table.insert(menu, {
                title   = "↺ Modèle par défaut du backend (" .. backend_default .. ")",
                checked = (active_display_model == backend_default),
                fn      = function()
                    Logger.info(LOG, string.format("Restoring backend default model -> %s", backend_default))
                    switch_model(backend_default)
                end
            })
        end

        -- Only show HuggingFace token when using a backend that downloads from HuggingFace
        if active_backend == "mlx" then
            local token_status = has_hf_token and "✅ Configuré" or "❌ Non configuré"
            table.insert(menu, {
                title = "🔑 Token HuggingFace : " .. token_status,
                fn = function()
                    if models_mgr and type(models_mgr.prompt_hf_login) == "function" then
                        models_mgr.prompt_hf_login(function()
                            save_prefs(); update_menu()
                        end)
                    end
                end
            })
        end

        table.insert(menu, { title = "-" })

        for _, provider in ipairs(presets) do
            local sub = {}
            for _, family in ipairs(provider.families or {}) do
                local family_sub = {}
                for _, m in ipairs(family.models or {}) do
                    local m_name = m.name or m.repo or "Inconnu"
                    local info = models_mgr.get_model_info(m_name) or {}
                    local ram = models_mgr.get_model_ram(m_name) or 0
                    local is_inst = models_mgr.is_model_installed(m_name)
                    
                    local prefix = (active_display_model == m_name) and "✓ " or "  "
                    local status = is_inst and "🟢 " or ""
                    local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
                    local params_ram_str = (info.params and info.params > 0)
                        and string.format(" (%gB params, ~%d Go RAM)", math.ceil(info.params * 10) / 10, math.ceil(ram))
                        or string.format(" (~%d Go RAM)", math.ceil(ram))
                    local title = string.format("%s%s%s%s%s", prefix, status, m_name, type_str, params_ram_str)

                    local hw = m.hardware_requirements or {}
                    local hw_active = hw[active_backend] or {}
                    local display_backend = (active_backend == "mlx") and "MLX" or "Ollama"
                    local active_source = m.urls and m.urls[active_backend]
                    local has_active_source = (type(active_source) == "string" and active_source ~= "")

                    if not has_active_source then
                        goto continue_model
                    end

                    local model_submenu = {}

                    table.insert(model_submenu, {
                        title   = "👉 Sélectionner ce modèle",
                        checked = (active_display_model == m_name),
                        fn      = function() switch_model(m_name) end
                    })

                    if is_inst then
                        table.insert(model_submenu, {
                            title = "🗑️ Supprimer ce modèle du cache",
                            fn = function()
                                local ok, choice = pcall(hs.dialog.blockAlert, "Supprimer le modèle ?", "Voulez-vous vraiment supprimer le modèle \"" .. m_name .. "\" du cache local ?", "Supprimer", "Annuler", "warning")
                                if ok and choice == "Supprimer" then
                                    models_mgr.delete_model(m_name)
                                end
                            end
                        })
                    end

                    table.insert(model_submenu, { title = "-" })

                    table.insert(model_submenu, { title = "Backend : " .. display_backend, fn = function() end })

                    table.insert(model_submenu, {
                        title = "Source : " .. active_source,
                        fn = function()
                            pcall(hs.urlevent.openURL, active_source)
                        end
                    })

                    table.insert(model_submenu, { title = "-" })
                    table.insert(model_submenu, { title = "— SPÉCIFICATIONS —", disabled = true })
                    
                    local m_type = m.type or info.type or "Inconnu"
                    local type_label = (m_type == "completion") and "📝 Complétion" or "💬 Chat"
                    table.insert(model_submenu, { title = "Type : " .. type_label, fn = function() end })
                    
                    if m.last_updated and m.last_updated ~= "Unknown" then
                        local y, mo, d = m.last_updated:match("^(%d+)%-(%d+)%-(%d+)$")
                        local formatted_date = (y and mo and d) and (d .. "/" .. mo .. "/" .. y) or m.last_updated
                        table.insert(model_submenu, { title = "Date de mise à jour : " .. formatted_date, fn = function() end })
                    end

                    if m.parameters then
                        if m.parameters.total and m.parameters.total ~= "N/A" then table.insert(model_submenu, { title = "Paramètres (Total) : " .. m.parameters.total, fn = function() end }) end
                        if m.parameters.active and m.parameters.active ~= "N/A" then table.insert(model_submenu, { title = "Paramètres (Actifs) : " .. m.parameters.active, fn = function() end }) end
                    end

                    if m.capabilities then
                        table.insert(model_submenu, { title = "-" })
                        table.insert(model_submenu, { title = "— CAPACITÉS —", disabled = true })
                        if m.capabilities.speed_tok_s then table.insert(model_submenu, { title = "Vitesse estimée : " .. m.capabilities.speed_tok_s .. " tok/s", fn = function() end }) end
                        local tags = m.capabilities.tags
                        if tags and type(tags) == "table" and #tags > 0 then
                            table.insert(model_submenu, { title = "Tags : " .. table.concat(tags, ", "), fn = function() end })
                        end
                    end

                    if hw_active.download_gb or hw_active.disk_gb or hw_active.ram_gb then
                        table.insert(model_submenu, { title = "-" })
                        table.insert(model_submenu, { title = "— CONFIGURATION REQUISE (" .. display_backend .. ") —", disabled = true })
                        if hw_active.download_gb then table.insert(model_submenu, { title = "Téléchargement : " .. hw_active.download_gb .. " Go", fn = function() end }) end
                        if hw_active.disk_gb then table.insert(model_submenu, { title = "Espace disque : " .. hw_active.disk_gb .. " Go", fn = function() end }) end
                        if hw_active.ram_gb then table.insert(model_submenu, { title = "Mémoire (RAM) : " .. hw_active.ram_gb .. " Go", fn = function() end }) end
                    end

                    table.insert(family_sub, {
                        title   = title,
                        menu    = model_submenu,
                        fn      = function()
                            -- clicking the model title selects it and triggers the same flow
                            pcall(function() switch_model(m_name) end)
                        end
                    })

                    ::continue_model::
                end

                if #family_sub > 0 then
                    if #sub > 0 then table.insert(sub, { title = "-" }) end
                    for _, model_entry in ipairs(family_sub) do
                        table.insert(sub, model_entry)
                    end
                end
            end
            if #sub > 0 then
                table.insert(menu, { title = provider.label, menu = sub })
            end
        end

        return menu
    end

    local function build_num_pred_menu()
        Logger.debug(LOG, "Building prediction count menu…")
        local m = {}
        for i = 1, 10 do
            table.insert(m, {
                title   = i .. " suggestion" .. (i > 1 and "s" or ""),
                checked = (state.llm_num_predictions == i),
                fn      = function()
                    Logger.info(LOG, string.format("Changing number of predictions -> %d", i))
                    state.llm_num_predictions = i
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then 
                        local ok = pcall(keymap.set_llm_num_predictions, i)
                        Logger.debug(LOG, string.format("keymap.set_llm_num_predictions(%d) execution -> %s", i, tostring(ok)))
                    else
                        Logger.warn(LOG, "keymap.set_llm_num_predictions is unavailable.")
                    end
                    save_prefs(); update_menu()
                end
            })
        end
        return m
    end



    -- =====================================
    -- ===== 2.3) Hotkeys & Triggers =======
    -- =====================================

    local _llm_trigger_hk = nil
    local _llm_profile_hks = {}
    local _startup_silence = false

    local function bind_hotkey(mods, key, callback)
        Logger.debug(LOG, string.format("Attempting hotkey bind: mods=%s, key=%s",
            type(mods) == "table" and table.concat(mods, "+") or tostring(mods),
            key or "nil"))
        local ok, hk = pcall(hs.hotkey.new, mods, key, callback)
        if ok and hk then
            Logger.debug(LOG, string.format("Hotkey created successfully: %s+%s",
                type(mods) == "table" and table.concat(mods, "+") or "", key or ""))
            return hk
        else
            Logger.error(LOG, string.format("Hotkey binding failed: ok=%s, err=%s", tostring(ok), tostring(hk)))
            return nil
        end
    end
    
    local function activate_hotkey(hk)
        if hk and type(hk.enable) == "function" then
            pcall(function() hk:enable() end)
            return true
        end
        return false
    end

    local function trigger_prediction_with_profile(profile_id)
        if type(profile_id) ~= "string" or profile_id == "" then 
            Logger.warn(LOG, string.format("trigger_prediction_with_profile: invalid profile_id: %s", tostring(profile_id)))
            return 
        end
        if not keymap or type(keymap.trigger_prediction) ~= "function" then 
            Logger.error(LOG, "trigger_prediction_with_profile: keymap or trigger_prediction is unavailable.")
            return 
        end

        Logger.debug(LOG, string.format("Triggering prediction with profile '%s'", profile_id))
        
        if type(keymap.reset_predictions) == "function" then
            pcall(keymap.reset_predictions)
            Logger.debug(LOG, "Active predictions cancelled before profile trigger.")
        end
        
        local previous_profile = state.llm_active_profile or "basic"
        Logger.debug(LOG, string.format("Changing profile: %s -> %s", previous_profile, profile_id))
        
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
        pcall(keymap.trigger_prediction, true, profile_label)
        llm_mod.set_active_profile(previous_profile)
        
        Logger.debug(LOG, string.format("Profile restored: %s", previous_profile))
    end

    local function apply_llm_shortcut(mods, key)
        if _llm_trigger_hk then pcall(function() _llm_trigger_hk:delete() end); _llm_trigger_hk = nil end

        local normalized = shortcut_ui.normalize_shortcut(mods, key, {"ctrl"})
        if normalized then
            state.llm_trigger_shortcut = { mods = normalized.mods, key = normalized.key }
            _llm_trigger_hk = bind_hotkey(normalized.mods, normalized.key, function()
                if keymap and type(keymap.trigger_prediction) == "function" then pcall(keymap.trigger_prediction, true) end
            end)
            if _llm_trigger_hk and not _startup_silence then activate_hotkey(_llm_trigger_hk) end
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
        Logger.debug(LOG, string.format("apply_llm_profile_shortcut('%s', mods=%s, key=%s) -> normalized=%s",
            profile_id,
            type(mods) == "table" and table.concat(mods, "+") or tostring(mods),
            key or "nil",
            normalized and (table.concat(normalized.mods, "+") .. "+" .. normalized.key) or "nil"))
        
        if normalized then
            state.llm_profile_shortcuts[profile_id] = { mods = normalized.mods, key = normalized.key }
            local hk = bind_hotkey(normalized.mods, normalized.key, function()
                Logger.debug(LOG, string.format("Profile shortcut triggered: '%s'", profile_id))
                trigger_prediction_with_profile(profile_id)
            end)
            if hk and not (type(opts) == "table" and opts.silent == true) then activate_hotkey(hk) end
            _llm_profile_hks[profile_id] = hk
            if hk then
                Logger.debug(LOG, string.format("Shortcut bound successfully for profile '%s'", profile_id))
            else
                Logger.error(LOG, string.format("Shortcut binding failed for profile '%s'", profile_id))
            end
        else
            state.llm_profile_shortcuts[profile_id] = nil
            Logger.debug(LOG, string.format("Shortcut disabled for profile '%s'", profile_id))
        end

        if not (type(opts) == "table" and opts.silent == true) then
            save_prefs(); update_menu()
        end
    end

    deps.apply_llm_profile_shortcut = apply_llm_profile_shortcut

    profiles_mgr = Profiles.new(deps, models_mgr)



    -- =========================================
    -- ===== 2.4) Lifecycle & Main Build =======
    -- =========================================

    local check_startup
    local _check_startup_attempts = nil

    local function build_item()
        Logger.debug(LOG, "Building LLM menu item (build_item)…")
        local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
        local is_disabled = (not state.llm_enabled) or paused
        Logger.debug(LOG, string.format("Menu state: paused=%s, llm_enabled=%s, is_disabled=%s", tostring(paused), tostring(state.llm_enabled), tostring(is_disabled)))
        local main_menu = {}

        -- When a download is running, offer a shortcut to bring the progress window back into view.
        -- The window is easy to lose across Spaces; this item avoids having to hunt for it.
        local _dl_active = deps.active_tasks and (deps.active_tasks["download"] or deps.active_tasks["download_tail"] or deps.active_tasks["install"])
        if _dl_active then
            local _dw = package.loaded["ui.download_window"]
            table.insert(main_menu, {
                title = "📥 Téléchargement en cours — Afficher la fenêtre",
                fn = function()
                    if _dw and type(_dw.focus) == "function" then
                        pcall(_dw.focus)
                    elseif _dw and type(_dw.is_active) == "function" and not _dw.is_active() then
                        -- Window was closed without cancelling — re-open it (no-op, just notify)
                        pcall(notifications.notify, "Fenêtre de téléchargement introuvable", "Le téléchargement est toujours en cours en arrière-plan.")
                    end
                end
            })
            table.insert(main_menu, { title = "-" })
        end

        local backend_title_str = "Moteur IA (Backend) : "
        if state.llm_backend == "mlx" then backend_title_str = backend_title_str .. "MLX 🚀"
        elseif state.llm_backend == "ollama" then backend_title_str = backend_title_str .. "Ollama 🦙"
        else backend_title_str = backend_title_str .. "Inconnu" end

        local backend_title = backend_title_str
        local backend_menu = {}

        table.insert(backend_menu, {
            title    = "MLX 🚀 — Recommandé (natif Mac, ultra-rapide)",
            checked  = (state.llm_backend == "mlx"),
            disabled = (not is_apple_silicon) or paused or nil,
            fn       = not paused and function()
                if state.llm_backend ~= "mlx" then
                    Logger.info(LOG, "Activating MLX backend…")
                    state.llm_backend = "mlx"
                    llm_mod.set_backend("mlx")

                    if keymap and type(keymap.set_llm_backend_name) == "function" then
                        pcall(keymap.set_llm_backend_name, "MLX 🚀")
                    end

                    -- Kill any stray ollama to free RAM
                    os.execute("pkill -f '[o]llama serve' 2>/dev/null || true")

                    local target_model = get_display_model_name(state.llm_model_mlx or M.DEFAULT_STATE.llm_model_mlx or "")
                    if target_model and target_model ~= "" then
                        switch_model(target_model)
                        -- Force server to start to be certain
                        if type(models_mgr.force_mlx_check) == "function" then
                            hs.timer.doAfter(0.5, function()
                                models_mgr.force_mlx_check(target_model, nil, nil, { silent_notifications = true })
                            end)
                        end
                    else
                        state.llm_model = ""
                        if keymap and type(keymap.set_llm_model) == "function" then
                            pcall(keymap.set_llm_model, "")
                        end
                        if keymap and type(keymap.set_llm_display_model_name) == "function" then
                            pcall(keymap.set_llm_display_model_name, "")
                        end
                        save_prefs()
                        update_menu()
                    end
                end
            end or nil
        })

        table.insert(backend_menu, {
            title    = "Ollama 🦙 — Standard (idéal si MLX est indisponible)",
            checked  = (state.llm_backend == "ollama"),
            disabled = paused or nil,
            fn       = not paused and function()
                if state.llm_backend ~= "ollama" then
                    Logger.info(LOG, "Deactivating MLX backend (switching to Ollama)…")
                    state.llm_backend = "ollama"
                    llm_mod.set_backend("ollama")
                    if models_mgr.stop_mlx_server_if_needed then models_mgr.stop_mlx_server_if_needed() end
                    -- Hard kill just in case
                    os.execute("pids=$(lsof -tiTCP:8080 -sTCP:LISTEN 2>/dev/null); [ -n \"$pids\" ] && kill -9 $pids 2>/dev/null")
                    Logger.debug(LOG, "MLX server stopped.")

                    if keymap and type(keymap.set_llm_backend_name) == "function" then
                        pcall(keymap.set_llm_backend_name, "Ollama 🦙")
                    end

                    local target_model = get_display_model_name(state.llm_model_ollama or M.DEFAULT_STATE.llm_model_ollama or "")
                    if target_model and target_model ~= "" then
                        switch_model(target_model)
                    else
                        state.llm_model = ""
                        if keymap and type(keymap.set_llm_model) == "function" then
                            pcall(keymap.set_llm_model, "")
                        end
                        if keymap and type(keymap.set_llm_display_model_name) == "function" then
                            pcall(keymap.set_llm_display_model_name, "")
                        end
                        save_prefs()
                        update_menu()
                    end
                end
            end or nil
        })

        table.insert(main_menu, {
            title    = backend_title,
            disabled = paused or nil,
            menu     = backend_menu
        })

        local active_display_model = get_display_model_name(state.llm_model)
        local info = models_mgr.get_model_info(active_display_model) or {}
        local ram = models_mgr.get_model_ram(active_display_model) or 0
        local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
        local params_ram_str = (info.params and info.params > 0)
            and string.format(" (%gB params, ~%d Go RAM)", info.params, math.ceil(ram))
            or string.format(" (~%d Go RAM)", math.ceil(ram))
        
        -- Trigger a fresh async probe on every menu open so the indicator stays accurate.
        -- The result arrives after the menu is shown; the next open will display it.
        if state.llm_enabled and not paused then
            probe_llm_health(state.llm_backend or "mlx", update_menu)
        end

        -- Health indicator: shown only when the feature is enabled.
        -- 🟢 = server responded to last probe, 🔴 = unreachable or not yet checked.
        local health_dot
        if not state.llm_enabled or paused then
            health_dot = ""
        elseif _llm_health_status == true then
            health_dot = "🟢 "
        else
            health_dot = "🔴 "
        end

        local rich_model_title = health_dot .. "Modèle actif : "
        if not state.llm_model or state.llm_model == "" then
            rich_model_title = rich_model_title .. "Aucun"
        else
            rich_model_title = rich_model_title .. string.format("%s%s%s", active_display_model, type_str, params_ram_str)
        end

        table.insert(main_menu, {
            title    = rich_model_title,
            disabled = paused or nil,
            menu     = build_models_selection()
        })

        if info and info.emojis and info.emojis:find("🧠💭") then
            table.insert(main_menu, { title = "  ↳ Info : Modèle thinking (réflexion masquée)", disabled = true })
        end

        table.insert(main_menu, { title = "-" })

        local profiles_item = profiles_mgr.get_menu_item()
        profiles_item.disabled = is_disabled or nil
        table.insert(main_menu, profiles_item)

        table.insert(main_menu, { title = "Nombre de suggestions : " .. tostring(state.llm_num_predictions or 1), disabled = is_disabled or nil, menu = build_num_pred_menu() })
        if state.llm_num_predictions ~= llm_mod.DEFAULT_STATE.llm_num_predictions then
            table.insert(main_menu, {
                title    = "  ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_num_predictions) .. ")",
                disabled = is_disabled or nil,
                fn       = function()
                    state.llm_num_predictions = llm_mod.DEFAULT_STATE.llm_num_predictions
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then pcall(keymap.set_llm_num_predictions, state.llm_num_predictions) end
                    save_prefs(); update_menu()
                end
            })
        end

        table.insert(main_menu, { title = "-" })


        -- ===== Trigger submenu =====

        local trigger_menu = {}

        local sc_label = shortcut_ui.shortcut_to_label(state.llm_trigger_shortcut, "Aucun")
        table.insert(trigger_menu, {
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

        local debounce_val = tonumber(state.llm_debounce) or llm_mod.DEFAULT_STATE.llm_debounce or 0.5
        local debounce_display = (debounce_val <= 0) and "Jamais" or (math.floor(debounce_val * 1000) .. " ms…")

        table.insert(trigger_menu, { title = "Temps d’inactivité avant suggestion : " .. debounce_display, disabled = is_disabled or nil, fn = settings_mgr.set_debounce })
        if state.llm_debounce ~= llm_mod.DEFAULT_STATE.llm_debounce then
            table.insert(trigger_menu, { title = "  ↳ Réinitialiser (défaut : " .. math.floor((llm_mod.DEFAULT_STATE.llm_debounce or 0.5) * 1000) .. " ms)", disabled = is_disabled or nil, fn = settings_mgr.reset_debounce })
        end

        table.insert(trigger_menu, {
            title    = "Suggestion instantanée en fin de mot",
            checked  = state.llm_instant_on_word_end,
            disabled = is_disabled or nil,
            fn       = not is_disabled and function()
                state.llm_instant_on_word_end = not state.llm_instant_on_word_end
                if keymap and type(keymap.set_llm_instant_on_word_end) == "function" then
                    pcall(keymap.set_llm_instant_on_word_end, state.llm_instant_on_word_end)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(trigger_menu, {
            title    = "Suggestion après expiration d’une bulle hotstring",
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

        table.insert(trigger_menu, { title = "-" })

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

        table.insert(trigger_menu, {
            title    = "Désactiver dans les barres d’adresse des navigateurs",
            checked  = state.llm_url_bar_filter_enabled,
            disabled = is_disabled or nil,
            fn       = not is_disabled and function()
                state.llm_url_bar_filter_enabled = not state.llm_url_bar_filter_enabled
                if keymap and type(keymap.set_llm_url_bar_filter_enabled) == "function" then
                    pcall(keymap.set_llm_url_bar_filter_enabled, state.llm_url_bar_filter_enabled)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(trigger_menu, {
            title    = "Désactiver dans les champs mot de passe",
            checked  = state.llm_secure_field_filter_enabled,
            disabled = is_disabled or nil,
            fn       = not is_disabled and function()
                state.llm_secure_field_filter_enabled = not state.llm_secure_field_filter_enabled
                if keymap and type(keymap.set_llm_secure_field_filter_enabled) == "function" then
                    pcall(keymap.set_llm_secure_field_filter_enabled, state.llm_secure_field_filter_enabled)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(trigger_menu, { title = disabled_label, disabled = is_disabled or nil, menu = exclusion_menu })

        table.insert(main_menu, { title = "Déclenchement de l’IA", disabled = is_disabled or nil, menu = trigger_menu })


        -- ===== Generation settings submenu =====

        local generation_menu = {}

        table.insert(generation_menu, { title = "Taille du contexte : " .. tostring(state.llm_context_length) .. " derniers caractères", disabled = is_disabled or nil, fn = settings_mgr.set_context_length })
        if state.llm_context_length ~= llm_mod.DEFAULT_STATE.llm_context_length then
            table.insert(generation_menu, { title = "  ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_context_length) .. ")", disabled = is_disabled or nil, fn = settings_mgr.reset_context_length })
        end

        table.insert(generation_menu, {
            title    = "Vider le contexte sur clic/navigation",
            checked  = state.llm_reset_on_nav,
            disabled = is_disabled or nil,
            fn       = function()
                state.llm_reset_on_nav = not state.llm_reset_on_nav
                if keymap and type(keymap.set_llm_reset_on_nav) == "function" then pcall(keymap.set_llm_reset_on_nav, state.llm_reset_on_nav) end
                save_prefs(); update_menu()
            end
        })

        local min_words_display = (state.llm_min_words and state.llm_min_words > 0) and tostring(state.llm_min_words) or "1"
        table.insert(generation_menu, { title = "Mots min par suggestion : " .. min_words_display, disabled = is_disabled or nil, fn = settings_mgr.set_min_words })
        if state.llm_min_words ~= llm_mod.DEFAULT_STATE.llm_min_words then
            table.insert(generation_menu, { title = "  ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_min_words) .. ")", disabled = is_disabled or nil, fn = settings_mgr.reset_min_words })
        end

        local max_words_display = (state.llm_max_words and state.llm_max_words > 0) and tostring(state.llm_max_words) or "Illimité"
        table.insert(generation_menu, { title = "Mots max par suggestion : " .. max_words_display, disabled = is_disabled or nil, fn = settings_mgr.set_max_words })
        if state.llm_max_words ~= llm_mod.DEFAULT_STATE.llm_max_words then
            local def_w_disp = (llm_mod.DEFAULT_STATE.llm_max_words and llm_mod.DEFAULT_STATE.llm_max_words > 0) and tostring(llm_mod.DEFAULT_STATE.llm_max_words) or "Illimité"
            table.insert(generation_menu, { title = "  ↳ Réinitialiser (défaut : " .. def_w_disp .. ")", disabled = is_disabled or nil, fn = settings_mgr.reset_max_words })
        end

        table.insert(generation_menu, { title = "Température (Créativité) : " .. tostring(state.llm_temperature), disabled = is_disabled or nil, fn = settings_mgr.set_temperature })
        if state.llm_temperature ~= llm_mod.DEFAULT_STATE.llm_temperature then
            table.insert(generation_menu, { title = "  ↳ Réinitialiser (défaut : " .. tostring(llm_mod.DEFAULT_STATE.llm_temperature) .. ")", disabled = is_disabled or nil, fn = settings_mgr.reset_temperature })
        end
        table.insert(generation_menu, {
            title    = "  ↳ Hausser la temp. automatiquement (+0.1 par suggestion)",
            checked  = state.llm_auto_raise_temp,
            disabled = (is_disabled or (tonumber(state.llm_num_predictions) or 1) < 2) or nil,
            fn       = function()
                state.llm_auto_raise_temp = not state.llm_auto_raise_temp
                if keymap and type(keymap.set_llm_auto_raise_temp) == "function" then
                    pcall(keymap.set_llm_auto_raise_temp, state.llm_auto_raise_temp)
                end
                save_prefs(); update_menu()
            end
        })

        table.insert(main_menu, { title = "Paramètres de génération", disabled = is_disabled or nil, menu = generation_menu })


        -- ===== Display submenu =====

        local display_menu = {}

        local num_preds_safe = tonumber(state.llm_num_predictions) or 1
        table.insert(display_menu, {
            title    = "Indentation de la suggestion sélectionnée",
            disabled = (is_disabled or num_preds_safe < 2) or nil,
            menu     = settings_mgr.build_indent_menu()
        })

        table.insert(display_menu, {
            title    = "Afficher la barre d’info (modèle et latence)",
            checked  = state.llm_show_info_bar,
            disabled = is_disabled or nil,
            fn       = function()
                state.llm_show_info_bar = not state.llm_show_info_bar
                if keymap and type(keymap.set_llm_show_info_bar) == "function" then pcall(keymap.set_llm_show_info_bar, state.llm_show_info_bar) end
                save_prefs(); update_menu()
            end
        })

        -- Streaming flags are nil-safe: old configs without these keys default to false
        local streaming_on       = (state.llm_streaming == true)
        local streaming_multi_on = (state.llm_streaming_multi == true)  -- true = show predictions as they arrive (progressive/parallel)
        local num_preds_multi    = tonumber(state.llm_num_predictions) or 1
        table.insert(display_menu, {
            title    = "Afficher chaque suggestion en streaming (token par token)",
            checked  = streaming_on,
            disabled = (is_disabled or not streaming_multi_on) or nil,
            fn       = not is_disabled and function()
                state.llm_streaming = not streaming_on
                if keymap and type(keymap.set_llm_streaming) == "function" then
                    pcall(keymap.set_llm_streaming, state.llm_streaming)
                end
                save_prefs(); update_menu()
            end or nil,
        })
        table.insert(display_menu, {
            -- Independent of token streaming; only irrelevant when num_predictions < 2
            title    = "Afficher toutes les suggestions d’un coup (multi-prédictions)",
            checked  = not streaming_multi_on,
            disabled = (is_disabled or num_preds_multi < 2) or nil,
            fn       = (not is_disabled and num_preds_multi >= 2) and function()
                state.llm_streaming_multi = not streaming_multi_on
                if keymap and type(keymap.set_llm_streaming_multi) == "function" then
                    pcall(keymap.set_llm_streaming_multi, state.llm_streaming_multi)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(main_menu, { title = "Affichage", disabled = is_disabled or nil, menu = display_menu })


        -- ===== Navigation submenu =====

        local nav_menu_items = {}

        local nav_mods = hs.settings.get("llm_nav_modifiers")
        if nav_mods == nil then nav_mods = llm_mod.DEFAULT_STATE.llm_nav_modifiers end
        if keymap and type(keymap.set_llm_nav_modifiers) == "function" then pcall(keymap.set_llm_nav_modifiers, nav_mods) end

        local val_mods = hs.settings.get("llm_val_modifiers")
        if val_mods == nil then val_mods = llm_mod.DEFAULT_STATE.llm_val_modifiers end
        if keymap and type(keymap.set_llm_val_modifiers) == "function" then pcall(keymap.set_llm_val_modifiers, val_mods) end

        local num_preds_safe = tonumber(state.llm_num_predictions) or 1
        local nav_title = format_shortcut_title("Naviguer dans les suggestions (↑/← et ↓/→)", nav_mods, "Flèches seules", "Flèches")
        table.insert(nav_menu_items, {
            title    = nav_title,
            disabled = (is_disabled or num_preds_safe < 2) or nil,
            menu     = settings_mgr.build_nav_modifier_menu()
        })

        local val_title = format_shortcut_title("Sélectionner la suggestion n° (" .. ((num_preds_safe == 10) and "1-0" or ("1-" .. num_preds_safe)) .. ")", val_mods, "Chiffres seuls", "Chiffres")
        table.insert(nav_menu_items, {
            title    = val_title,
            disabled = (is_disabled or num_preds_safe < 2) or nil,
            menu     = settings_mgr.build_val_modifier_menu()
        })

        table.insert(main_menu, { title = "Navigation", disabled = is_disabled or nil, menu = nav_menu_items })

        return {
            title   = "Intelligence Artificielle ✨",
            checked = (state.llm_enabled and not paused) or nil,
            fn      = not paused and function()
                local function toggle_state()
                    Logger.info(LOG, string.format("Toggling LLM: %s -> %s", tostring(state.llm_enabled), tostring(not state.llm_enabled)))
                    state.llm_enabled = not state.llm_enabled
                    if keymap and type(keymap.set_llm_enabled) == "function" then 
                        local ok = pcall(keymap.set_llm_enabled, state.llm_enabled)
                        Logger.debug(LOG, string.format("keymap.set_llm_enabled(%s) execution -> %s", tostring(state.llm_enabled), tostring(ok)))
                    else
                        Logger.warn(LOG, "keymap.set_llm_enabled is unavailable.")
                    end
                    save_prefs(); update_menu()
                    pcall(function() hs.notify.new({title = state.llm_enabled and "🟢 ACTIVÉ" or "🔴 DÉSACTIVÉ", informativeText = "Suggestions IA"}):send() end)
                end

                if not state.llm_enabled then
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
        Logger.info(LOG, "═══════════════ Starting menu_llm ═══════════════")
        
        _startup_silence = true
        
        if type(state.llm_trigger_shortcut) == "table" then
            Logger.debug(LOG, string.format("Restoring trigger shortcut: %s+%s",
                table.concat(state.llm_trigger_shortcut.mods or {}, "+"),
                state.llm_trigger_shortcut.key or "nil"))
            apply_llm_shortcut(state.llm_trigger_shortcut.mods, state.llm_trigger_shortcut.key)
        else
            Logger.debug(LOG, "No global trigger shortcut configured.")
        end

        local valid_profile_ids = {}
        local builtin_count = 0
        for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
            if type(profile) == "table" and type(profile.id) == "string" then
                valid_profile_ids[profile.id] = true
                builtin_count = builtin_count + 1
            end
        end
        Logger.debug(LOG, string.format("Built-in profiles loaded: %d", builtin_count))
        
        local user_count = 0
        for _, profile in ipairs(type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}) do
            if type(profile) == "table" and type(profile.id) == "string" then
                valid_profile_ids[profile.id] = true
                user_count = user_count + 1
            end
        end
        Logger.debug(LOG, string.format("User profiles loaded: %d", user_count))

        local profile_shortcuts = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts or {}
        local sc_count = 0
        for _ in pairs(profile_shortcuts) do sc_count = sc_count + 1 end
        Logger.info(LOG, string.format("Profile shortcuts loaded: %d entries", sc_count))
        
        for profile_id, sc in pairs(profile_shortcuts) do
            local mods_str = (type(sc) == "table" and type(sc.mods) == "table") and table.concat(sc.mods, "+") or "nil"
            local key_str = (type(sc) == "table" and type(sc.key) == "string") and sc.key or "nil"
            Logger.debug(LOG, string.format("Profile '%s': mods=%s, key=%s", profile_id, mods_str, key_str))
            
            if valid_profile_ids[profile_id] and type(sc) == "table" then
                Logger.debug(LOG, string.format("Binding shortcut for profile '%s' on startup.", profile_id))
                apply_llm_profile_shortcut(profile_id, sc.mods, sc.key, { silent = true })
            else
                Logger.warn(LOG, string.format("Removing invalid shortcut for profile '%s'.", profile_id))
                apply_llm_profile_shortcut(profile_id, nil, nil, { silent = true })
            end
        end

        Logger.debug(LOG, "Activating bound hotkeys…")
        if _llm_trigger_hk then activate_hotkey(_llm_trigger_hk) end
        for _, hk in pairs(_llm_profile_hks) do
            if hk then activate_hotkey(hk) end
        end
        
        _startup_silence = false

        if not state.llm_enabled then 
            Logger.debug(LOG, "LLM disabled at startup.")
            return 
        end
        
        Logger.info(LOG, string.format("LLM enabled at startup, model: %s", state.llm_model or "nil"))
        
        local function disable_llm()
            Logger.error(LOG, "Disabling LLM (requirements check failed).")
            state.llm_enabled = false
            if keymap and type(keymap.set_llm_enabled) == "function" then 
                pcall(keymap.set_llm_enabled, false)
            end
            save_prefs(); update_menu()
        end

        if not state.llm_model or state.llm_model == "" then 
            Logger.warn(LOG, "No model configured at startup.")
            return 
        end

        if state.llm_backend == "mlx" then
            Logger.debug(LOG, "MLX mode: locking predictions during initialization.")
            if keymap and type(keymap.set_llm_enabled) == "function" then
                pcall(keymap.set_llm_enabled, false)
            end
        end

        if keymap and type(keymap.set_llm_backend_name) == "function" then
            local startup_backend = ""
            if state.llm_backend == "mlx" then startup_backend = "MLX 🚀"
            elseif state.llm_backend == "ollama" then startup_backend = "Ollama 🦙" end
            pcall(keymap.set_llm_backend_name, startup_backend)
        end

        Logger.debug(LOG, string.format("Checking model requirements: %s", state.llm_model))
        -- Defer until the async installed-models cache is populated (refresh_installed_async
        -- fires at doAfter(0)); polling here avoids a false "not installed" dialog at startup
        local function do_check_requirements()
            local installed = models_mgr.get_installed_models()
            local count = 0; for _ in pairs(installed) do count = count + 1 end
            Logger.debug(LOG, string.format("Startup installed-models cache count: %d", count))
            if count == 0 then
                -- Cache not yet ready — retry in 1s (max 10 attempts)
                if not _check_startup_attempts then _check_startup_attempts = 0 end
                _check_startup_attempts = _check_startup_attempts + 1
                Logger.debug(LOG, string.format("Startup requirements deferred (attempt %d/10)", _check_startup_attempts))
                if _check_startup_attempts < 10 then
                    hs.timer.doAfter(1, do_check_requirements)
                    return
                end
                -- After 10s, proceed anyway (Ollama may not be running)
            end
            _check_startup_attempts = nil

            local check_fn = guarded_check_requirements
            if state.llm_backend == "mlx" and type(models_mgr.force_mlx_check) == "function" then
                Logger.debug(LOG, string.format("Startup MLX mode: forcing MLX requirements check for model %s", state.llm_model))
                check_fn = function(model_name, on_ok, on_fail)
                    models_mgr.force_mlx_check(model_name, on_ok, on_fail, { silent_notifications = false })
                end
            end

            check_fn(state.llm_model, function()
                Logger.info(LOG, string.format("Requirements verified for model %s.", state.llm_model))
                if state.llm_backend == "mlx" and state.llm_enabled
                    and keymap and type(keymap.set_llm_enabled) == "function" then
                    Logger.debug(LOG, "Reactivating MLX predictions.")
                    pcall(keymap.set_llm_enabled, true)
                    end
            end, disable_llm)
        end
        hs.timer.doAfter(1, do_check_requirements)

        -- Backup startup path: ensure MLX boot is attempted even if requirements callback chain is skipped.
        hs.timer.doAfter(3, function()
            if state.llm_backend == "mlx" and state.llm_enabled and state.llm_model and state.llm_model ~= ""
                and type(models_mgr.force_mlx_check) == "function" then
                Logger.debug(LOG, string.format("Startup MLX backup check fired for model %s", state.llm_model))
                models_mgr.force_mlx_check(state.llm_model, function()
                    Logger.info(LOG, string.format("Startup MLX backup check succeeded for model %s", state.llm_model))
                    if keymap and type(keymap.set_llm_enabled) == "function" then
                        pcall(keymap.set_llm_enabled, true)
                    end
                end, function()
                    Logger.warn(LOG, string.format("Startup MLX backup check failed for model %s", state.llm_model))
                end, { silent_notifications = false })
            end
        end)
        Logger.info(LOG, "═══════════════ Startup completed for menu_llm ═══════════════")
    end

    return { 
        build_item    = build_item, 
        check_startup = check_startup 
    }
end

return M
