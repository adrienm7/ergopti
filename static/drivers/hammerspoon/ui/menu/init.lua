-- ui/menu/init.lua

-- ===========================================================================
-- Menu UI Module.
--
-- Orchestrates the macOS Menu Bar icon (System Tray). Acts as the central 
-- hub tying together settings for hotstrings, gestures, shortcuts, etc.
-- UI components have been extracted into dedicated menu_* modules.
-- ===========================================================================

local M = {}

local hs               = hs
local notifications    = require("lib.notifications")
local llm_mod          = require("modules.llm")
local hotstring_editor = require("ui.hotstring_editor")

-- Load isolated sub-menu builders safely
local ok_gest, menu_gestures      = pcall(require, "ui.menu.menu_gestures")
local ok_short, menu_shortcuts    = pcall(require, "ui.menu.menu_shortcuts")
local ok_script, menu_script_ctrl = pcall(require, "ui.menu.menu_script_control")
local ok_hot, menu_hotstrings     = pcall(require, "ui.menu.menu_hotstrings")
local ok_llm, menu_llm            = pcall(require, "ui.menu.menu_llm")

M._active_tasks = {}

local function get_group_name(file)
    if type(file) ~= "string" then return "" end
    return file:match("^(.*)%.lua$") or file:match("^(.*)%.toml$") or file
end

--- Initializes the menu bar app, loads configurations, and binds modules
function M.start(base_dir, hotfiles, gestures, keymap, shortcuts, personal_info, module_sections, script_control)
    base_dir = type(base_dir) == "string" and base_dir or (hs.configdir .. "/")
    
    local ok, myMenu = pcall(hs.menubar.new)
    if not ok or not myMenu then
        print("[menu] Failed to create hs.menubar object.")
        return nil, nil
    end

    local updateMenu

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
        expansion_delay          = (keymap and keymap.BASE_DELAY_SEC_DEFAULT) or 0.75,
        delays                   = {},
        script_control_shortcuts = { return_key = "pause", backspace = "reload" },
        script_control_enabled   = true,
        ahk_source_path          = "",
        preview_enabled          = true,
        llm_enabled              = llm_mod and llm_mod.DEFAULT_LLM_ENABLED  or false,
        llm_debounce             = (keymap and keymap.LLM_DEBOUNCE_DEFAULT) or 0.5,
        llm_model                = llm_mod and llm_mod.DEFAULT_LLM_MODEL    or "llama3.2",
        trigger_char             = "★",
        llm_context_length       = (keymap and keymap.LLM_CONTEXT_LENGTH_DEFAULT) or 500,
        llm_reset_on_nav         = true,
        llm_temperature          = (keymap and keymap.LLM_TEMPERATURE_DEFAULT) or 0.1,
        llm_max_predict          = (keymap and keymap.LLM_MAX_PREDICT_DEFAULT) or 40,
        llm_num_predictions      = (keymap and keymap.LLM_NUM_PREDICTIONS_DEFAULT) or 3,
        llm_arrow_nav_enabled    = false,
        llm_nav_modifiers        = (keymap and keymap.LLM_NAV_MODIFIERS_DEFAULT) or {},
        llm_show_info_bar        = false,
        llm_val_modifiers        = (keymap and keymap.LLM_VAL_MODIFIERS_DEFAULT) or {"alt"},
        llm_pred_indent          = (keymap and keymap.LLM_PRED_INDENT_DEFAULT) or -3,
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
            llm_nav_modifiers        = state.llm_nav_modifiers,
            llm_show_info_bar        = state.llm_show_info_bar,
            llm_val_modifiers        = state.llm_val_modifiers,
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
            
            if saved.llm_debounce      ~= nil then state.llm_debounce      = saved.llm_debounce    end
            if type(saved.llm_model)   == "string" then state.llm_model    = saved.llm_model       end
            if saved.llm_context_length ~= nil    then state.llm_context_length = saved.llm_context_length end
            if saved.llm_reset_on_nav  ~= nil     then state.llm_reset_on_nav   = saved.llm_reset_on_nav   end
            if saved.llm_temperature   ~= nil     then state.llm_temperature    = saved.llm_temperature    end
            if saved.llm_max_predict   ~= nil     then state.llm_max_predict    = saved.llm_max_predict    end
            if saved.llm_num_predictions ~= nil   then state.llm_num_predictions  = saved.llm_num_predictions  end
            if saved.llm_arrow_nav_enabled ~= nil then state.llm_arrow_nav_enabled = saved.llm_arrow_nav_enabled end
            if saved.llm_show_info_bar ~= nil     then state.llm_show_info_bar   = saved.llm_show_info_bar   end
            if saved.llm_pred_indent   ~= nil     then state.llm_pred_indent       = saved.llm_pred_indent       end
            if type(saved.llm_user_models) == "table" then state.llm_user_models       = saved.llm_user_models       end
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

            if keymap and type(keymap.set_delay) == "function" then
                local defs = keymap.DELAYS_DEFAULT or {}
                for k, default_val in pairs(defs) do
                    local v = state.delays[k] or default_val
                    pcall(keymap.set_delay, k, v)
                end
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
                { fn = "set_llm_nav_modifiers",   val = state.llm_nav_modifiers },
                { fn = "set_llm_show_info_bar",   val = state.llm_show_info_bar },
                { fn = "set_llm_val_modifiers",   val = state.llm_val_modifiers },
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

    -- Setup LLM handler safely
    local llm_handler = nil
    if ok_llm and menu_llm and type(menu_llm.create) == "function" then
        local ok_h, res = pcall(menu_llm.create, {
            state          = state,
            active_tasks   = M._active_tasks,
            update_icon    = update_icon,
            update_menu    = function() updateMenu() end,
            save_prefs     = save_prefs,
            keymap         = keymap,
            script_control = script_control,
        })
        if ok_h then llm_handler = res end
    end
    
    if llm_handler and type(llm_handler.check_startup) == "function" then
        pcall(llm_handler.check_startup)
    end

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
        -- Context generated dynamically at each update for accurate paused state
        local ctx = {
            state            = state,
            paused           = script_control and type(script_control.is_paused) == "function" and script_control.is_paused() or false,
            save_prefs       = save_prefs,
            updateMenu       = updateMenu,
            notify_feature   = notify_feature,
            do_reload        = do_reload,
            applyTriggerChar = applyTriggerChar,
            get_group_name   = get_group_name,
            keymap           = keymap,
            hotfiles         = hotfiles,
            module_sections  = module_sections,
            hotstring_editor = hotstring_editor,
            personal_info    = personal_info,
            gestures         = gestures,
            shortcuts        = shortcuts,
            script_control   = script_control,
        }

        local items = {}
        table.insert(items, {
            title = hs.styledtext.new("Ergopti+", {
                font           = { name = "Helvetica-Bold", size = 16 },
                paragraphStyle = { alignment = "center" },
            }),
            fn = function() end,
        })
        table.insert(items, { title = "-" })

        if ok_hot and menu_hotstrings then
            for _, it in ipairs(menu_hotstrings.build_groups(ctx)) do table.insert(items, it) end
            table.insert(items, menu_hotstrings.build_management(ctx))

            table.insert(items, { title = "-" })
            local personnel_item = menu_hotstrings.build_personal(ctx)
            if personnel_item then table.insert(items, personnel_item) end
            table.insert(items, menu_hotstrings.build_custom(ctx))
        end

        table.insert(items, { title = "-" })
        if llm_handler and type(llm_handler.build_item) == "function" then
            local ok_b, llm_item = pcall(llm_handler.build_item)
            if ok_b and llm_item then table.insert(items, llm_item) end
        end

        table.insert(items, { title = "-" })
        if ok_gest and menu_gestures then
            local g_item = menu_gestures.build(ctx)
            if g_item then table.insert(items, g_item) end
        end
        
        if ok_short and menu_shortcuts then
            local r_item = menu_shortcuts.build(ctx)
            if r_item then table.insert(items, r_item) end
        end

        if ok_script and menu_script_ctrl then
            local sc = menu_script_ctrl.build(ctx)
            if sc then table.insert(items, sc) end
        end

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

    pcall(notifications.notify, "Script prêt ! 🚀")
    return myMenu, configWatcher
end

return M
