--- modules/shortcuts/bindings.lua

--- ==============================================================================
--- MODULE: Shortcuts Bindings Registry
--- DESCRIPTION:
--- Registers the default hotkeys mapping to their helper functions.
---
--- FEATURES & RATIONALE:
--- 1. Declarative Routing: Easy to read list of all system-wide shortcuts.
--- 2. Lifecycle Management: Handles enabling/disabling specific or all shortcuts.
--- ==============================================================================

local M = {}
local hs = hs
local helpers = require("modules.shortcuts.helpers")





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

M.DEFAULT_CHATGPT_URL = "https://chat.openai.com"

local hotkeys       = {}
local hotkey_defs   = {}
local hotkey_labels = {}

local started       = false

-- Ordered list used to build canonical shortcut labels
local MOD_ORDER  = { "cmd", "ctrl", "alt", "shift", "fn" }
local MOD_LABELS = { cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift", fn = "Fn" }

--- Builds a canonical shortcut label from a mods table and a key string.
--- @param mods table Array of modifier strings (e.g. {"ctrl", "shift"}).
--- @param key string The primary key character or name.
--- @return string Canonical label (e.g. "Ctrl+Shift+S").
local function make_label(mods, key)
	local parts = {}
	for _, m in ipairs(MOD_ORDER) do
		for _, bound_m in ipairs(mods) do
			if bound_m == m then table.insert(parts, MOD_LABELS[m] or m); break end
		end
	end
	local k = (#key == 1) and key:upper() or (key:sub(1, 1):upper() .. key:sub(2))
	table.insert(parts, k)
	return table.concat(parts, "+")
end

--- Wraps hs.hotkey.bind to log the shortcut immediately before executing the action.
--- Uses a direct lazy-require of the keylogger so no external wiring is needed.
--- @param mods table Modifier array.
--- @param key string Primary key.
--- @param fn function Action callback.
--- @return table The hotkey object.
local function bind_log(mods, key, fn)
	local label = make_label(mods, key)
	return hs.hotkey.bind(mods, key, function()
		local ok_kl, kl = pcall(require, "modules.keylogger")
		if ok_kl and kl and type(kl.log_shortcut) == "function" then
            local app = hs.application.frontmostApplication()
            local app_name = app and app:title() or nil
            if not app_name or app_name == "" then
                local win = hs.window.focusedWindow()
                local win_app = win and win:application()
                app_name = win_app and win_app:title() or "Unknown"
            end
            pcall(kl.log_shortcut, label, app_name)
		end
		fn()
	end)
end





-- =====================================
-- =====================================
-- ======= 2/ Hotkey Definitions =======
-- =====================================
-- =====================================

-- System & Tools
hotkey_labels.at_hash = "Capture d’écran instantanée"
hotkey_defs.at_hash = function()
    return helpers.bind_instant_screenshot()
end

hotkey_labels.ctrl_h = "Capture interactive vers le presse-papiers"
hotkey_defs.ctrl_h = function()
    return bind_log({"ctrl"}, "h", helpers.interactive_screenshot)
end

hotkey_labels.ctrl_m = "Anti-veille"
hotkey_defs.ctrl_m = function()
    return bind_log({"ctrl"}, "m", helpers.toggle_awake)
end

hotkey_labels.ctrl_x = "Copier la couleur hex du pixel sous le curseur"
hotkey_defs.ctrl_x = function()
    return bind_log({"ctrl"}, "x", helpers.copy_pixel_color)
end

hotkey_labels.layer_scroll = "Volume"
hotkey_defs.layer_scroll = function()
    return helpers.bind_layer_scroll()
end

-- Text & Selection
hotkey_labels.cmd_star = "Cmd + S (préserve mod.)"
hotkey_defs.cmd_star = function()
    return helpers.bind_cmd_star()
end

hotkey_labels.cmd_shift_v = "Coller sans mise en forme"
hotkey_defs.cmd_shift_v = function()
    return bind_log({"cmd","shift"}, "v", helpers.paste_as_plain_text)
end

hotkey_labels.ctrl_a = "Sélectionner la ligne"
hotkey_defs.ctrl_a = function()
    return bind_log({"ctrl"}, "a", helpers.select_line)
end

hotkey_labels.ctrl_o = "Entourer la ligne de parenthèses"
hotkey_defs.ctrl_o = function()
    return bind_log({"ctrl"}, "o", helpers.surround_with_parens)
end

hotkey_labels.ctrl_t = "Toggle Casse De Titre / minuscules"
hotkey_defs.ctrl_t = function()
    return bind_log({"ctrl"}, "t", helpers.toggle_titlecase)
end

hotkey_labels.ctrl_u = "Toggle MAJUSCULES / minuscules"
hotkey_defs.ctrl_u = function()
    return bind_log({"ctrl"}, "u", helpers.toggle_uppercase)
end

hotkey_labels.ctrl_w = "Sélectionner le mot courant"
hotkey_defs.ctrl_w = function()
    return bind_log({"ctrl"}, "w", helpers.select_word)
end

-- App Navigation
hotkey_labels.ctrl_d = "Ouvrir Téléchargements"
hotkey_defs.ctrl_d = function()
    return bind_log({"ctrl"}, "d", helpers.open_downloads)
end

hotkey_labels.ctrl_e = "Ouvrir Finder"
hotkey_defs.ctrl_e = function()
    return bind_log({"ctrl"}, "e", helpers.open_finder)
end

hotkey_labels.ctrl_g = "Ouvrir ChatGPT (URL définie dans le menu)"
hotkey_defs.ctrl_g = function()
    return bind_log({"ctrl"}, "g", function()
        helpers.open_chatgpt(M.DEFAULT_CHATGPT_URL)
    end)
end

hotkey_labels.ctrl_i = "Ouvrir Réglages"
hotkey_defs.ctrl_i = function()
    return bind_log({"ctrl"}, "i", helpers.open_settings)
end

hotkey_labels.ctrl_s = "Ouvrir / Copier chemin"
hotkey_defs.ctrl_s = function()
    return bind_log({"ctrl"}, "s", helpers.copy_or_open_path)
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Initializes and binds all configured hotkeys.
function M.start()
    if started then return end
    started = true
    
    for name, def in pairs(hotkey_defs) do
        if not hotkeys[name] then
            local ok, obj = pcall(def)
            if ok and type(obj) == "table" then
                hotkeys[name] = obj
            end
        end
    end
    
    -- Re-seed random for keep-awake jitter
    math.randomseed(os.time())
end

--- Unbinds all hotkeys and stops background tasks.
function M.stop()
    if not started then return end
    
    helpers.stop_awake()
    
    for _, v in pairs(hotkeys) do
        if v and type(v.delete) == "function" then 
            pcall(function() v:delete() end)
        elseif v and type(v.disable) == "function" then
            pcall(function() v:disable() end)
        end
    end
    
    hotkeys = {}
    started = false
end

--- Enables a single named hotkey.
--- @param name string The ID of the hotkey.
function M.enable(name)
    if type(name) ~= "string" or hotkeys[name] then return end
    local def = hotkey_defs[name]
    if type(def) == "function" then 
        local ok, obj = pcall(def)
        if ok and type(obj) == "table" then
            hotkeys[name] = obj
        end
    end
end

--- Disables a single named hotkey.
--- @param name string The ID of the hotkey.
function M.disable(name)
    local h = hotkeys[name]
    if h and type(h.delete) == "function" then 
        pcall(function() h:delete() end)
    elseif h and type(h.disable) == "function" then
        pcall(function() h:disable() end)
    end
    hotkeys[name] = nil
end

--- Checks if a specific hotkey is currently enabled.
--- @param name string The ID of the hotkey.
--- @return boolean True if enabled.
function M.is_enabled(name)
    return hotkeys[name] ~= nil
end

--- Retrieves a list of all registered shortcuts with their status.
--- @return table An array of shortcuts.
function M.list_shortcuts()
    local out = {}
    for name, _ in pairs(hotkey_defs) do
        table.insert(out, {
            id = name, 
            label = hotkey_labels[name] or name, 
            enabled = (hotkeys[name] ~= nil)
        })
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

return M
