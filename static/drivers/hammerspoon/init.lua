
-- What this script does:
-- 1) Three-finger tap to toggle selection mode (click-and-drag)
-- 2) Three-finger gestures for tab navigation
-- 3) Change volume with left Option + scroll

local gestures = require("gestures")
local scroll = require("scroll")
local keymap = require("keymap")

gestures.start()
scroll.start()

keymap.add("ae★", "æ", true)
keymap.add("oe★", "œ", true)
keymap.add("1er★", "premier", false)
keymap.add("1ere★", "première", false)
keymap.add("2e★", "deuxième", false)

-- generated keymaps: dynamically load generated Lua modules
-- To (re)generate the Lua modules from TOML hotstrings run:
-- python3 static/drivers/hammerspoon/generate_hotstrings_lua.py

-- local function script_dir()
-- 	local info = debug.getinfo(1, 'S')
-- 	local src = info and info.source or ''
-- 	if src:sub(1,1) == '@' then
-- 		return src:match('(.*/)' ) or './'
-- 	end
-- 	return './'
-- end

-- local dir = script_dir()
-- local gen_dir = dir .. 'generated_hotstrings/'

-- local ok, p = pcall(io.popen, 'ls "' .. gen_dir .. '" 2>/dev/null')
-- if ok and p then
-- 	for file in p:lines() do
-- 		if file:match('%.lua$') then
-- 			local path = gen_dir .. file
-- 			dofile(path)
-- 		end
-- 	end
-- 	p:close()
-- end

local gen_dir = "/Users/b519hs/Documents/perso/ergopti/static/drivers/hammerspoon/generated_hotstrings/"

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
