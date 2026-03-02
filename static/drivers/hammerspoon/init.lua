-- What this script does:
-- 1) Three-finger tap to toggle selection mode (click-and-drag)
-- 2) Three-finger gestures for tab navigation
-- 3) Change volume with left Option + scroll

local gestures = require("gestures")
local scroll = require("scroll")
local keymap = require("keymap")
local shortcuts = require("shortcuts")
local repeat_keys = require("repeat_keys")
local script_control = require("script_control")

-- Initial startup of modules
gestures.start()
scroll.start()
-- Also start the shortcuts module (`shortcuts`)
shortcuts.start()
-- (keymap already starts itself via your `keymap.lua`)
-- repeat_keys is registered after TOML hotstrings to ensure lowest priority
-- (it acts as a fallback when no other hotstring matches)




---------------------------------------------------------------------------
-- TOML hotstrings (loaded directly from ../hotstrings/*.toml)
---------------------------------------------------------------------------
-- Absolute path to this Hammerspoon config directory
-- Derive absolute path to this Hammerspoon config directory from this file's
-- location so the config remains portable across machines.
local script_path = debug.getinfo(1, "S").source
if script_path:sub(1, 1) == "@" then
    script_path = script_path:sub(2)
end
local base_dir = script_path:match("^(.*[/\\])") or "./"
if not base_dir:match("[/\\]$") then
    base_dir = base_dir .. "/"
end
local hotstrings_dir = base_dir .. "../hotstrings/"

-- Collect and sort all .toml filenames for a deterministic load order.
local toml_fnames = {}
for fname in hs.fs.dir(hotstrings_dir) do
    if fname:match("%.toml$") then
        toml_fnames[#toml_fnames + 1] = fname
    end
end
table.sort(toml_fnames)

-- Load each TOML file as an independent keymap group (group name = stem).
local hotfiles = {}  -- group names passed to the menu
for _, fname in ipairs(toml_fnames) do
    local name = fname:match("^(.-)%.toml$")
    keymap.load_toml(name, hotstrings_dir .. fname)
    hotfiles[#hotfiles + 1] = name
end


---------------------------------------------------------------------------
-- Repeat keys (registered last = lowest priority, fallback if nothing else matches)
---------------------------------------------------------------------------
repeat_keys.start(keymap)

---------------------------------------------------------------------------
-- Menubar menu (Hammerspoon Menubar)
---------------------------------------------------------------------------
-- External menu module
local menu = require("menu")
menu.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts)

---------------------------------------------------------------------------
-- Script control shortcuts (AltGr+Return = pause/resume, AltGr+Backspace = reload)
---------------------------------------------------------------------------
script_control.start(keymap, shortcuts, gestures, scroll)
