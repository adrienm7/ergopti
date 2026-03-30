--- modules/llm/init.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine Core
--- DESCRIPTION:
--- Coordinates communication with the local Ollama API through decoupled API, 
--- Profiles, and Parsing engines.
--- ==============================================================================

local M = {}

local hs = hs
local Profiles = require("modules.llm.profiles")
local Api      = require("modules.llm.api")





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

M.DEFAULT_STATE = {
    llm_enabled           = false,
    llm_model             = "llama3.2",
    llm_debounce          = 0.5,
    llm_num_predictions   = 3,
    llm_sequential_mode   = false,
    llm_context_length    = 500,
    llm_temperature       = 0.1,
    llm_max_predict       = 40,
    llm_arrow_nav_enabled = false,
    llm_nav_modifiers     = {},
    llm_show_info_bar     = false,
    llm_val_modifiers     = {"alt"},
    llm_pred_indent       = -3,
    llm_active_profile    = "basic",
}

local CoreState = {
    active_profile_id = M.DEFAULT_STATE.llm_active_profile,
    user_profiles     = {},
}





-- =======================================
-- =======================================
-- ======= 2/ Core Orchestration =========
-- =======================================
-- =======================================

--- Retrieves the currently active profile object.
--- @return table The active profile object.
function M.get_active_profile()
    return Profiles.get_active_profile(CoreState.active_profile_id, CoreState.user_profiles)
end

--- Updates the active profile ID and logic state.
--- @param id string The ID of the profile to activate.
function M.set_active_profile(id)
    if type(id) == "string" then
        CoreState.active_profile_id = id
    end
end

--- Exposes built-in profiles and user profiles.
--- @return table An array containing all available profiles.
function M.get_all_profiles()
    return Profiles.get_all_profiles(CoreState.user_profiles)
end

--- Overrides user profiles globally.
function M.set_user_profiles(profiles_table)
    if type(profiles_table) == "table" then
        CoreState.user_profiles = profiles_table
    end
end

--- Initiates a new LLM prediction request, selecting the optimal fetch strategy based on profile state.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param on_success function Function to execute when successfully parsed payload returns.
--- @param on_fail function Function to execute on timeout, error, or empty output.
--- @param sequential_mode boolean Flag to enforce sequential API requests instead of parallel.
--- @param force boolean If true, bypasses application exclusions.
function M.fetch_llm_prediction(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions, on_success, on_fail, sequential_mode, force)

    -- Prevent firing requests if the active application is blacklisted by user settings
    if not force then
        local ok_front, front = pcall(hs.application.frontmostApplication)
        if ok_front and front then
            local disabled = hs.settings.get("llm_disabled_apps")
            if type(disabled) == "table" then
                local bid  = type(front.bundleID) == "function" and front:bundleID() or ""
                local path = type(front.path) == "function" and front:path() or ""
                for _, app in ipairs(disabled) do
                    if type(app) == "table" and ((app.bundleID and app.bundleID == bid) or (app.appPath and app.appPath == path)) then
                        if type(on_fail) == "function" then pcall(on_fail) end
                        return
                    end
                end
            end
        end
    end

    num_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
    local profile = M.get_active_profile()

    if type(profile) == "table" and (not profile.batch) and num_predictions > 1 then
        if sequential_mode then
            Api.fetch_sequential(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail)
        else
            Api.fetch_parallel(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail)
        end
    else
        Api.fetch_batch(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail)
    end
end

--- Validates keystroke event modifiers against an expected explicit modifier set.
--- @param eventFlags table The flags object emitted by the keystroke event.
--- @param targetMods table A list of expected modifier keys (e.g., {"cmd", "shift"}).
--- @return boolean True if the flags exactly match the target criteria, false otherwise.
function M.check_modifiers(eventFlags, targetMods)
    if type(targetMods) ~= "table" then return false end
    if #targetMods == 1 and targetMods[1] == "none" then return false end
    
    local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
    for _, mod in ipairs(targetMods) do if target_map[mod] ~= nil then target_map[mod] = true end end
    
    if (eventFlags.cmd or false)   ~= target_map.cmd   then return false end
    if (eventFlags.alt or false)   ~= target_map.alt   then return false end
    if (eventFlags.shift or false) ~= target_map.shift then return false end
    if (eventFlags.ctrl or false)  ~= target_map.ctrl  then return false end
    
    return true
end

-- Proxy Model Heuristics Methods
M.is_thinking_model  = Api.is_thinking_model
M.check_availability = Api.check_availability

return M
