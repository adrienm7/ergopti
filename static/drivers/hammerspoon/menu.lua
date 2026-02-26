local M = {}
local hs = hs
local image = hs.image
local menubar = hs.menubar
local pathwatcher = hs.pathwatcher

-- Labels des slots affichés dans le menu
local SLOT_LABELS = {
    tap_3         = "Tap 3 doigts",
    tap_4         = "Tap 4 doigts",
    tap_5         = "Tap 5 doigts",
    swipe_2_diag  = "Swipe 2 ↗/↙",
    swipe_3_horiz = "Swipe 3 ←/→",
    swipe_3_diag  = "Swipe 3 ↗/↙",
    swipe_3_up    = "Swipe 3 ↑",
    swipe_3_down  = "Swipe 3 ↓",
    swipe_4_horiz = "Swipe 4 ←/→",
    swipe_4_diag  = "Swipe 4 ↗/↙",
    swipe_4_up    = "Swipe 4 ↑",
    swipe_4_down  = "Swipe 4 ↓",
    swipe_5_horiz = "Swipe 5 ←/→",
    swipe_5_diag  = "Swipe 5 ↗/↙",
    swipe_5_up    = "Swipe 5 ↑",
    swipe_5_down  = "Swipe 5 ↓",
}

function M.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts)
    base_dir = base_dir or (hs.configdir .. "/")
    local gen_dir = base_dir .. "generated_hotstrings/"

    local descriptions = {}
    local ok, res = pcall(function() return dofile(gen_dir .. "_descriptions.lua") end)
    if ok and type(res) == "table" then descriptions = res end

    local myMenu = menubar.new()

    local function isDarkMode()
        local ok2, out = pcall(function()
            return hs.execute('defaults read -g AppleInterfaceStyle 2>/dev/null')
        end)
        return ok2 and out and out:match("Dark") ~= nil
    end

    local function make_icon()
        local logo_file = isDarkMode() and "logo_black.png" or "logo_white.png"
        local icon_path = base_dir .. "images/" .. logo_file
        local icon = image.imageFromPath(icon_path)
        if icon then pcall(function() if icon.setSize then icon:setSize({w=18,h=18}) end end) end
        return icon, icon_path
    end

    local icon, icon_path = make_icon()
    if icon then myMenu:setIcon(icon, false); print("menu icon loaded:", icon_path)
    else         myMenu:setTitle("🔨");         print("menu icon NOT loaded:", icon_path) end

    local function do_reload(source)
        if source == "watcher" then
            pcall(function()
                hs.notify.new({title="Hammerspoon",
                    informativeText="Fichiers modifiés — rechargement"}):send()
            end)
        else
            pcall(function() hs.alert.show("Rechargement Hammerspoon…", 1.0) end)
        end
        hs.timer.doAfter(0.25, function() hs.reload() end)
    end

    local state = {keymap=true, gestures=true, scroll=true, shortcuts=true, hotstrings={}}
    for _, f in ipairs(hotfiles or {}) do
        local name = f:match("^(.*)%.lua$") or f
        state.hotstrings[name] = true
    end

    local prefs_file = base_dir .. "ergopti_prefs.json"

    local function load_prefs()
        local fh = io.open(prefs_file, "r")
        if not fh then return {} end
        local content = fh:read("*a"); fh:close()
        local ok2, tbl = pcall(function() return hs.json.decode(content) end)
        return (ok2 and type(tbl) == "table") and tbl or {}
    end

    local function save_prefs()
        local prefs = {
            keymap    = state.keymap,
            gestures  = state.gestures,
            scroll    = state.scroll,
            shortcuts = state.shortcuts,
            hotstrings     = state.hotstrings,
            shortcut_keys  = {},
            gesture_actions = gestures.get_all_actions(),  -- nouveau format
        }
        if shortcuts and type(shortcuts.list_shortcuts) == "function" then
            for _, s in ipairs(shortcuts.list_shortcuts()) do
                prefs.shortcut_keys[s.id] = s.enabled
            end
        end
        local ok2, encoded = pcall(function() return hs.json.encode(prefs) end)
        if not ok2 or not encoded then return end
        local fh = io.open(prefs_file, "w")
        if not fh then return end
        fh:write(encoded); fh:close()
    end

    -- Appliquer les préférences sauvegardées
    do
        local saved = load_prefs()
        if type(saved) == "table" then
            if saved.keymap    ~= nil then state.keymap    = saved.keymap    end
            if saved.gestures  ~= nil then state.gestures  = saved.gestures  end
            if saved.scroll    ~= nil then state.scroll    = saved.scroll    end
            if saved.shortcuts ~= nil then state.shortcuts = saved.shortcuts end
            if type(saved.hotstrings) == "table" then
                for name in pairs(state.hotstrings) do
                    if saved.hotstrings[name] ~= nil then
                        state.hotstrings[name] = saved.hotstrings[name]
                    end
                end
            end
            -- Restaurer les actions de geste (nouveau format)
            if type(saved.gesture_actions) == "table" then
                for slot, action in pairs(saved.gesture_actions) do
                    gestures.set_action(slot, action)
                end
            end
        end

        if state.keymap    then keymap.start()    else keymap.stop()    end
        if state.gestures  then gestures.enable_all()  else gestures.disable_all() end
        if state.scroll    then scroll.start()    else scroll.stop()    end
        if state.shortcuts then shortcuts.start() else shortcuts.stop() end

        for name, enabled in pairs(state.hotstrings) do
            if enabled then keymap.enable_group(name) else keymap.disable_group(name) end
        end
        if type(saved) == "table" and type(saved.shortcut_keys) == "table" then
            for id, enabled in pairs(saved.shortcut_keys) do
                if enabled then shortcuts.enable(id) else shortcuts.disable(id) end
            end
        end
        save_prefs()
    end

    -- ── Constructeurs d'items ─────────────────────────────────────────────────

    local function buildHotstringsItem()
        local item = {
            title   = "Expansion de texte",
            checked = state.keymap or nil,
            fn = function()
                state.keymap = not state.keymap
                if state.keymap then keymap.start() else keymap.stop() end
                save_prefs(); do_reload()
            end
        }
        if state.keymap then
            local normal_menu, plus_menu = {}, {}
            for _, f in ipairs(hotfiles or {}) do
                local name = f:match("^(.*)%.lua$") or f
                local pretty = name:gsub("_"," ")
                if descriptions[name] and descriptions[name] ~= "" then pretty = descriptions[name] end
                local entry = {
                    title   = pretty,
                    checked = (keymap and type(keymap.is_group_enabled)=="function"
                               and keymap.is_group_enabled(name))
                              or state.hotstrings[name] or nil,
                    fn = function()
                        state.hotstrings[name] = not state.hotstrings[name]
                        if state.hotstrings[name] then keymap.enable_group(name)
                        else keymap.disable_group(name) end
                        save_prefs(); do_reload()
                    end
                }
                if name:match("^plus") then table.insert(plus_menu, entry)
                else                        table.insert(normal_menu, entry) end
            end
            local out = {}
            for _, it in ipairs(normal_menu) do table.insert(out, it) end
            if #plus_menu > 0 then
                table.insert(out, {title="-"})
                for _, it in ipairs(plus_menu) do table.insert(out, it) end
            end
            item.menu = out
        end
        return item
    end

    local function buildGestesItem()
        local item = {
            title   = "Gestes",
            checked = state.gestures or nil,
            fn = function()
                state.gestures = not state.gestures
                if state.gestures then gestures.enable_all() else gestures.disable_all() end
                save_prefs(); do_reload()
            end
        }

        if not state.gestures then return item end

        -- Construit un item avec sous-menu radio pour un slot donné.
        -- isAxis=true → liste AX_NAMES, false → liste SG_NAMES
        local function slotItem(slot, isAxis)
            local current  = gestures.get_action(slot)
            local slotLbl  = SLOT_LABELS[slot] or slot
            local actionLbl = gestures.get_action_label(current)
            local names    = isAxis and gestures.AX_NAMES or gestures.SG_NAMES
            local submenu  = {}
            for _, aname in ipairs(names) do
                table.insert(submenu, {
                    title   = gestures.get_action_label(aname),
                    checked = (current == aname) or nil,
                    fn = (function(a) return function()
                        gestures.set_action(slot, a)
                        save_prefs(); do_reload()
                    end end)(aname)
                })
            end
            return {title = slotLbl .. " : " .. actionLbl, menu = submenu}
        end

        -- Construit un groupe de slots avec séparateur
        local function section(slots, isAxis)
            local items = {}
            for _, slot in ipairs(slots) do
                table.insert(items, slotItem(slot, isAxis))
            end
            return items
        end

        local menu = {}
        -- Taps
        for _, it in ipairs(section({"tap_3","tap_4","tap_5"}, false)) do
            table.insert(menu, it)
        end
        table.insert(menu, {title="-"})
        -- 2 doigts
        table.insert(menu, slotItem("swipe_2_diag", true))
        table.insert(menu, {title="-"})
        -- 3 doigts
        for _, it in ipairs(section({"swipe_3_horiz","swipe_3_diag"}, true)) do
            table.insert(menu, it)
        end
        for _, it in ipairs(section({"swipe_3_up","swipe_3_down"}, false)) do
            table.insert(menu, it)
        end
        table.insert(menu, {title="-"})
        -- 4 doigts
        for _, it in ipairs(section({"swipe_4_horiz","swipe_4_diag"}, true)) do
            table.insert(menu, it)
        end
        for _, it in ipairs(section({"swipe_4_up","swipe_4_down"}, false)) do
            table.insert(menu, it)
        end
        table.insert(menu, {title="-"})
        -- 5 doigts
        for _, it in ipairs(section({"swipe_5_horiz","swipe_5_diag"}, true)) do
            table.insert(menu, it)
        end
        for _, it in ipairs(section({"swipe_5_up","swipe_5_down"}, false)) do
            table.insert(menu, it)
        end

        item.menu = menu
        return item
    end

    local function buildRaccourcisItem()
        local item = {
            title   = "Raccourcis",
            checked = state.shortcuts or nil,
            fn = function()
                state.shortcuts = not state.shortcuts
                if state.shortcuts then shortcuts.start() else shortcuts.stop() end
                save_prefs(); do_reload()
            end
        }
        if state.shortcuts then
            local s_menu = {}
            local function pretty_key(id)
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
            for _, s in ipairs(shortcuts.list_shortcuts()) do
                local key   = pretty_key(s.id)
                local desc  = trim((s.label or ""):gsub("%s*%b()",""))
                local title = key.." : "..(desc~="" and desc or s.id)
                local is_on = shortcuts.is_enabled and shortcuts.is_enabled(s.id) or s.enabled
                table.insert(s_menu, {
                    title   = title,
                    checked = is_on or nil,
                    fn = (function(id) return function()
                        if shortcuts.is_enabled(id) then shortcuts.disable(id)
                        else shortcuts.enable(id) end
                        save_prefs(); do_reload()
                    end end)(s.id)
                })
            end
            item.menu = s_menu
        end
        return item
    end

    local function buildUtilityItems()
        return {
            {title="Option + Scroll : Volume", checked=state.scroll or nil, fn=function()
                state.scroll = not state.scroll
                if state.scroll then scroll.start() else scroll.stop() end
                save_prefs(); do_reload()
            end},
            {title="-"},
            {title="Ouvrir init.lua",           fn=function() hs.execute('open "'..base_dir..'init.lua"') end},
            {title="Console Hammerspoon",       fn=function() hs.openConsole() end},
            {title="Préférences Hammerspoon",   fn=function() hs.openPreferences() end},
            {title="Recharger la configuration",fn=function() do_reload() end},
            {title="Quitter Hammerspoon",        fn=function() hs.quit() end},
        }
    end

    local function updateMenu()
        local items = {}
        table.insert(items, buildHotstringsItem())
        table.insert(items, buildGestesItem())
        table.insert(items, buildRaccourcisItem())
        for _, it in ipairs(buildUtilityItems()) do table.insert(items, it) end
        myMenu:setMenu({})
        hs.timer.doAfter(0.02, function() myMenu:setMenu(items) end)
    end

    updateMenu()

    local function reloadConfig(files)
        for _, file in pairs(files) do
            if file:sub(-4) == ".lua" then do_reload("watcher"); return end
        end
    end
    local configWatcher = pathwatcher.new(base_dir, reloadConfig):start()

    M._menu    = myMenu
    M._watcher = configWatcher
    M._icon    = icon

    hs.alert.show("Hammerspoon prêt ! 🚀")
    return myMenu, configWatcher
end

return M
