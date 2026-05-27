--- modules/shortcuts/keyboard_shortcuts.lua

--- ==============================================================================
--- MODULE: Keyboard Shortcuts
--- DESCRIPTION:
--- Manages configurable keyboard shortcuts for Cmd+, Ctrl+, and Option+ combos.
--- Each slot (e.g. "cmd_a", "hs_ctrl_0") maps to any action in the gesture
--- registry, allowing the user to customise every modifier+key combination
--- via the tray menu — identical in concept to the AHK system.
---
--- FEATURES & RATIONALE:
--- 1. Unified Registry: Reuses GestActions (gestures/actions.lua) so all action
---    labels, icons, and implementations stay in one place.
--- 2. Configurable Defaults: Current Cmd+ shortcuts that were hard-coded in
---    bindings.lua are seeded as defaults; the user can override any slot.
--- 3. hs.hotkey Lifecycle: Hotkeys are created by start(), deleted by stop(),
---    and rebuilt after any assignment change + reload.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("lib.logger")
local GestActions = require("modules.gestures.actions")

local LOG = "shortcuts.keyboard_shortcuts"

local _hotkeys   = {}
local _actions   = {}  -- slot_id → action_id
local _started   = false
local _settings_prefix = "keyboard_shortcut_"




-- ====================================
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

-- Modifier symbols for labels
local MOD_SYMBOLS = {
	cmd        = "⌘",
	shift      = "⇧",
	ctrl       = "^",
	alt        = "⌥",
}

-- Slot prefix → hs.hotkey modifier list
local SLOT_MODS = {
	["cmd_"]            = {"cmd"},
	["cmd_shift_"]      = {"cmd", "shift"},
	["hs_ctrl_"]        = {"ctrl"},
	["hs_ctrl_shift_"]  = {"ctrl", "shift"},
	["hs_option_"]      = {"alt"},
}

-- Special key suffix → hs.hotkey key name
local SPECIAL_KEYS = {
	space  = "space",
	enter  = "return",
	period = ".",
	comma  = ",",
}

-- Default assignments (mirrors common macOS conventions + current bindings.lua shortcuts)
M.DEFAULTS = {
	-- No hard defaults on a fresh install: all slots start at "none".
	-- Users configure via the menu.
}




-- ====================================
-- ====================================
-- ======= 2/ Slot Resolution =========
-- ====================================
-- ====================================

--- Resolves a slot id to (mods, key) for hs.hotkey.bind().
--- Returns nil, nil when the slot cannot be mapped to a valid hotkey.
--- @param slot_id string e.g. "cmd_a", "hs_ctrl_0", "hs_option_space".
--- @return table|nil mods, string|nil key
local function slot_to_hotkey(slot_id)
	for prefix, mods in pairs(SLOT_MODS) do
		if slot_id:sub(1, #prefix) == prefix then
			local suffix = slot_id:sub(#prefix + 1)
			local key = SPECIAL_KEYS[suffix] or suffix
			return mods, key
		end
	end
	return nil, nil
end

--- Returns a human-readable label for a slot (e.g. "⌘ A", "^ Espace").
--- @param slot_id string
--- @return string
local function slot_label(slot_id)
	for prefix, mods in pairs(SLOT_MODS) do
		if slot_id:sub(1, #prefix) == prefix then
			local suffix = slot_id:sub(#prefix + 1)
			local key_display = suffix:sub(1,1):upper() .. suffix:sub(2)
			local mod_str = ""
			for _, m in ipairs(mods) do
				mod_str = mod_str .. (MOD_SYMBOLS[m] or m) .. " "
			end
			return mod_str .. key_display
		end
	end
	return slot_id
end




-- ==============================
--- ==============================
-- ======= 3/ Hotkey CRUD =======
--- ==============================
-- ==============================

--- Creates and starts a hotkey binding for a single slot.
--- @param slot_id string
--- @param action_id string
local function bind_slot(slot_id, action_id)
	if action_id == "none" then return end
	local mods, key = slot_to_hotkey(slot_id)
	if not mods then
		Logger.debug(LOG, "Slot '%s' has no valid hotkey mapping — skipped.", slot_id)
		return
	end
	local ok, hk = pcall(hs.hotkey.bind, mods, key, function()
		Logger.debug(LOG, "Keyboard shortcut fired: %s → %s.", slot_id, action_id)
		pcall(GestActions.execute_single, action_id)
	end)
	if ok and hk then
		_hotkeys[slot_id] = hk
		Logger.done(LOG, "Bound %s → %s.", slot_label(slot_id), action_id)
	else
		Logger.warn(LOG, "Failed to bind slot '%s' (key: %s).", slot_id, tostring(key))
	end
end

--- Releases the hotkey for a slot if active.
--- @param slot_id string
local function unbind_slot(slot_id)
	local hk = _hotkeys[slot_id]
	if hk then
		pcall(function() hk:delete() end)
		_hotkeys[slot_id] = nil
	end
end




-- =============================
--- =============================
-- ======= 4/ Public API =======
--- =============================
-- =============================

--- Returns the full action→slot assignment table (slot_id → action_id).
--- @return table
function M.get_assignments()
	return _actions
end

--- Returns the current action id for a given slot.
--- @param slot_id string
--- @return string action_id or "none".
function M.get_action(slot_id)
	return _actions[slot_id] or "none"
end

--- Returns a human-readable label for a slot.
--- @param slot_id string
--- @return string
function M.get_slot_label(slot_id)
	return slot_label(slot_id)
end

--- Configures the action for a slot and hot-rebinds without a full reload.
--- Persists the assignment in hs.settings so it survives reloads.
--- @param slot_id string
--- @param action_id string
function M.set_action(slot_id, action_id)
	if type(slot_id) ~= "string" or type(action_id) ~= "string" then
		Logger.error(LOG, "set_action(): both arguments must be strings.")
		return
	end
	_actions[slot_id] = action_id
	hs.settings.set(_settings_prefix .. slot_id, action_id)
	Logger.debug(LOG, "Slot '%s' → '%s' persisted.", slot_id, action_id)

	-- Hot-rebind: release old hotkey, create new one if not "none"
	unbind_slot(slot_id)
	if _started and action_id ~= "none" then
		bind_slot(slot_id, action_id)
	end
end

--- Loads persisted assignments from hs.settings, seeding defaults first.
local function load_assignments()
	-- Seed defaults
	for slot, action in pairs(M.DEFAULTS) do
		_actions[slot] = action
	end
	-- Apply user overrides from hs.settings
	-- We iterate over all known SG action names to find relevant settings keys.
	-- Any slot that has been set via M.set_action() will be in hs.settings.
	-- Since slot ids are open-ended (any modifier+key), we read all settings
	-- with our prefix and apply them.
	local all_settings = hs.settings.getKeys() or {}
	local prefix_len = #_settings_prefix
	for _, k in ipairs(all_settings) do
		if k:sub(1, prefix_len) == _settings_prefix then
			local slot = k:sub(prefix_len + 1)
			local val  = hs.settings.get(k)
			if type(val) == "string" then
				_actions[slot] = val
			end
		end
	end
end

--- Starts the keyboard shortcuts module: loads assignments and binds all active slots.
function M.start()
	Logger.start(LOG, "Starting keyboard shortcuts…")
	load_assignments()
	for slot, action in pairs(_actions) do
		if action ~= "none" then
			bind_slot(slot, action)
		end
	end
	_started = true
	local count = 0
	for _ in pairs(_hotkeys) do count = count + 1 end
	Logger.success(LOG, "Keyboard shortcuts started (%d active binding(s)).", count)
end

--- Stops the keyboard shortcuts module and releases all hotkeys.
function M.stop()
	Logger.start(LOG, "Stopping keyboard shortcuts…")
	for slot in pairs(_hotkeys) do
		unbind_slot(slot)
	end
	_started = false
	Logger.success(LOG, "Keyboard shortcuts stopped.")
end

return M
