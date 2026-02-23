local hs = hs

local M = {}

local function isDarkMode()
    local ok, out = pcall(function()
        return hs.execute('defaults read -g AppleInterfaceStyle 2>/dev/null')
    end)
    if not ok or not out then return false end
    return out:match("Dark") ~= nil
end

local function make_icon(base_dir)
    local logo_file = isDarkMode() and "logo_black.png" or "logo_white.png"
    local icon_path = base_dir .. logo_file
    local icon = hs.image.imageFromPath(icon_path)
    if icon then
        pcall(function()
            if icon.setSize then icon:setSize({w=18, h=18}) end
        end)
        return icon, icon_path
    end
    return nil, icon_path
end

function M.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts)
    local myMenu = hs.menubar.new()
    local icon, icon_path = make_icon(base_dir)
    if icon then
        myMenu:setIcon(icon, false)
        print("menu icon loaded:", icon_path)
    else
        myMenu:setTitle("🔨")
        print("menu icon NOT loaded, tried:", icon_path)
    end

    -- État actuel des modules
    local state = {
        keymap = true,
        gestures = true,
        scroll = true,
        shortcuts = true
    }

    state.hotstrings = {}
    for _, f in ipairs(hotfiles) do
        local name = f:match("^(.*)%.lua$") or f
        state.hotstrings[name] = true
    end

    local function updateMenu()
        myMenu:setMenu({
            {
                title = "Hotstrings (Keymap)",
                checked = state.keymap,
                fn = function()
                    state.keymap = not state.keymap
                    if state.keymap then keymap.start() else keymap.stop() end
                    updateMenu()
                end
            },
            {
                title = "Hotstrings",
                menu = (function()
                    local hot_menu = {}
                    for _, f in ipairs(hotfiles) do
                        local name = f:match("^(.*)%.lua$") or f
                        table.insert(hot_menu, {
                            title = name,
                            checked = state.hotstrings[name],
                            fn = function()
                                state.hotstrings[name] = not state.hotstrings[name]
                                if state.hotstrings[name] then
                                    keymap.enable_group(name)
                                else
                                    keymap.disable_group(name)
                                end
                                updateMenu()
                            end
                        })
                    end
                    return hot_menu
                end)()
            },
            {
                title = "Gestes à 3 doigts",
                checked = state.gestures,
                fn = function()
                    state.gestures = not state.gestures
                    if state.gestures then gestures.start() else gestures.stop() end
                    updateMenu()
                end
            },
            {
                title = "Raccourcis (Shortcuts)",
                checked = state.shortcuts,
                fn = function()
                    state.shortcuts = not state.shortcuts
                    if state.shortcuts then shortcuts.start() else shortcuts.stop() end
                    updateMenu()
                end
            },
            {
                title = "Shortcuts",
                menu = (function()
                    local s_menu = {}
                    local list = shortcuts.list_shortcuts()
                    for _, s in ipairs(list) do
                        table.insert(s_menu, {
                            title = s.label,
                            checked = s.enabled,
                            fn = (function(id)
                                return function()
                                    if shortcuts.is_enabled(id) then
                                        shortcuts.disable(id)
                                    else
                                        shortcuts.enable(id)
                                    end
                                    updateMenu()
                                end
                            end)(s.id)
                        })
                    end
                    return s_menu
                end)()
            },
            {
                title = "Option + Scroll (Volume)",
                checked = state.scroll,
                fn = function()
                    state.scroll = not state.scroll
                    if state.scroll then scroll.start() else scroll.stop() end
                    updateMenu()
                end
            },
            { title = "Ouvrir la configuration" , fn = function()
                hs.execute('open "' .. base_dir .. 'init.lua"')
            end },
            { title = "Afficher la console", fn = function() hs.openConsole() end },
            { title = "Préférences Hammerspoon", fn = function() hs.openPreferences() end },
            { title = "-" },
            { title = "Recharger la configuration", fn = function() hs.reload() end },
            { title = "Quitter Hammerspoon", fn = function() hs.quit() end }
        })
    end

    updateMenu()

    -- reloader (surveille le dossier source réel)
    local function reloadConfig(files)
        local doReload = false
        for _, file in pairs(files) do
            if file:sub(-4) == ".lua" then
                doReload = true
                break
            end
        end
        if doReload then hs.reload() end
    end
    local configWatcher = hs.pathwatcher.new(base_dir, reloadConfig):start()

    hs.alert.show("Hammerspoon prêt ! 🚀")

    return myMenu, configWatcher
end

return M
