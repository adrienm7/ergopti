-- init.lua

local gestures = require("modules.gestures")
local scroll = require("modules.scroll")
local keymap = require("modules.keymap")
local shortcuts = require("modules.shortcuts")
local personal_info = require("modules.personal_info")
local dynamic_hotstrings = require("modules.dynamic_hotstrings")
local repeat_keys = require("modules.repeat_keys")
local script_control = require("modules.script_control")
local menu = require("modules.menu")

-- Initial startup of modules
gestures.start()
scroll.start()
shortcuts.start()
-- (keymap starts itself at the end of its file)

---------------------------------------------------------------------------
-- Path Resolution
---------------------------------------------------------------------------
local script_path = debug.getinfo(1, "S").source
if script_path:sub(1, 1) == "@" then
    script_path = script_path:sub(2)
end
local base_dir = script_path:match("^(.*[/\\])") or "./"
if not base_dir:match("[/\\]$") then base_dir = base_dir .. "/" end

local hotstrings_dir = base_dir .. "../hotstrings/"
local config_file    = base_dir .. "config.json"

---------------------------------------------------------------------------
-- Configuration Initialization
---------------------------------------------------------------------------
-- Prime hs.settings from config.json BEFORE loading any TOML
do
    local fh = io.open(config_file, "r")
    if fh then
        local raw = fh:read("*a"); fh:close()
        local ok, cfg = pcall(function() return hs.json.decode(raw) end)
        if ok and type(cfg) == "table" and type(cfg.section_states) == "table" then
            for grp, secs in pairs(cfg.section_states) do
                if type(secs) == "table" then
                    for sec_name, enabled in pairs(secs) do
                        local key = "hotstrings_section_" .. grp .. "_" .. sec_name
                        if enabled ~= false then
                            hs.settings.set(key, nil)
                        else
                            hs.settings.set(key, false)
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- TOML File Indexing & Ordering
---------------------------------------------------------------------------
local ordered_names   = nil
local module_sections = nil

do
    local idx_fh = io.open(hotstrings_dir .. "_index.json", "r")
    if idx_fh then
        local raw = idx_fh:read("*a"); idx_fh:close()
        local ok, data = pcall(function() return hs.json.decode(raw) end)
        if ok and data then
            if type(data.categories_order) == "table" then ordered_names = data.categories_order end
            if type(data.module_sections) == "table" then module_sections = data.module_sections end
        end
    end
end

local toml_set = {}
for fname in hs.fs.dir(hotstrings_dir) do
    if fname:match("%.toml$") then
        local name = fname:match("^(.-)%.toml$")
        toml_set[name] = fname
    end
end

local toml_fnames = {}

-- 1) Personal files first (highest priority)
local PRIVATE_STEMS = { personal = true }
local personal_fnames = {}
for stem, fname in pairs(toml_set) do
    if PRIVATE_STEMS[stem] then table.insert(personal_fnames, fname) end
end
table.sort(personal_fnames)
for _, fname in ipairs(personal_fnames) do
    local stem = fname:match("^(.-)%.toml$")
    table.insert(toml_fnames, fname)
    toml_set[stem] = nil 
end

-- 2) _index.json order
if ordered_names then
    for _, name in ipairs(ordered_names) do
        if toml_set[name] then
            table.insert(toml_fnames, toml_set[name])
            toml_set[name] = nil
        end
    end
end

-- 3) Remaining files alphabetically
local remaining = {}
for _, fname in pairs(toml_set) do table.insert(remaining, fname) end
table.sort(remaining)
for _, fname in ipairs(remaining) do table.insert(toml_fnames, fname) end

-- Load all hotstrings
local hotfiles = {}
for _, fname in ipairs(toml_fnames) do
    local name = fname:match("^(.-)%.toml$")
    keymap.load_toml(name, hotstrings_dir .. fname)
    table.insert(hotfiles, name)
end

---------------------------------------------------------------------------
-- Post-Load Module Hooks
---------------------------------------------------------------------------
local function register_repeat_keys()
    keymap.set_group_context("magickey")
    repeat_keys.start(keymap)
    keymap.set_group_context(nil)
end
register_repeat_keys()
keymap.sort_mappings()
keymap.set_post_load_hook("magickey", register_repeat_keys)

personal_info.start(base_dir, keymap)

dynamic_hotstrings.start(keymap)
dynamic_hotstrings.register_personal_data(
    personal_info.get_info(),
    personal_info.get_trigger_char()
)
table.insert(hotfiles, "dynamichotstrings")

---------------------------------------------------------------------------
-- Menubar & File Watcher
---------------------------------------------------------------------------
menu.start(base_dir, hotfiles, gestures, scroll, keymap, shortcuts, personal_info, module_sections, script_control)
script_control.start(keymap, shortcuts, gestures, scroll)

do
    local reload_timer = nil
    local function schedule_reload()
        if reload_timer then
            reload_timer:stop()
            reload_timer = nil
        end
        reload_timer = hs.timer.doAfter(0.5, function()
            hs.notify.new({title = "Hammerspoon", informativeText = "Hotstrings changed — reloading config"}):send()
            hs.reload()
        end)
    end

    local function watch_hotstrings()
        local watcher = hs.pathwatcher.new(hotstrings_dir, function(paths)
            for _, p in ipairs(paths) do
                if p:match("%.toml$") or p:match("_index%.json$") or p:match("%.local_ahk_path$") then
                    schedule_reload()
                    break
                end
            end
        end)
        watcher:start()
        return watcher
    end

    local function watch_all_tomls()
        for fname in hs.fs.dir(hotstrings_dir) do
            if fname:match("%.toml$") or fname:match("_index%.json$") then
                local fpath = hotstrings_dir .. fname
                local watcher = hs.pathwatcher.new(fpath, function() schedule_reload() end)
                watcher:start()
            end
        end
    end

    watch_hotstrings()
    watch_all_tomls()
end

---------------------------------------------------------------------------
-- Shutdown Callback
---------------------------------------------------------------------------
hs.shutdownCallback = function()
    gestures.restore_all_overrides()
end
