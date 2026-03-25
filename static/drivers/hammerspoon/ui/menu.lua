-- ui/menu.lua

-- ===========================================================================
-- Menu UI Module.
--
-- Handles the construction, state management, and updates of the macOS 
-- Menu Bar icon (System Tray). Acts as the central hub tying together
-- settings for hotstrings, gestures, shortcuts, and LLM preferences.
-- Saves and loads states automatically from config.json.
-- ===========================================================================

local M = {}

local hs               = hs
local notifications    = require("lib.notifications")
local llm_mod          = require("modules.llm")
local menu_llm         = require("ui.menu_llm")
local hotstring_editor = require("ui.hotstring_editor")

M._active_tasks = {}





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local DEFAULT_DELAYS = {
    STAR_TRIGGER       = 2.0,
    dynamichotstrings  = 2.0,
    autocorrection     = 0.75,
    rolls              = 0.5,
    sfbsreduction      = 0.5,
    distancesreduction = 0.5,
}

local SLOT_LABELS = {
    tap_3         = "Tap 3 doigts",
    tap_4         = "Tap 4 doigts",
    tap_5         = "Tap 5 doigts",
    swipe_2_diag  = "Swipe 2 doigts ↖/↘",
    swipe_3_horiz = "Swipe 3 doigts ←/→",
    swipe_3_diag  = "Swipe 3 doigts ↖/↘",
    swipe_3_up    = "Swipe 3 doigts ↑",
    swipe_3_down  = "Swipe 3 doigts ↓",
    swipe_4_horiz = "Swipe 4 doigts ←/→",
    swipe_4_diag  = "Swipe 4 doigts ↖/↘",
    swipe_4_up    = "Swipe 4 doigts ↑",
    swipe_4_down  = "Swipe 4 doigts ↓",
    swipe_5_horiz = "Swipe 5 doigts ←/→",
    swipe_5_diag  = "Swipe 5 doigts ↖/↘",
    swipe_5_up    = "Swipe 5 doigts ↑",
    swipe_5_down  = "Swipe 5 doigts ↓",
}





-- =======================================
-- =======================================
-- ======= 2/ Formatting Helpers =======
-- =======================================
-- =======================================

--- Formats a number with space thousands separators (e.g. 1 000)
--- @param n number The number to format
--- @return string The formatted string
local function fmt_count(n)
    local num = tonumber(n) or 0
    local s = tostring(math.floor(num + 0.5))
    local r = ""
    for i = 1, #s do
        if i > 1 and (#s - i + 1) % 3 == 0 then r = r .. " " end
        r = r .. s:sub(i, i)
    end
    return r
end

--- Extracts the logical group name from a filename (removes extension)
--- @param file string The filename
--- @return string The group name
local function get_group_name(file)
    if type(file) ~= "string" then return "" end
    return file:match("^(.*)%.lua$") or file:match("^(.*)%.toml$") or file
end





-- =================================
-- =================================
-- ======= 3/ Main Lifecycle =======
-- =================================
-- =================================

--- Initializes the menu bar app, loads configurations, and binds modules
function M.start(base_dir, hotfiles, gestures, keymap, shortcuts, personal_info, module_sections, script_control)
    base_dir = type(base_dir) == "string" and base_dir or (hs.configdir .. "/")
    
    local ok, myMenu = pcall(hs.menubar.new)
    if not ok or not myMenu then
        print("[menu] Failed to create hs.menubar object.")
        return nil, nil
    end

    local updateMenu



    -- ==============================
    -- ===== 3.1) State & Helpers =====
    -- ==============================

    local function update_icon(custom_text)
        local paused    = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local logo_file = paused and "logo_black.png" or "logo_white.png"
        local ok_img, ico = pcall(hs.image.imageFromPath, base_dir .. "images/" .. logo_file)
        
        myMenu:setTitle(custom_text and (" " .. tostring(custom_text)) or "")
        
        if ok_img and ico then
            pcall(function() if type(ico.setSize) == "function" then ico:setSize({ w = 18, h = 18 }) end end)
            myMenu:setIcon(ico, false)
        elseif not custom_text then
            myMenu:setTitle("🔧")
        end
    end
    update_icon()

    local _suppress_watcher_until = 0

    local function do_reload(source)
        local msg = source == "watcher"
            and "Fichiers modifiés — Rechargement…"
            or  "Rechargement du script…"
        pcall(notifications.notify, msg)
        hs.timer.doAfter(0.25, function() pcall(hs.reload) end)
    end

    local function notify_feature(label, is_enabled)
        pcall(function()
            hs.notify.new({
                title           = is_enabled and "🟢 ACTIVÉ" or "🔴 DÉSACTIVÉ",
                informativeText = tostring(label),
            }):send()
        end)
    end

    local state = {
        keymap                   = true,
        gestures                 = true,
        shortcuts                = true,
        personal_info            = true,
        hotstrings               = {},
        chatgpt_url              = "https://chat.openai.com",
        sections_order_overrides = {},
        terminator_states        = {},
        expansion_delay          = (keymap and keymap.DEFAULT_BASE_DELAY_SEC) or 0.75,
        delays                   = {},
        script_control_shortcuts = { return_key = "pause", backspace = "reload" },
        script_control_enabled   = true,
        ahk_source_path          = "",
        preview_enabled          = true,
        llm_enabled              = llm_mod and llm_mod.DEFAULT_LLM_ENABLED  or false,
        llm_debounce             = llm_mod and llm_mod.DEFAULT_LLM_DEBOUNCE or 0.5,
        llm_model                = llm_mod and llm_mod.DEFAULT_LLM_MODEL    or "llama3.2",
        trigger_char             = "★",
        llm_context_length       = 500,
        llm_reset_on_nav         = true,
        llm_temperature          = 0.1,
        llm_max_predict          = 40,
        llm_num_predictions      = (llm_mod and llm_mod.DEFAULT_LLM_NUM_PREDICTIONS or 3),
        llm_arrow_nav_enabled    = false,
        llm_arrow_nav_mods       = {},
        llm_show_info_bar        = false,
        llm_pred_shortcut_mod    = "ctrl",
        llm_pred_indent          = 0,
        llm_user_models          = {},
        llm_disabled_apps        = {},
        llm_active_profile       = "standard",
        llm_user_profiles        = {},
        custom_editor_shortcut   = nil,
        custom_default_section   = nil,
        custom_close_on_add      = false,
    }

    local function applyTriggerChar(text)
        if type(text) ~= "string" then return text end
        local safe_repl = tostring(state.trigger_char):gsub("%%", "%%%%")
        return text:gsub("★", safe_repl)
    end

    for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
        local name = get_group_name(f)
        if name ~= "" then state.hotstrings[name] = true end
    end



    -- ============================
    -- ===== 3.2) Preferences =====
    -- ============================

    local prefs_file = base_dir .. "config.json"

    local function load_prefs()
        local ok, fh = pcall(io.open, prefs_file, "r")
        if not ok or not fh then return {} end
        
        local content = fh:read("*a")
        pcall(function() fh:close() end)
        
        local dec_ok, tbl = pcall(hs.json.decode, content)
        return (dec_ok and type(tbl) == "table") and tbl or {}
    end

    local function save_prefs()
        _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 1.0

        local section_states = {}
        for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
            local name = get_group_name(f)
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

        local existing = load_prefs()
        local prefs = {
            keymap                   = state.keymap, 
            gestures                 = state.gestures,
            shortcuts                = state.shortcuts, 
            personal_info            = state.personal_info,
            hotstrings               = state.hotstrings, 
            chatgpt_url              = state.chatgpt_url,
            sections_order_overrides = state.sections_order_overrides,
            section_states           = section_states, 
            terminator_states        = state.terminator_states,
            expansion_delay          = state.expansion_delay, 
            delays                   = state.delays, 
            shortcut_keys            = {},
            gesture_actions          = (gestures and type(gestures.get_all_actions) == "function") and gestures.get_all_actions() or {},
            script_control_shortcuts = state.script_control_shortcuts,
            script_control_enabled   = state.script_control_enabled,
            ahk_source_path          = state.ahk_source_path,
            preview_enabled          = state.preview_enabled,
            llm_enabled              = state.llm_enabled,
            llm_debounce             = state.llm_debounce,
            llm_model                = state.llm_model,
            trigger_char             = state.trigger_char,
            llm_context_length       = state.llm_context_length,
            llm_reset_on_nav         = state.llm_reset_on_nav,
            llm_temperature          = state.llm_temperature,
            llm_max_predict          = state.llm_max_predict,
            llm_num_predictions      = state.llm_num_predictions,
            llm_arrow_nav_enabled    = state.llm_arrow_nav_enabled,
            llm_arrow_nav_mods       = state.llm_arrow_nav_mods,
            llm_show_info_bar        = state.llm_show_info_bar,
            llm_pred_shortcut_mod    = state.llm_pred_shortcut_mod,
            llm_pred_indent          = state.llm_pred_indent,
            llm_user_models          = state.llm_user_models,
            llm_disabled_apps        = state.llm_disabled_apps,
            llm_active_profile       = state.llm_active_profile or "standard",
            llm_user_profiles        = state.llm_user_profiles  or {},
            custom_editor_shortcut   = state.custom_editor_shortcut or false,
            custom_default_section   = state.custom_default_section or false,
            custom_close_on_add      = state.custom_close_on_add,
        }

        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            local ok, list = pcall(shortcuts.list_shortcuts)
            if ok and type(list) == "table" then
                for _, s in ipairs(list) do
                    if type(s) == "table" and s.id then
                        prefs.shortcut_keys[s.id] = s.enabled
                    end
                end
            end
        end

        for k, v in pairs(prefs) do existing[k] = v end

        local ok, encoded = pcall(hs.json.encode, existing, true)
        if ok and encoded then
            local file_ok, fh = pcall(io.open, prefs_file, "w")
            if file_ok and fh then 
                fh:write(encoded)
                pcall(function() fh:close() end) 
            end
        end
    end

    -- Initial load
    do
        local saved         = load_prefs()
        local config_absent = (next(saved) == nil)

        if config_absent then
            for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
                local name = get_group_name(f)
                local secs = keymap and type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
                if type(secs) == "table" then
                    for _, sec in ipairs(secs) do
                        if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
                            pcall(hs.settings.set, "hotstrings_section_" .. name .. "_" .. sec.name, nil)
                        end
                    end
                end
                if keymap then
                    if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
                    if type(keymap.enable_group) == "function"  then pcall(keymap.enable_group, name) end
                end
            end
        end

        if type(saved) == "table" then
            if type(saved.trigger_char) == "string" then state.trigger_char = saved.trigger_char end
            if saved.keymap            ~= nil then state.keymap            = saved.keymap          end
            if saved.gestures          ~= nil then state.gestures          = saved.gestures        end
            if saved.shortcuts         ~= nil then state.shortcuts         = saved.shortcuts       end
            if saved.personal_info     ~= nil then state.personal_info     = saved.personal_info   end
            if saved.chatgpt_url       ~= nil then state.chatgpt_url       = saved.chatgpt_url     end
            if saved.preview_enabled   ~= nil then state.preview_enabled   = saved.preview_enabled end
            if saved.llm_enabled       ~= nil then state.llm_enabled       = saved.llm_enabled     end
            
            if type(saved.llm_debounce) == "number" then state.llm_debounce = saved.llm_debounce end
            if type(saved.llm_model)    == "string" then state.llm_model    = saved.llm_model    end
            if type(saved.llm_context_length) == "number" then state.llm_context_length = saved.llm_context_length end
            if saved.llm_reset_on_nav         ~= nil      then state.llm_reset_on_nav   = saved.llm_reset_on_nav   end
            if type(saved.llm_temperature)    == "number" then state.llm_temperature    = saved.llm_temperature    end
            if type(saved.llm_max_predict)    == "number" then state.llm_max_predict    = saved.llm_max_predict    end
            if type(saved.llm_num_predictions)  == "number"  then state.llm_num_predictions  = saved.llm_num_predictions  end
            if saved.llm_arrow_nav_enabled ~= nil        then state.llm_arrow_nav_enabled = saved.llm_arrow_nav_enabled end
            if type(saved.llm_arrow_nav_mods) == "table" then state.llm_arrow_nav_mods    = saved.llm_arrow_nav_mods    end
            if saved.llm_show_info_bar ~= nil          then state.llm_show_info_bar   = saved.llm_show_info_bar   end
            if type(saved.llm_pred_shortcut_mod) == "string" then state.llm_pred_shortcut_mod = saved.llm_pred_shortcut_mod end
            if type(saved.llm_pred_indent)  == "number"  then state.llm_pred_indent       = saved.llm_pred_indent       end
            if type(saved.llm_user_models) == "table"     then state.llm_user_models       = saved.llm_user_models       end
            if type(saved.sections_order_overrides) == "table" then state.sections_order_overrides = saved.sections_order_overrides end
            if type(saved.llm_disabled_apps) == "table" then state.llm_disabled_apps = saved.llm_disabled_apps end
            
            if type(saved.llm_active_profile) == "string" then state.llm_active_profile = saved.llm_active_profile end
            if type(saved.llm_user_profiles) == "table" then state.llm_user_profiles = saved.llm_user_profiles end

            if type(saved.custom_editor_shortcut) == "table" then
                state.custom_editor_shortcut = saved.custom_editor_shortcut
            elseif saved.custom_editor_shortcut == false then
                state.custom_editor_shortcut = false
            end
            
            if type(saved.custom_default_section) == "string" then
                state.custom_default_section = saved.custom_default_section
            elseif saved.custom_default_section == false then
                state.custom_default_section = nil
            end
            
            if saved.custom_close_on_add ~= nil then state.custom_close_on_add = saved.custom_close_on_add end

            if type(saved.section_states) == "table" then
                for group_name, secs in pairs(saved.section_states) do
                    if type(secs) == "table" then
                        for sec_name, sec_enabled in pairs(secs) do
                            local key = "hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(sec_name)
                            pcall(hs.settings.set, key, sec_enabled == false and false or nil)
                        end
                    end
                end
            end

            if type(saved.terminator_states) == "table" then
                state.terminator_states = saved.terminator_states
                for key, enabled in pairs(saved.terminator_states) do
                    if keymap and type(keymap.set_terminator_enabled) == "function" then
                        pcall(keymap.set_terminator_enabled, key, enabled)
                    end
                end
            end
            
            if type(saved.expansion_delay) == "number" then
                state.expansion_delay = saved.expansion_delay
                if keymap and type(keymap.set_base_delay) == "function" then pcall(keymap.set_base_delay, saved.expansion_delay) end
            end
            
            if type(saved.delays) == "table" then
                state.delays = saved.delays
            end

            -- Apply custom delays to keymap module safely
            if keymap and type(keymap.DELAYS) == "table" then
                local max_d = 0
                for k, default_val in pairs(DEFAULT_DELAYS) do
                    local v = state.delays[k] or default_val
                    keymap.DELAYS[k] = v
                    if v > max_d then max_d = v end
                end
                keymap.WORD_TIMEOUT_SEC = math.min(5.0, max_d + 0.5)
            end

            if type(saved.script_control_shortcuts) == "table" then
                for k, v in pairs(saved.script_control_shortcuts) do
                    state.script_control_shortcuts[k] = v
                end
            end
            
            if saved.script_control_enabled ~= nil then state.script_control_enabled = saved.script_control_enabled end
            if saved.ahk_source_path ~= nil then state.ahk_source_path = saved.ahk_source_path end
            
            if type(saved.hotstrings) == "table" then
                for name in pairs(state.hotstrings) do
                    if saved.hotstrings[name] ~= nil then
                        state.hotstrings[name] = saved.hotstrings[name]
                    end
                end
            end
            
            if gestures and type(saved.gesture_actions) == "table" then
                for slot, action in pairs(saved.gesture_actions) do 
                    if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, action) end
                end
            end
            
            if gestures and type(gestures.apply_all_overrides) == "function" then
                pcall(gestures.apply_all_overrides)
            end
        end

        -- Propagate settings to Keymap engine
        if keymap then
            local map = {
                { fn = "set_preview_enabled",     val = state.preview_enabled },
                { fn = "set_llm_enabled",         val = state.llm_enabled },
                { fn = "set_llm_debounce",        val = state.llm_debounce },
                { fn = "set_llm_model",           val = state.llm_model },
                { fn = "set_trigger_char",        val = state.trigger_char },
                { fn = "set_llm_context_length",  val = state.llm_context_length },
                { fn = "set_llm_reset_on_nav",    val = state.llm_reset_on_nav },
                { fn = "set_llm_temperature",     val = state.llm_temperature },
                { fn = "set_llm_max_predict",     val = state.llm_max_predict },
                { fn = "set_llm_num_predictions", val = state.llm_num_predictions },
                { fn = "set_llm_arrow_nav_enabled", val = state.llm_arrow_nav_enabled },
                { fn = "set_llm_arrow_nav_mods",  val = state.llm_arrow_nav_mods },
                { fn = "set_llm_show_info_bar",   val = state.llm_show_info_bar },
                { fn = "set_llm_pred_shortcut_mod", val = state.llm_pred_shortcut_mod },
                { fn = "set_llm_pred_indent",     val = state.llm_pred_indent },
                { fn = "set_llm_disabled_apps",   val = state.llm_disabled_apps },
            }
            for _, item in ipairs(map) do
                if type(keymap[item.fn]) == "function" then pcall(keymap[item.fn], item.val) end
            end
        end
        
        -- Propagate settings to Editor
        if type(hotstring_editor.set_trigger_char) == "function"    then pcall(hotstring_editor.set_trigger_char, state.trigger_char) end
        if type(hotstring_editor.set_default_section) == "function" then pcall(hotstring_editor.set_default_section, state.custom_default_section) end
        if type(hotstring_editor.set_close_on_add) == "function"    then pcall(hotstring_editor.set_close_on_add, state.custom_close_on_add) end

        do
            local sc = state.custom_editor_shortcut
            if sc == nil then
                local def = { mods = {"ctrl"}, key = state.trigger_char }
                state.custom_editor_shortcut = def
                if type(hotstring_editor.set_shortcut) == "function" then pcall(hotstring_editor.set_shortcut, def.mods, def.key) end
            elseif type(sc) == "table" and type(sc.mods) == "table" and type(sc.key) == "string" then
                if type(hotstring_editor.set_shortcut) == "function" then pcall(hotstring_editor.set_shortcut, sc.mods, sc.key) end
            end
        end

        -- Start engines according to states
        if keymap then
            if state.keymap then 
                if type(keymap.start) == "function" then pcall(keymap.start) end 
            else 
                if type(keymap.stop) == "function" then pcall(keymap.stop) end 
            end
        end
        
        if gestures then
            if state.gestures then 
                if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end 
            else 
                if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end 
            end
        end
        
        if shortcuts then
            if state.shortcuts then 
                if type(shortcuts.start) == "function" then pcall(shortcuts.start) end 
            else 
                if type(shortcuts.stop) == "function" then pcall(shortcuts.stop) end 
            end
        end
        
        if personal_info then
            if state.personal_info then 
                if type(personal_info.enable) == "function" then pcall(personal_info.enable) end 
            else 
                if type(personal_info.disable) == "function" then pcall(personal_info.disable) end 
            end
        end

        -- Sync hotstring groups
        if keymap then
            for name, enabled in pairs(state.hotstrings) do
                if enabled then
                    if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
                    if type(keymap.enable_group) == "function" then pcall(keymap.enable_group, name) end
                else
                    if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
                end
            end
        end

        -- Sync shortcuts
        if shortcuts and type(saved) == "table" and type(saved.shortcut_keys) == "table" then
            if type(shortcuts.enable) == "function" and type(shortcuts.disable) == "function" then
                for id, enabled in pairs(saved.shortcut_keys) do
                    if enabled then pcall(shortcuts.enable, id) else pcall(shortcuts.disable, id) end
                end
            end
        end

        if config_absent then save_prefs() end
    end

    local llm_handler = menu_llm.create({
        state          = state,
        active_tasks   = M._active_tasks,
        update_icon    = update_icon,
        update_menu    = function() updateMenu() end,
        save_prefs     = save_prefs,
        keymap         = keymap,
        script_control = script_control,
    })
    
    if type(llm_handler.check_startup) == "function" then pcall(llm_handler.check_startup) end

    if type(hotstring_editor.set_update_menu) == "function" then
        pcall(hotstring_editor.set_update_menu, function() updateMenu() end)
    end

    if script_control then
        if type(script_control.set_on_pause_change) == "function" then
            pcall(script_control.set_on_pause_change, function(_) update_icon(); updateMenu() end)
        end

        if state.script_control_enabled then
            pcall(script_control.set_shortcut_action, "return_key", state.script_control_shortcuts.return_key)
            pcall(script_control.set_shortcut_action, "backspace",  state.script_control_shortcuts.backspace)
        else
            pcall(script_control.set_shortcut_action, "return_key", "none")
            pcall(script_control.set_shortcut_action, "backspace",  "none")
        end

        pcall(script_control.set_extras, {
            open_init = function()
                hs.timer.doAfter(0, function()
                    _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8
                    pcall(hs.execute, "open \"" .. base_dir .. "init.lua\"")
                end)
            end,
            open_ahk = function()
                hs.timer.doAfter(0, function()
                    local path = (state.ahk_source_path ~= "") and state.ahk_source_path or nil
                    if not path then path = os.getenv("LOCAL_AHK_PATH") end
                    if not path then
                        local ok_lf, lf = pcall(io.open, base_dir .. "../hotstrings/.local_ahk_path", "r")
                        if ok_lf and lf then
                            local raw = lf:read("*a")
                            pcall(function() lf:close() end)
                            raw = raw:match("^%s*(.-)%s*$")
                            if raw ~= "" then path = raw end
                        end
                    end
                    if not path then path = base_dir .. "../autohotkey/ErgoptiPlus.ahk" end
                    
                    local app_name = hs.execute(string.format(
                        "osascript -e 'tell application \"Finder\" to return name of "
                        .. "(default application of (info for POSIX file \"%s\"))' 2>/dev/null", path))
                    
                    app_name = type(app_name) == "string" and app_name:match("^%s*(.-)%s*$") or ""
                    if app_name ~= "" then 
                        pcall(hs.execute, string.format("open -a \"%s\" \"%s\"", app_name, path))
                    else 
                        pcall(hs.execute, string.format("open -t \"%s\"", path)) 
                    end
                end)
            end,
        })
    end

    local function groupEnabled(name)
        return (keymap and type(keymap.is_group_enabled) == "function" and keymap.is_group_enabled(name))
            or (state.hotstrings[name] ~= false)
    end

    local function groupLabel(name)
        local meta = keymap and type(keymap.get_meta_description) == "function" and keymap.get_meta_description(name)
        local lbl = (type(meta) == "string" and meta ~= "") and meta or tostring(name):gsub("_", " ")
        return applyTriggerChar(lbl)
    end

    local function toggleGroupFn(name)
        return function()
            state.hotstrings[name] = not groupEnabled(name)
            if state.hotstrings[name] then
                if keymap and type(keymap.enable_group) == "function" then pcall(keymap.enable_group, name) end
                if not state.keymap then 
                    state.keymap = true; 
                    if keymap and type(keymap.start) == "function" then pcall(keymap.start) end 
                end
            else
                if keymap and type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
            end
            save_prefs()
            notify_feature(groupLabel(name), state.hotstrings[name])
            updateMenu()
        end
    end

    local function toggleSectionFn(group_name, sec_name, sec_label)
        return function()
            local will_enable = not (keymap and type(keymap.is_section_enabled) == "function" and keymap.is_section_enabled(group_name, sec_name) or false)
            if will_enable then
                if keymap and type(keymap.enable_section) == "function" then pcall(keymap.enable_section, group_name, sec_name) end
                if not state.keymap then 
                    state.keymap = true; 
                    if keymap and type(keymap.start) == "function" then pcall(keymap.start) end 
                end
            else
                if keymap and type(keymap.disable_section) == "function" then pcall(keymap.disable_section, group_name, sec_name) end
            end
            save_prefs()
            notify_feature(applyTriggerChar(sec_label or sec_name), will_enable)
            updateMenu()
        end
    end

    local buildPersonalInfoItems



    -- =================================
    -- ===== 3.3) Menu: Hotstrings =====
    -- =================================

    local function buildHotstringsItems()
        local paused    = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local top_names = {}
        for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
            top_names[#top_names + 1] = get_group_name(f)
        end
        if #top_names == 0 then return {} end

        local items = {}
        for _, name in ipairs(top_names) do
            if name == "custom" or name == "personal" then goto continue_group end

            local enabled  = groupEnabled(name)
            local sections = keymap and type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
            local has_secs = type(sections) == "table" and #sections > 0

            local total, has_count = 0, false
            if enabled and has_secs then
                for _, sec in ipairs(sections) do
                    if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
                        and (keymap and type(keymap.is_section_enabled) == "function" and keymap.is_section_enabled(name, sec.name)) then
                        if sec.count ~= nil then has_count = true; total = total + tonumber(sec.count) end
                    end
                end
            end

            local base_label = groupLabel(name)
            local item = {
                title   = has_count and (base_label .. " (" .. fmt_count(total) .. ")") or base_label,
                checked = (enabled and not paused) or nil,
                fn      = toggleGroupFn(name),
            }

            if has_secs then
                local override    = (type(state.sections_order_overrides) == "table" and state.sections_order_overrides)[name]
                local ordered_secs

                if type(override) == "table" then
                    local by_name = {}
                    for _, sec in ipairs(sections) do if type(sec) == "table" then by_name[sec.name] = sec end end
                    local seen = {}
                    ordered_secs = {}
                    for _, entry in ipairs(override) do
                        if entry == "-" then table.insert(ordered_secs, { name = "-" })
                        elseif by_name[entry] then
                            table.insert(ordered_secs, by_name[entry]); seen[entry] = true
                        end
                    end
                    for _, sec in ipairs(sections) do
                        if type(sec) == "table" and not seen[sec.name] and sec.name ~= "-" then
                            table.insert(ordered_secs, sec)
                        end
                    end
                else
                    ordered_secs = sections
                end

                local sec_menu = {}
                for _, sec in ipairs(ordered_secs) do
                    if type(sec) == "table" then
                        if sec.name == "-" then
                            sec_menu[#sec_menu + 1] = { title = "-" }
                        elseif sec.is_module_placeholder then
                            local ms       = type(module_sections) == "table" and module_sections[name]
                            local ms_entry = type(ms) == "table" and ms[sec.name]
                            local mod_id   = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
                            if mod_id == "personal_info" then
                                local ms_desc  = type(ms_entry) == "table" and ms_entry.description or nil
                                local pi_items = buildPersonalInfoItems(applyTriggerChar(ms_desc))
                                if type(pi_items) == "table" then
                                    for _, pi in ipairs(pi_items) do
                                        if type(pi) == "table" then
                                            if pi.checked ~= nil and paused then pi.checked = nil end
                                            if not enabled or paused then pi.fn = nil; pi.disabled = true end
                                            sec_menu[#sec_menu + 1] = pi
                                        end
                                    end
                                end
                            end
                        else
                            local sec_on = keymap and type(keymap.is_section_enabled) == "function" and keymap.is_section_enabled(name, sec.name) or false
                            local lbl    = (type(sec.description) == "string" and sec.description ~= "")
                                           and sec.description or tostring(sec.name):gsub("_", " ")
                            lbl = applyTriggerChar(lbl)
                            sec_menu[#sec_menu + 1] = {
                                title    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
                                checked  = (sec_on and not paused) or nil,
                                fn       = (enabled and not paused)
                                           and toggleSectionFn(name, sec.name, lbl) or nil,
                                disabled = not enabled or paused or nil,
                            }
                        end
                    end
                end
                item.menu = sec_menu
            end
            items[#items + 1] = item
            ::continue_group::
        end
        return items
    end



    -- ===============================
    -- ===== 3.4) Menu: Settings =====
    -- ===============================

    local function buildHotstringsManagementItem()
        local paused    = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local menu      = {}

        table.insert(menu, {
            title    = "Afficher la prévisualisation (Bulle)",
            checked  = (state.preview_enabled and not paused) or nil,
            disabled = paused or nil,
            fn       = not paused and function()
                state.preview_enabled = not state.preview_enabled
                if keymap and type(keymap.set_preview_enabled) == "function" then
                    pcall(keymap.set_preview_enabled, state.preview_enabled)
                end
                save_prefs()
                notify_feature("Prévisualisation", state.preview_enabled)
                updateMenu()
            end or nil,
        })
        table.insert(menu, { title = "-" })

        local defs    = keymap and type(keymap.get_terminator_defs) == "function" and keymap.get_terminator_defs() or {}
        local exp_sub = {}
        for _, def in ipairs(defs) do
            if type(def) == "table" then
                local enabled_t = keymap and type(keymap.is_terminator_enabled) == "function" and keymap.is_terminator_enabled(def.key) or false
                exp_sub[#exp_sub + 1] = {
                    title    = applyTriggerChar(def.label),
                    checked  = (enabled_t and not paused) or nil,
                    disabled = paused or nil,
                    fn       = not paused and (function(k, lbl) return function()
                        local nv = true
                        if keymap and type(keymap.is_terminator_enabled) == "function" then
                            nv = not keymap.is_terminator_enabled(k)
                            if type(keymap.set_terminator_enabled) == "function" then
                                pcall(keymap.set_terminator_enabled, k, nv)
                            end
                        end
                        state.terminator_states[k] = nv
                        save_prefs()
                        notify_feature("Expanseur : " .. applyTriggerChar(lbl), nv)
                        updateMenu()
                    end end)(def.key, def.label) or nil,
                }
            end
        end
        table.insert(menu, { title = "Expanseurs", disabled = paused or nil, menu = exp_sub })
        table.insert(menu, { title = "-" })

        local delay_menu = {}

        local function make_delay_item(title, key, default_val, is_base)
            local cur_val = is_base and state.expansion_delay or (state.delays[key] or default_val)
            local cur_ms = math.floor(cur_val * 1000 + 0.5)
            local def_ms = math.floor(default_val * 1000 + 0.5)
            
            return {
                title    = title .. " : " .. cur_ms .. " ms" .. (cur_ms == def_ms and " (défaut)" or ""),
                disabled = paused or nil,
                fn       = not paused and function()
                    local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
                        title,
                        "Entrez le délai en millisecondes (entier ≥ 0) :",
                        tostring(cur_ms), "OK", "Annuler"
                    )
                    if not ok_p or btn ~= "OK" then return end
                    
                    local val = tonumber(raw)
                    if not val or val < 0 or val ~= math.floor(val) then
                        pcall(function() hs.notify.new({ title = "Délai invalide", informativeText = "Veuillez saisir un entier ≥ 0." }):send() end)
                        return
                    end
                    
                    local new_sec = val / 1000
                    if is_base then
                        state.expansion_delay = new_sec
                        if keymap and type(keymap.set_base_delay) == "function" then pcall(keymap.set_base_delay, new_sec) end
                    else
                        state.delays[key] = new_sec
                        if keymap and type(keymap.DELAYS) == "table" then
                            keymap.DELAYS[key] = new_sec
                            local max_d = 0
                            for k, d in pairs(DEFAULT_DELAYS) do
                                local v = state.delays[k] or d
                                if v > max_d then max_d = v end
                            end
                            keymap.WORD_TIMEOUT_SEC = math.min(5.0, max_d + 0.5)
                        end
                    end
                    save_prefs()
                    updateMenu()
                end or nil,
            }
        end

        local def_base = (keymap and keymap.DEFAULT_BASE_DELAY_SEC) or 0.75
        table.insert(delay_menu, make_delay_item("Défaut (autres catégories)", nil, def_base, true))
        table.insert(delay_menu, { title = "-" })
        table.insert(delay_menu, make_delay_item("Touche ★", "STAR_TRIGGER", DEFAULT_DELAYS.STAR_TRIGGER, false))
        table.insert(delay_menu, make_delay_item("Auto-complétions (ex: numéros)", "dynamichotstrings", DEFAULT_DELAYS.dynamichotstrings, false))
        table.insert(delay_menu, make_delay_item("Autocorrections", "autocorrection", DEFAULT_DELAYS.autocorrection, false))
        table.insert(delay_menu, make_delay_item("Roulements", "rolls", DEFAULT_DELAYS.rolls, false))
        table.insert(delay_menu, make_delay_item("Réductions de SFBs", "sfbsreduction", DEFAULT_DELAYS.sfbsreduction, false))
        table.insert(delay_menu, make_delay_item("Réductions de distances", "distancesreduction", DEFAULT_DELAYS.distancesreduction, false))
        
        table.insert(delay_menu, { title = "-" })
        table.insert(delay_menu, {
            title    = "Réinitialiser tous les délais",
            disabled = paused or nil,
            fn       = not paused and function()
                state.expansion_delay = def_base
                state.delays = {}
                if keymap then
                    if type(keymap.set_base_delay) == "function" then pcall(keymap.set_base_delay, def_base) end
                    if type(keymap.DELAYS) == "table" then
                        local max_d = 0
                        for k, v in pairs(DEFAULT_DELAYS) do 
                            keymap.DELAYS[k] = v 
                            if v > max_d then max_d = v end
                        end
                        keymap.WORD_TIMEOUT_SEC = math.min(5.0, max_d + 0.5)
                    end
                end
                save_prefs()
                updateMenu()
            end or nil,
        })

        table.insert(menu, { title = "Délais d’expansion", disabled = paused or nil, menu = delay_menu })
        table.insert(menu, { title = "-" })

        table.insert(menu, {
            title    = "Caractère de déclenchement : " .. state.trigger_char,
            disabled = paused or nil,
            fn       = not paused and function()
                local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
                    "Caractère de déclenchement",
                    "Entrez le caractère à utiliser (actuel : " .. state.trigger_char .. ") :",
                    state.trigger_char, "OK", "Annuler"
                )
                if ok_p and btn == "OK" and type(raw) == "string" and raw ~= "" then
                    local new_char = raw:match("^([%z\1-\127\194-\244][\128-\191]*)") or raw:sub(1,1)
                    if new_char and new_char ~= state.trigger_char then
                        state.trigger_char = new_char
                        if keymap and type(keymap.set_trigger_char) == "function" then
                            pcall(keymap.set_trigger_char, new_char)
                        end
                        if type(hotstring_editor.set_trigger_char) == "function" then
                            pcall(hotstring_editor.set_trigger_char, new_char)
                        end
                        save_prefs()
                        do_reload("menu")
                    end
                end
            end or nil,
        })
        table.insert(menu, {
            title    = "   ↳ Réinitialiser (défaut : ★)",
            disabled = (paused or state.trigger_char == "★") or nil,
            fn       = (not paused and state.trigger_char ~= "★") and function()
                state.trigger_char = "★"
                if keymap and type(keymap.set_trigger_char) == "function" then pcall(keymap.set_trigger_char, "★") end
                save_prefs(); do_reload("menu")
            end or nil,
        })

        return { title = "Paramètres Hotstrings", menu = menu }
    end



    -- ====================================
    -- ===== 3.5) Menu: Personal Info =====
    -- ====================================

    buildPersonalInfoItems = function(description)
        if not personal_info then return nil end
        description = applyTriggerChar(description)
        return {
            {
                title   = description,
                checked = state.personal_info or nil,
                fn      = function()
                    state.personal_info = not state.personal_info
                    if state.personal_info then 
                        if type(personal_info.enable) == "function" then pcall(personal_info.enable) end
                    else 
                        if type(personal_info.disable) == "function" then pcall(personal_info.disable) end 
                    end
                    save_prefs()
                    notify_feature(description or "Informations personnelles", state.personal_info)
                    updateMenu()
                end,
            },
            {
                title = "   ↳ Modifier les informations…",
                fn    = function() hs.timer.doAfter(0.1, function() pcall(personal_info.open_editor) end) end,
            },
        }
    end

    local function buildPersonnelGroupItem()
        local paused   = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local name     = "personal"
        local found = false
        for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
            if get_group_name(f) == name then found = true; break end
        end
        if not found then return nil end

        local enabled  = groupEnabled(name)
        local sections = keymap and type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
        local has_secs = type(sections) == "table" and #sections > 0

        local total, has_count = 0, false
        if enabled and has_secs then
            for _, sec in ipairs(sections) do
                if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
                    and (keymap and type(keymap.is_section_enabled) == "function" and keymap.is_section_enabled(name, sec.name)) then
                    if sec.count ~= nil then has_count = true; total = total + tonumber(sec.count) end
                end
            end
        end

        local base_label = groupLabel(name)
        local item = {
            title   = has_count and (base_label .. " (" .. fmt_count(total) .. ")") or base_label,
            checked = (enabled and not paused) or nil,
            fn      = toggleGroupFn(name),
        }

        if has_secs then
            local override    = (type(state.sections_order_overrides) == "table" and state.sections_order_overrides)[name]
            local ordered_secs

            if type(override) == "table" then
                local by_name = {}
                for _, sec in ipairs(sections) do if type(sec) == "table" then by_name[sec.name] = sec end end
                local seen = {}
                ordered_secs = {}
                for _, entry in ipairs(override) do
                    if entry == "-" then table.insert(ordered_secs, { name = "-" })
                    elseif by_name[entry] then
                        table.insert(ordered_secs, by_name[entry]); seen[entry] = true
                    end
                end
                for _, sec in ipairs(sections) do
                    if type(sec) == "table" and not seen[sec.name] and sec.name ~= "-" then
                        table.insert(ordered_secs, sec)
                    end
                end
            else
                ordered_secs = sections
            end

            local sec_menu = {}
            for _, sec in ipairs(ordered_secs) do
                if type(sec) == "table" then
                    if sec.name == "-" then
                        sec_menu[#sec_menu + 1] = { title = "-" }
                    elseif sec.is_module_placeholder then
                        local ms       = type(module_sections) == "table" and module_sections[name]
                        local ms_entry = type(ms) == "table" and ms[sec.name]
                        local mod_id   = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
                        if mod_id == "personal_info" then
                            local ms_desc  = type(ms_entry) == "table" and ms_entry.description or nil
                            local pi_items = buildPersonalInfoItems(applyTriggerChar(ms_desc))
                            if type(pi_items) == "table" then
                                for _, pi in ipairs(pi_items) do
                                    if type(pi) == "table" then
                                        if pi.checked ~= nil and paused then pi.checked = nil end
                                        if not enabled or paused then pi.fn = nil; pi.disabled = true end
                                        sec_menu[#sec_menu + 1] = pi
                                    end
                                end
                            end
                        end
                    else
                        local sec_on = keymap and type(keymap.is_section_enabled) == "function" and keymap.is_section_enabled(name, sec.name) or false
                        local lbl    = (type(sec.description) == "string" and sec.description ~= "")
                                       and sec.description or tostring(sec.name):gsub("_", " ")
                        lbl = applyTriggerChar(lbl)
                        sec_menu[#sec_menu + 1] = {
                            title    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
                            checked  = (sec_on and not paused) or nil,
                            fn       = (enabled and not paused)
                                       and toggleSectionFn(name, sec.name, lbl) or nil,
                            disabled = not enabled or paused or nil,
                        }
                    end
                end
            end
            item.menu = sec_menu
        end
        return item
    end



    -- ====================================
    -- ===== 3.6) Menu: Custom Editor =====
    -- ====================================

    local function buildCustomEditorItem()
        local paused          = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local custom_sections = keymap and type(keymap.get_sections) == "function" and keymap.get_sections("custom") or nil
        local custom_enabled  = groupEnabled("custom")

        local total_count = 0
        if type(custom_sections) == "table" then
            for _, sec in ipairs(custom_sections) do
                if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder and sec.count ~= nil then
                    total_count = total_count + tonumber(sec.count)
                end
            end
        end

        local base_title = "Hotstrings personnels"
        local title_str  = total_count > 0
            and (base_title .. " (" .. fmt_count(total_count) .. ")")
            or  base_title

        local function default_sc()
            return { mods = {"ctrl"}, key = state.trigger_char }
        end
        local function sc_is_default(sc)
            if not sc or sc == false or type(sc) ~= "table" then return false end
            local def = default_sc()
            if sc.key ~= def.key then return false end
            if #(sc.mods or {}) ~= 1 then return false end
            return sc.mods[1] == "ctrl"
        end
        local function sc_label()
            local sc = state.custom_editor_shortcut
            if not sc or sc == false then return "Aucun" end
            if sc_is_default(sc) then
                return "Ctrl+" .. state.trigger_char .. " (défaut)"
            end
            local mods_str = table.concat(sc.mods or {}, "+")
            return mods_str ~= "" and (mods_str .. "+" .. (sc.key or "?"):upper())
                    or (sc.key or "?"):upper()
        end
        local function apply_shortcut(mods, key)
            if mods and key then
                state.custom_editor_shortcut = { mods = mods, key = key }
                if type(hotstring_editor.set_shortcut) == "function" then pcall(hotstring_editor.set_shortcut, mods, key) end
            else
                state.custom_editor_shortcut = false
                if type(hotstring_editor.clear_shortcut) == "function" then pcall(hotstring_editor.clear_shortcut) end
            end
            save_prefs(); updateMenu()
        end

        local function default_section_label()
            if not state.custom_default_section then return "Aucune" end
            if type(custom_sections) == "table" then
                for _, sec in ipairs(custom_sections) do
                    if type(sec) == "table" and sec.name == state.custom_default_section then
                        local lbl = (type(sec.description) == "string" and sec.description ~= "")
                            and sec.description or tostring(sec.name):gsub("_", " ")
                        return applyTriggerChar(lbl)
                    end
                end
            end
            return state.custom_default_section
        end

        local cat_menu = {}
        table.insert(cat_menu, {
            title   = "Aucune",
            checked = (not state.custom_default_section) or nil,
            fn      = function()
                state.custom_default_section = nil
                if type(hotstring_editor.set_default_section) == "function" then
                    pcall(hotstring_editor.set_default_section, nil)
                end
                save_prefs(); updateMenu()
            end,
        })
        
        if type(custom_sections) == "table" then
            local has_real = false
            for _, sec in ipairs(custom_sections) do
                if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then has_real = true; break end
            end
            if has_real then
                table.insert(cat_menu, { title = "-" })
                for _, sec in ipairs(custom_sections) do
                    if type(sec) == "table" then
                        if sec.name == "-" then
                            table.insert(cat_menu, { title = "-" })
                        elseif not sec.is_module_placeholder then
                            local lbl  = (type(sec.description) == "string" and sec.description ~= "")
                                and sec.description or tostring(sec.name):gsub("_", " ")
                            lbl = applyTriggerChar(lbl)
                            local sname = sec.name
                            table.insert(cat_menu, {
                                title   = lbl,
                                checked = (state.custom_default_section == sname) or nil,
                                fn      = function()
                                    state.custom_default_section = sname
                                    if type(hotstring_editor.set_default_section) == "function" then
                                        pcall(hotstring_editor.set_default_section, sname)
                                    end
                                    save_prefs(); updateMenu()
                                end,
                            })
                        end
                    end
                end
            end
        end

        local def_sc      = default_sc()
        local already_def = sc_is_default(state.custom_editor_shortcut)
        local sc_menu = {
            {
                title   = "Aucun (désactiver)",
                checked = (state.custom_editor_shortcut == false) or nil,
                fn      = function() apply_shortcut(nil, nil) end,
            },
            { title = "-" },
            {
                title = "Personnaliser…",
                fn    = function()
                    local current_str = ""
                    if type(state.custom_editor_shortcut) == "table" then
                        current_str = table.concat(state.custom_editor_shortcut.mods or {}, "+")
                            .. "+" .. (state.custom_editor_shortcut.key or "")
                    end
                    local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
                        "Raccourci personnalisé",
                        "Format : mods+touche  (ex : cmd+alt+p  ou  ctrl+shift+e)\n"
                            .. "Mods disponibles : cmd, alt, ctrl, shift",
                        current_str, "OK", "Annuler"
                    )
                    if not ok_p or btn ~= "OK" or type(raw) ~= "string" or raw == "" then return end
                    raw = raw:match("^%s*(.-)%s*$"):lower()
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
                    apply_shortcut(mods, key)
                end,
            },
            {
                title    = "   ↳ Réinitialiser (défaut : Ctrl+" .. state.trigger_char .. ")",
                disabled = already_def or nil,
                fn       = not already_def and function()
                    apply_shortcut(def_sc.mods, def_sc.key)
                end or nil,
            },
            { title = "-" },
            {
                title = "Catégorie par défaut : " .. default_section_label(),
                menu  = cat_menu,
            },
            { title = "-" },
            {
                title   = "Fermer l’UI après ajout d’une hotstring avec le raccourci",
                checked = state.custom_close_on_add or nil,
                fn      = function()
                    state.custom_close_on_add = not state.custom_close_on_add
                    if type(hotstring_editor.set_close_on_add) == "function" then
                        pcall(hotstring_editor.set_close_on_add, state.custom_close_on_add)
                    end
                    save_prefs(); updateMenu()
                end,
            },
        }

        local menu_items = {
            {
                title    = "Ouvrir l’éditeur",
                disabled = paused or nil,
                fn       = not paused and function()
                    hs.timer.doAfter(0, function() pcall(hotstring_editor.open) end)
                end or nil,
            },
            {
                title = "Raccourci : " .. sc_label(),
                menu  = sc_menu,
            },
        }

        if type(custom_sections) == "table" and #custom_sections > 0 then
            local has_real = false
            for _, sec in ipairs(custom_sections) do
                if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then has_real = true; break end
            end
            if has_real then
                table.insert(menu_items, { title = "-" })
                for _, sec in ipairs(custom_sections) do
                    if type(sec) == "table" then
                        if sec.name == "-" then
                            table.insert(menu_items, { title = "-" })
                        elseif not sec.is_module_placeholder then
                            local sec_on = keymap and type(keymap.is_section_enabled) == "function" and keymap.is_section_enabled("custom", sec.name) or false
                            local lbl    = (type(sec.description) == "string" and sec.description ~= "")
                                           and sec.description or tostring(sec.name):gsub("_", " ")
                            lbl = applyTriggerChar(lbl)
                            table.insert(menu_items, {
                                title    = sec.count ~= nil
                                    and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
                                checked  = (sec_on and not paused) or nil,
                                fn       = (custom_enabled and not paused)
                                           and toggleSectionFn("custom", sec.name, lbl) or nil,
                                disabled = not custom_enabled or paused or nil,
                            })
                        end
                    end
                end
            end
        end

        return {
            title   = title_str,
            checked = (custom_enabled and not paused) or nil,
            fn      = function()
                local will_enable = not custom_enabled
                state.hotstrings["custom"] = will_enable
                if will_enable then
                    if keymap and type(keymap.enable_group) == "function" then pcall(keymap.enable_group, "custom") end
                    if not state.keymap then 
                        state.keymap = true; 
                        if keymap and type(keymap.start) == "function" then pcall(keymap.start) end 
                    end
                else
                    if keymap and type(keymap.disable_group) == "function" then pcall(keymap.disable_group, "custom") end
                end
                save_prefs()
                notify_feature(base_title, will_enable)
                updateMenu()
            end,
            menu = menu_items,
        }
    end



    -- ==========================================
    -- ===== 3.7) Menu: Tools & Features ========
    -- ==========================================

    local function buildGesturesItem()
        if not gestures then return nil end
        local paused = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local item   = {
            title   = "Gestes",
            checked = (state.gestures and not paused) or nil,
            fn      = function()
                state.gestures = not state.gestures
                if gestures then
                    if state.gestures then 
                        if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end 
                    else 
                        if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end 
                    end
                end
                save_prefs()
                notify_feature("Gestes", state.gestures)
                updateMenu()
            end,
        }

        local function slotItem(slot, isAxis)
            local current   = type(gestures.get_action) == "function" and gestures.get_action(slot) or nil
            local slotLbl   = SLOT_LABELS[slot] or slot
            local actionLbl = type(gestures.get_action_label) == "function" and gestures.get_action_label(current) or "Inconnu"
            local names     = isAxis and gestures.AX_NAMES or gestures.SG_NAMES
            local submenu   = {}
            if type(names) == "table" then
                for _, aname in ipairs(names) do
                    table.insert(submenu, {
                        title    = type(gestures.get_action_label) == "function" and gestures.get_action_label(aname) or aname,
                        checked  = ((current == aname) and not paused) or nil,
                        disabled = not state.gestures or paused or nil,
                        fn       = (state.gestures and not paused) and (function(a) return function()
                            if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, a) end
                            local conflict = type(gestures.on_action_changed) == "function" and gestures.on_action_changed(slot, a) or nil
                            save_prefs()
                            updateMenu()
                            if type(conflict) == "table" then
                                hs.timer.doAfter(0.3, function()
                                    pcall(hs.focus)
                                    local ok_c, clicked = pcall(hs.dialog.blockAlert,
                                        "⚠️  Conflit potentiel", conflict.msg or "",
                                        "Ouvrir Réglages", "Plus tard", "warning")
                                    if ok_c and clicked == "Ouvrir Réglages" then
                                        pcall(hs.execute, string.format("open \"%s\"", conflict.url or ""))
                                    end
                                end)
                            end
                        end end)(aname) or nil,
                    })
                end
            end
            return {
                title    = slotLbl .. " : " .. actionLbl,
                disabled = not state.gestures or paused or nil,
                menu     = submenu,
            }
        end

        local function section(slots, isAxis)
            local its = {}
            for _, slot in ipairs(slots) do table.insert(its, slotItem(slot, isAxis)) end
            return its
        end

        local gm = {}
        table.insert(gm, slotItem("swipe_2_diag", true)); table.insert(gm, { title = "-" })
        table.insert(gm, slotItem("tap_3", false))
        for _, it in ipairs(section({"swipe_3_horiz","swipe_3_diag"}, true))  do table.insert(gm, it) end
        for _, it in ipairs(section({"swipe_3_up",   "swipe_3_down"}, false)) do table.insert(gm, it) end
        table.insert(gm, { title = "-" })
        table.insert(gm, slotItem("tap_4", false))
        for _, it in ipairs(section({"swipe_4_horiz","swipe_4_diag"}, true))  do table.insert(gm, it) end
        for _, it in ipairs(section({"swipe_4_up",   "swipe_4_down"}, false)) do table.insert(gm, it) end
        table.insert(gm, { title = "-" })
        table.insert(gm, slotItem("tap_5", false))
        for _, it in ipairs(section({"swipe_5_horiz","swipe_5_diag"}, true))  do table.insert(gm, it) end
        for _, it in ipairs(section({"swipe_5_up",   "swipe_5_down"}, false)) do table.insert(gm, it) end
        item.menu = gm
        return item
    end

    local function buildRaccourcisItem()
        if not shortcuts then return nil end
        local paused = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local item   = {
            title   = "Raccourcis",
            checked = (state.shortcuts and not paused) or nil,
            fn      = function()
                state.shortcuts = not state.shortcuts
                if state.shortcuts then 
                    if type(shortcuts.start) == "function" then pcall(shortcuts.start) end 
                else 
                    if type(shortcuts.stop) == "function" then pcall(shortcuts.stop) end 
                end
                save_prefs()
                notify_feature("Raccourcis", state.shortcuts)
                updateMenu()
            end,
        }

        local function pretty_key(id)
            if id == "at_hash" then return "Touche @/#" end
            local parts = {}
            for p in id:gmatch("[^_]+") do table.insert(parts, p) end
            if #parts == 0 then return id end
            local key = parts[#parts]
            if key == "star" or key == "asterisk" then key = state.trigger_char end
            local mods = {}
            for i = 1, #parts - 1 do
                local p   = parts[i]
                local lbl = ({ ctrl="Ctrl", cmd="Cmd", alt="Alt", option="Alt", shift="Shift" })[p]
                table.insert(mods, lbl or (p:sub(1,1):upper() .. p:sub(2)))
            end
            return (#mods > 0 and table.concat(mods, " + ") .. " + " or "") .. key:upper()
        end

        local s_menu = {}
        local last_was_non_ctrl, separator_inserted = false, false
        
        if type(shortcuts.list_shortcuts) == "function" then
            local ok, list = pcall(shortcuts.list_shortcuts)
            if ok and type(list) == "table" then
                for _, s in ipairs(list) do
                    if type(s) == "table" and s.id then
                        local is_ctrl = s.id:sub(1, 5) == "ctrl_"
                        if not separator_inserted and last_was_non_ctrl and is_ctrl then
                            table.insert(s_menu, { title = "-" })
                            separator_inserted = true
                        end
                        if not is_ctrl then last_was_non_ctrl = true end

                        local is_on = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(s.id) or s.enabled
                        local desc  = applyTriggerChar((s.label or ""):gsub("^%s*(.-)%s*$", "%1"))
                        
                        table.insert(s_menu, {
                            title    = pretty_key(s.id) .. " : " .. (desc ~= "" and desc or s.id),
                            checked  = (is_on and not paused) or nil,
                            disabled = not state.shortcuts or paused or nil,
                            fn       = (state.shortcuts and not paused) and (function(id) 
                                return function()
                                    local on = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(id) or false
                                    if on then 
                                        if type(shortcuts.disable) == "function" then pcall(shortcuts.disable, id) end 
                                    else 
                                        if type(shortcuts.enable) == "function" then pcall(shortcuts.enable, id) end 
                                    end
                                    save_prefs()
                                    notify_feature(pretty_key(id), not on)
                                    updateMenu()
                                end 
                            end)(s.id) or nil,
                        })
                        
                        if s.id == "ctrl_g" then
                            table.insert(s_menu, {
                                title    = "   ↳ Modifier l’URL ChatGPT…",
                                disabled = paused or nil,
                                fn       = not paused and function()
                                    local ok_p, clicked, url = pcall(hs.dialog.textPrompt, "URL ChatGPT",
                                        "URL ouverte par Ctrl+G :",
                                        state.chatgpt_url or "", "OK", "Annuler")
                                    if ok_p and clicked == "OK" and type(url) == "string" and url ~= "" then
                                        state.chatgpt_url = url
                                        save_prefs()
                                        updateMenu()
                                    end
                                end or nil,
                            })
                        end
                    end
                end
            end
        end
        
        item.menu = s_menu
        return item
    end

    local function buildScriptControlItem()
        if not script_control then return nil end
        local paused     = type(script_control.is_paused) == "function" and script_control.is_paused() or false
        local actions    = type(script_control.ACTIONS) == "table" and script_control.ACTIONS or {}
        local act_labels = type(script_control.ACTION_LABELS) == "table" and script_control.ACTION_LABELS or {}
        local enabled    = state.script_control_enabled

        local function key_submenu(keyname)
            local current = state.script_control_shortcuts[keyname] or "none"
            local sub = {}
            for _, act in ipairs(actions) do
                table.insert(sub, {
                    title    = act_labels[act] or act,
                    checked  = ((current == act) and not paused) or nil,
                    disabled = not enabled or paused or nil,
                    fn       = (enabled and not paused) and (function(a) return function()
                        state.script_control_shortcuts[keyname] = a
                        if type(script_control.set_shortcut_action) == "function" then pcall(script_control.set_shortcut_action, keyname, a) end
                        save_prefs()
                        updateMenu()
                    end end)(act) or nil,
                })
            end
            return sub
        end

        local cur_return = state.script_control_shortcuts.return_key or "none"
        local cur_back   = state.script_control_shortcuts.backspace  or "none"
        return {
            title   = "Contrôle du script",
            checked = (enabled and not paused) or nil,
            fn      = function()
                state.script_control_enabled = not state.script_control_enabled
                if type(script_control.set_shortcut_action) == "function" then
                    if state.script_control_enabled then
                        pcall(script_control.set_shortcut_action, "return_key", state.script_control_shortcuts.return_key)
                        pcall(script_control.set_shortcut_action, "backspace",  state.script_control_shortcuts.backspace)
                    else
                        pcall(script_control.set_shortcut_action, "return_key", "none")
                        pcall(script_control.set_shortcut_action, "backspace",  "none")
                    end
                end
                save_prefs()
                notify_feature("Contrôle du script", state.script_control_enabled)
                updateMenu()
            end,
            menu = {
                { title = "Option droite + ↩ : " .. (act_labels[cur_return] or cur_return),
                   disabled = not enabled or paused or nil, menu = key_submenu("return_key") },
                { title = "Option droite + ⌫ : " .. (act_labels[cur_back] or cur_back),
                   disabled = not enabled or paused or nil, menu = key_submenu("backspace") },
                { title = "-" },
                { title    = "Chemin du script AHK…",
                   disabled = paused or nil,
                   fn       = not paused and function()
                    local ok_p, btn, path = pcall(hs.dialog.textPrompt, "Script AHK",
                        "Chemin du fichier AHK source :",
                        state.ahk_source_path or "", "OK", "Annuler")
                    if ok_p and btn == "OK" and type(path) == "string" then
                        state.ahk_source_path = path
                        save_prefs()
                        updateMenu()
                    end
                   end or nil },
            },
        }
    end



    -- =================================
    -- ===== 3.8) Final Assembly =======
    -- =================================

    local function set_all_enabled(enabled)
        state.keymap = enabled; state.gestures = enabled
        state.shortcuts = enabled
        if personal_info then state.personal_info = enabled end
        
        for name in pairs(state.hotstrings) do 
            state.hotstrings[name] = enabled 
        end

        if keymap then
            for name in pairs(state.hotstrings) do
                if name ~= "custom" then 
                    if type(keymap.disable_group) == "function" then pcall(keymap.disable_group, name) end
                    if enabled and type(keymap.enable_group) == "function" then pcall(keymap.enable_group, name) end
                end
            end
            if enabled then
                if type(keymap.start) == "function" then pcall(keymap.start) end
            else
                if type(keymap.stop) == "function" then pcall(keymap.stop) end
            end
        end

        if gestures then
            if enabled then 
                if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end 
            else 
                if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end 
            end
        end
        
        if shortcuts then
            if enabled then 
                if type(shortcuts.start) == "function" then pcall(shortcuts.start) end 
            else 
                if type(shortcuts.stop) == "function" then pcall(shortcuts.stop) end 
            end
            if type(shortcuts.list_shortcuts) == "function" then
                local ok, list = pcall(shortcuts.list_shortcuts)
                if ok and type(list) == "table" then
                    for _, s in ipairs(list) do
                        if type(s) == "table" and s.id then
                            if enabled then 
                                if type(shortcuts.enable) == "function" then pcall(shortcuts.enable, s.id) end 
                            else 
                                if type(shortcuts.disable) == "function" then pcall(shortcuts.disable, s.id) end 
                            end
                        end
                    end
                end
            end
        end
        
        if personal_info then
            if enabled then 
                if type(personal_info.enable) == "function" then pcall(personal_info.enable) end 
            else 
                if type(personal_info.disable) == "function" then pcall(personal_info.disable) end 
            end
        end

        save_prefs()
        notify_feature(enabled
            and "Toutes les fonctionnalités ont été activées."
            or  "Toutes les fonctionnalités ont été désactivées.", enabled)
        updateMenu()
    end

    updateMenu = function()
        local items = {}
        table.insert(items, {
            title = hs.styledtext.new("Ergopti+", {
                font           = { name = "Helvetica-Bold", size = 16 },
                paragraphStyle = { alignment = "center" },
            }),
            fn = function() end,
        })
        table.insert(items, { title = "-" })

        for _, it in ipairs(buildHotstringsItems()) do table.insert(items, it) end
        table.insert(items, buildHotstringsManagementItem())

        table.insert(items, { title = "-" })
        local personnel_item = buildPersonnelGroupItem()
        if personnel_item then table.insert(items, personnel_item) end
        table.insert(items, buildCustomEditorItem())

        table.insert(items, { title = "-" })
        local llm_item = type(llm_handler.build_item) == "function" and llm_handler.build_item() or nil
        if llm_item then table.insert(items, llm_item) end

        table.insert(items, { title = "-" })
        local g_item = buildGesturesItem()
        if g_item then table.insert(items, g_item) end
        
        local r_item = buildRaccourcisItem()
        if r_item then table.insert(items, r_item) end

        local sc = buildScriptControlItem()
        if sc then table.insert(items, sc) end

        table.insert(items, { title = "-" })
        table.insert(items, { title = "☑ Activer toutes les fonctionnalités",
            fn = function() set_all_enabled(true)  end })
        table.insert(items, { title = "☐ Désactiver toutes les fonctionnalités",
            fn = function() set_all_enabled(false) end })
        table.insert(items, { title = "-" })
        table.insert(items, { title = "Ouvrir init.lua",
            fn = function() pcall(hs.execute, string.format("open \"%sinit.lua\"", base_dir)) end })
        table.insert(items, { title = "Console",
            fn = function() pcall(hs.openConsole) end })
        table.insert(items, { title = "Préférences",
            fn = function() pcall(hs.openPreferences) end })
        table.insert(items, { title = "Recharger",
            fn = function() do_reload("menu") end })
        table.insert(items, { title = "Quitter",
            fn = function() hs.timer.doAfter(0.1, function() os.exit(0) end) end })

        pcall(function() myMenu:setMenu({}) end)
        hs.timer.doAfter(0.02, function() pcall(function() myMenu:setMenu(items) end) end)
    end

    updateMenu()

    local function reloadConfig(files)
        if hs.timer.secondsSinceEpoch() < _suppress_watcher_until then return end
        if type(files) == "table" then
            for _, file in pairs(files) do
                if type(file) == "string" then
                    local filename = file:match("[^/]+$")
                    if file:sub(-4) == ".lua" or filename == "config.json" then
                        do_reload("watcher"); return
                    end
                end
            end
        end
    end
    
    local ok_w, configWatcher = pcall(hs.pathwatcher.new, base_dir, reloadConfig)
    if ok_w and configWatcher then
        pcall(function() configWatcher:start() end)
    else
        configWatcher = nil
    end

    M._menu    = myMenu
    M._watcher = configWatcher

    pcall(notifications.notify, "Script prêt ! 🚀")
    return myMenu, configWatcher
end

return M
