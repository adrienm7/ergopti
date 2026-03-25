-- ui/menu_llm/profiles_manager.lua

-- ===========================================================================
-- LLM Profiles Manager Sub-module.
--
-- Logic for handling prompt strategies. Manages built-in and user-defined 
-- profiles, handles compatibility warnings for reasoning models, and 
-- integrates with the Prompt Editor UI for CRUD operations.
-- ===========================================================================

local M = {}

local notifications = require("lib.notifications")
local llm_mod       = require("modules.llm")

local ok_pe, prompt_editor = pcall(require, "ui.prompt_editor")
if not ok_pe then prompt_editor = nil end





-- ======================================
-- ======================================
-- ======= 1/ Profile Logic =============
-- ======================================
-- ======================================

--- Synchronizes the internal state of the LLM module with current preferences
--- @param state table Shared menu state
local function sync_profiles(state)
    if type(state) ~= "table" then return end
    llm_mod.active_profile_id = state.llm_active_profile or "parallel_simple"
    llm_mod.user_profiles     = type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}
end

--- Aggregates built-in and user-created profiles into a single list
--- @param state table Shared menu state
--- @return table List of all profile definitions
local function get_all_profiles(state)
    local all = {}
    for _, p in ipairs(llm_mod.BUILTIN_PROFILES) do table.insert(all, p) end
    local user_p = (type(state) == "table" and type(state.llm_user_profiles) == "table") and state.llm_user_profiles or {}
    for _, p in ipairs(user_p) do table.insert(all, p) end
    return all
end

--- Retrieves the human-readable label of the currently selected strategy
--- @param state table Shared menu state
--- @return string The display label
local function active_profile_label(state)
    local id = type(state) == "table" and state.llm_active_profile or "parallel_simple"
    local all = get_all_profiles(state)
    for _, p in ipairs(all) do
        if type(p) == "table" and p.id == id then return p.label end
    end
    return tostring(id)
end





-- ======================================
-- ======================================
-- ======= 2/ Menu Construction =========
-- ======================================
-- ======================================

--- Builds the strategy selection submenu with support for custom profiles
--- @param deps table Global dependencies
--- @return table The Hammerspoon menu structure
local function build_profile_menu(deps)
    local state  = deps.state
    local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
    local menu   = {}
    local all    = get_all_profiles(state)

    for _, profile in ipairs(all) do
        if type(profile) == "table" then
            local pid = profile.id
            local is_builtin = false
            
            for _, bp in ipairs(llm_mod.BUILTIN_PROFILES) do
                if bp.id == pid then is_builtin = true; break end
            end

            -- Thinking models often fail with parallel strategies; add a visual warning
            local is_thinking = llm_mod.is_thinking_model(state.llm_model)
            local extra = ""
            if (pid == "parallel_simple" or pid == "parallel_advanced") and is_thinking then
                extra = "  ⚠️ Non recommandé (Thinking)"
            end

            local item = {
                title    = (profile.label or "") .. (profile.description and ("  —  " .. profile.description) or "") .. extra,
                checked  = (state.llm_active_profile == pid) or nil,
                disabled = paused or nil,
            }

            -- User profiles get a sub-menu for Editing/Deleting
            if not is_builtin then
                item.menu = {
                    {
                        title    = "Utiliser ce profil",
                        checked  = (state.llm_active_profile == pid) or nil,
                        disabled = paused or nil,
                        fn       = not paused and function()
                            state.llm_active_profile = pid
                            sync_profiles(state)
                            pcall(deps.save_prefs)
                            pcall(deps.update_menu)
                        end or nil,
                    },
                    { title = "-" },
                    {
                        title = "✏️ Modifier…",
                        fn    = function()
                            if prompt_editor and type(prompt_editor.open) == "function" then
                                hs.timer.doAfter(0.1, function()
                                    pcall(prompt_editor.open, profile, function(updated)
                                        if type(updated) == "table" then
                                            for i, p in ipairs(state.llm_user_profiles) do
                                                if type(p) == "table" and p.id == updated.id then
                                                    state.llm_user_profiles[i] = updated
                                                    break
                                                end
                                            end
                                            sync_profiles(state)
                                            pcall(deps.save_prefs)
                                            pcall(deps.update_menu)
                                            pcall(notifications.notify, "✅ Profil modifié", updated.label)
                                        end
                                    end)
                                end)
                            end
                        end,
                    },
                    {
                        title = "🗑️ Supprimer…",
                        fn    = function()
                            pcall(hs.focus)
                            local ok_c, choice = pcall(hs.dialog.blockAlert, 
                                "Supprimer \"" .. (profile.label or "") .. "\" ?", 
                                "Ce profil personnalisé sera supprimé définitivement.", 
                                "Supprimer", "Annuler", "critical")
                                
                            if ok_c and choice == "Supprimer" then
                                local kept = {}
                                for _, p in ipairs(state.llm_user_profiles) do
                                    if type(p) == "table" and p.id ~= pid then table.insert(kept, p) end
                                end
                                state.llm_user_profiles = kept
                                if state.llm_active_profile == pid then 
                                    state.llm_active_profile = "parallel_simple" 
                                end
                                sync_profiles(state)
                                pcall(deps.save_prefs)
                                pcall(deps.update_menu)
                            end
                        end,
                    },
                }
                item.fn = nil
            else
                -- Built-in profiles are simply toggled
                item.fn = not paused and function()
                    state.llm_active_profile = pid
                    sync_profiles(state)
                    pcall(deps.save_prefs)
                    pcall(deps.update_menu)
                end or nil
            end
            table.insert(menu, item)
        end
    end

    table.insert(menu, { title = "-" })
    table.insert(menu, {
        title = "+ Créer un profil personnalisé…",
        fn    = not paused and function()
            if prompt_editor and type(prompt_editor.open) == "function" then
                hs.timer.doAfter(0.1, function()
                    pcall(prompt_editor.open, nil, function(new_profile)
                        if type(new_profile) == "table" then
                            if type(state.llm_user_profiles) ~= "table" then state.llm_user_profiles = {} end
                            table.insert(state.llm_user_profiles, new_profile)
                            state.llm_active_profile = new_profile.id
                            sync_profiles(state)
                            pcall(deps.save_prefs)
                            pcall(deps.update_menu)
                            pcall(notifications.notify, "✅ Profil créé", new_profile.label)
                        end
                    end)
                end)
            end
        end or nil,
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
    sync_profiles(deps.state)

    --- Returns the main menu entry for Strategy selection
    function obj.get_menu_item()
        local label = active_profile_label(deps.state)
        local is_thinking = llm_mod.is_thinking_model(deps.state.llm_model)
        local warning = (is_thinking and deps.state.llm_active_profile == "parallel_simple") and "  ⚠️" or ""

        return {
            title = "Stratégie IA : " .. label .. warning,
            menu  = build_profile_menu(deps)
        }
    end

    return obj
end

return M
