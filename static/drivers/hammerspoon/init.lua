-- What this script does:
-- 1) Three-finger tap to toggle selection mode (click-and-drag)
-- 2) Three-finger gestures for tab navigation
-- 3) Change volume with left Option + scroll

local gestures = require("gestures")
local scroll = require("scroll")
local keymap = require("keymap")
local shortcuts = require("shortcuts")
local repeat_keys = require("repeat_keys")

-- Initial startup of modules
gestures.start()
scroll.start()
-- Also start the shortcuts module (`shortcuts`)
shortcuts.start()
-- Register repeat keys
repeat_keys.start(keymap)
-- (keymap already starts itself via your `keymap.lua`)




---------------------------------------------------------------------------
-- Dynamic hotstrings
---------------------------------------------------------------------------
-- Absolute path to your real source directory
local base_dir = "/Users/b519hs/Documents/perso/ergopti/static/drivers/hammerspoon/"
local gen_dir = base_dir .. "generated_hotstrings/"

-- List of generated hotstrings files
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
    "sfb_reduction.lua",
    "plus_suffixes.lua",
    "punctuation.lua",
    "symbols.lua",
    "symbols_typst.lua",
}

-- Load each file via keymap.load_file (allows toggling per group)
for _, f in ipairs(hotfiles) do
    local name = f:match("^(.*)%.lua$") or f
    keymap.load_file(name, gen_dir .. f)
end


---------------------------------------------------------------------------
-- Menubar menu (Hammerspoon Menubar)
---------------------------------------------------------------------------
-- External menu module
local menu = require("menu")
menu.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts)
