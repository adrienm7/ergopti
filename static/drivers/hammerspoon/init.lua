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
-- External menu module
local menu = require("menu")
menu.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts)
