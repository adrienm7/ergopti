--- modules/shortcuts/bindings.lua

--- ==============================================================================
--- MODULE: Shortcuts Bindings Registry
--- DESCRIPTION:
--- Declares every system-wide hotkey, wires it to the correct action module, and
--- manages the enable/disable lifecycle for each shortcut individually.
---
--- FEATURES & RATIONALE:
--- 1. Declarative Routing: Each shortcut is a one-liner in hotkey_defs, keeping
---    the registry easy to scan and extend.
--- 2. Uniform Lifecycle: All shortcut objects — whether hs.hotkey or eventtap —
---    expose a :delete() method so M.enable/M.disable works identically for all.
--- ==============================================================================

local M = {}

local hs          = hs
local text_acts   = require("modules.shortcuts.actions.text")
local sys_acts    = require("modules.shortcuts.actions.system")
local app_acts    = require("modules.shortcuts.actions.apps")
local Logger      = require("lib.logger")

local LOG = "shortcuts.bindings"




-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

M.DEFAULT_CHATGPT_URL = "https://chat.openai.com"

local hotkeys       = {}   -- Active hotkey/tap objects, keyed by shortcut id
local hotkey_defs   = {}   -- Factory functions that create and return a hotkey object
local hotkey_labels = {}   -- User-facing French label for each shortcut

local started = false

-- Canonical modifier ordering used to build display labels
local MOD_ORDER  = {"cmd", "ctrl", "alt", "shift", "fn"}
local MOD_LABELS = {cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift", fn = "Fn"}




-- ===========================================
-- ===========================================
-- ======= 2/ Internal Binding Helpers =======
-- ===========================================
-- ===========================================

--- Builds a canonical display label from a modifier array and a key name.
--- @param mods table Array of modifier strings (e.g. {"ctrl", "shift"}).
--- @param key string The primary key name or character.
--- @return string Canonical label (e.g. "Ctrl+Shift+S").
local function make_label(mods, key)
	local parts = {}
	for _, m in ipairs(MOD_ORDER) do
		for _, bm in ipairs(mods) do
			if bm == m then table.insert(parts, MOD_LABELS[m] or m); break end
		end
	end
	local k = (#key == 1) and key:upper() or (key:sub(1, 1):upper() .. key:sub(2))
	table.insert(parts, k)
	return table.concat(parts, "+")
end

--- Resolves the name of the currently frontmost application.
--- Falls back to the focused window's application when frontmostApplication returns nil.
--- @return string The application name, or "Unknown" if unavailable.
local function get_frontmost_app_name()
	local app  = hs.application.frontmostApplication()
	local name = app and app:title()
	if not name or name == "" then
		local win = hs.window.focusedWindow()
		local wa  = win and win:application()
		name      = wa and wa:title()
	end
	return name or "Unknown"
end

--- Logs a shortcut invocation via the keylogger module when it is available.
--- Uses a lazy require so the keylogger is optional and need not be pre-wired.
--- @param label string The canonical shortcut label (e.g. "Ctrl+T").
--- @param app_name string The name of the app in which the shortcut fired.
local function log_shortcut(label, app_name)
	local ok_kl, kl = pcall(require, "modules.keylogger")
	if ok_kl and kl and type(kl.log_shortcut) == "function" then
		pcall(kl.log_shortcut, label, app_name)
	end
end

--- Binds a standard hotkey and logs its invocation before running the action.
--- @param mods table Modifier array.
--- @param key string Primary key.
--- @param fn function Action callback.
--- @return table The hs.hotkey object.
local function bind_log(mods, key, fn)
	local label = make_label(mods, key)
	return hs.hotkey.bind(mods, key, function()
		log_shortcut(label, get_frontmost_app_name())
		fn()
	end)
end




-- =====================================
-- =====================================
-- ======= 3/ Hotkey Definitions ========
-- =====================================
-- =====================================

-- Screenshots & Layer (appear first in the menu, before the Ctrl block)
hotkey_labels.at_hash = "Capture d'écran instantanée"
hotkey_defs.at_hash   = function()
	return sys_acts.bind_instant_screenshot()
end

hotkey_labels.layer_scroll = "Volume"
hotkey_defs.layer_scroll   = function()
	return sys_acts.bind_layer_scroll()
end

-- Ctrl shortcuts — alphabetical by id (mirrors list_shortcuts() sort order)
hotkey_labels.ctrl_a = "Sélectionner la ligne"
hotkey_defs.ctrl_a   = function()
	return bind_log({"ctrl"}, "a", text_acts.select_line)
end

hotkey_labels.ctrl_d = "Ouvrir Téléchargements"
hotkey_defs.ctrl_d   = function()
	return bind_log({"ctrl"}, "d", app_acts.open_downloads)
end

hotkey_labels.ctrl_e = "Ouvrir Finder"
hotkey_defs.ctrl_e   = function()
	return bind_log({"ctrl"}, "e", app_acts.open_finder)
end

hotkey_labels.ctrl_g = "Ouvrir ChatGPT (URL définie dans le menu)"
hotkey_defs.ctrl_g   = function()
	return bind_log({"ctrl"}, "g", function()
		app_acts.open_chatgpt(M.DEFAULT_CHATGPT_URL)
	end)
end

hotkey_labels.ctrl_h = "Capture interactive vers le presse-papiers"
hotkey_defs.ctrl_h   = function()
	return bind_log({"ctrl"}, "h", sys_acts.interactive_screenshot)
end

hotkey_labels.ctrl_i = "Ouvrir Réglages"
hotkey_defs.ctrl_i   = function()
	return bind_log({"ctrl"}, "i", app_acts.open_settings)
end

hotkey_labels.ctrl_m = "Anti-veille"
hotkey_defs.ctrl_m   = function()
	return bind_log({"ctrl"}, "m", sys_acts.toggle_awake)
end

hotkey_labels.ctrl_o = "Entourer la ligne de parenthèses"
hotkey_defs.ctrl_o   = function()
	return bind_log({"ctrl"}, "o", text_acts.surround_with_parens)
end

hotkey_labels.ctrl_s = "Ouvrir / Copier chemin"
hotkey_defs.ctrl_s   = function()
	return bind_log({"ctrl"}, "s", app_acts.copy_or_open_path)
end

hotkey_labels.ctrl_t = "Toggle Casse De Titre / minuscules"
hotkey_defs.ctrl_t   = function()
	return bind_log({"ctrl"}, "t", text_acts.toggle_titlecase)
end

hotkey_labels.ctrl_u = "Toggle MAJUSCULES / minuscules"
hotkey_defs.ctrl_u   = function()
	return bind_log({"ctrl"}, "u", text_acts.toggle_uppercase)
end

hotkey_labels.ctrl_w = "Sélectionner le mot courant"
hotkey_defs.ctrl_w   = function()
	return bind_log({"ctrl"}, "w", text_acts.select_word)
end

hotkey_labels.ctrl_x = "Copier la couleur hex du pixel sous le curseur"
hotkey_defs.ctrl_x   = function()
	return bind_log({"ctrl"}, "x", sys_acts.copy_pixel_color)
end

-- Cmd shortcuts — alphabetical by id
hotkey_labels.cmd_shift_v = "Coller sans mise en forme"
hotkey_defs.cmd_shift_v   = function()
	return bind_log({"cmd", "shift"}, "v", text_acts.paste_as_plain_text)
end

hotkey_labels.cmd_star = "Cmd + S (préserve mod.)"
hotkey_defs.cmd_star   = function()
	-- Pass the log callback so bind_cmd_star can log the re-fired Cmd+S
	return sys_acts.bind_cmd_star(log_shortcut)
end




-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Binds all configured hotkeys and starts background tasks.
function M.start()
	if started then
		Logger.warn(LOG, "M.start() called more than once — ignoring duplicate call.")
		return
	end
	Logger.start(LOG, "Starting shortcuts bindings…")
	started = true

	for name, def in pairs(hotkey_defs) do
		if not hotkeys[name] then
			local ok, obj = pcall(def)
			if ok and type(obj) == "table" then
				hotkeys[name] = obj
				Logger.debug(LOG, "Hotkey '%s' bound.", name)
			else
				Logger.error(LOG, "Failed to bind hotkey '%s'.", name)
			end
		end
	end

	-- Seed random for keep-awake jitter on first start
	math.randomseed(os.time())

	local count = 0
	for _ in pairs(hotkeys) do count = count + 1 end
	Logger.success(LOG, "Shortcuts bindings started (%d hotkey(s)).", count)
end

--- Unbinds all hotkeys and stops background tasks.
function M.stop()
	if not started then
		Logger.debug(LOG, "M.stop() called when not started — nothing to do.")
		return
	end
	Logger.start(LOG, "Stopping shortcuts bindings…")

	sys_acts.stop_awake()

	for name, v in pairs(hotkeys) do
		if v and type(v.delete) == "function" then
			pcall(function() v:delete() end)
		elseif v and type(v.disable) == "function" then
			pcall(function() v:disable() end)
		end
		Logger.debug(LOG, "Hotkey '%s' unbound.", name)
	end

	hotkeys = {}
	started = false
	Logger.success(LOG, "Shortcuts bindings stopped.")
end

--- Enables a single named hotkey by running its factory function.
--- @param name string The shortcut identifier.
function M.enable(name)
	if type(name) ~= "string" then
		Logger.error(LOG, "M.enable(): name must be a string.")
		return
	end
	if hotkeys[name] then
		Logger.debug(LOG, "Hotkey '%s' already enabled — skipping.", name)
		return
	end
	local def = hotkey_defs[name]
	if type(def) ~= "function" then
		Logger.error(LOG, "M.enable(): unknown hotkey '%s'.", name)
		return
	end
	local ok, obj = pcall(def)
	if ok and type(obj) == "table" then
		hotkeys[name] = obj
		Logger.debug(LOG, "Hotkey '%s' enabled.", name)
	else
		Logger.error(LOG, "M.enable(): factory for '%s' failed.", name)
	end
end

--- Disables a single named hotkey.
--- @param name string The shortcut identifier.
function M.disable(name)
	if type(name) ~= "string" then
		Logger.error(LOG, "M.disable(): name must be a string.")
		return
	end
	local h = hotkeys[name]
	if not h then
		Logger.debug(LOG, "Hotkey '%s' not active — nothing to disable.", name)
		return
	end
	if type(h.delete) == "function" then
		pcall(function() h:delete() end)
	elseif type(h.disable) == "function" then
		pcall(function() h:disable() end)
	end
	hotkeys[name] = nil
	Logger.debug(LOG, "Hotkey '%s' disabled.", name)
end

--- Returns whether a specific hotkey is currently active.
--- @param name string The shortcut identifier.
--- @return boolean True if the hotkey is bound.
function M.is_enabled(name)
	return hotkeys[name] ~= nil
end

--- Returns a sorted array of all registered shortcuts with their current status.
--- @return table Array of {id, label, enabled} tables.
function M.list_shortcuts()
	local out = {}
	for name in pairs(hotkey_defs) do
		table.insert(out, {
			id      = name,
			label   = hotkey_labels[name] or name,
			enabled = (hotkeys[name] ~= nil),
		})
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

return M
