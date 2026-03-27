-- init.lua
-- Entry point: loads all modules, discovers TOML hotstring files,
-- then hands off to the menubar UI and file watchers.

-- =======================================
-- =======================================
-- =======================================
-- ========== 1. MODULE IMPORTS ==========
-- =======================================
-- =======================================
-- =======================================

local gestures           = require("modules.gestures")
local keymap             = require("modules.keymap")
local shortcuts          = require("modules.shortcuts")
local personal_info      = require("modules.personal_info")
local dynamic_hotstrings = require("modules.dynamic_hotstrings")
local script_control     = require("modules.script_control")
local menu               = require("ui.menu")
local hotstring_editor   = require("ui.hotstring_editor")

-- Pre-start modules so they are active before menu.lua reads saved prefs.
-- menu.lua will honour saved state and stop/start them as needed.
gestures.start()
shortcuts.start()

-- ========================================
-- ========================================
-- ========================================
-- ========== 2. PATH RESOLUTION ==========
-- ========================================
-- ========================================
-- ========================================

local script_path = debug.getinfo(1, "S").source
if script_path:sub(1, 1) == "@" then script_path = script_path:sub(2) end

local base_dir = script_path:match("^(.*[/\\])") or "./"
if not base_dir:match("[/\\]$") then base_dir = base_dir .. "/" end

local hotstrings_dir = base_dir .. "../hotstrings/"
local config_file    = base_dir .. "config.json"

-- =======================================
-- =======================================
-- =======================================
-- ========== 3. CONFIG PRIMING ==========
-- =======================================
-- =======================================
-- =======================================

-- Restore section-enabled states and global trigger char from config.json
-- BEFORE any TOML is parsed.
local magic_key = "★"

do
    local fh = io.open(config_file, "r")
    if fh then
        local raw = fh:read("*a"); fh:close()
        local ok, cfg = pcall(hs.json.decode, raw)
        if ok and type(cfg) == "table" then
            
            -- 1. Read the global trigger character
            if type(cfg.trigger_char) == "string" then
                magic_key = cfg.trigger_char
            end

            -- 2. Restore section states
            if type(cfg.section_states) == "table" then
                for grp, secs in pairs(cfg.section_states) do
                    if type(secs) == "table" then
                        for sec_name, enabled in pairs(secs) do
                            local key = "hotstrings_section_" .. grp .. "_" .. sec_name
                            hs.settings.set(key, enabled ~= false and nil or false)
                        end
                    end
                end
            end
        end
    end
end

-- Pass the loaded trigger char to keymap before loading files
if keymap.set_trigger_char then
    keymap.set_trigger_char(magic_key)
end





-- =================================================
-- =================================================
-- =================================================
-- ========== 4. TOML DISCOVERY & LOADING ==========
-- =================================================
-- =================================================
-- =================================================

local ordered_names   = nil
local module_sections = nil

do
    local fh = io.open(hotstrings_dir .. "_index.json", "r")
    if fh then
        local raw = fh:read("*a"); fh:close()
        local ok, data = pcall(hs.json.decode, raw)
        if ok and data then
            if type(data.categories_order) == "table" then ordered_names   = data.categories_order end
            if type(data.module_sections)  == "table" then module_sections = data.module_sections  end
        end
    end
end

local toml_set = {}
for fname in hs.fs.dir(hotstrings_dir) do
    if fname:match("%.toml$") then
        toml_set[fname:match("^(.-)%.toml$")] = fname
    end
end

local toml_fnames = {}

-- =======================================
-- ======= 4.1 Private Files First =======
-- =======================================
local PRIVATE_STEMS  = { personal = true }
local private_fnames = {}
for stem, fname in pairs(toml_set) do
    if PRIVATE_STEMS[stem] then table.insert(private_fnames, fname) end
end
table.sort(private_fnames)
for _, fname in ipairs(private_fnames) do
    toml_set[fname:match("^(.-)%.toml$")] = nil
    table.insert(toml_fnames, fname)
end

-- =======================================
-- ======= 4.2 Index-Ordered Files =======
-- =======================================
if ordered_names then
    for _, name in ipairs(ordered_names) do
        if toml_set[name] then
            table.insert(toml_fnames, toml_set[name])
            toml_set[name] = nil
        end
    end
end

-- ==================================================
-- ======= 4.3 Remaining Files Alphabetically =======
-- ==================================================
local remaining = {}
for _, fname in pairs(toml_set) do table.insert(remaining, fname) end
table.sort(remaining)
for _, fname in ipairs(remaining) do table.insert(toml_fnames, fname) end

local hotfiles = {}
for _, fname in ipairs(toml_fnames) do
    local name = fname:match("^(.-)%.toml$")
    keymap.load_toml(name, hotstrings_dir .. fname)
    table.insert(hotfiles, name)
end

-- ========================================
-- ========================================
-- ========================================
-- ========== 5. POST-LOAD HOOKS ==========
-- ========================================
-- ========================================
-- ========================================

keymap.sort_mappings()
personal_info.start(base_dir, keymap)

dynamic_hotstrings.start(keymap)
dynamic_hotstrings.register_personal_data(
    personal_info.get_info(),
    magic_key -- Changed: passing the global char instead of personal_info’s
)
table.insert(hotfiles, "dynamichotstrings")

-- ── Custom hotstrings (personal, git-ignored) ───────────────────────────────
-- Stored alongside config.json so it is easy to .gitignore independently.
-- The file is created automatically if it doesn’t exist yet.
do
    local custom_path = base_dir .. "custom.toml"
    hotstring_editor.init(custom_path, keymap)
    keymap.load_toml("custom", custom_path)
    table.insert(hotfiles, "custom")
end

-- ===================================
-- ===================================
-- ===================================
-- ========== 6. UI STARTUP ==========
-- ===================================
-- ===================================
-- ===================================

menu.start(
    base_dir, hotfiles, gestures,
    keymap, shortcuts, personal_info, module_sections, script_control
)
script_control.start(keymap, shortcuts, gestures)

-- ======================================
-- ======================================
-- ======================================
-- ========== 7. FILE WATCHERS ==========
-- ======================================
-- ======================================
-- ======================================

do
    local reload_timer = nil

    local function schedule_reload()
        if reload_timer then reload_timer:stop() end
        reload_timer = hs.timer.doAfter(0.5, function()
            hs.notify.new({
                title           = "Hammerspoon",
                informativeText = "Hotstrings modifiés — rechargement…",
            }):send()
            hs.reload()
        end)
    end

-- ===========================================
-- ======= 7.1 Directory-Level Watcher =======
-- ===========================================
    -- Catches file creation, deletion, and renames.
    local dir_watcher = hs.pathwatcher.new(hotstrings_dir, function(paths)
        for _, p in ipairs(paths) do
            if p:match("%.toml$") or p:match("_index%.json$")
                or p:match("%.local_ahk_path$") then
                schedule_reload(); return
            end
        end
    end)
    dir_watcher:start()

-- =====================================
-- ======= 7.2 Per-File Watchers =======
-- =====================================
    -- Safety net for in-place edits that directory watchers may miss.
    for fname in hs.fs.dir(hotstrings_dir) do
        if fname:match("%.toml$") or fname:match("_index%.json$") then
            local w = hs.pathwatcher.new(hotstrings_dir .. fname, schedule_reload)
            w:start()
        end
    end
end

-- ==========================================
-- ==========================================
-- ==========================================
-- ========== 8. SHUTDOWN CALLBACK ==========
-- ==========================================
-- ==========================================
-- ==========================================

hs.shutdownCallback = function()
    gestures.restore_all_overrides()
end
