-- What this script does:
-- 1) Three-finger tap to toggle selection mode (click-and-drag)
-- 2) Three-finger gestures for tab navigation
-- 3) Change volume with left Option + scroll

local gestures = require("gestures")
local scroll = require("scroll")
local keymap = require("keymap")
local shortcuts = require("shortcuts")
local repeat_keys = require("repeat_keys")

-- Démarrage initial des modules
gestures.start()
scroll.start()
-- Démarrer aussi les raccourcis (module `shortcuts`)
shortcuts.start()
-- Register repeat keys
repeat_keys.start(keymap)
-- (keymap démarre déjà tout seul grâce à ton keymap.lua)




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
-- External menu module
local menu = require("menu")
menu.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts)
