local M = {}
local hs = hs
local image = hs.image
local menubar = hs.menubar
local pathwatcher = hs.pathwatcher
local utils = require("lib.utils")

-- Display labels for slots shown in the menu
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

    -- Icon logic: dark mode XOR paused → logo_white, else logo_black.
    -- In dark mode the bar is dark, so white = visible (normal) / black = faded (paused).
    -- In light mode it is the inverse.
    local function isDarkMode()
        local ok2, out = pcall(function()
            return hs.execute('defaults read -g AppleInterfaceStyle 2>/dev/null')
        end)
        return ok2 and out and out:match("Dark") ~= nil
    end

    local function update_icon()
        local is_dark   = isDarkMode()
        local is_paused = script_control and script_control.is_paused() or false
        -- XOR: normal state = readable icon; paused = faded icon
        local logo_file = (is_dark ~= is_paused) and "logo_black.png" or "logo_white.png"
        local icon_path = base_dir .. "images/" .. logo_file
        local ico = image.imageFromPath(icon_path)
        if ico then
            pcall(function() if ico.setSize then ico:setSize({w=18,h=18}) end end)
            myMenu:setIcon(ico, false)
        else
            myMenu:setTitle("🔨")
        end
    end

    update_icon()

    local function do_reload(source)
        if source == "watcher" then
            pcall(function()
                utils.notify("Fichiers modifiés — Rechargement du script… 🔄")
            end)
        else
            pcall(function()
                utils.notify("Rechargement du script… 🔄")
            end)
        end
        hs.timer.doAfter(0.25, function() hs.reload() end)
    end

    local state = {keymap=true, gestures=true, scroll=true, shortcuts=true, personal_info=true, hotstrings={}, chatgpt_url="https://chat.openai.com", sections_order_overrides={}, terminator_states={}, expansion_delay=0.75, script_control_shortcuts={return_key="pause", backspace="reload"}, script_control_enabled=true, ahk_source_path=""}
    for _, f in ipairs(hotfiles or {}) do
        local name = f:match("^(.*)%.lua$") or f
        state.hotstrings[name] = true
    end

    local prefs_file = base_dir .. "config.json"
    -- Timestamp until which the path-watcher ignores .lua change events.
    -- Set after open_init to avoid a spurious reload when the editor opens
    -- the file and writes metadata/swap files back to the directory.
    local _suppress_watcher_until = 0

    local function load_prefs()
        local fh = io.open(prefs_file, "r")
        if not fh then return {} end
        local content = fh:read("*a"); fh:close()
        local ok2, tbl = pcall(function() return hs.json.decode(content) end)
        return (ok2 and type(tbl) == "table") and tbl or {}
    end

    local function save_prefs()
        -- Snapshot section states from hs.settings so they are fully portable.
        local section_states = {}
        for _, f in ipairs(hotfiles or {}) do
            local name = f:match("^(.*)%.lua$") or f
            local secs = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            if secs then
                section_states[name] = {}
                for _, sec in ipairs(secs) do
                    if sec.name ~= '-' and not sec.is_module_placeholder then
                        section_states[name][sec.name] =
                            keymap.is_section_enabled(name, sec.name)
                    end
                end
            end
        end

        -- Read existing config.json first so keys managed by other modules
        -- (e.g. personal_info_config) are preserved across saves.
        local existing = load_prefs()

        local prefs = {
            keymap                   = state.keymap,
            gestures                 = state.gestures,
            scroll                   = state.scroll,
            shortcuts                = state.shortcuts,
            personal_info            = state.personal_info,
            hotstrings               = state.hotstrings,
            chatgpt_url              = state.chatgpt_url,
            sections_order_overrides = state.sections_order_overrides,
            section_states           = section_states,
            terminator_states        = state.terminator_states,
            expansion_delay          = state.expansion_delay,
            shortcut_keys            = {},
            gesture_actions          = gestures.get_all_actions(),
            script_control_shortcuts = state.script_control_shortcuts,
            script_control_enabled   = state.script_control_enabled,
            ahk_source_path          = state.ahk_source_path,
        }
        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            for _, s in ipairs(shortcuts.list_shortcuts()) do
                prefs.shortcut_keys[s.id] = s.enabled
            end
        end

        -- Merge: start from existing file, then overwrite only our own keys.
        -- This preserves foreign keys (e.g. personal_info_config) untouched.
        for k, v in pairs(prefs) do
            existing[k] = v
        end

        local ok2, encoded = pcall(function() return hs.json.encode(existing) end)
        if not ok2 or not encoded then return end
        local fh = io.open(prefs_file, "w")
        if not fh then return end
        fh:write(encoded); fh:close()
    end

    -- Forward declaration so toggle closures can reference it before its body is defined.
    local updateMenu

    -- Apply saved preferences
    do
        local saved = load_prefs()
        local config_absent = (next(saved) == nil)  -- empty table = file missing

        if config_absent then
            -- No config.json: reset hs.settings section keys to nil (= enabled)
            -- so that stale NSUserDefaults values from a previous session do not
            -- pollute the new file that save_prefs() will write below.
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
                -- Reload each group so load_toml re-reads the now-cleared hs.settings.
                keymap.disable_group(name)
                keymap.enable_group(name)
            end
        end

        if type(saved) == "table" then
            if saved.keymap    ~= nil then state.keymap    = saved.keymap    end
            if saved.gestures  ~= nil then state.gestures  = saved.gestures  end
            if saved.scroll    ~= nil then state.scroll    = saved.scroll    end
            if saved.shortcuts     ~= nil then state.shortcuts     = saved.shortcuts     end
            if saved.personal_info ~= nil then state.personal_info = saved.personal_info end
            if saved.chatgpt_url              ~= nil then state.chatgpt_url              = saved.chatgpt_url              end
            if type(saved.sections_order_overrides) == 'table' then
                state.sections_order_overrides = saved.sections_order_overrides
            end
            if type(saved.terminator_states) == 'table' then
                state.terminator_states = saved.terminator_states
                for key, enabled in pairs(saved.terminator_states) do
                    if keymap and keymap.set_terminator_enabled then
                        keymap.set_terminator_enabled(key, enabled)
                    end
                end
            end
            if type(saved.expansion_delay) == 'number' then
                state.expansion_delay = saved.expansion_delay
                if keymap and keymap.set_base_delay then
                    keymap.set_base_delay(saved.expansion_delay)
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
            -- Restore gesture actions
            if type(saved.gesture_actions) == "table" then
                for slot, action in pairs(saved.gesture_actions) do
                    gestures.set_action(slot, action)
                end
            end
            -- Silently re-enforce any overrides the user may have re-activated
            -- in System Settings between two script sessions.
            gestures.apply_all_overrides()
            -- Note: section_states are applied to hs.settings by init.lua BEFORE
            -- load_toml is called, so no hs.settings manipulation is needed here.
        end

        if state.keymap        then keymap.start()        else keymap.stop()        end
        if state.gestures      then gestures.enable_all()  else gestures.disable_all() end
        if state.scroll        then scroll.start()        else scroll.stop()        end
        if state.shortcuts     then shortcuts.start()     else shortcuts.stop()     end
        if personal_info then
            if state.personal_info then personal_info.enable() else personal_info.disable() end
        end

        -- Groups are already loaded correctly by init.lua (hs.settings was primed
        -- from config.json before load_toml ran).  Just enable/disable the tap.
        for name, enabled in pairs(state.hotstrings) do
            if enabled then keymap.enable_group(name) else keymap.disable_group(name) end
        end
        if type(saved) == "table" and type(saved.shortcut_keys) == "table" then
            for id, enabled in pairs(saved.shortcut_keys) do
                if enabled then shortcuts.enable(id) else shortcuts.disable(id) end
            end
        end
        -- Only rewrite config.json when it was absent (first run / migration).
        -- When the file already exists it is already canonical: rewriting it
        -- from live-module states would corrupt a config just written by
        -- set_all_enabled() before the reload.
        if config_absent then
            save_prefs()
        end
    end
    -- Configure script_control with persisted shortcuts and callbacks.
    if script_control then
        script_control.set_on_pause_change(function(_) update_icon(); updateMenu() end)
        -- Apply enabled state: if disabled, push "none" for all slots.
        local function apply_sc_enabled()
            if state.script_control_enabled then
                script_control.set_shortcut_action("return_key", state.script_control_shortcuts.return_key)
                script_control.set_shortcut_action("backspace",  state.script_control_shortcuts.backspace)
            else
                script_control.set_shortcut_action("return_key", "none")
                script_control.set_shortcut_action("backspace",  "none")
            end
        end
        apply_sc_enabled()
        script_control.set_extras({
            open_init = function()
                hs.timer.doAfter(0, function()
                    -- Suppress the path-watcher for a few seconds so that the
                    -- editor opening init.lua does not trigger a spurious reload
                    -- (e.g. VS Code writing metadata / swap files on open).
                    _suppress_watcher_until = hs.timer.secondsSinceEpoch() + 8
                    hs.execute('open "'..base_dir..'init.lua"')
                end)
            end,
            open_ahk  = function()
                -- Run entirely async to avoid blocking the eventtap handler.
                hs.timer.doAfter(0, function()
                    -- Resolution order for the file path:
                    -- 1. User override saved in config.json
                    -- 2. LOCAL_AHK_PATH environment variable
                    -- 3. .local_ahk_path file next to hotstrings
                    -- 4. Default project path: ../autohotkey/ErgoptiPlus.ahk
                    local path = (state.ahk_source_path ~= "") and state.ahk_source_path or nil
                    if not path then
                        path = os.getenv("LOCAL_AHK_PATH")
                    end
                    if not path then
                        local lf = io.open(base_dir .. "../hotstrings/.local_ahk_path", "r")
                        if lf then
                            local raw = lf:read("*a"); lf:close()
                            raw = raw:match("^%s*(.-)%s*$")
                            if raw ~= "" then path = raw end
                        end
                    end
                    if not path then
                        path = base_dir .. "../autohotkey/ErgoptiPlus.ahk"
                    end
                    -- Open with the same app that handles init.lua (e.g. VS Code),
                    -- falling back to the system text editor (open -t).
                    local init_path = base_dir .. "init.lua"
                    local app_name = hs.execute(string.format(
                        "osascript -e 'tell application \"Finder\" to return name of" ..
                        " (default application of (info for POSIX file \"%s\"))' 2>/dev/null",
                        init_path
                    ))
                    app_name = app_name and app_name:match("^%s*(.-)%s*$") or ""
                    if app_name ~= "" then
                        hs.execute(string.format('open -a "%s" "%s"', app_name, path))
                    else
                        hs.execute('open -t "'..path..'"')
                    end
                end)
            end,
        })
    end
    -- ── Menu item builders ─────────────────────────────────────────────────────

    -- Helper: resolve enabled state for a top-level TOML/Lua group.
    local function groupEnabled(name)
        return (keymap and type(keymap.is_group_enabled) == "function"
                and keymap.is_group_enabled(name))
               or (state.hotstrings[name] ~= false)
    end

    -- Helper: label for a top-level group (uses [_meta] description if present).
    local function groupLabel(name)
        local meta = keymap and keymap.get_meta_description
                     and keymap.get_meta_description(name) or nil
        return (meta and meta ~= '') and meta or name:gsub('_', ' ')
    end

    -- Helper: toggle function for a top-level group.
    -- Enabling any group also restarts the eventtap if it was stopped
    -- (e.g. after a "Disable all" which sets state.keymap=false).
    local function toggleGroupFn(name)
        return function()
            state.hotstrings[name] = not groupEnabled(name)
            if state.hotstrings[name] then
                keymap.enable_group(name)
                -- Ensure the eventtap is running; calling start() when already
                -- running is a no-op in Hammerspoon.
                if not state.keymap then
                    state.keymap = true
                    keymap.start()
                end
            else
                keymap.disable_group(name)
            end
            save_prefs(); updateMenu()
        end
    end

    -- Helper: toggle function for a section within a TOML group.
    -- Also restarts the eventtap if it was stopped (state.keymap=false).
    local function toggleSectionFn(group_name, sec_name)
        return function()
            if keymap.is_section_enabled(group_name, sec_name) then
                keymap.disable_section(group_name, sec_name)
            else
                keymap.enable_section(group_name, sec_name)
                -- Ensure the eventtap is running.
                if not state.keymap then
                    state.keymap = true
                    keymap.start()
                end
            end
            save_prefs(); updateMenu()
        end
    end

    -- Forward declaration: buildPersonalInfoItem is defined below but called
    -- from inside buildHotstringsItems (to inject it at the right sub-menu slot).
    local buildPersonalInfoItem

    -- Returns a flat list of items, one per TOML/Lua group, inserted directly
    -- into the top-level menu (no extra "Hotstrings" parent wrapper).
    --
    -- Each group item title includes the total hotstring count: "Label (N)".
    -- TOML groups always show a ">" sub-menu listing every section as a
    -- checkable toggle (even when the group is disabled).  The parent item is
    -- itself clickable (toggles the group) while the sub-menu lets the user
    -- control individual sections.  When the group is disabled, sub-items are
    -- rendered without an fn so macOS greys them out; the group must be
    -- re-enabled first before sections can be toggled.
    -- Lua groups (no sections) keep the simple click-to-toggle behaviour.
    local function buildHotstringsItems()
        local paused = script_control and script_control.is_paused() or false
        local top_names = {}
        for _, f in ipairs(hotfiles or {}) do
            top_names[#top_names + 1] = f:match("^(.*)%.lua$") or f
        end

        if #top_names == 0 then return {} end

        local items = {}
        for _, name in ipairs(top_names) do
            local enabled  = groupEnabled(name)
            local sections = keymap and keymap.get_sections
                             and keymap.get_sections(name) or nil
            local has_sections = sections and #sections > 0

            -- Compute total count: only active sections, 0 when group is disabled.
            -- has_count stays false when no section provides a real count (e.g. Lua
            -- groups like dynamichotstrings): in that case the badge is omitted.
            local total     = 0
            local has_count = false
            if enabled and has_sections then
                for _, sec in ipairs(sections) do
                    if sec.name ~= '-' and not sec.is_module_placeholder
                       and keymap.is_section_enabled(name, sec.name) then
                        if sec.count ~= nil then
                            has_count = true
                            total = total + sec.count
                        end
                    end
                end
            end

            local base_label = groupLabel(name)
            local item = {
                title   = has_count and (base_label .. " (" .. total .. ")") or base_label,
                checked = (enabled and not paused) or nil,
                -- The parent item is clickable even alongside a sub-menu.
                fn      = toggleGroupFn(name),
            }

            if has_sections then
                -- Always build sub-menu regardless of enabled state.
                -- Entries with name == "-" become native menu separators.
                -- An optional override can be supplied via config.json as:
                --   "sections_order_overrides": { "rolls": ["hc","sx","-",...] }
                -- When present, the override list is used instead of the TOML order;
                -- sections not mentioned in the override are appended at the end.
                local override_map = state.sections_order_overrides or {}
                local override = override_map[name]  -- nil or list of strings

                local ordered_secs  -- list of section objects in display order
                if override then
                    -- Build a lookup of sections by name for fast access.
                    local by_name = {}
                    for _, sec in ipairs(sections) do by_name[sec.name] = sec end
                    local seen = {}
                    ordered_secs = {}
                    for _, entry in ipairs(override) do
                        if entry == '-' then
                            table.insert(ordered_secs, { name = '-' })
                        elseif by_name[entry] then
                            table.insert(ordered_secs, by_name[entry])
                            seen[entry] = true
                        end
                    end
                    -- Append sections absent from the override.
                    for _, sec in ipairs(sections) do
                        if not seen[sec.name] and sec.name ~= '-' then
                            table.insert(ordered_secs, sec)
                        end
                    end
                else
                    -- Use the order already provided by keymap (from TOML sections_order).
                    ordered_secs = sections
                end

                local sec_menu = {}

                for _, sec in ipairs(ordered_secs) do
                    if sec.name == '-' then
                        sec_menu[#sec_menu + 1] = { title = "-" }
                    elseif sec.is_module_placeholder then
                        -- This section has no TOML entries: it is handled by a
                        -- dedicated Lua module whose toggle item is injected here
                        -- so that its position in the sub-menu follows the AHK
                        -- __Order definition automatically.
                        -- When the group is disabled, omit fn so the item is greyed.
                        local ms = module_sections and module_sections[name]
                        local ms_entry = ms and ms[sec.name]
                        local mod_id = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
                        local mod_desc = type(ms_entry) == "table" and ms_entry.description or nil
                        if mod_id == "personal_info" then
                            local pi = buildPersonalInfoItem(mod_desc)
                            if pi then
                                if paused then pi.checked = nil end
                            if not enabled or paused then pi.fn = nil; pi.disabled = true end
                                sec_menu[#sec_menu + 1] = pi
                            end
                        end
                    else
                        local sec_on = keymap.is_section_enabled(name, sec.name)
                        local label  = (sec.description and sec.description ~= '')
                                       and sec.description or sec.name:gsub('_', ' ')
                        -- Omit fn when the parent group is disabled so macOS greys
                        -- out the item; the user must re-enable the group first.
                        sec_menu[#sec_menu + 1] = {
                            -- Show count badge only when a real count is provided.
                            -- Lua-generated sections (e.g. dynamichotstrings) omit
                            -- sec.count so no misleading "(0)" is shown.
                            title    = sec.count ~= nil
                                       and (label .. " (" .. sec.count .. ")")
                                       or  label,
                            checked  = (sec_on and not paused) or nil,
                            fn       = (enabled and not paused) and toggleSectionFn(name, sec.name) or nil,
                            disabled = not enabled or paused or nil,
                        }
                    end
                end
                item.menu = sec_menu
            else
                -- Lua group (no sections): simple click-to-toggle.
                item.fn = toggleGroupFn(name)
            end

            items[#items + 1] = item
        end

        return items
    end

    local function buildGestesItem()
        local paused = script_control and script_control.is_paused() or false
        local item = {
            title   = "Gestes",
            checked = (state.gestures and not paused) or nil,
            fn = function()
                state.gestures = not state.gestures
                if state.gestures then gestures.enable_all() else gestures.disable_all() end
                save_prefs(); updateMenu()
            end
        }

        -- Builds an item with a radio sub-menu for a given slot.
        -- Sub-items are greyed out when gestures are disabled; the parent
        -- item's fn still lets the user toggle gestures back on.
        -- isAxis=true → AX_NAMES list, false → SG_NAMES list
        local function slotItem(slot, isAxis)
            local current  = gestures.get_action(slot)
            local slotLbl  = SLOT_LABELS[slot] or slot
            local actionLbl = gestures.get_action_label(current)
            local names    = isAxis and gestures.AX_NAMES or gestures.SG_NAMES
            local submenu  = {}
            for _, aname in ipairs(names) do
                table.insert(submenu, {
                    title    = gestures.get_action_label(aname),
                    checked  = ((current == aname) and not paused) or nil,
                    disabled = not state.gestures or paused or nil,
                    fn = (state.gestures and not paused) and (function(a) return function()
                        gestures.set_action(slot, a)
                        -- Warn user if the chosen action conflicts with a macOS gesture.
                        local conflict = gestures.on_action_changed(slot, a)
                        save_prefs(); updateMenu()
                        if conflict then
                            hs.timer.doAfter(0.3, function()
                                hs.focus()
                                local clicked = hs.dialog.blockAlert(
                                    "⚠️  Conflit potentiel avec un geste macOS", conflict.msg,
                                    "Ouvrir Réglages", "OK", "warning")
                                if clicked == "Ouvrir Réglages" then
                                    hs.execute(string.format(
                                        "open '%s'", conflict.url))
                                end
                            end)
                        end
                    end end)(aname) or nil,
                })
            end
            -- Grey the slot header itself when gestures or pause are active.
            return {
                title    = slotLbl .. " : " .. actionLbl,
                disabled = not state.gestures or paused or nil,
                menu     = submenu,
            }
        end

        -- Builds a group of slots (flat list, no separator)
        local function section(slots, isAxis)
            local items = {}
            for _, slot in ipairs(slots) do
                table.insert(items, slotItem(slot, isAxis))
            end
            return items
        end

        local menu = {}
        -- 2 fingers
        table.insert(menu, slotItem("swipe_2_diag", true))
        table.insert(menu, {title="-"})
        -- 3 fingers: tap first, then swipes
        table.insert(menu, slotItem("tap_3", false))
        for _, it in ipairs(section({"swipe_3_horiz","swipe_3_diag"}, true)) do
            table.insert(menu, it)
        end
        for _, it in ipairs(section({"swipe_3_up","swipe_3_down"}, false)) do
            table.insert(menu, it)
        end
        table.insert(menu, {title="-"})
        -- 4 fingers: tap first, then swipes
        table.insert(menu, slotItem("tap_4", false))
        for _, it in ipairs(section({"swipe_4_horiz","swipe_4_diag"}, true)) do
            table.insert(menu, it)
        end
        for _, it in ipairs(section({"swipe_4_up","swipe_4_down"}, false)) do
            table.insert(menu, it)
        end
        table.insert(menu, {title="-"})
        -- 5 fingers: tap first, then swipes
        table.insert(menu, slotItem("tap_5", false))
        for _, it in ipairs(section({"swipe_5_horiz","swipe_5_diag"}, true)) do
            table.insert(menu, it)
        end
        for _, it in ipairs(section({"swipe_5_up","swipe_5_down"}, false)) do
            table.insert(menu, it)
        end

        item.menu = menu
        return item
    end

    buildPersonalInfoItem = function(description)
        if not personal_info then return nil end
        return {
            title   = description,
            checked = state.personal_info or nil,
            fn = function()
                state.personal_info = not state.personal_info
                if state.personal_info then
                    personal_info.enable()
                else
                    personal_info.disable()
                end
                save_prefs(); updateMenu()
            end
        }
    end

    local function buildExpandersItem()
        local paused = script_control and script_control.is_paused() or false
        local defs = keymap and keymap.get_terminator_defs and keymap.get_terminator_defs() or {}
        local sub = {}
        for _, def in ipairs(defs) do
            local enabled = keymap.is_terminator_enabled(def.key)
            sub[#sub + 1] = {
                title    = def.label,
                checked  = (enabled and not paused) or nil,
                disabled = paused or nil,
                fn = not paused and (function(k) return function()
                    local new_val = not keymap.is_terminator_enabled(k)
                    keymap.set_terminator_enabled(k, new_val)
                    state.terminator_states[k] = new_val
                    save_prefs(); updateMenu()
                end end)(def.key) or nil,
            }
        end
        return { title = "Expanseurs", menu = sub }
    end

    local function buildDelayItem()
        local current = keymap and keymap.get_base_delay and keymap.get_base_delay() or state.expansion_delay
        -- Display value in ms, rounded to avoid floating-point noise.
        local current_ms = math.floor(current * 1000 + 0.5)
        return {
            title = string.format("Délai maximal d'expansion : %d ms…", current_ms),
            fn = function()
                local btn, raw = hs.dialog.textPrompt(
                    "Délai maximal d'expansion",
                    "Entrez le délai en millisecondes\n (nombre entier ≥ 0) :",
                    tostring(current_ms),
                    "OK", "Annuler"
                )
                if btn ~= "OK" then return end
                local val = tonumber(raw)
                if not val or val < 0 or val ~= math.floor(val) then
                    hs.notify.new({ title = "Délai invalide",
                        informativeText = "Veuillez saisir un entier ≥ 0." }):send()
                    return
                end
                local secs = val / 1000
                keymap.set_base_delay(secs)
                state.expansion_delay = secs
                save_prefs(); updateMenu()
            end,
        }
    end

    local function buildRaccourcisItem()
        local paused = script_control and script_control.is_paused() or false
        local item = {
            title   = "Raccourcis",
            checked = (state.shortcuts and not paused) or nil,
            fn = function()
                state.shortcuts = not state.shortcuts
                if state.shortcuts then shortcuts.start() else shortcuts.stop() end
                save_prefs(); updateMenu()
            end
        }
        -- Always build the sub-menu so the user can see items even when
        -- shortcuts are disabled.  Items without fn are greyed out by macOS.
        local s_menu = {}
        -- Option+Scroll to change volume: grouped here since it is a
        -- system-wide shortcut managed alongside the other shortcuts.
        table.insert(s_menu, {
            title    = "Option + Scroll : Volume",
            checked  = (state.scroll and not paused) or nil,
            disabled = not state.shortcuts or paused or nil,
            fn = (state.shortcuts and not paused) and function()
                state.scroll = not state.scroll
                if state.scroll then scroll.start() else scroll.stop() end
                save_prefs(); updateMenu()
            end or nil,
        })
        table.insert(s_menu, {title = "-"})
        local function pretty_key(id)
            -- Special cases to avoid ugly tokenised display
            if id == "at_hash" then return "Touche @/#" end
            local parts = {}
            for p in id:gmatch("[^_]+") do table.insert(parts, p) end
            if #parts == 0 then return id end
            local key  = parts[#parts]
            local mods = {}
            for i = 1, #parts-1 do
                local p = parts[i]
                if     p=="ctrl"  then table.insert(mods,"Ctrl")
                elseif p=="cmd"   then table.insert(mods,"Cmd")
                elseif p=="alt" or p=="option" then table.insert(mods,"Alt")
                elseif p=="shift" then table.insert(mods,"Shift")
                else table.insert(mods, p:sub(1,1):upper()..p:sub(2)) end
            end
            return (#mods>0 and table.concat(mods," + ").." + " or "")..key:upper()
        end
        local function trim(s) return (s:gsub("^%s*(.-)%s*$","%1")) end
        local last_was_non_ctrl = false
        local separator_inserted = false
        for _, s in ipairs(shortcuts.list_shortcuts()) do
            -- Insert a separator between non-Ctrl shortcuts (e.g. @/#, Cmd+…)
            -- and the Ctrl shortcuts.
            local is_ctrl = s.id:sub(1, 5) == "ctrl_"
            if not separator_inserted and last_was_non_ctrl and is_ctrl then
                table.insert(s_menu, {title = "-"})
                separator_inserted = true
            end
            if not is_ctrl then last_was_non_ctrl = true end
            local key   = pretty_key(s.id)
            local desc  = trim((s.label or ""):gsub("%s*%b()",""))
            local title = key.." : "..(desc~="" and desc or s.id)
            local is_on = shortcuts.is_enabled and shortcuts.is_enabled(s.id) or s.enabled
            table.insert(s_menu, {
                title    = title,
                checked  = (is_on and not paused) or nil,
                disabled = not state.shortcuts or paused or nil,
                fn = (state.shortcuts and not paused) and (function(id) return function()
                    if shortcuts.is_enabled(id) then shortcuts.disable(id)
                    else shortcuts.enable(id) end
                    save_prefs(); updateMenu()
                end end)(s.id) or nil,
            })
        end
        item.menu = s_menu
        return item
    end

    -- Enable or disable every feature at once, including sub-items
    -- (sections within TOML groups and individual shortcuts).
    -- State is written directly (config.json + hs.settings) then the script
    -- is reloaded for a clean single-pass restart — no per-item module calls.
    local function set_all_enabled(enabled)
        -- Update top-level state flags.
        state.keymap    = enabled
        state.gestures  = enabled
        state.scroll    = enabled
        state.shortcuts = enabled
        if personal_info then state.personal_info = enabled end

        for name in pairs(state.hotstrings) do
            state.hotstrings[name] = enabled
        end

        -- Write section states into hs.settings so the keymap module picks
        -- them up correctly on reload.  No live per-section calls here: since
        -- do_reload() triggers hs.reload() we let the fresh session apply
        -- everything in one clean pass, which is both faster and correct.
        for name in pairs(state.hotstrings) do
            local sections = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            if sections then
                for _, sec in ipairs(sections) do
                    if sec.name ~= '-' and not sec.is_module_placeholder then
                        local key = "hotstrings_section_" .. name .. "_" .. sec.name
                        -- nil = enabled (default), false = disabled.
                        -- Explicit if/else avoids the Lua nil-ternary anti-pattern
                        -- where `true and nil or false` always evaluates to false.
                        if enabled then
                            hs.settings.set(key, nil)
                        else
                            hs.settings.set(key, false)
                        end
                    end
                end
            end
        end

        -- Write config.json with all shortcut_keys and section_states forced.
        local section_states = {}
        for name in pairs(state.hotstrings) do
            local secs = keymap and keymap.get_sections and keymap.get_sections(name) or nil
            if secs then
                section_states[name] = {}
                for _, sec in ipairs(secs) do
                    if sec.name ~= '-' and not sec.is_module_placeholder then
                        section_states[name][sec.name] = enabled
                    end
                end
            end
        end
        local prefs = {
            keymap                   = state.keymap,
            gestures                 = state.gestures,
            scroll                   = state.scroll,
            shortcuts                = state.shortcuts,
            personal_info            = state.personal_info,
            hotstrings               = state.hotstrings,
            chatgpt_url              = state.chatgpt_url,
            sections_order_overrides = state.sections_order_overrides,
            section_states           = section_states,
            terminator_states        = state.terminator_states,
            expansion_delay          = state.expansion_delay,
            shortcut_keys            = {},
            gesture_actions          = gestures.get_all_actions(),
            script_control_shortcuts = state.script_control_shortcuts,
            script_control_enabled   = state.script_control_enabled,
            ahk_source_path          = state.ahk_source_path,
        }
        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            for _, s in ipairs(shortcuts.list_shortcuts()) do
                prefs.shortcut_keys[s.id] = enabled
            end
        end
        -- Merge into existing config.json to preserve third-party keys.
        local existing2 = load_prefs()
        for k, v in pairs(prefs) do existing2[k] = v end
        local ok2, encoded = pcall(function() return hs.json.encode(existing2) end)
        if ok2 and encoded then
            local fh = io.open(prefs_file, "w")
            if fh then fh:write(encoded); fh:close() end
        end

        -- Reload the whole script so everything is applied in one clean pass.
        do_reload()
    end

    local function buildScriptControlItem()
        if not script_control then return nil end
        local paused  = script_control.is_paused()
        local actions    = script_control.ACTIONS
        local act_labels = script_control.ACTION_LABELS
        local enabled    = state.script_control_enabled

        -- Build a radio sub-menu for one key slot.
        -- Items are greyed out (no fn) when the module is disabled.
        local function key_submenu(keyname)
            local current = state.script_control_shortcuts[keyname] or "none"
            local sub = {}
            for _, act in ipairs(actions) do
                table.insert(sub, {
                    title    = act_labels[act],
                    checked  = ((current == act) and not paused) or nil,
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
        local sub = {}
        table.insert(sub, {
            title    = "AltGr + Entrée : " .. (act_labels[cur_return] or cur_return),
            disabled = not enabled or paused or nil,
            menu     = key_submenu("return_key"),
        })
        table.insert(sub, {
            title    = "AltGr + ⌫ : " .. (act_labels[cur_back] or cur_back),
            disabled = not enabled or paused or nil,
            menu     = key_submenu("backspace"),
        })
        table.insert(sub, {title = "-"})
        table.insert(sub, {
            title    = "Chemin du script AHK...",
            disabled = paused or nil,
            fn = not paused and function()
                local btn, path = hs.dialog.textPrompt(
                    "Script AHK",
                    "Chemin du fichier AHK source :",
                    state.ahk_source_path or "", "OK", "Annuler")
                if btn == "OK" and path ~= nil then
                    state.ahk_source_path = path
                    save_prefs(); updateMenu()
                end
            end or nil,
        })
        return {
            title   = "Contrôle du script",
            checked = (enabled and not paused) or nil,
            fn = function()
                state.script_control_enabled = not state.script_control_enabled
                if state.script_control_enabled then
                    -- Restore the configured actions.
                    script_control.set_shortcut_action("return_key", state.script_control_shortcuts.return_key)
                    script_control.set_shortcut_action("backspace",  state.script_control_shortcuts.backspace)
                else
                    -- Disable all slots without erasing the user config.
                    script_control.set_shortcut_action("return_key", "none")
                    script_control.set_shortcut_action("backspace",  "none")
                end
                save_prefs(); updateMenu()
            end,
            menu = sub,
        }
    end

    updateMenu = function()
        local items = {}
        for _, it in ipairs(buildHotstringsItems()) do table.insert(items, it) end
        table.insert(items, {title="-"})
        table.insert(items, buildGestesItem())
        table.insert(items, buildRaccourcisItem())
        local sc_item = buildScriptControlItem()
        if sc_item then table.insert(items, sc_item) end
        table.insert(items, {title="-"})
        table.insert(items, {title="Tout activer",    fn=function() set_all_enabled(true)  end})
        table.insert(items, {title="Tout désactiver", fn=function() set_all_enabled(false) end})
        table.insert(items, {title="-"})
        table.insert(items, buildExpandersItem())
        table.insert(items, buildDelayItem())
        if personal_info and type(personal_info.open_editor) == "function" then
            table.insert(items, {
                title = "Modifier les informations personnelles...",
                fn = function()
                    hs.timer.doAfter(0.1, function()
                        personal_info.open_editor()
                    end)
                end,
            })
        end
        table.insert(items, {title="URL ChatGPT...", fn=function()
            local clicked, url = hs.dialog.textPrompt(
                "URL ChatGPT",
                "URL ouverte par Ctrl+G :",
                state.chatgpt_url or "", "OK", "Annuler")
            if clicked == "OK" and url ~= nil and url ~= "" then
                state.chatgpt_url = url
                save_prefs()
                updateMenu()
            end
        end})
        table.insert(items, {title="-"})
        table.insert(items, {title="Ouvrir init.lua",           fn=function() hs.execute('open "'..base_dir..'init.lua"') end})
        table.insert(items, {title="Console Hammerspoon",       fn=function() hs.openConsole() end})
        table.insert(items, {title="Préférences Hammerspoon",   fn=function() hs.openPreferences() end})
        table.insert(items, {title="-"})
        table.insert(items, {title="Recharger la configuration",fn=function() do_reload() end})
        table.insert(items, {title="Quitter Hammerspoon",       fn=function() hs.timer.doAfter(0.1, function() os.exit(0) end) end})
        myMenu:setMenu({})
        hs.timer.doAfter(0.02, function() update_icon(); myMenu:setMenu(items) end)
    end

    updateMenu()

    local function reloadConfig(files)
        -- Ignore events fired shortly after open_init ran: the editor may
        -- write swap/metadata files that look like .lua modifications.
        if hs.timer.secondsSinceEpoch() < _suppress_watcher_until then return end
        for _, file in pairs(files) do
            if file:sub(-4) == ".lua" then do_reload("watcher"); return end
        end
    end
    local configWatcher = pathwatcher.new(base_dir, reloadConfig):start()

    M._menu    = myMenu
    M._watcher = configWatcher
    M._icon    = icon

    utils.notify("Script prêt ! 🚀")
    return myMenu, configWatcher
end

return M
