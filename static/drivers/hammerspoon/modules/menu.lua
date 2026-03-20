-- modules/menu.lua
local M = {}
local hs = hs
local image = hs.image
local menubar = hs.menubar
local pathwatcher = hs.pathwatcher
local utils = require("lib.utils")

-- Load modules to access their constants
local llm_mod = require("modules.llm")
local gestures_mod = require("modules.gestures")
local keymap_mod_ref = require("modules.keymap")

-- User-facing labels for gesture slots
local SLOT_LABELS = {
    tap_3         = "Tap 3 doigts",
    tap_4         = "Tap 4 doigts",
    tap_5         = "Tap 5 doigts",
    swipe_2_diag  = "Swipe 2 doigts ↗/↙",
    swipe_3_horiz = "Swipe 3 doigts ←/→",
    swipe_3_diag  = "Swipe 3 doigts ↗/↙",
    swipe_3_up    = "Swipe 3 doigts ↑",
    swipe_3_down  = "Swipe 3 doigts ↓",
    swipe_4_horiz = "Swipe 4 doigts ←/→",
    swipe_4_diag  = "Swipe 4 doigts ↗/↙",
    swipe_4_up    = "Swipe 4 doigts ↑",
    swipe_4_down  = "Swipe 4 doigts ↓",
    swipe_5_horiz = "Swipe 5 doigts ←/→",
    swipe_5_diag  = "Swipe 5 doigts ↗/↙",
    swipe_5_up    = "Swipe 5 doigts ↑",
    swipe_5_down  = "Swipe 5 doigts ↓",
}

function M.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts, personal_info, module_sections, script_control)
    base_dir = base_dir or (hs.configdir .. "/")
    local myMenu = menubar.new()

    -- ==========================================
    -- 1. Core Menu Logic & Icons
    -- ==========================================
    local function update_icon(custom_text)
        local is_paused = script_control and script_control.is_paused() or false
        local logo_file = is_paused and "logo_black.png" or "logo_white.png"
        local icon_path = base_dir .. "images/" .. logo_file
        local ico = image.imageFromPath(icon_path)
        
        if custom_text then
            myMenu:setTitle(custom_text)
        else
            myMenu:setTitle("") -- Reset title
        end

        if ico then
            pcall(function() if ico.setSize then ico:setSize({w=18,h=18}) end end)
            myMenu:setIcon(ico, false)
        elseif not custom_text then
            myMenu:setTitle("🔨")
        end
    end
    update_icon()

    local function do_reload(source)
        local msg = source == "watcher" and "Fichiers modifiés — Rechargement du script… 🔄" or "Rechargement du script… 🔄"
        pcall(utils.notify, msg)
        hs.timer.doAfter(0.25, function() hs.reload() end)
    end

    -- ==========================================
    -- 2. State & Config Management
    -- ==========================================
    local state = {
        keymap = true, gestures = true, scroll = true, shortcuts = true, personal_info = true, 
        hotstrings = {}, chatgpt_url = "https://chat.openai.com", sections_order_overrides = {}, 
        terminator_states = {}, expansion_delay = keymap_mod_ref.DEFAULT_BASE_DELAY_SEC, 
        script_control_shortcuts = {return_key = "pause", backspace = "reload"}, 
        script_control_enabled = true, ahk_source_path = "", 
        preview_enabled = true, 
        llm_enabled = llm_mod.DEFAULT_LLM_ENABLED, 
        llm_debounce = llm_mod.DEFAULT_LLM_DEBOUNCE, 
        llm_model = llm_mod.DEFAULT_LLM_MODEL
    }
    
    local updateMenu -- Forward declaration

    for _, f in ipairs(hotfiles or {}) do
        local name = f:match("^(.*)%.lua$") or f
        state.hotstrings[name] = true
    end

    local prefs_file = base_dir .. "config.json"
    local _suppress_watcher_until = 0

    local function load_prefs()
        local fh = io.open(prefs_file, "r")
        if not fh then return {} end
        local content = fh:read("*a"); fh:close()
        local ok, tbl = pcall(hs.json.decode, content)
        return (ok and type(tbl) == "table") and tbl or {}
    end

    local function save_prefs()
        local section_states = {}
        for _, f in ipairs(hotfiles or {}) do
            local name = f:match("^(.*)%.lua$") or f
            local secs = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            if secs then
                section_states[name] = {}
                for _, sec in ipairs(secs) do
                    if sec.name ~= '-' and not sec.is_module_placeholder then
                        section_states[name][sec.name] = keymap.is_section_enabled(name, sec.name)
                    end
                end
            end
        end

        local existing = load_prefs()
        local prefs = {
            keymap = state.keymap, gestures = state.gestures, scroll = state.scroll,
            shortcuts = state.shortcuts, personal_info = state.personal_info, hotstrings = state.hotstrings,
            chatgpt_url = state.chatgpt_url, sections_order_overrides = state.sections_order_overrides,
            section_states = section_states, terminator_states = state.terminator_states,
            expansion_delay = state.expansion_delay, shortcut_keys = {},
            gesture_actions = gestures.get_all_actions(), script_control_shortcuts = state.script_control_shortcuts,
            script_control_enabled = state.script_control_enabled, ahk_source_path = state.ahk_source_path,
            preview_enabled = state.preview_enabled, llm_enabled = state.llm_enabled, 
            llm_debounce = state.llm_debounce, llm_model = state.llm_model
        }

        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            for _, s in ipairs(shortcuts.list_shortcuts()) do prefs.shortcut_keys[s.id] = s.enabled end
        end

        for k, v in pairs(prefs) do existing[k] = v end

        local ok, encoded = pcall(hs.json.encode, existing)
        if ok and encoded then
            local fh = io.open(prefs_file, "w")
            if fh then fh:write(encoded); fh:close() end
        end
    end

    -- ==========================================
    -- 3. Ollama Installer & System Checks
    -- ==========================================
    
    -- Helper to calculate required disk and RAM based on model parameters
    local function get_model_requirements(model_name)
        local name = model_name:lower()
        local total_b = 0
        
        -- Extract parameters (e.g., 8x7b, 14b, 1.5b)
        local experts, size = name:match("(%d+)x([%d%.]+)b")
        if experts and size then
            total_b = tonumber(experts) * tonumber(size)
        else
            local b = name:match("([%d%.]+)b")
            if b then total_b = tonumber(b) end
        end
        
        -- Fallback if no parameter is found in the name
        if total_b == 0 then
            if name:find("llama3%.2") then total_b = 3
            elseif name:find("llama3") then total_b = 8
            elseif name:find("mistral") or name:find("qwen") then total_b = 7
            elseif name:find("gemma2") then total_b = 9
            elseif name:find("phi3") then total_b = 4
            elseif name:find("mixtral") then total_b = 47
            else total_b = 8 end
        end
        
        -- Estimated calculation: Disk (~0.6 GB per billion) / RAM (~0.7 GB per billion + 2 GB)
        local required_disk = math.ceil(total_b * 0.6 + 0.5)
        local required_ram = math.ceil(total_b * 0.7 + 2.0)
        
        return required_disk, required_ram
    end

    local function install_ollama_auto()
        local function pull_model()
            hs.notify.new({title="Ergopti+ AI", informativeText="Téléchargement de " .. state.llm_model .. "...\nRegardez la barre des menus pour la progression."}):send()
            update_icon("📥 0%")
            
            -- Use a stream callback to read the percentage
            local task = hs.task.new("/usr/local/bin/ollama", function(exitCode, stdOut, stdErr)
                update_icon() -- Reset
                local output = (stdOut or "") .. (stdErr or "")
                local is_not_found = output:lower():find("not found") or output:lower():find("error")
                
                if exitCode == 0 and not is_not_found then
                    hs.notify.new({title="Ergopti+ AI", informativeText="✅ Modèle " .. state.llm_model .. " téléchargé avec succès !"}):send()
                    hs.timer.doAfter(1, hs.reload)
                else
                    hs.notify.new({title="Ergopti+ AI", informativeText="❌ Échec du téléchargement du modèle " .. state.llm_model}):send()
                    hs.dialog.blockAlert("Erreur de modèle", 
                        "Le modèle [" .. state.llm_model .. "] n'a pas pu être téléchargé.\n\nDétails : " .. output:sub(1, 150) .. "...", 
                        "OK", nil, "critical")
                end
            end, function(task, stdOut, stdErr)
                -- Stream parser for the progress bar
                local out = stdOut or stdErr or ""
                local percent = out:match("(%d+)%%")
                if percent then
                    update_icon("📥 " .. percent .. "%")
                end
                return true
            end, {"pull", state.llm_model})
            
            task:start()
        end

        if hs.fs.attributes("/usr/local/bin/ollama") then
            pull_model()
        else
            hs.notify.new({title="Ergopti+ AI", informativeText="Étape 1/2 : Installation de l'application Ollama..."}):send()
            local install_script = [[
                curl -L https://ollama.com/download/ollama-darwin-universal.zip -o /tmp/ollama.zip
                unzip -o /tmp/ollama.zip -d /tmp/ollama_app
                cp -R /tmp/ollama_app/Ollama.app /Applications/
            ]]
            
            hs.task.new("/bin/bash", function(code)
                if code == 0 then 
                    hs.notify.new({title="Ergopti+ AI", informativeText="✅ Application Ollama installée. Lancement du téléchargement."}):send()
                    pull_model()
                else 
                    hs.notify.new({title="Ergopti+ AI", informativeText="❌ Erreur lors de l'installation d'Ollama."}):send() 
                end
            end, {"-c", install_script}):start()
        end
    end

    local function check_ram_and_install(model_name, on_cancel)
        local required_disk, required_ram = get_model_requirements(model_name)
        
        -- Retrieve Mac system RAM (in bytes -> GB) and Disk (GB)
        local sys_ram_gb = math.ceil((tonumber(hs.execute("sysctl -n hw.memsize")) or 0) / (1024^3))
        local free_disk_gb = tonumber(hs.execute("df -g / | awk 'NR==2 {print $4}'")) or 0

        local warnings = {}
        local is_critical = false

        -- RAM Analysis
        if sys_ram_gb > 0 and sys_ram_gb < required_ram then
            table.insert(warnings, string.format("🔴 RAM insuffisante : Ce modèle requiert ~%d Go de RAM (Vous avez %d Go). Risque majeur de ralentissement de votre Mac.", required_ram, sys_ram_gb))
        end

        -- Disk Analysis
        if free_disk_gb > 0 then
            local remaining_after = free_disk_gb - required_disk
            if remaining_after < 2 then
                is_critical = true
                table.insert(warnings, string.format("❌ Disque saturé : Ce modèle pèse ~%d Go. Il ne vous restera plus que %d Go sur votre Mac. Installation impossible pour la sécurité du système.", required_disk, remaining_after))
            elseif remaining_after < 15 then
                table.insert(warnings, string.format("⚠️ Espace disque limite : Ce modèle pèse ~%d Go. Il ne vous restera que %d Go après l'installation.", required_disk, remaining_after))
            else
                table.insert(warnings, string.format("ℹ️ Espace disque OK : Ce modèle pèsera environ %d Go (Il vous restera %d Go libres).", required_disk, remaining_after))
            end
        end

        -- Display alert
        if #warnings > 0 then
            local msg = "Analyse du modèle '" .. model_name .. "' :\n\n" .. table.concat(warnings, "\n\n")
            
            if is_critical then
                hs.dialog.blockAlert("Téléchargement bloqué", msg, "Annuler", nil, "critical")
                if on_cancel then on_cancel() end
                return
            end

            local alert_type = (msg:find("🔴") or msg:find("⚠️")) and "warning" or "informational"
            local choice = hs.dialog.blockAlert("Confirmer le téléchargement", msg .. "\n\nVoulez-vous procéder au téléchargement ?", "Télécharger", "Annuler", alert_type)
            
            if choice == "Annuler" then
                if on_cancel then on_cancel() end
                return
            end
        end
        
        -- Execution
        state.llm_model = model_name
        if keymap and keymap.set_llm_model then keymap.set_llm_model(model_name) end
        save_prefs()
        install_ollama_auto()
    end

    -- Initial setup logic
    do
        local saved = load_prefs()
        local config_absent = (next(saved) == nil)

        if config_absent then
            for _, f in ipairs(hotfiles or {}) do
                local name = f:match("^(.*)%.lua$") or f
                local secs = keymap and keymap.get_sections and keymap.get_sections(name) or nil
                if secs then
                    for _, sec in ipairs(secs) do
                        if sec.name ~= '-' and not sec.is_module_placeholder then
                            hs.settings.set("hotstrings_section_" .. name .. "_" .. sec.name, nil)
                        end
                    end
                end
                keymap.disable_group(name)
                keymap.enable_group(name)
            end
        end

        if type(saved) == "table" then
            if saved.keymap ~= nil then state.keymap = saved.keymap end
            if saved.gestures ~= nil then state.gestures = saved.gestures end
            if saved.scroll ~= nil then state.scroll = saved.scroll end
            if saved.shortcuts ~= nil then state.shortcuts = saved.shortcuts end
            if saved.personal_info ~= nil then state.personal_info = saved.personal_info end
            if saved.chatgpt_url ~= nil then state.chatgpt_url = saved.chatgpt_url end
            if saved.preview_enabled ~= nil then state.preview_enabled = saved.preview_enabled end
            if saved.llm_enabled ~= nil then state.llm_enabled = saved.llm_enabled end
            if type(saved.llm_debounce) == 'number' then state.llm_debounce = saved.llm_debounce end
            if type(saved.llm_model) == 'string' then state.llm_model = saved.llm_model end

            if type(saved.sections_order_overrides) == 'table' then state.sections_order_overrides = saved.sections_order_overrides end
            if type(saved.terminator_states) == 'table' then
                state.terminator_states = saved.terminator_states
                for key, enabled in pairs(saved.terminator_states) do
                    if keymap and keymap.set_terminator_enabled then keymap.set_terminator_enabled(key, enabled) end
                end
            end
            if type(saved.expansion_delay) == 'number' then
                state.expansion_delay = saved.expansion_delay
                if keymap and keymap.set_base_delay then keymap.set_base_delay(saved.expansion_delay) end
            end
            if type(saved.script_control_shortcuts) == "table" then
                for k, v in pairs(saved.script_control_shortcuts) do state.script_control_shortcuts[k] = v end
            end
            if saved.script_control_enabled ~= nil then state.script_control_enabled = saved.script_control_enabled end
            if saved.ahk_source_path ~= nil then state.ahk_source_path = saved.ahk_source_path end
            if type(saved.hotstrings) == "table" then
                for name in pairs(state.hotstrings) do
                    if saved.hotstrings[name] ~= nil then state.hotstrings[name] = saved.hotstrings[name] end
                end
            end
            if type(saved.gesture_actions) == "table" then
                for slot, action in pairs(saved.gesture_actions) do gestures.set_action(slot, action) end
            end
            gestures.apply_all_overrides()
        end

        -- Sync settings with the keymap engine
        if keymap then
            if keymap.set_preview_enabled then keymap.set_preview_enabled(state.preview_enabled) end
            if keymap.set_llm_enabled then keymap.set_llm_enabled(state.llm_enabled) end
            if keymap.set_llm_debounce then keymap.set_llm_debounce(state.llm_debounce) end
            if keymap.set_llm_model then keymap.set_llm_model(state.llm_model) end
        end

        -- Start/Stop modules
        if state.keymap then keymap.start() else keymap.stop() end
        if state.gestures then gestures.enable_all() else gestures.disable_all() end
        if state.scroll then scroll.start() else scroll.stop() end
        if state.shortcuts then shortcuts.start() else shortcuts.stop() end
        if personal_info then if state.personal_info then personal_info.enable() else personal_info.disable() end end

        for name, enabled in pairs(state.hotstrings) do
            if enabled then keymap.enable_group(name) else keymap.disable_group(name) end
        end
        if type(saved) == "table" and type(saved.shortcut_keys) == "table" then
            for id, enabled in pairs(saved.shortcut_keys) do
                if enabled then shortcuts.enable(id) else shortcuts.disable(id) end
            end
        end

        -- Startup Check
        if state.llm_enabled then
            llm_mod.check_availability(state.llm_model, nil, function(needs_ollama)
                local msg = needs_ollama and "Ollama n'est pas lancé ou installé." 
                                          or ("Le modèle [" .. state.llm_model .. "] n'est pas téléchargé.")
                
                hs.timer.doAfter(1, function()
                    local choice = hs.dialog.blockAlert("IA non configurée", 
                        msg .. "\n\nSouhaitez-vous régler cela maintenant ?", 
                        "Installer automatiquement l'IA", "Plus tard", "informational")
                    
                    if choice == "Installer automatiquement l'IA" then
                        check_ram_and_install(state.llm_model, function()
                            state.llm_enabled = false
                            if keymap and keymap.set_llm_enabled then keymap.set_llm_enabled(false) end
                            save_prefs(); updateMenu()
                        end)
                    else
                        state.llm_enabled = false
                        if keymap and keymap.set_llm_enabled then keymap.set_llm_enabled(false) end
                        save_prefs(); updateMenu()
                    end
                end)
            end)
        end

        if config_absent then save_prefs() end
    end

    -- Setup Script Control logic
    if script_control then
        script_control.set_on_pause_change(function(_) update_icon(); updateMenu() end)
        if state.script_control_enabled then
            script_control.set_shortcut_action("return_key", state.script_control_shortcuts.return_key)
            script_control.set_shortcut_action("backspace",  state.script_control_shortcuts.backspace)
        else
            script_control.set_shortcut_action("return_key", "none")
            script_control.set_shortcut_action("backspace",  "none")
        end
        script_control.set_extras({
            open_init = function()
                hs.timer.doAfter(0, function()
                    _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8
                    hs.execute('open "'..base_dir..'init.lua"')
                end)
            end,
            open_ahk = function()
                hs.timer.doAfter(0, function()
                    local path = (state.ahk_source_path ~= "") and state.ahk_source_path or nil
                    if not path then path = os.getenv("LOCAL_AHK_PATH") end
                    if not path then
                        local lf = io.open(base_dir .. "../hotstrings/.local_ahk_path", "r")
                        if lf then
                            local raw = lf:read("*a"); lf:close()
                            raw = raw:match("^%s*(.-)%s*$")
                            if raw ~= "" then path = raw end
                        end
                    end
                    if not path then path = base_dir .. "../autohotkey/ErgoptiPlus.ahk" end
                    
                    local init_path = base_dir .. "init.lua"
                    local app_name = hs.execute(string.format("osascript -e 'tell application \"Finder\" to return name of (default application of (info for POSIX file \"%s\"))' 2>/dev/null", init_path))
                    app_name = app_name and app_name:match("^%s*(.-)%s*$") or ""
                    
                    if app_name ~= "" then hs.execute(string.format('open -a "%s" "%s"', app_name, path))
                    else hs.execute('open -t "'..path..'"') end
                end)
            end,
        })
    end

    -- ==========================================
    -- 4. Menu Item Builders
    -- ==========================================
    
    local function groupEnabled(name)
        return (keymap and type(keymap.is_group_enabled) == "function" and keymap.is_group_enabled(name)) or (state.hotstrings[name] ~= false)
    end

    local function groupLabel(name)
        local meta = keymap and keymap.get_meta_description and keymap.get_meta_description(name) or nil
        return (meta and meta ~= '') and meta or name:gsub('_', ' ')
    end

    local function toggleGroupFn(name)
        return function()
            state.hotstrings[name] = not groupEnabled(name)
            if state.hotstrings[name] then
                keymap.enable_group(name)
                if not state.keymap then state.keymap = true; keymap.start() end
            else keymap.disable_group(name) end
            save_prefs(); updateMenu()
        end
    end

    local function toggleSectionFn(group_name, sec_name)
        return function()
            if keymap.is_section_enabled(group_name, sec_name) then keymap.disable_section(group_name, sec_name)
            else
                keymap.enable_section(group_name, sec_name)
                if not state.keymap then state.keymap = true; keymap.start() end
            end
            save_prefs(); updateMenu()
        end
    end

    local buildPersonalInfoItems -- Forward declaration
    
    local function buildHotstringsItems()
        local paused = script_control and script_control.is_paused() or false
        local top_names = {}
        for _, f in ipairs(hotfiles or {}) do top_names[#top_names + 1] = f:match("^(.*)%.lua$") or f end
        if #top_names == 0 then return {} end

        local items = {}
        for _, name in ipairs(top_names) do
            local enabled = groupEnabled(name)
            local sections = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            local has_sections = sections and #sections > 0

            local total, has_count = 0, false
            if enabled and has_sections then
                for _, sec in ipairs(sections) do
                    if sec.name ~= '-' and not sec.is_module_placeholder and keymap.is_section_enabled(name, sec.name) then
                        if sec.count ~= nil then has_count = true; total = total + sec.count end
                    end
                end
            end

            local base_label = groupLabel(name)
            local item = {
                title = has_count and (base_label .. " (" .. total .. ")") or base_label,
                checked = (enabled and not paused) or nil,
                fn = toggleGroupFn(name),
            }

            if has_sections then
                local override_map = state.sections_order_overrides or {}
                local override = override_map[name]
                local ordered_secs
                
                if override then
                    local by_name = {}
                    for _, sec in ipairs(sections) do by_name[sec.name] = sec end
                    local seen = {}
                    ordered_secs = {}
                    for _, entry in ipairs(override) do
                        if entry == '-' then table.insert(ordered_secs, { name = '-' })
                        elseif by_name[entry] then
                            table.insert(ordered_secs, by_name[entry])
                            seen[entry] = true
                        end
                    end
                    for _, sec in ipairs(sections) do
                        if not seen[sec.name] and sec.name ~= '-' then table.insert(ordered_secs, sec) end
                    end
                else
                    ordered_secs = sections
                end

                local sec_menu = {}
                for _, sec in ipairs(ordered_secs) do
                    if sec.name == '-' then sec_menu[#sec_menu + 1] = { title = "-" }
                    elseif sec.is_module_placeholder then
                        local ms = module_sections and module_sections[name]
                        local ms_entry = ms and ms[sec.name]
                        local mod_id = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
                        if mod_id == "personal_info" then
                            local pi_items = buildPersonalInfoItems(type(ms_entry) == "table" and ms_entry.description or nil)
                            if pi_items then
                                for _, pi in ipairs(pi_items) do
                                    if pi.checked ~= nil and paused then pi.checked = nil end
                                    if not enabled or paused then pi.fn = nil; pi.disabled = true end
                                    sec_menu[#sec_menu + 1] = pi
                                end
                            end
                        end
                    else
                        local sec_on = keymap.is_section_enabled(name, sec.name)
                        local label = (sec.description and sec.description ~= '') and sec.description or sec.name:gsub('_', ' ')
                        sec_menu[#sec_menu + 1] = {
                            title = sec.count ~= nil and (label .. " (" .. sec.count .. ")") or label,
                            checked = (sec_on and not paused) or nil,
                            fn = (enabled and not paused) and toggleSectionFn(name, sec.name) or nil,
                            disabled = not enabled or paused or nil,
                        }
                    end
                end
                item.menu = sec_menu
            else
                item.fn = toggleGroupFn(name)
            end
            items[#items + 1] = item
        end
        return items
    end

    local function buildGesturesItem()
        local paused = script_control and script_control.is_paused() or false
        local item = {
            title = "Gestes",
            checked = (state.gestures and not paused) or nil,
            fn = function()
                state.gestures = not state.gestures
                if state.gestures then gestures.enable_all() else gestures.disable_all() end
                save_prefs(); updateMenu()
            end
        }

        local function slotItem(slot, isAxis)
            local current = gestures.get_action(slot)
            local slotLbl = SLOT_LABELS[slot] or slot
            local actionLbl = gestures.get_action_label(current)
            local names = isAxis and gestures.AX_NAMES or gestures.SG_NAMES
            local submenu = {}
            for _, aname in ipairs(names) do
                table.insert(submenu, {
                    title = gestures.get_action_label(aname),
                    checked = ((current == aname) and not paused) or nil,
                    disabled = not state.gestures or paused or nil,
                    fn = (state.gestures and not paused) and (function(a) return function()
                        gestures.set_action(slot, a)
                        local conflict = gestures.on_action_changed(slot, a)
                        save_prefs(); updateMenu()
                        if conflict then
                            hs.timer.doAfter(0.3, function()
                                hs.focus()
                                local clicked = hs.dialog.blockAlert("⚠️  Conflit potentiel", conflict.msg, "Ouvrir Réglages", "Plus tard", "warning")
                                if clicked == "Ouvrir Réglages" then hs.execute(string.format("open '%s'", conflict.url)) end
                            end)
                        end
                    end end)(aname) or nil,
                })
            end
            return { title = slotLbl .. " : " .. actionLbl, disabled = not state.gestures or paused or nil, menu = submenu }
        end

        local function section(slots, isAxis)
            local items = {}
            for _, slot in ipairs(slots) do table.insert(items, slotItem(slot, isAxis)) end
            return items
        end

        local menu = {}
        table.insert(menu, slotItem("swipe_2_diag", true))
        table.insert(menu, {title="-"})
        table.insert(menu, slotItem("tap_3", false))
        for _, it in ipairs(section({"swipe_3_horiz","swipe_3_diag"}, true)) do table.insert(menu, it) end
        for _, it in ipairs(section({"swipe_3_up","swipe_3_down"}, false)) do table.insert(menu, it) end
        table.insert(menu, {title="-"})
        table.insert(menu, slotItem("tap_4", false))
        for _, it in ipairs(section({"swipe_4_horiz","swipe_4_diag"}, true)) do table.insert(menu, it) end
        for _, it in ipairs(section({"swipe_4_up","swipe_4_down"}, false)) do table.insert(menu, it) end
        table.insert(menu, {title="-"})
        table.insert(menu, slotItem("tap_5", false))
        for _, it in ipairs(section({"swipe_5_horiz","swipe_5_diag"}, true)) do table.insert(menu, it) end
        for _, it in ipairs(section({"swipe_5_up","swipe_5_down"}, false)) do table.insert(menu, it) end

        item.menu = menu
        return item
    end

    buildPersonalInfoItems = function(description)
        if not personal_info then return nil end
        return {
            {
                title = description,
                checked = state.personal_info or nil,
                fn = function()
                    state.personal_info = not state.personal_info
                    if state.personal_info then personal_info.enable() else personal_info.disable() end
                    save_prefs(); updateMenu()
                end
            },
            {
                title = "   ↳ Modifier les informations...",
                fn = function() hs.timer.doAfter(0.1, personal_info.open_editor) end
            }
        }
    end

    local function buildHotstringsManagementItem()
        local paused = script_control and script_control.is_paused() or false
        local menu = {}

        table.insert(menu, {
            title = "Afficher la prévisualisation (Bulle)",
            checked = (state.preview_enabled and not paused) or nil,
            disabled = paused or nil,
            fn = not paused and function()
                state.preview_enabled = not state.preview_enabled
                if keymap and keymap.set_preview_enabled then keymap.set_preview_enabled(state.preview_enabled) end
                save_prefs(); updateMenu()
            end or nil
        })

        table.insert(menu, {title = "-"})

        local defs = keymap and keymap.get_terminator_defs and keymap.get_terminator_defs() or {}
        local exp_sub = {}
        for _, def in ipairs(defs) do
            local enabled = keymap.is_terminator_enabled(def.key)
            exp_sub[#exp_sub + 1] = {
                title = def.label,
                checked = (enabled and not paused) or nil,
                disabled = paused or nil,
                fn = not paused and (function(k) return function()
                    local new_val = not keymap.is_terminator_enabled(k)
                    keymap.set_terminator_enabled(k, new_val)
                    state.terminator_states[k] = new_val
                    save_prefs(); updateMenu()
                end end)(def.key) or nil,
            }
        end
        table.insert(menu, { title = "Expanseurs", disabled = paused or nil, menu = exp_sub })

        local current = keymap and keymap.get_base_delay and keymap.get_base_delay() or state.expansion_delay
        local current_ms = math.floor(current * 1000 + 0.5)
        table.insert(menu, {
            title = string.format("Délai maximal d'expansion : %d ms...", current_ms),
            disabled = paused or nil,
            fn = not paused and function()
                local btn, raw = hs.dialog.textPrompt(
                    "Délai maximal d'expansion",
                    "Entrez le délai en millisecondes\n (nombre entier ≥ 0) :",
                    tostring(current_ms), "OK", "Annuler"
                )
                if btn ~= "OK" then return end
                local val = tonumber(raw)
                if not val or val < 0 or val ~= math.floor(val) then
                    hs.notify.new({ title = "Délai invalide", informativeText = "Veuillez saisir un entier ≥ 0." }):send()
                    return
                end
                local secs = val / 1000
                keymap.set_base_delay(secs)
                state.expansion_delay = secs
                save_prefs(); updateMenu()
            end or nil
        })

        return { title = "Paramètres Hotstrings", menu = menu }
    end

    local function buildLlmItem()
        local paused = script_control and script_control.is_paused() or false
        local cur_debounce_ms = math.floor(state.llm_debounce * 1000 + 0.5)

        -- Model change function
        local function trigger_model_change(new_model)
            llm_mod.check_availability(new_model, function()
                state.llm_model = new_model
                if keymap and keymap.set_llm_model then keymap.set_llm_model(new_model) end
                save_prefs(); updateMenu()
            end, function(needs_ollama)
                if needs_ollama then
                    hs.dialog.blockAlert("Ollama absent", "Ollama ne semble pas être lancé.", "OK")
                else
                    check_ram_and_install(new_model)
                end
            end)
        end

        -- Build the models dropdown list grouped by provider, sorted by weight
        local preset_groups = {
            {"llama3.2:1b", "llama3.2", "llama3.1"},                       -- Meta / Llama
            {"qwen2.5:0.5b", "qwen2.5:1.5b", "qwen2.5:7b", "qwen2.5:14b"}, -- Alibaba / Qwen
            {"mistral", "mixtral:8x7b"},                                   -- Mistral AI
            {"gemma2:2b", "gemma2", "gemma2:27b"},                         -- Google / Gemma
            {"phi3", "phi3:14b"}                                           -- Microsoft / Phi
        }
        
        local models_menu = {}
        for i, group in ipairs(preset_groups) do
            for _, m in ipairs(group) do
                local _, ram = get_model_requirements(m)
                table.insert(models_menu, {
                    title = string.format("%s (~%d Go RAM)", m, ram),
                    checked = (state.llm_model == m),
                    fn = not paused and function() trigger_model_change(m) end or nil
                })
            end
            if i < #preset_groups then
                table.insert(models_menu, {title = "-"})
            end
        end
        
        table.insert(models_menu, {title = "-"})
        table.insert(models_menu, {
            title = "Autre modèle (Saisie manuelle)...",
            fn = not paused and function()
                local btn, raw = hs.dialog.textPrompt(
                    "Modèle IA personnalisé",
                    "Entrez le nom exact du modèle Ollama à utiliser :",
                    state.llm_model, "OK", "Annuler"
                )
                if btn == "OK" and raw ~= "" then
                    trigger_model_change(raw:match("^%s*(.-)%s*$"))
                end
            end or nil
        })

        return {
            title = "Prédiction par IA (LLM)",
            menu = {
                {
                    title = "Activer l'IA",
                    checked = (state.llm_enabled and not paused) or nil,
                    disabled = paused or nil,
                    fn = not paused and function()
                        llm_mod.check_availability(state.llm_model, function()
                            state.llm_enabled = not state.llm_enabled
                            if keymap and keymap.set_llm_enabled then keymap.set_llm_enabled(state.llm_enabled) end
                            save_prefs(); updateMenu()
                        end, function(needs_ollama)
                            local msg = needs_ollama and "Pour utiliser l'IA, il faut installer Ollama."
                                                      or ("Le modèle [" .. state.llm_model .. "] est manquant.")
                            
                            local choice = hs.dialog.blockAlert("Installation requise", 
                                msg .. " Souhaitez-vous procéder au téléchargement ?", 
                                "Installer", "Plus tard", "informational")
                            
                            if choice == "Installer" then
                                check_ram_and_install(state.llm_model, function()
                                    state.llm_enabled = false
                                    if keymap and keymap.set_llm_enabled then keymap.set_llm_enabled(false) end
                                    save_prefs(); updateMenu()
                                end)
                            else
                                state.llm_enabled = false
                                if keymap and keymap.set_llm_enabled then keymap.set_llm_enabled(false) end
                                save_prefs(); updateMenu()
                            end
                        end)
                    end or nil
                },
                { title = "-" },
                {
                    title = string.format("Modèle IA : %s", state.llm_model),
                    disabled = paused or nil,
                    menu = models_menu
                },
                {
                    title = string.format("Délai de réflexion IA : %d ms...", cur_debounce_ms),
                    disabled = paused or nil,
                    fn = not paused and function()
                        local btn, raw = hs.dialog.textPrompt(
                            "Délai de l'IA",
                            "Entrez le délai d'inactivité avant le déclenchement du LLM (en ms) :",
                            tostring(cur_debounce_ms), "OK", "Annuler"
                        )
                        if btn ~= "OK" then return end
                        local val = tonumber(raw)
                        if not val or val < 0 or val ~= math.floor(val) then
                            hs.notify.new({ title = "Délai invalide", informativeText = "Veuillez saisir un entier ≥ 0." }):send()
                            return
                        end
                        local secs = val / 1000
                        state.llm_debounce = secs
                        if keymap and keymap.set_llm_debounce then keymap.set_llm_debounce(secs) end
                        save_prefs(); updateMenu()
                    end or nil
                }
            }
        }
    end

    local function buildRaccourcisItem()
        local paused = script_control and script_control.is_paused() or false
        local item = {
            title = "Raccourcis",
            checked = (state.shortcuts and not paused) or nil,
            fn = function()
                state.shortcuts = not state.shortcuts
                if state.shortcuts then shortcuts.start() else shortcuts.stop() end
                save_prefs(); updateMenu()
            end
        }
        local s_menu = {}
        table.insert(s_menu, {
            title = "Layer (Left Command) + Scroll : Volume",
            checked = (state.scroll and not paused) or nil,
            disabled = not state.shortcuts or paused or nil,
            fn = (state.shortcuts and not paused) and function()
                state.scroll = not state.scroll
                if state.scroll then scroll.start() else scroll.stop() end
                save_prefs(); updateMenu()
            end or nil,
        })
        table.insert(s_menu, {title = "-"})
        
        local function pretty_key(id)
            if id == "at_hash" then return "Touche @/#" end
            local parts = {}
            for p in id:gmatch("[^_]+") do table.insert(parts, p) end
            if #parts == 0 then return id end
            local key = parts[#parts]
            if key == "star" or key == "asterisk" then key = "★" end
            local mods = {}
            for i = 1, #parts-1 do
                local p = parts[i]
                if p=="ctrl" then table.insert(mods,"Ctrl")
                elseif p=="cmd" then table.insert(mods,"Cmd")
                elseif p=="alt" or p=="option" then table.insert(mods,"Alt")
                elseif p=="shift" then table.insert(mods,"Shift")
                else table.insert(mods, p:sub(1,1):upper()..p:sub(2)) end
            end
            return (#mods>0 and table.concat(mods," + ").." + " or "")..key:upper()
        end
        
        local last_was_non_ctrl, separator_inserted = false, false
        for _, s in ipairs(shortcuts.list_shortcuts()) do
            local is_ctrl = s.id:sub(1, 5) == "ctrl_"
            if not separator_inserted and last_was_non_ctrl and is_ctrl then
                table.insert(s_menu, {title = "-"})
                separator_inserted = true
            end
            if not is_ctrl then last_was_non_ctrl = true end
            
            local is_on = shortcuts.is_enabled and shortcuts.is_enabled(s.id) or s.enabled
            local desc = (s.label or ""):gsub("^%s*(.-)%s*$","%1")
            table.insert(s_menu, {
                title = pretty_key(s.id) .. " : " .. (desc ~= "" and desc or s.id),
                checked = (is_on and not paused) or nil,
                disabled = not state.shortcuts or paused or nil,
                fn = (state.shortcuts and not paused) and (function(id) return function()
                    if shortcuts.is_enabled(id) then shortcuts.disable(id) else shortcuts.enable(id) end
                    save_prefs(); updateMenu()
                end end)(s.id) or nil,
            })

            if s.id == "ctrl_g" then
                table.insert(s_menu, {
                    title = "   ↳ Modifier l'URL ChatGPT...",
                    disabled = paused or nil,
                    fn = not paused and function()
                        local clicked, url = hs.dialog.textPrompt("URL ChatGPT", "URL ouverte par Ctrl+G :", state.chatgpt_url or "", "OK", "Annuler")
                        if clicked == "OK" and url ~= nil and url ~= "" then
                            state.chatgpt_url = url; save_prefs(); updateMenu()
                        end
                    end or nil
                })
            end
        end
        item.menu = s_menu
        return item
    end

    local function set_all_enabled(enabled)
        state.keymap = enabled
        state.gestures = enabled
        state.scroll = enabled
        state.shortcuts = enabled
        if personal_info then state.personal_info = enabled end
        for name in pairs(state.hotstrings) do state.hotstrings[name] = enabled end

        for name in pairs(state.hotstrings) do
            local sections = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            if sections then
                for _, sec in ipairs(sections) do
                    if sec.name ~= '-' and not sec.is_module_placeholder then
                        local key = "hotstrings_section_" .. name .. "_" .. sec.name
                        if enabled then hs.settings.set(key, nil) else hs.settings.set(key, false) end
                    end
                end
            end
        end

        local section_states = {}
        for name in pairs(state.hotstrings) do
            local secs = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            if secs then
                section_states[name] = {}
                for _, sec in ipairs(secs) do
                    if sec.name ~= '-' and not sec.is_module_placeholder then section_states[name][sec.name] = enabled end
                end
            end
        end

        local existing2 = load_prefs()
        existing2.keymap = enabled; existing2.gestures = enabled; existing2.scroll = enabled; 
        existing2.shortcuts = enabled; existing2.personal_info = enabled; existing2.hotstrings = state.hotstrings;
        existing2.section_states = section_states; existing2.shortcut_keys = {}

        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            for _, s in ipairs(shortcuts.list_shortcuts()) do existing2.shortcut_keys[s.id] = enabled end
        end

        local ok2, encoded = pcall(hs.json.encode, existing2)
        if ok2 and encoded then
            local fh = io.open(prefs_file, "w")
            if fh then fh:write(encoded); fh:close() end
        end

        do_reload()
    end

    local function buildScriptControlItem()
        if not script_control then return nil end
        local paused = script_control.is_paused()
        local actions, act_labels = script_control.ACTIONS, script_control.ACTION_LABELS
        local enabled = state.script_control_enabled

        local function key_submenu(keyname)
            local current = state.script_control_shortcuts[keyname] or "none"
            local sub = {}
            for _, act in ipairs(actions) do
                table.insert(sub, {
                    title = act_labels[act],
                    checked = ((current == act) and not paused) or nil,
                    disabled = not enabled or paused or nil,
                    fn = (enabled and not paused) and (function(a) return function()
                        state.script_control_shortcuts[keyname] = a
                        script_control.set_shortcut_action(keyname, a)
                        save_prefs(); updateMenu()
                    end end)(act) or nil,
                })
            end
            return sub
        end

        local cur_return = state.script_control_shortcuts.return_key or "none"
        local cur_back   = state.script_control_shortcuts.backspace   or "none"
        local sub = {
            { title = "Option droite + ↩ : " .. (act_labels[cur_return] or cur_return), disabled = not enabled or paused or nil, menu = key_submenu("return_key") },
            { title = "Option droite + ⌫ : " .. (act_labels[cur_back] or cur_back), disabled = not enabled or paused or nil, menu = key_submenu("backspace") },
            { title = "-" },
            { title = "Chemin du script AHK...", disabled = paused or nil, fn = not paused and function()
                local btn, path = hs.dialog.textPrompt("Script AHK", "Chemin du fichier AHK source :", state.ahk_source_path or "", "OK", "Annuler")
                if btn == "OK" and path ~= nil then
                    state.ahk_source_path = path; save_prefs(); updateMenu()
                end
            end or nil }
        }
        return {
            title = "Contrôle du script",
            checked = (enabled and not paused) or nil,
            fn = function()
                state.script_control_enabled = not state.script_control_enabled
                if state.script_control_enabled then
                    script_control.set_shortcut_action("return_key", state.script_control_shortcuts.return_key)
                    script_control.set_shortcut_action("backspace",  state.script_control_shortcuts.backspace)
                else
                    script_control.set_shortcut_action("return_key", "none")
                    script_control.set_shortcut_action("backspace",  "none")
                end
                save_prefs(); updateMenu()
            end,
            menu = sub,
        }
    end

    -- ==========================================
    -- 5. Final Menu Assembly
    -- ==========================================
    updateMenu = function()
        local items = {}
        
        local title_style = {
            font = { name = "Helvetica-Bold", size = 16 },
            paragraphStyle = { alignment = "center" }
        }
        table.insert(items, {
            title = hs.styledtext.new("Ergopti+", title_style),
            fn = function() end 
        })
        table.insert(items, {title="-"})
        
        for _, it in ipairs(buildHotstringsItems()) do table.insert(items, it) end
        table.insert(items, buildHotstringsManagementItem())
        table.insert(items, {title="-"})
        table.insert(items, buildLlmItem())
        table.insert(items, {title="-"})
        table.insert(items, buildGesturesItem())
        table.insert(items, buildRaccourcisItem())
        
        local sc_item = buildScriptControlItem()
        if sc_item then table.insert(items, sc_item) end

        table.insert(items, {title="-"})
        
        table.insert(items, {title="☑ Tout activer", fn=function() set_all_enabled(true) end})
        table.insert(items, {title="☒ Tout désactiver", fn=function() set_all_enabled(false) end})
        table.insert(items, {title="-"})
        table.insert(items, {title="Ouvrir init.lua", fn=function() hs.execute('open "'..base_dir..'init.lua"') end})
        table.insert(items, {title="Console Hammerspoon", fn=function() hs.openConsole() end})
        table.insert(items, {title="Préférences Hammerspoon", fn=function() hs.openPreferences() end})
        table.insert(items, {title="Recharger la configuration", fn=function() do_reload() end})
        table.insert(items, {title="Quitter Hammerspoon", fn=function() hs.timer.doAfter(0.1, function() os.exit(0) end) end})
        
        myMenu:setMenu({})
        hs.timer.doAfter(0.02, function() myMenu:setMenu(items) end)
    end

    updateMenu()

    local function reloadConfig(files)
        if hs.timer.secondsSinceEpoch() < _suppress_watcher_until then return end
        for _, file in pairs(files) do
            if file:sub(-4) == ".lua" then do_reload("watcher"); return end
        end
    end
    local configWatcher = pathwatcher.new(base_dir, reloadConfig):start()

    M._menu    = myMenu
    M._watcher = configWatcher

    pcall(utils.notify, "Script prêt ! 🚀")
    return myMenu, configWatcher
end

return M
