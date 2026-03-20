-- ui/menu.lua
-- Menubar UI: assembles the Ergopti+ status-bar menu, owns preference
-- persistence (config.json), and drives the config file watcher.
-- LLM-specific logic is delegated to ui/menu_llm.lua.

local M = {}

local hs        = hs
local utils     = require("lib.utils")
local llm_mod   = require("modules.llm")
local menu_llm  = require("ui.menu_llm")

local NBSP  = "\194\160"      -- U+00A0  non-breaking space   (before :)
local NNBSP = "\226\128\175"  -- U+202F  narrow no-break sp.  (before !  ?)

M._active_tasks = {}

local SLOT_LABELS = {
    tap_3         = "Tap 3 doigts",
    tap_4         = "Tap 4 doigts",
    tap_5         = "Tap 5 doigts",
    swipe_2_diag  = "Swipe 2 doigts \226\134\151/\226\134\153",
    swipe_3_horiz = "Swipe 3 doigts \226\134\144/\226\134\146",
    swipe_3_diag  = "Swipe 3 doigts \226\134\151/\226\134\153",
    swipe_3_up    = "Swipe 3 doigts \226\134\145",
    swipe_3_down  = "Swipe 3 doigts \226\134\147",
    swipe_4_horiz = "Swipe 4 doigts \226\134\144/\226\134\146",
    swipe_4_diag  = "Swipe 4 doigts \226\134\151/\226\134\153",
    swipe_4_up    = "Swipe 4 doigts \226\134\145",
    swipe_4_down  = "Swipe 4 doigts \226\134\147",
    swipe_5_horiz = "Swipe 5 doigts \226\134\144/\226\134\146",
    swipe_5_diag  = "Swipe 5 doigts \226\134\151/\226\134\153",
    swipe_5_up    = "Swipe 5 doigts \226\134\145",
    swipe_5_down  = "Swipe 5 doigts \226\134\147",
}

-- ====================================
-- ====================================
-- ====================================
-- ========== 1. ENTRY POINT ==========
-- ====================================
-- ====================================
-- ====================================

---@param base_dir        string
---@param hotfiles        table
---@param gestures        table
---@param scroll          table
---@param keymap          table
---@param shortcuts       table
---@param personal_info   table
---@param module_sections table
---@param script_control  table
function M.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts,
                 personal_info, module_sections, script_control)

    base_dir = base_dir or (hs.configdir .. "/")
    local myMenu  = hs.menubar.new()
    local updateMenu  -- forward declaration

-- ======================================
-- ======================================
-- ======================================
-- ========== 2. ICON & RELOAD ==========
-- ======================================
-- ======================================
-- ======================================

    local function update_icon(custom_text)
        local paused    = script_control and script_control.is_paused() or false
        local logo_file = paused and "logo_black.png" or "logo_white.png"
        local ico       = hs.image.imageFromPath(base_dir .. "images/" .. logo_file)
        myMenu:setTitle(custom_text and (" " .. custom_text) or "")
        if ico then
            pcall(function() if ico.setSize then ico:setSize({ w = 18, h = 18 }) end end)
            myMenu:setIcon(ico, false)
        elseif not custom_text then
            myMenu:setTitle("\240\159\148\168")
        end
    end
    update_icon()

    local _suppress_watcher_until = 0

    local function do_reload(source)
        local msg = source == "watcher"
            and "Fichiers modifiés \226\128\148 Rechargement\226\128\166"
            or  "Rechargement du script\226\128\166"
        pcall(utils.notify, msg)
        hs.timer.doAfter(0.25, function() hs.reload() end)
    end

-- ======================================
-- ======================================
-- ======================================
-- ========== 3. NOTIFICATIONS ==========
-- ======================================
-- ======================================
-- ======================================

    -- Two-line notification: uppercase bold title + feature label below.
    local function notify_feature(label, is_enabled)
        pcall(function()
            hs.notify.new({
                title           = is_enabled
                                  and "🟢 ACTIVÉ"
                                  or  "🔴 DÉSACTIVÉ",
                informativeText = label,
            }):send()
        end)
    end

-- ============================================
-- ============================================
-- ============================================
-- ========== 4. STATE & PREFERENCES ==========
-- ============================================
-- ============================================
-- ============================================


    -- ===============================
-- ======= 4.1 State Table =======
-- ===============================

    local state = {
        keymap           = true,
        gestures         = true,
        scroll           = true,
        shortcuts        = true,
        personal_info    = true,
        hotstrings       = {},
        chatgpt_url      = "https://chat.openai.com",
        sections_order_overrides = {},
        terminator_states        = {},
        expansion_delay          = (keymap and keymap.DEFAULT_BASE_DELAY_SEC) or 0.05,
        script_control_shortcuts = { return_key = "pause", backspace = "reload" },
        script_control_enabled   = true,
        ahk_source_path          = "",
        preview_enabled          = true,
        llm_enabled   = llm_mod and llm_mod.DEFAULT_LLM_ENABLED  or false,
        llm_debounce  = llm_mod and llm_mod.DEFAULT_LLM_DEBOUNCE or 0.5,
        llm_model     = llm_mod and llm_mod.DEFAULT_LLM_MODEL    or "llama3.2",
    }

    for _, f in ipairs(hotfiles or {}) do
        local name = f:match("^(.*)%.lua$") or f
        state.hotstrings[name] = true
    end

    local prefs_file = base_dir .. "config.json"

    -- ===================================
-- ======= 4.2 Preferences I/O =======
-- ===================================

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
            shortcuts = state.shortcuts, personal_info = state.personal_info,
            hotstrings = state.hotstrings, chatgpt_url = state.chatgpt_url,
            sections_order_overrides = state.sections_order_overrides,
            section_states = section_states, terminator_states = state.terminator_states,
            expansion_delay = state.expansion_delay, shortcut_keys = {},
            gesture_actions = gestures.get_all_actions(),
            script_control_shortcuts = state.script_control_shortcuts,
            script_control_enabled   = state.script_control_enabled,
            ahk_source_path  = state.ahk_source_path,
            preview_enabled  = state.preview_enabled,
            llm_enabled      = state.llm_enabled,
            llm_debounce     = state.llm_debounce,
            llm_model        = state.llm_model,
        }

        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            for _, s in ipairs(shortcuts.list_shortcuts()) do
                prefs.shortcut_keys[s.id] = s.enabled
            end
        end

        for k, v in pairs(prefs) do existing[k] = v end

        local ok, encoded = pcall(hs.json.encode, existing)
        if ok and encoded then
            local fh = io.open(prefs_file, "w")
            if fh then fh:write(encoded); fh:close() end
        else
            hs.printf("[ui/menu] save_prefs failed\226\128\148 %s", tostring(encoded))
        end
    end

-- ===============================================
-- ===============================================
-- ===============================================
-- ========== 5. STARTUP INITIALISATION ==========
-- ===============================================
-- ===============================================
-- ===============================================

    -- IMPORTANT: llm_handler is created AFTER this block so it captures
    -- fully initialised state values (llm_model, llm_enabled, etc.).

    do
        local saved         = load_prefs()
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
            if saved.keymap           ~= nil then state.keymap           = saved.keymap           end
            if saved.gestures         ~= nil then state.gestures         = saved.gestures         end
            if saved.scroll           ~= nil then state.scroll           = saved.scroll           end
            if saved.shortcuts        ~= nil then state.shortcuts        = saved.shortcuts        end
            if saved.personal_info    ~= nil then state.personal_info    = saved.personal_info    end
            if saved.chatgpt_url      ~= nil then state.chatgpt_url      = saved.chatgpt_url      end
            if saved.preview_enabled  ~= nil then state.preview_enabled  = saved.preview_enabled  end
            if saved.llm_enabled      ~= nil then state.llm_enabled      = saved.llm_enabled      end
            if type(saved.llm_debounce) == "number" then state.llm_debounce = saved.llm_debounce end
            if type(saved.llm_model)    == "string" then state.llm_model    = saved.llm_model    end
            if type(saved.sections_order_overrides) == "table" then
                state.sections_order_overrides = saved.sections_order_overrides
            end
            if type(saved.terminator_states) == "table" then
                state.terminator_states = saved.terminator_states
                for key, enabled in pairs(saved.terminator_states) do
                    if keymap and keymap.set_terminator_enabled then
                        keymap.set_terminator_enabled(key, enabled)
                    end
                end
            end
            if type(saved.expansion_delay) == "number" then
                state.expansion_delay = saved.expansion_delay
                if keymap and keymap.set_base_delay then keymap.set_base_delay(saved.expansion_delay) end
            end
            if type(saved.script_control_shortcuts) == "table" then
                for k, v in pairs(saved.script_control_shortcuts) do
                    state.script_control_shortcuts[k] = v
                end
            end
            if saved.script_control_enabled ~= nil then
                state.script_control_enabled = saved.script_control_enabled
            end
            if saved.ahk_source_path ~= nil then state.ahk_source_path = saved.ahk_source_path end
            if type(saved.hotstrings) == "table" then
                for name in pairs(state.hotstrings) do
                    if saved.hotstrings[name] ~= nil then
                        state.hotstrings[name] = saved.hotstrings[name]
                    end
                end
            end
            if type(saved.gesture_actions) == "table" then
                for slot, action in pairs(saved.gesture_actions) do gestures.set_action(slot, action) end
            end
            gestures.apply_all_overrides()
        end

        if keymap then
            if keymap.set_preview_enabled then keymap.set_preview_enabled(state.preview_enabled) end
            if keymap.set_llm_enabled     then keymap.set_llm_enabled(state.llm_enabled)         end
            if keymap.set_llm_debounce    then keymap.set_llm_debounce(state.llm_debounce)       end
            if keymap.set_llm_model       then keymap.set_llm_model(state.llm_model)             end
        end

        if state.keymap    then keymap.start()        else keymap.stop()          end
        if state.gestures  then gestures.enable_all() else gestures.disable_all() end
        if state.scroll    then scroll.start()         else scroll.stop()          end
        if state.shortcuts then shortcuts.start()      else shortcuts.stop()       end
        if personal_info then
            if state.personal_info then personal_info.enable() else personal_info.disable() end
        end

        for name, enabled in pairs(state.hotstrings) do
            if enabled then keymap.enable_group(name) else keymap.disable_group(name) end
        end

        if type(saved) == "table" and type(saved.shortcut_keys) == "table" then
            for id, enabled in pairs(saved.shortcut_keys) do
                if enabled then shortcuts.enable(id) else shortcuts.disable(id) end
            end
        end

        if config_absent then save_prefs() end
    end

    -- ====================================
-- ====================================
-- ====================================
-- ========== 6. LLM HANDLER ==========
-- ====================================
-- ====================================
-- ====================================

    -- Created AFTER startup so it captures fully initialised state values.
    local llm_handler = menu_llm.create({
        state          = state,
        active_tasks   = M._active_tasks,
        update_icon    = update_icon,
        update_menu    = function() updateMenu() end,
        save_prefs     = save_prefs,
        keymap         = keymap,
        script_control = script_control,
    })
    llm_handler.check_startup()

-- =============================================
-- =============================================
-- =============================================
-- ========== 7. SCRIPT CONTROL SETUP ==========
-- =============================================
-- =============================================
-- =============================================

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
                    hs.execute('open "' .. base_dir .. 'init.lua"')
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
                    local app_name = hs.execute(string.format(
                        "osascript -e 'tell application \"Finder\" to return name of "
                        .. "(default application of (info for POSIX file \"%s\"))' 2>/dev/null", path))
                    app_name = app_name and app_name:match("^%s*(.-)%s*$") or ""
                    if app_name ~= "" then hs.execute(string.format('open -a "%s" "%s"', app_name, path))
                    else hs.execute('open -t "' .. path .. '"') end
                end)
            end,
        })
    end

-- ===========================================
-- ===========================================
-- ===========================================
-- ========== 8. MENU ITEM BUILDERS ==========
-- ===========================================
-- ===========================================
-- ===========================================


    -- ==================================
-- ======= 8.1 Shared Helpers =======
-- ==================================

    local function groupEnabled(name)
        return (keymap and type(keymap.is_group_enabled) == "function"
                and keymap.is_group_enabled(name))
            or (state.hotstrings[name] ~= false)
    end

    local function groupLabel(name)
        local meta = keymap and keymap.get_meta_description and keymap.get_meta_description(name)
        return (meta and meta ~= "") and meta or name:gsub("_", " ")
    end

    local function toggleGroupFn(name)
        return function()
            state.hotstrings[name] = not groupEnabled(name)
            if state.hotstrings[name] then
                keymap.enable_group(name)
                if not state.keymap then state.keymap = true; keymap.start() end
            else
                keymap.disable_group(name)
            end
            save_prefs()
            notify_feature(groupLabel(name), state.hotstrings[name])
            updateMenu()
        end
    end

    local function toggleSectionFn(group_name, sec_name, sec_label)
        return function()
            local will_enable = not keymap.is_section_enabled(group_name, sec_name)
            if will_enable then
                keymap.enable_section(group_name, sec_name)
                if not state.keymap then state.keymap = true; keymap.start() end
            else
                keymap.disable_section(group_name, sec_name)
            end
            save_prefs()
            notify_feature(sec_label or sec_name, will_enable)
            updateMenu()
        end
    end

    local buildPersonalInfoItems  -- forward declaration

    -- ==============================
-- ======= 8.2 Hotstrings =======
-- ==============================

    local function buildHotstringsItems()
        local paused    = script_control and script_control.is_paused() or false
        local top_names = {}
        for _, f in ipairs(hotfiles or {}) do
            top_names[#top_names + 1] = f:match("^(.*)%.lua$") or f
        end
        if #top_names == 0 then return {} end

        local items = {}
        for _, name in ipairs(top_names) do
            local enabled  = groupEnabled(name)
            local sections = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            local has_secs = sections and #sections > 0

            local total, has_count = 0, false
            if enabled and has_secs then
                for _, sec in ipairs(sections) do
                    if sec.name ~= "-" and not sec.is_module_placeholder
                        and keymap.is_section_enabled(name, sec.name) then
                        if sec.count ~= nil then has_count = true; total = total + sec.count end
                    end
                end
            end

            local base_label = groupLabel(name)
            local item = {
                title   = has_count and (base_label .. " (" .. total .. ")") or base_label,
                checked = (enabled and not paused) or nil,
                fn      = toggleGroupFn(name),
            }

            if has_secs then
                local override = (state.sections_order_overrides or {})[name]
                local ordered_secs

                if override then
                    local by_name = {}
                    for _, sec in ipairs(sections) do by_name[sec.name] = sec end
                    local seen = {}
                    ordered_secs = {}
                    for _, entry in ipairs(override) do
                        if entry == "-" then table.insert(ordered_secs, { name = "-" })
                        elseif by_name[entry] then
                            table.insert(ordered_secs, by_name[entry]); seen[entry] = true
                        end
                    end
                    for _, sec in ipairs(sections) do
                        if not seen[sec.name] and sec.name ~= "-" then
                            table.insert(ordered_secs, sec)
                        end
                    end
                else
                    ordered_secs = sections
                end

                local sec_menu = {}
                for _, sec in ipairs(ordered_secs) do
                    if sec.name == "-" then
                        sec_menu[#sec_menu + 1] = { title = "-" }
                    elseif sec.is_module_placeholder then
                        local ms       = module_sections and module_sections[name]
                        local ms_entry = ms and ms[sec.name]
                        local mod_id   = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
                        if mod_id == "personal_info" then
                            local pi_items = buildPersonalInfoItems(
                                type(ms_entry) == "table" and ms_entry.description or nil)
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
                        local lbl    = (sec.description and sec.description ~= "")
                                       and sec.description or sec.name:gsub("_", " ")
                        sec_menu[#sec_menu + 1] = {
                            title    = sec.count ~= nil and (lbl .. " (" .. sec.count .. ")") or lbl,
                            checked  = (sec_on and not paused) or nil,
                            fn       = (enabled and not paused)
                                       and toggleSectionFn(name, sec.name, lbl) or nil,
                            disabled = not enabled or paused or nil,
                        }
                    end
                end
                item.menu = sec_menu
            end
            items[#items + 1] = item
        end
        return items
    end

    -- =================================
-- ======= 8.3 Personal Info =======
-- =================================

    buildPersonalInfoItems = function(description)
        if not personal_info then return nil end
        return {
            {
                title   = description,
                checked = state.personal_info or nil,
                fn      = function()
                    state.personal_info = not state.personal_info
                    if state.personal_info then personal_info.enable()
                    else personal_info.disable() end
                    save_prefs()
                    notify_feature(description or "Informations personnelles", state.personal_info)
                    updateMenu()
                end,
            },
            {
                title = "   \226\134\179 Modifier les informations\226\128\166",
                fn    = function() hs.timer.doAfter(0.1, personal_info.open_editor) end,
            },
        }
    end

-- ======================================
-- ======= 8.4 Hotstring Settings =======
-- ======================================

    local function buildHotstringsManagementItem()
        local paused = script_control and script_control.is_paused() or false
        local menu   = {}

        table.insert(menu, {
            title    = "Afficher la prévisualisation (Bulle)",
            checked  = (state.preview_enabled and not paused) or nil,
            disabled = paused or nil,
            fn       = not paused and function()
                state.preview_enabled = not state.preview_enabled
                if keymap and keymap.set_preview_enabled then
                    keymap.set_preview_enabled(state.preview_enabled)
                end
                save_prefs()
                notify_feature("Prévisualisation", state.preview_enabled)
                updateMenu()
            end or nil,
        })
        table.insert(menu, { title = "-" })

        local defs    = keymap and keymap.get_terminator_defs and keymap.get_terminator_defs() or {}
        local exp_sub = {}
        for _, def in ipairs(defs) do
            local enabled_t = keymap.is_terminator_enabled(def.key)
            exp_sub[#exp_sub + 1] = {
                title    = def.label,
                checked  = (enabled_t and not paused) or nil,
                disabled = paused or nil,
                fn       = not paused and (function(k, lbl) return function()
                    local nv = not keymap.is_terminator_enabled(k)
                    keymap.set_terminator_enabled(k, nv)
                    state.terminator_states[k] = nv
                    save_prefs()
                    notify_feature("Expanseur" .. NBSP .. ": " .. lbl, nv)
                    updateMenu()
                end end)(def.key, def.label) or nil,
            }
        end
        table.insert(menu, { title = "Expanseurs", disabled = paused or nil, menu = exp_sub })

        local current_ms = math.floor(
            ((keymap and keymap.get_base_delay and keymap.get_base_delay()) or state.expansion_delay) * 1000 + 0.5)
        table.insert(menu, {
            title    = "Délai maximal d'expansion" .. NBSP .. ": " .. current_ms .. " ms\226\128\166",
            disabled = paused or nil,
            fn       = not paused and function()
                local btn, raw = hs.dialog.textPrompt(
                    "Délai maximal d'expansion",
                    "Entrez le délai en millisecondes (entier \226\137\165 0)" .. NBSP .. ":",
                    tostring(current_ms), "OK", "Annuler")
                if btn ~= "OK" then return end
                local val = tonumber(raw)
                if not val or val < 0 or val ~= math.floor(val) then
                    hs.notify.new({ title = "Délai invalide",
                        informativeText = "Veuillez saisir un entier \226\137\165 0." }):send(); return
                end
                keymap.set_base_delay(val / 1000); state.expansion_delay = val / 1000
                save_prefs(); updateMenu()
            end or nil,
        })

        return { title = "Param\195\168tres Hotstrings", menu = menu }
    end

    -- ============================
-- ======= 8.5 Gestures =======
-- ============================

    local function buildGesturesItem()
        local paused = script_control and script_control.is_paused() or false
        local item   = {
            title   = "Gestes",
            checked = (state.gestures and not paused) or nil,
            fn      = function()
                state.gestures = not state.gestures
                if state.gestures then gestures.enable_all() else gestures.disable_all() end
                save_prefs(); notify_feature("Gestes", state.gestures); updateMenu()
            end,
        }

        local function slotItem(slot, isAxis)
            local current   = gestures.get_action(slot)
            local slotLbl   = SLOT_LABELS[slot] or slot
            local actionLbl = gestures.get_action_label(current)
            local names     = isAxis and gestures.AX_NAMES or gestures.SG_NAMES
            local submenu   = {}
            for _, aname in ipairs(names) do
                table.insert(submenu, {
                    title    = gestures.get_action_label(aname),
                    checked  = ((current == aname) and not paused) or nil,
                    disabled = not state.gestures or paused or nil,
                    fn       = (state.gestures and not paused) and (function(a) return function()
                        gestures.set_action(slot, a)
                        local conflict = gestures.on_action_changed(slot, a)
                        save_prefs(); updateMenu()
                        if conflict then
                            hs.timer.doAfter(0.3, function()
                                hs.focus()
                                local clicked = hs.dialog.blockAlert(
                                    "\226\154\160\239\184\143  Conflit potentiel", conflict.msg,
                                    "Ouvrir Réglages", "Plus tard", "warning")
                                if clicked == "Ouvrir Réglages" then
                                    hs.execute(string.format("open '%s'", conflict.url))
                                end
                            end)
                        end
                    end end)(aname) or nil,
                })
            end
            return {
                title    = slotLbl .. NBSP .. ": " .. actionLbl,
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

-- =============================
-- ======= 8.6 Shortcuts =======
-- =============================

    local function buildRaccourcisItem()
        local paused = script_control and script_control.is_paused() or false
        local item   = {
            title   = "Raccourcis",
            checked = (state.shortcuts and not paused) or nil,
            fn      = function()
                state.shortcuts = not state.shortcuts
                if state.shortcuts then shortcuts.start() else shortcuts.stop() end
                save_prefs(); notify_feature("Raccourcis", state.shortcuts); updateMenu()
            end,
        }

        local function pretty_key(id)
            if id == "at_hash" then return "Touche @/#" end
            local parts = {}
            for p in id:gmatch("[^_]+") do table.insert(parts, p) end
            if #parts == 0 then return id end
            local key = parts[#parts]
            if key == "star" or key == "asterisk" then key = "\226\152\133" end
            local mods = {}
            for i = 1, #parts - 1 do
                local p = parts[i]
                local lbl = ({ ctrl="Ctrl", cmd="Cmd", alt="Alt", option="Alt", shift="Shift" })[p]
                table.insert(mods, lbl or (p:sub(1,1):upper() .. p:sub(2)))
            end
            return (#mods > 0 and table.concat(mods, " + ") .. " + " or "") .. key:upper()
        end

        local s_menu = {}
        table.insert(s_menu, {
            title    = "Layer (Left Command) + Scroll" .. NBSP .. ": Volume",
            checked  = (state.scroll and not paused) or nil,
            disabled = not state.shortcuts or paused or nil,
            fn       = (state.shortcuts and not paused) and function()
                state.scroll = not state.scroll
                if state.scroll then scroll.start() else scroll.stop() end
                save_prefs(); notify_feature("Volume (Scroll)", state.scroll); updateMenu()
            end or nil,
        })
        table.insert(s_menu, { title = "-" })

        local last_was_non_ctrl, separator_inserted = false, false
        for _, s in ipairs(shortcuts.list_shortcuts()) do
            local is_ctrl = s.id:sub(1, 5) == "ctrl_"
            if not separator_inserted and last_was_non_ctrl and is_ctrl then
                table.insert(s_menu, { title = "-" }); separator_inserted = true
            end
            if not is_ctrl then last_was_non_ctrl = true end

            local is_on = shortcuts.is_enabled and shortcuts.is_enabled(s.id) or s.enabled
            local desc  = (s.label or ""):gsub("^%s*(.-)%s*$", "%1")
            table.insert(s_menu, {
                title    = pretty_key(s.id) .. NBSP .. ": " .. (desc ~= "" and desc or s.id),
                checked  = (is_on and not paused) or nil,
                disabled = not state.shortcuts or paused or nil,
                fn       = (state.shortcuts and not paused) and (function(id) return function()
                    local on = shortcuts.is_enabled(id)
                    if on then shortcuts.disable(id) else shortcuts.enable(id) end
                    save_prefs(); notify_feature(pretty_key(id), not on); updateMenu()
                end end)(s.id) or nil,
            })
            if s.id == "ctrl_g" then
                table.insert(s_menu, {
                    title    = "   \226\134\179 Modifier l'URL ChatGPT\226\128\166",
                    disabled = paused or nil,
                    fn       = not paused and function()
                        local clicked, url = hs.dialog.textPrompt("URL ChatGPT",
                            "URL ouverte par Ctrl+G" .. NBSP .. ":",
                            state.chatgpt_url or "", "OK", "Annuler")
                        if clicked == "OK" and url ~= nil and url ~= "" then
                            state.chatgpt_url = url; save_prefs(); updateMenu()
                        end
                    end or nil,
                })
            end
        end
        item.menu = s_menu
        return item
    end

-- ==================================
-- ======= 8.7 Script Control =======
-- ==================================

    local function buildScriptControlItem()
        if not script_control then return nil end
        local paused     = script_control.is_paused()
        local actions    = script_control.ACTIONS
        local act_labels = script_control.ACTION_LABELS
        local enabled    = state.script_control_enabled

        local function key_submenu(keyname)
            local current = state.script_control_shortcuts[keyname] or "none"
            local sub = {}
            for _, act in ipairs(actions) do
                table.insert(sub, {
                    title    = act_labels[act],
                    checked  = ((current == act) and not paused) or nil,
                    disabled = not enabled or paused or nil,
                    fn       = (enabled and not paused) and (function(a) return function()
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
        return {
            title   = "Contr\195\180le du script",
            checked = (enabled and not paused) or nil,
            fn      = function()
                state.script_control_enabled = not state.script_control_enabled
                if state.script_control_enabled then
                    script_control.set_shortcut_action("return_key", state.script_control_shortcuts.return_key)
                    script_control.set_shortcut_action("backspace",  state.script_control_shortcuts.backspace)
                else
                    script_control.set_shortcut_action("return_key", "none")
                    script_control.set_shortcut_action("backspace",  "none")
                end
                save_prefs()
                notify_feature("Contr\195\180le du script", state.script_control_enabled)
                updateMenu()
            end,
            menu = {
                { title = "Option droite + \226\134\169" .. NBSP .. ": " .. (act_labels[cur_return] or cur_return),
                   disabled = not enabled or paused or nil, menu = key_submenu("return_key") },
                { title = "Option droite + \226\140\171" .. NBSP .. ": " .. (act_labels[cur_back] or cur_back),
                   disabled = not enabled or paused or nil, menu = key_submenu("backspace") },
                { title = "-" },
                { title    = "Chemin du script AHK\226\128\166",
                   disabled = paused or nil,
                   fn       = not paused and function()
                    local btn, path = hs.dialog.textPrompt("Script AHK",
                        "Chemin du fichier AHK source" .. NBSP .. ":",
                        state.ahk_source_path or "", "OK", "Annuler")
                    if btn == "OK" and path ~= nil then
                        state.ahk_source_path = path; save_prefs(); updateMenu()
                    end
                   end or nil },
            },
        }
    end

-- =========================================
-- ======= 8.8 Bulk Enable / Disable =======
-- =========================================

    -- *** FIX: Apply changes in-place without hs.reload().
    --   1. Update state + hs.settings for sections
    --   2. Force-disable then re-enable every TOML group (triggers load_toml
    --      which re-reads hs.settings, correctly loading/omitting sections)
    --   3. Apply to all other modules directly
    --   4. save_prefs() + notify + updateMenu  — no reload needed
    local function set_all_enabled(enabled)
        state.keymap = enabled; state.gestures = enabled
        state.scroll = enabled; state.shortcuts = enabled
        if personal_info then state.personal_info = enabled end
        for name in pairs(state.hotstrings) do state.hotstrings[name] = enabled end

        -- Update section hs.settings BEFORE re-enabling groups
        for name in pairs(state.hotstrings) do
            local secs = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            if secs then
                for _, sec in ipairs(secs) do
                    if sec.name ~= "-" and not sec.is_module_placeholder then
                        local key = "hotstrings_section_" .. name .. "_" .. sec.name
                        if enabled then
                            hs.settings.set(key, nil)
                        else
                            hs.settings.set(key, false)
                        end
                    end
                end
            end
        end

        -- Force-reload every TOML group so sections are re-evaluated
        for name in pairs(state.hotstrings) do
            if groupEnabled(name) then keymap.disable_group(name) end
            if enabled then keymap.enable_group(name) end
        end

        -- Apply to other modules
        if enabled then keymap.start()        else keymap.stop()          end
        if enabled then gestures.enable_all() else gestures.disable_all() end
        if enabled then scroll.start()         else scroll.stop()          end
        if enabled then shortcuts.start()      else shortcuts.stop()       end
        if personal_info then
            if enabled then personal_info.enable() else personal_info.disable() end
        end

        -- Apply individual shortcut states
        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            for _, s in ipairs(shortcuts.list_shortcuts()) do
                if enabled then shortcuts.enable(s.id) else shortcuts.disable(s.id) end
            end
        end

        save_prefs()
        notify_feature(enabled and "Tout activé" or "Tout désactivé", enabled)
        updateMenu()
    end

-- ======================================
-- ======================================
-- ======================================
-- ========== 9. MENU ASSEMBLY ==========
-- ======================================
-- ======================================
-- ======================================

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
        table.insert(items, llm_handler.build_item())
        table.insert(items, { title = "-" })
        table.insert(items, buildGesturesItem())
        table.insert(items, buildRaccourcisItem())

        local sc = buildScriptControlItem()
        if sc then table.insert(items, sc) end

        table.insert(items, { title = "-" })
        table.insert(items, { title = "🟩 Tout activer",
            fn = function() set_all_enabled(true)  end })
        table.insert(items, { title = "🟥 Tout désactiver",
            fn = function() set_all_enabled(false) end })
        table.insert(items, { title = "-" })
        table.insert(items, { title = "Ouvrir init.lua",
            fn = function() hs.execute('open "' .. base_dir .. 'init.lua"') end })
        table.insert(items, { title = "Console Hammerspoon",
            fn = function() hs.openConsole() end })
        table.insert(items, { title = "Préférences Hammerspoon",
            fn = function() hs.openPreferences() end })
        table.insert(items, { title = "Recharger la configuration",
            fn = function() do_reload() end })
        table.insert(items, { title = "Quitter Hammerspoon",
            fn = function() hs.timer.doAfter(0.1, function() os.exit(0) end) end })

        myMenu:setMenu({})
        hs.timer.doAfter(0.02, function() myMenu:setMenu(items) end)
    end

    updateMenu()

-- ======================================
-- ======================================
-- ======================================
-- ========== 10. FILE WATCHER ==========
-- ======================================
-- ======================================
-- ======================================

    local function reloadConfig(files)
        if hs.timer.secondsSinceEpoch() < _suppress_watcher_until then return end
        for _, file in pairs(files) do
            if file:sub(-4) == ".lua" then do_reload("watcher"); return end
        end
    end
    local configWatcher = hs.pathwatcher.new(base_dir, reloadConfig):start()

    M._menu    = myMenu
    M._watcher = configWatcher

    pcall(utils.notify, "Script pr\195\170t\194\160! \240\159\154\128")
    return myMenu, configWatcher
end

return M
