-- What this script does:
-- 1) Three-finger tap to toggle selection mode (click-and-drag)
-- 2) Three-finger gestures for tab navigation
-- 3) Change volume with left Option + scroll

local gestures = require("gestures")
local scroll = require("scroll")
local keymap = require("keymap")
local shortcuts = require("shortcuts")

-- Démarrage initial des modules
gestures.start()
scroll.start()
-- Démarrer aussi les raccourcis (module `shortcuts`)
shortcuts.start()
-- (keymap démarre déjà tout seul grâce à ton keymap.lua)


-- Repeat key
keymap.add("a★", "aa", true)
keymap.add("b★", "bb", true)
keymap.add("c★", "cc", true)
keymap.add("d★", "dd", true)
keymap.add("e★", "ee", true)
keymap.add("f★", "ff", true)
keymap.add("g★", "gg", true)
keymap.add("h★", "hh", true)
keymap.add("i★", "ii", true)
keymap.add("j★", "jj", true)
keymap.add("k★", "kk", true)
keymap.add("l★", "ll", true)
keymap.add("m★", "mm", true)
keymap.add("n★", "nn", true)
keymap.add("o★", "oo", true)
keymap.add("p★", "pp", true)
keymap.add("q★", "qq", true)
keymap.add("r★", "rr", true)
keymap.add("s★", "ss", true)
keymap.add("t★", "tt", true)
keymap.add("u★", "uu", true)
keymap.add("v★", "vv", true)
keymap.add("w★", "ww", true)
keymap.add("x★", "xx", true)
keymap.add("y★", "yy", true)
keymap.add("z★", "zz", true)

---------------------------------------------------------------------------
-- Hotstrings dynamiques
---------------------------------------------------------------------------
-- Le chemin absolu vers ton vrai dossier source
local base_dir = "/Users/b519hs/Documents/perso/ergopti/static/drivers/hammerspoon/"
local gen_dir = base_dir .. "generated_hotstrings/"

-- Liste des fichiers hotstrings générés
local hotfiles = {
    "accents.lua",
    "brands.lua",
    "emojis.lua",
    "errors.lua",
    "magic.lua",
    "minus.lua",
    "names.lua",
    "plus_apostrophe.lua",
    "plus_comma.lua",
    "plus_e_deadkey.lua",
    "plus_qu.lua",
    "plus_rolls.lua",
    "plus_sfb_reduction.lua",
    "plus_suffixes.lua",
    "punctuation.lua",
    "symbols.lua",
    "symbols_typst.lua",
}

-- Charger chaque fichier via keymap.load_file (permet toggle par groupe)
for _, f in ipairs(hotfiles) do
    local name = f:match("^(.*)%.lua$") or f
    keymap.load_file(name, gen_dir .. f)
end


---------------------------------------------------------------------------
-- Menu Barre des tâches (Hammerspoon Menubar)
---------------------------------------------------------------------------
-- Création de l'icône dans la barre des menus
local myMenu = hs.menubar.new()
-- Charger une icône PNG adaptée au thème (noir pour thème sombre, blanc sinon)
local function isDarkMode()
    local ok, out = pcall(function()
        return hs.execute('defaults read -g AppleInterfaceStyle 2>/dev/null')
    end)
    if not ok or not out then return false end
    return out:match("Dark") ~= nil
end

local logo_file = isDarkMode() and "logo_black.png" or "logo_white.png"
local icon_path = base_dir .. logo_file
local icon = hs.image.imageFromPath(icon_path)
if icon then
    -- Try to force the icon to a small size suitable for macOS menubar
    local ok, err = pcall(function()
        if icon.setSize then
            icon:setSize({w=18, h=18})
        elseif icon.setSize then
            icon:setSize({w=18, h=18})
        end
    end)
    if not ok then
        print("warning: failed to call setSize on icon:", err)
    end
    myMenu:setIcon(icon, false)
    print("menu icon loaded:", icon_path)
else
    myMenu:setTitle("🔨") -- fallback emoji
    print("menu icon NOT loaded, tried:", icon_path)
end

-- État actuel de tes modules
local state = {
    keymap = true,
    gestures = true,
    scroll = true
    ,
    shortcuts = true
}

-- État des hotstrings (par fichier)
state.hotstrings = {}
for _, f in ipairs(hotfiles) do
    local name = f:match("^(.*)%.lua$") or f
    state.hotstrings[name] = true
end

-- Fonction pour rafraîchir le menu et ses coches
local function updateMenu()
    myMenu:setMenu({
        {
            title = "Hotstrings (Keymap)",
            checked = state.keymap,
            fn = function()
                state.keymap = not state.keymap
                if state.keymap then keymap.start() else keymap.stop() end
                updateMenu() -- Rafraîchit la coche
            end
        },
        -- Sous-menu pour activer/désactiver chaque fichier de hotstrings
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
            title = "Option + Scroll (Volume)",
            checked = state.scroll,
            fn = function()
                state.scroll = not state.scroll
                if state.scroll then scroll.start() else scroll.stop() end
                updateMenu()
            end
        },
        { title = "Ouvrir la configuration" , fn = function()
            -- Ouvre le fichier `init.lua` avec l'application par défaut
            hs.execute('open "' .. base_dir .. 'init.lua"')
        end },
        { title = "Afficher la console", fn = function() hs.openConsole() end },
        { title = "Préférences Hammerspoon", fn = function() hs.openPreferences() end },
        { title = "-" }, -- Ligne de séparation
        { 
            title = "Recharger la configuration", 
            fn = function() hs.reload() end 
        },
        { title = "Quitter Hammerspoon", fn = function() hs.quit() end }
    })
end

-- On génère le menu une première fois
updateMenu()

---------------------------------------------------------------------------
-- Rechargement automatique de la configuration (Correction Symlink)
---------------------------------------------------------------------------
local function reloadConfig(files)
    local doReload = false
    for _, file in pairs(files) do
        if file:sub(-4) == ".lua" then
            doReload = true
            break
        end
    end
    if doReload then
        hs.reload()
    end
end

-- Au lieu de surveiller le symlink, on surveille LE VRAI DOSSIER source :
local configWatcher = hs.pathwatcher.new(base_dir, reloadConfig):start()

hs.alert.show("Hammerspoon prêt ! 🚀")
