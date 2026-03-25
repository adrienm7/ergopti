-- ui/menu_llm/settings_manager.lua

-- ===========================================================================
-- LLM Settings Manager Sub-module.
--
-- Logic for handling numerical configurations via system dialogs.
-- Manages debounce delays, temperature, token limits, and context length.
-- Includes a dedicated menu builder for indentation preferences.
-- ===========================================================================

local M = {}





-- ===================================
-- ===================================
-- ======= 1/ Dialog Helpers =========
-- ===================================
-- ===================================

--- Opens a standardized numeric input prompt and updates the state
--- @param deps table Global dependencies
--- @param title string Dialog title
--- @param msg string Dialog informative text
--- @param key string The state key to update
--- @param factor number|nil Multiply factor for display (e.g. 1000 for ms)
--- @param hs_fn string|nil The keymap function name to sync the value
local function generic_numeric_prompt(deps, title, msg, key, factor, hs_fn)
    local state = deps.state
    pcall(hs.focus)

    local current_val = tonumber(state[key]) or 0
    local display_val = factor and math.floor(current_val * factor) or current_val

    local ok_p, btn, raw = pcall(hs.dialog.textPrompt, 
        tostring(title), 
        tostring(msg), 
        tostring(display_val), 
        "OK", "Annuler"
    )

    if ok_p and btn == "OK" then
        local new_val = tonumber(raw)
        if new_val then
            -- Reverse the factor if applied
            local final_val = factor and (new_val / factor) or new_val
            state[key] = final_val

            -- Sync with the keymap engine if a function is provided
            if deps.keymap and type(deps.keymap[hs_fn]) == "function" then
                pcall(deps.keymap[hs_fn], final_val)
            end

            pcall(deps.save_prefs)
            pcall(deps.update_menu)
        end
    end
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

function M.new(deps)
    local obj = { deps = deps }

    --- Sets the idle delay before triggering the LLM
    function obj.set_debounce()
        generic_numeric_prompt(deps, 
            "Délai d’inactivité", 
            "Temps d’attente requis (en ms) avant de solliciter l’IA :", 
            "llm_debounce", 1000, "set_llm_debounce"
        )
    end

    --- Sets the maximum number of tokens generated per prediction
    function obj.set_max_predict()
        generic_numeric_prompt(deps, 
            "Tokens max", 
            "Nombre maximum de tokens à générer par suggestion :", 
            "llm_max_predict", nil, "set_llm_max_predict"
        )
    end

    --- Sets the AI temperature (creativity vs stability)
    function obj.set_temperature()
        generic_numeric_prompt(deps, 
            "Température", 
            "Niveau de créativité (de 0.0 à 1.0) :", 
            "llm_temperature", nil, "set_llm_temperature"
        )
    end

    --- Sets the size of the text buffer sent as context to the AI
    function obj.set_context_length()
        generic_numeric_prompt(deps, 
            "Taille du contexte", 
            "Nombre de caractères précédents à analyser :", 
            "llm_context_length", nil, "set_llm_context_length"
        )
    end

    --- Builds the indentation selection submenu
    --- @return table The Hammerspoon menu structure
    function obj.build_indent_menu()
        local menu = {}
        local current = math.max(0, math.min(5, math.floor(tonumber(deps.state.llm_pred_indent) or 0)))
        local paused  = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false

        for i = 0, 5 do
            table.insert(menu, {
                title   = i == 0 and "0 — aucune" or (i .. " espace" .. (i > 1 and "s" or "")),
                checked = (i == current) or nil,
                fn      = not paused and function()
                    deps.state.llm_pred_indent = i
                    if deps.keymap and type(deps.keymap.set_llm_pred_indent) == "function" then
                        pcall(deps.keymap.set_llm_pred_indent, i)
                    end
                    pcall(deps.save_prefs)
                    pcall(deps.update_menu)
                end or nil,
            })
        end
        return menu
    end

    return obj
end

return M
