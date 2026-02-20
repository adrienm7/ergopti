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
local base_dir = "~/Documents/perso/ergopti/static/drivers/hammerspoon/"
local gen_dir = base_dir .. "generated_hotstrings/"

dofile(gen_dir .. "accents.lua")
dofile(gen_dir .. "brands.lua")
dofile(gen_dir .. "emojis.lua")
dofile(gen_dir .. "errors.lua")
dofile(gen_dir .. "magic.lua")
dofile(gen_dir .. "minus.lua")
dofile(gen_dir .. "names.lua")
dofile(gen_dir .. "plus_apostrophe.lua")
dofile(gen_dir .. "plus_comma.lua")
dofile(gen_dir .. "plus_e_deadkey.lua")
dofile(gen_dir .. "plus_qu.lua")
dofile(gen_dir .. "plus_rolls.lua")
dofile(gen_dir .. "plus_sfb_reduction.lua")
dofile(gen_dir .. "plus_suffixes.lua")
dofile(gen_dir .. "punctuation.lua")
dofile(gen_dir .. "symbols.lua")
dofile(gen_dir .. "symbols_typst.lua")


---------------------------------------------------------------------------
-- Menu Barre des tâches (Hammerspoon Menubar)
---------------------------------------------------------------------------
-- Création de l'icône dans la barre des menus
local myMenu = hs.menubar.new()
myMenu:setTitle("🔨") -- Tu peux mettre l'émoji ou le texte de ton choix

-- État actuel de tes modules
local state = {
    keymap = true,
    gestures = true,
    scroll = true
}

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
            title = "Option + Scroll (Volume)",
            checked = state.scroll,
            fn = function()
                state.scroll = not state.scroll
                if state.scroll then scroll.start() else scroll.stop() end
                updateMenu()
            end
        },
        { title = "-" }, -- Ligne de séparation
        { 
            title = "Recharger la configuration", 
            fn = function() hs.reload() end 
        }
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
