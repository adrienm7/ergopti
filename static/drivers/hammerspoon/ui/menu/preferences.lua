--- ui/menu/preferences.lua

--- ==============================================================================
--- MODULE: Menu Preferences
--- DESCRIPTION:
--- Manages the persistence of the global state to and from the disk.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth: Centralizes config.json reading and writing.
--- 2. Dynamic Hydration: Merges default module states with user overrides.
--- ==============================================================================

local M = {}
local hs = hs





-- ===================================
-- ===================================
-- ======= 1/ Helper Functions =======
-- ===================================
-- ===================================

--- Extracts the group name from a file path or name.
--- @param file string The file name or path.
--- @return string The extracted group name.
function M.get_group_name(file)
    if type(file) ~= "string" then return "" end
    return file:match("^(.*)%.lua$") or file:match("^(.*)%.toml$") or file
end





-- =================================
-- =================================
-- ======= 2/ State Hydration ======
-- =================================
-- =================================

--- Constructs the initial state by aggregating defaults from all modules.
--- @param hotfiles table List of hotstring files.
--- @param menu_mods table Loaded UI menu modules.
--- @param core_mods table Loaded core modules.
--- @return table The initialized state dictionary.
function M.build_initial_state(hotfiles, menu_mods, core_mods)
    local state = {
        hotstrings               = {},
        sections_order_overrides = {},
        terminator_states        = {},
        delays                   = {},
    }

    local function load_defaults(mod)
        if type(mod) == "table" and type(mod.DEFAULT_STATE) == "table" then
            for k, v in pairs(mod.DEFAULT_STATE) do
                if state[k] == nil then state[k] = v end
            end
        end
    end

    for _, mod in pairs(menu_mods) do load_defaults(mod) end
    for _, mod in pairs(core_mods) do load_defaults(mod) end

    for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
        local name = M.get_group_name(f)
        if name ~= "" then state.hotstrings[name] = true end
    end

    return state
end





-- =================================
-- =================================
-- ======= 3/ Disk Operations ======
-- =================================
-- =================================

--- Loads user preferences from the JSON configuration file.
--- @param prefs_file string Path to the config.json file.
--- @return table The loaded preferences.
function M.load(prefs_file)
    local ok, fh = pcall(io.open, prefs_file, "r")
    if not ok or not fh then return {} end
    
    local content = fh:read("*a")
    pcall(function() fh:close() end)
    
    local dec_ok, tbl = pcall(hs.json.decode, content)
    return (dec_ok and type(tbl) == "table") and tbl or {}
end

--- Saves the current state to the JSON configuration file.
--- @param prefs_file string Path to the config.json file.
--- @param state table The current global state.
--- @param hotfiles table List of hotstring files.
--- @param core_mods table Loaded core modules.
function M.save(prefs_file, state, hotfiles, core_mods)
    local existing = M.load(prefs_file)
    
    for k, v in pairs(state) do
        existing[k] = v
    end

    local section_states = {}
    local keymap = core_mods.keymap
    for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
        local name = M.get_group_name(f)
        local secs = keymap and type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
        if type(secs) == "table" then
            section_states[name] = {}
            for _, sec in ipairs(secs) do
                if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
                    local is_en = keymap and type(keymap.is_section_enabled) == "function" 
                                  and keymap.is_section_enabled(name, sec.name) or false
                    section_states[name][sec.name] = is_en
                end
            end
        end
    end
    existing.section_states = section_states

    local gestures = core_mods.gestures
    existing.gesture_actions = (gestures and type(gestures.get_all_actions) == "function") and gestures.get_all_actions() or {}
    
    existing.shortcut_keys = {}
    local shortcuts_mod = core_mods.shortcuts_mod
    if shortcuts_mod and type(shortcuts_mod.list_shortcuts) == "function" then
        local ok, list = pcall(shortcuts_mod.list_shortcuts)
        if ok and type(list) == "table" then
            for _, s in ipairs(list) do
                if type(s) == "table" and s.id then
                    existing.shortcut_keys[s.id] = s.enabled
                end
            end
        end
    end

    local ok, encoded = pcall(hs.json.encode, existing, true)
    if ok and encoded then
        local file_ok, fh = pcall(io.open, prefs_file, "w")
        if file_ok and fh then 
            fh:write(encoded)
            pcall(function() fh:close() end) 
        end
    end
end

--- Merges the saved disk state into the current memory state.
--- @param state table The current global state.
--- @param saved table The dictionary loaded from disk.
function M.merge_saved_data(state, saved)
    if type(saved) ~= "table" then return end
    
    local exclude_keys = { section_states = true, gesture_actions = true, shortcut_keys = true, hotstrings = true, script_control_shortcuts = true }
    
    for k, v in pairs(saved) do
        if v ~= nil and not exclude_keys[k] then
            state[k] = v
        end
    end

    if type(saved.hotstrings) == "table" then
        for name in pairs(state.hotstrings) do
            if saved.hotstrings[name] ~= nil then
                state.hotstrings[name] = saved.hotstrings[name]
            end
        end
    end
    
    if type(saved.script_control_shortcuts) == "table" then
        if type(state.script_control_shortcuts) ~= "table" then state.script_control_shortcuts = {} end
        for k, v in pairs(saved.script_control_shortcuts) do
            state.script_control_shortcuts[k] = v
        end
    end

    if type(saved.terminator_states) == "table" then
        state.terminator_states = saved.terminator_states
    end
end

return M
