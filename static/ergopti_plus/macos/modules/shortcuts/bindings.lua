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
local Logger      = require("infra.logger")
local i18n        = require("infra.i18n")
local Manifest    = require("infra.manifest_reader")

local LOG = "shortcuts.bindings"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Sourced from the manifest (the cross-driver SSoT, platforms ahk+hs) rather
-- than re-declared, so a change to shortcuts.chatgpt_url cannot diverge from the
-- AHK driver (which reads the same default from its generated map). Fails fast
-- if the path is absent.
M.DEFAULT_CHATGPT_URL = Manifest.default_for("shortcuts.chatgpt_url")

local hotkeys       = {}   -- Active hotkey/tap objects, keyed by shortcut id
local hotkey_defs   = {}   -- Factory functions that create and return a hotkey object
local hotkey_labels = {}   -- User-facing French label for each shortcut

-- Shortcuts explicitly disabled via M.disable() survive a stop/start cycle so
-- that a resume after focus loss cannot silently re-enable a hotkey the caller
-- intentionally turned off (shortcuts-bindings-reenable-on-resume).
local _disabled_set = {}

local started = false

-- Callback that returns the live active-wrap-pairs table.
-- Set by M.set_wrap_pairs_getter() when the menu wires up the user's symbol state.
-- Falls back to nil so bind_wrap_text_if_selected uses the full built-in catalogue.
local _wrap_pairs_getter = nil

-- User-configured ChatGPT URL, persisted to config.toml by the menu's save
-- callback. Set by M.set_chatgpt_url() at boot-time state restoration and on
-- every menu edit, so ctrl_g always opens the URL the user actually configured
-- instead of the hardcoded manifest default (shortcuts-ctrl-g-ignores-config).
-- Falls back to nil so ctrl_g uses M.DEFAULT_CHATGPT_URL.
local _chatgpt_url = nil

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
hotkey_labels.at_hash = i18n.get("shortcuts.label_at_hash")
hotkey_defs.at_hash   = function()
	return sys_acts.bind_instant_screenshot()
end

hotkey_labels.layer_scroll = i18n.get("shortcuts.label_layer_scroll")
hotkey_defs.layer_scroll   = function()
	return sys_acts.bind_layer_scroll()
end

hotkey_labels.wrap_text_if_selected = i18n.get("shortcuts.label_wrap_text")
hotkey_defs.wrap_text_if_selected   = function()
	return sys_acts.bind_wrap_text_if_selected(_wrap_pairs_getter)
end

-- Ctrl shortcuts — alphabetical by id (mirrors list_shortcuts() sort order)
hotkey_labels.ctrl_a = i18n.get("shortcuts.label_ctrl_a")
hotkey_defs.ctrl_a   = function()
	return bind_log({"ctrl"}, "a", text_acts.select_line)
end

hotkey_labels.ctrl_d = i18n.get("shortcuts.label_ctrl_d")
hotkey_defs.ctrl_d   = function()
	return bind_log({"ctrl"}, "d", app_acts.open_downloads)
end

hotkey_labels.ctrl_e = i18n.get("shortcuts.label_ctrl_e")
hotkey_defs.ctrl_e   = function()
	return bind_log({"ctrl"}, "e", app_acts.open_finder)
end

hotkey_labels.ctrl_g = i18n.get("shortcuts.label_ctrl_g")
hotkey_defs.ctrl_g   = function()
	return bind_log({"ctrl"}, "g", function()
		app_acts.open_chatgpt(_chatgpt_url or M.DEFAULT_CHATGPT_URL)
	end)
end

hotkey_labels.ctrl_h = i18n.get("shortcuts.label_ctrl_h")
hotkey_defs.ctrl_h   = function()
	return bind_log({"ctrl"}, "h", sys_acts.interactive_screenshot)
end

hotkey_labels.ctrl_i = i18n.get("shortcuts.label_ctrl_i")
hotkey_defs.ctrl_i   = function()
	return bind_log({"ctrl"}, "i", app_acts.open_settings)
end

hotkey_labels.ctrl_m = i18n.get("shortcuts.label_ctrl_m")
hotkey_defs.ctrl_m   = function()
	return bind_log({"ctrl"}, "m", sys_acts.toggle_awake)
end

hotkey_labels.ctrl_o = i18n.get("shortcuts.label_ctrl_o")
hotkey_defs.ctrl_o   = function()
	return bind_log({"ctrl"}, "o", text_acts.surround_with_parens)
end

hotkey_labels.ctrl_p = i18n.get("shortcuts.label_ctrl_p")
hotkey_defs.ctrl_p   = function()
	return bind_log({"ctrl"}, "p", sys_acts.toggle_display_mirror)
end

hotkey_labels.ctrl_s = i18n.get("shortcuts.label_ctrl_s")
hotkey_defs.ctrl_s   = function()
	return bind_log({"ctrl"}, "s", app_acts.copy_or_open_path)
end

hotkey_labels.ctrl_t = i18n.get("shortcuts.label_ctrl_t")
hotkey_defs.ctrl_t   = function()
	return bind_log({"ctrl"}, "t", sys_acts.teleport_mouse)
end

hotkey_labels.ctrl_u = i18n.get("shortcuts.label_ctrl_u")
hotkey_defs.ctrl_u   = function()
	return bind_log({"ctrl"}, "u", text_acts.toggle_uppercase)
end

hotkey_labels.ctrl_w = i18n.get("shortcuts.label_ctrl_w")
hotkey_defs.ctrl_w   = function()
	return bind_log({"ctrl"}, "w", text_acts.toggle_titlecase)
end

hotkey_labels.ctrl_x = i18n.get("shortcuts.label_ctrl_x")
hotkey_defs.ctrl_x   = function()
	return bind_log({"ctrl"}, "x", sys_acts.copy_pixel_color)
end

hotkey_labels.ctrl_capslock = i18n.get("shortcuts.label_ctrl_capslock")
hotkey_defs.ctrl_capslock   = function()
	return bind_log({"ctrl"}, "capslock", sys_acts.toggle_capslock)
end

hotkey_labels.ctrl_l = i18n.get("shortcuts.label_ctrl_l")
hotkey_defs.ctrl_l   = function()
	return bind_log({"ctrl"}, "l", sys_acts.lock_screen)
end

-- Punctuation shortcuts — after all letter-based ctrl shortcuts
hotkey_labels.ctrl_period = i18n.get("shortcuts.label_ctrl_period")
hotkey_defs.ctrl_period   = function()
	return bind_log({"ctrl"}, ".", sys_acts.open_emoji_picker)
end

hotkey_labels.ctrl_quote = i18n.get("shortcuts.label_ctrl_quote")
hotkey_defs.ctrl_quote   = function()
	return bind_log({"ctrl"}, "'", sys_acts.spotlight_mouse)
end

-- Cmd shortcuts — alphabetical by id
hotkey_labels.cmd_shift_v = i18n.get("shortcuts.label_cmd_shift_v")
hotkey_defs.cmd_shift_v   = function()
	return bind_log({"cmd", "shift"}, "v", text_acts.paste_as_plain_text)
end

hotkey_labels.cmd_star = i18n.get("shortcuts.label_cmd_star")
hotkey_defs.cmd_star   = function()
	-- Pass the log callback so bind_cmd_star can log the re-fired Cmd+S
	return sys_acts.bind_cmd_star(log_shortcut)
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Releases every live hotkey/eventtap object without forgetting cleanup debt.
--- Extracted so the two callers cannot drift apart on how an object is torn
--- down: M.stop() (a genuine subsystem shutdown) and M.rebind() (a layout
--- re-arm). Only the former owns the subsystem-level state — see M.stop().
--- @return boolean settled True only when every native owner was released.
local function release_hotkeys()
	local settled = true
	local names = {}
	for name in pairs(hotkeys) do names[#names + 1] = name end
	for _, name in ipairs(names) do
		local v = hotkeys[name]
		local released = false
		if v and type(v.delete) == "function" then
			local ok, result = pcall(function() return v:delete() end)
			released = ok and result ~= false
		elseif v and type(v.disable) == "function" then
			local ok, result = pcall(function() return v:disable() end)
			released = ok and result ~= false
		end
		if released then
			hotkeys[name] = nil
			Logger.debug(LOG, "Hotkey '%s' unbound.", name)
		else
			settled = false
			Logger.error(LOG, "Hotkey '%s' teardown did not settle — native handle retained for retry.", name)
		end
	end
	return settled
end

--- Binds all configured hotkeys and starts background tasks transactionally.
--- @return boolean committed True only when every enabled binding is owned.
function M.start()
	if started then
		-- A second start() per boot is the intended reconciliation, not a bug:
		-- init.lua starts the bindings early so hotkeys work during boot, then
		-- menu_state re-starts them to apply the saved on/off preference. Mirror
		-- keymap.start's silently-idempotent restart and log at DEBUG so a normal
		-- boot stays warning-free (a WARNING every boot trains users to ignore them)
		Logger.debug(LOG, "M.start() already active — ignoring duplicate start (boot reconciliation).")
		return true
	end
	if next(hotkeys) ~= nil and release_hotkeys() ~= true then
		Logger.error(LOG, "Shortcuts bindings cannot start while native cleanup is pending.")
		return false
	end
	Logger.start(LOG, "Starting shortcuts bindings…")

	for name, def in pairs(hotkey_defs) do
		-- Skip hotkeys that are already active OR that were explicitly disabled
		-- via M.disable() — the _disabled_set persists across stop/start cycles
		-- so that resume after focus loss cannot silently re-enable them
		-- (shortcuts-bindings-reenable-on-resume).
		if not hotkeys[name] and not _disabled_set[name] then
			local ok, obj = xpcall(def, debug.traceback)
			local object_type = type(obj)
			if ok and obj ~= nil and (object_type == "table" or object_type == "userdata") then
				hotkeys[name] = obj
				Logger.debug(LOG, "Hotkey '%s' bound.", name)
			else
				Logger.error(LOG, "Failed to bind hotkey '%s': %s.", name, tostring(obj))
				local rollback_settled = release_hotkeys()
				if not rollback_settled then
					Logger.error(LOG, "Shortcuts bindings startup rollback is incomplete.")
				end
				return false
			end
		end
	end

	-- Seed random for keep-awake jitter on first start
	math.randomseed(os.time())

	local count = 0
	for _ in pairs(hotkeys) do count = count + 1 end
	started = true
	Logger.success(LOG, "Shortcuts bindings started (%d hotkey(s)).", count)
	return true
end

--- Unbinds all hotkeys and stops background tasks.
--- @return boolean settled True only when every owned resource was released.
function M.stop()
	if not started and next(hotkeys) == nil then
		Logger.debug(LOG, "M.stop() called when not started — nothing to do.")
		return true
	end
	Logger.start(LOG, "Stopping shortcuts bindings…")

	-- Only a genuine shutdown owns the keep-awake teardown. Keep-awake is
	-- subsystem-level state (jiggler timer + persistent banner the user armed for
	-- a meeting), not a hotkey object, so a layout re-arm has no business
	-- cancelling it. M.rebind() must NEVER reach this line — routing the layout
	-- rebind through stop() is what silently killed keep-awake, and the laptop
	-- slept, on every input-source change (shortcuts-rebind-kills-keep-awake).
	local awake_settled = true
	if started then
		local ok, result = xpcall(sys_acts.stop_awake, debug.traceback)
		awake_settled = ok and result ~= false
		if not awake_settled then
			Logger.error(LOG, "Keep-awake teardown did not settle: %s.", tostring(result))
		end
	end

	local hotkeys_settled = release_hotkeys()
	started = false
	if not awake_settled or not hotkeys_settled then
		Logger.error(LOG, "Shortcuts bindings stop is incomplete and remains retryable.")
		return false
	end
	Logger.success(LOG, "Shortcuts bindings stopped.")
	return true
end

--- Re-creates every hotkey object in place, WITHOUT touching subsystem-level
--- state. hs.hotkey.bind resolves key names to physical scancodes at bind time,
--- so after a keyboard-layout change the live bindings still point at the old
--- layout's positions and must be rebuilt.
--- Deliberately not M.stop() followed by M.start(): stop() also tears down
--- keep-awake, which a layout switch must leave running. Hotkeys the caller
--- turned off via M.disable() stay off, because M.start() honours _disabled_set.
function M.rebind()
	if not started then
		-- A rebind is meaningless on a stopped layer, and re-arming from here
		-- would resurrect hotkeys the user deliberately turned off
		-- (shortcuts-layout-rebind-reenables).
		Logger.debug(LOG, "M.rebind() called when not started — nothing to re-arm.")
		return false
	end
	Logger.trace(LOG, "Rebinding shortcuts hotkeys…")
	started = false
	if release_hotkeys() ~= true then
		Logger.error(LOG, "Shortcuts hotkey rebind could not release every prior owner.")
		return false
	end
	if M.start() ~= true then
		Logger.error(LOG, "Shortcuts hotkey rebind could not commit replacement owners.")
		return false
	end
	Logger.done(LOG, "Shortcuts hotkeys rebound.")
	return true
end

--- Returns true when bindings have been started and not yet stopped.
--- @return boolean
function M.is_started() return started end

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
	_disabled_set[name] = nil
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
	_disabled_set[name] = true
	Logger.debug(LOG, "Hotkey '%s' disabled.", name)
end

--- Returns whether a specific hotkey is currently active.
--- @param name string The shortcut identifier.
--- @return boolean True if the hotkey is bound.
function M.is_enabled(name)
	return hotkeys[name] ~= nil
end

--- Builds a sort key that groups shortcuts in display order:
---   1) ctrl + single letter (ctrl_a … ctrl_z)
---   2) ctrl + punctuation word (ctrl_period, ctrl_quote, …)
---   3) cmd shortcuts (cmd_shift_v, cmd_star, …)
---   4) everything else (at_hash, layer_scroll — extracted separately by the menu)
--- Within each group items sort alphabetically by id.
--- @param id string The shortcut identifier.
--- @return string Opaque sort key.
local function sort_key(id)
	if id:match("^ctrl_%a$") then return "1_" .. id end
	if id:match("^ctrl_")    then return "2_" .. id end
	if id:match("^cmd_")     then return "3_" .. id end
	return "4_" .. id
end

--- Sets the callback used by the wrap-text eventtap to resolve the active symbol table.
--- Call this whenever the user changes the symbol list so the tap uses the new table
--- on the very next keystroke without needing a restart.
--- @param getter function|nil Returns the live {[char]={left,right}} table, or nil to use defaults.
function M.set_wrap_pairs_getter(getter)
	_wrap_pairs_getter = type(getter) == "function" and getter or nil
	Logger.debug(LOG, "wrap_pairs_getter updated.")
	-- Re-arm the tap so it captures the new closure immediately
	if hotkeys.wrap_text_if_selected then
		local def = hotkey_defs.wrap_text_if_selected
		if type(def) == "function" then
			local h = hotkeys.wrap_text_if_selected
			if type(h.delete) == "function" then pcall(function() h:delete() end) end
			local ok, obj = pcall(def)
			if ok and type(obj) == "table" then
				hotkeys.wrap_text_if_selected = obj
			end
		end
	end
end

--- Sets the ChatGPT URL that Ctrl+G opens. Call this whenever the user edits the
--- URL from the menu, and once at boot-time state restoration, so ctrl_g always
--- reflects config.toml (the SSoT) instead of the hardcoded manifest default.
--- No re-arm is needed here (unlike set_wrap_pairs_getter): ctrl_g's closure
--- reads _chatgpt_url fresh on every keypress rather than capturing it once.
--- @param url string|nil The configured URL, or nil to fall back to the default.
function M.set_chatgpt_url(url)
	_chatgpt_url = (type(url) == "string" and url ~= "") and url or nil
	Logger.debug(LOG, "chatgpt_url updated: %s.", tostring(_chatgpt_url))
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
	table.sort(out, function(a, b) return sort_key(a.id) < sort_key(b.id) end)
	return out
end

return M
