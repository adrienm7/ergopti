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
--- 3. Registrar Lifecycle: bindings are created by start(), released by stop(),
---    and rebuilt after any assignment change + reload. The OS call itself lives
---    in adapters/hotkey_registrar.lua, so this module never names hs.hotkey.
--- ==============================================================================

local M = {}

local hs          = hs
local Chord       = require("chord")
local Registrar   = require("adapters.hotkey_registrar")
local FileSystem  = require("adapters.file_system")
local Paths       = require("infra.paths")
local Logger      = require("infra.logger")
local GestActions = require("modules.gestures.actions")

local LOG = "shortcuts.keyboard_shortcuts"

local _hotkeys   = {}  -- slot_id → registrar handle
local _actions   = {}  -- slot_id → action_id
local _started   = false
local _settings_prefix = "keyboard_shortcut_"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Modifier symbols for labels
local MOD_SYMBOLS = {
	cmd        = "⌘",
	shift      = "⇧",
	ctrl       = "^",
	alt        = "⌥",
}

-- Slot prefix → canonical modifier list.
-- Stored as an ordered array (longest prefix first) so slot_to_chord()
-- and slot_label() use ipairs() and never mistake "cmd_shift_x" for "cmd_x"
-- due to non-deterministic pairs() iteration.
local SLOT_MODS = {
	{ "hs_ctrl_shift_",  {"ctrl", "shift"} },
	{ "cmd_shift_",      {"cmd",  "shift"} },
	{ "hs_ctrl_",        {"ctrl"} },
	{ "hs_option_",      {"alt"} },
	{ "cmd_",            {"cmd"} },
}

-- Special key suffix → canonical key name. The registrar translates these to
-- whatever the OS calls them; "enter" is spelled "return" here because that is
-- the name the key has, not because Hammerspoon happens to want it.
local SPECIAL_KEYS = {
	space  = "space",
	enter  = "return",
	period = ".",
	comma  = ",",
}

-- The groups the menu offers, in display order, each with the i18n keys for its
-- submenu title and its "add a binding" row. The prefixes are the SLOT_MODS
-- prefixes: a group whose prefix is not in SLOT_MODS would render rows that
-- resolve to no chord, which is why test_keyboard_slot_groups.lua ties the two
-- together rather than trusting them to stay in step.
M.SLOT_GROUPS = {
	{ prefix = "hs_option_",     group_key = "menu.shortcuts.alt_group",       add_key = "menu.shortcuts.alt_add" },
	{ prefix = "hs_ctrl_",       group_key = "menu.shortcuts.ctrl_group",      add_key = "menu.shortcuts.ctrl_add" },
	{ prefix = "hs_ctrl_shift_", group_key = "menu.shortcuts.ctrl_shift_group", add_key = "menu.shortcuts.ctrl_shift_add" },
	{ prefix = "cmd_",           group_key = "menu.shortcuts.cmd_group",       add_key = "menu.shortcuts.cmd_add" },
	{ prefix = "cmd_shift_",     group_key = "menu.shortcuts.cmd_shift_group",  add_key = "menu.shortcuts.cmd_shift_add" },
}

-- Path to the shared key catalogue. The slot space is prefix × key, and the keys
-- are the same 40 the gesture actions and the Windows driver already use — a
-- private list here would be a fourth answer to "which keys exist".
local KEY_CATALOGUE_PATH = Paths.shared("modules/actions/modifier_chords.json")

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

-- The catalogue, decoded once. Nil until the first read; false once a read has
-- failed, so a missing file is reported once rather than on every menu rebuild.
local _catalogue = nil

--- Reads the shared key catalogue.
--- @return table|nil keys The ordered key entries, or nil when unavailable.
local function catalogue_keys()
	if _catalogue == false then return nil end
	if _catalogue == nil then
		local raw = FileSystem.read(KEY_CATALOGUE_PATH)
		local ok, decoded = pcall(hs.json.decode, raw or "")
		if not raw or not ok or type(decoded) ~= "table" or type(decoded.keys) ~= "table" then
			-- No local fallback list: an unsynchronised private copy of the key
			-- space is exactly what the shared catalogue exists to prevent, so an
			-- unreadable catalogue means an empty picker, not a made-up one.
			Logger.error(LOG, "Shared key catalogue unreadable at %s — no slots can be offered.", tostring(KEY_CATALOGUE_PATH))
			_catalogue = false
			return nil
		end
		_catalogue = decoded
	end
	return _catalogue.keys
end

--- Key id → display label, from the catalogue.
--- @return table
local function key_labels()
	local labels = {}
	for _, entry in ipairs(catalogue_keys() or {}) do
		labels[entry.id] = entry.label or entry.id
	end
	return labels
end

--- Resolves a slot id to a canonical chord string.
--- Returns nil when the slot cannot be mapped to a valid chord — a slot whose
--- prefix matches nothing names no modifiers, and binding its bare suffix would
--- steal a plain letter key from every application.
--- @param slot_id string e.g. "cmd_a", "hs_ctrl_0", "hs_option_space".
--- @return string|nil chord Canonical chord, e.g. "Cmd+A".
local function slot_to_chord(slot_id)
	for _, entry in ipairs(SLOT_MODS) do
		local prefix, mods = entry[1], entry[2]
		if slot_id:sub(1, #prefix) == prefix then
			local suffix = slot_id:sub(#prefix + 1)
			local key = SPECIAL_KEYS[suffix] or suffix
			return Chord.format(mods, key)
		end
	end
	return nil
end

--- Returns a human-readable label for a slot (e.g. "⌘ A", "^ Espace").
--- @param slot_id string
--- @return string
local function slot_label(slot_id)
	for _, entry in ipairs(SLOT_MODS) do
		local prefix, mods = entry[1], entry[2]
		if slot_id:sub(1, #prefix) == prefix then
			local suffix = slot_id:sub(#prefix + 1)
			local key_display = key_labels()[suffix] or (suffix:sub(1, 1):upper() .. suffix:sub(2))
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
-- ==============================
-- ======= 3/ Hotkey CRUD =======
-- ==============================
-- ==============================

--- Creates and starts a hotkey binding for a single slot.
--- @param slot_id string
--- @param action_id string
--- @return boolean committed True when no binding is needed or one is owned.
local function bind_slot(slot_id, action_id)
	if action_id == "none" then return true end
	if _hotkeys[slot_id] then
		local ok_enable, enabled = xpcall(Registrar.setEnabled, debug.traceback,
			_hotkeys[slot_id], true)
		if ok_enable and enabled == true then return true end
		Logger.error(LOG, "Failed to re-enable retained slot '%s': %s.",
			slot_id, tostring(enabled))
		return false
	end
	local chord = slot_to_chord(slot_id)
	if not chord then
		Logger.error(LOG, "Slot '%s' has no valid chord mapping — startup refused.", slot_id)
		return false
	end
	local ok_bind, handle = xpcall(Registrar.bind, debug.traceback, chord, function()
		local current_action = _actions[slot_id] or "none"
		if current_action == "none" then
			Logger.debug(LOG, "Ignored inactive configurable shortcut slot '%s'.", slot_id)
			return false
		end
		Logger.debug(LOG, "Keyboard shortcut fired: %s → %s.", slot_id, current_action)
		local ok_action, handled = Logger.callback(LOG,
			"Configurable shortcut '" .. tostring(slot_id) .. "'",
			GestActions.execute_single, current_action, "keyboard__" .. slot_id)
		if not ok_action then return false end
		if handled ~= true then
			Logger.error(LOG, "Configurable shortcut '%s' was not handled by action '%s'.",
				tostring(slot_id), tostring(current_action))
			return false
		end
		return true
	end)
	if ok_bind and handle then
		_hotkeys[slot_id] = handle
		Logger.done(LOG, "Bound %s → %s.", slot_label(slot_id), action_id)
		return true
	else
		Logger.error(LOG, "Failed to bind slot '%s' (chord: %s): %s.",
			slot_id, chord, tostring(handle))
		return false
	end
end

--- Changes whether an exact retained slot handle may deliver callbacks.
--- @param slot_id string
--- @param enabled boolean
--- @return boolean settled
local function set_slot_enabled(slot_id, enabled)
	local handle = _hotkeys[slot_id]
	if not handle then return false end
	local ok, result = xpcall(Registrar.setEnabled, debug.traceback, handle, enabled)
	if ok and result == true then return true end
	Logger.error(LOG, "Failed to set slot '%s' enabled=%s: %s — exact handle retained.",
		slot_id, tostring(enabled), tostring(result))
	return false
end

--- Reads the exact persisted value before a mutation.
--- @param key string
--- @return boolean ok
--- @return any value_or_error
local function read_setting(key)
	local ok, value = xpcall(hs.settings.get, debug.traceback, key)
	if not ok then
		Logger.error(LOG, "Shortcut setting snapshot failed for '%s': %s.", key, tostring(value))
		return false, value
	end
	return true, value
end

--- Writes a value and restores the snapshot when the write raises after mutation.
--- @param key string
--- @param value any
--- @param snapshot any
--- @return boolean committed
local function persist_setting(key, value, snapshot)
	local ok, err = xpcall(hs.settings.set, debug.traceback, key, value)
	if ok then return true end

	local restored, restore_err = xpcall(hs.settings.set, debug.traceback, key, snapshot)
	if not restored then
		Logger.error(LOG,
			"Shortcut setting write failed for '%s': %s; snapshot restore also failed: %s.",
			key, tostring(err), tostring(restore_err))
	else
		Logger.error(LOG, "Shortcut setting write failed for '%s': %s; snapshot restored.",
			key, tostring(err))
	end
	return false
end

--- Releases the hotkey for a slot if active.
--- @param slot_id string
--- @return boolean settled True only when the native owner was released.
local function unbind_slot(slot_id)
	local handle = _hotkeys[slot_id]
	if not handle then return true end
	local ok, result = xpcall(Registrar.unbind, debug.traceback, handle)
	if ok and result == true then
		_hotkeys[slot_id] = nil
		return true
	end
	Logger.error(LOG, "Failed to release slot '%s': %s — handle retained for retry.",
		slot_id, tostring(result))
	return false
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
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

--- Lists every slot a group can offer, in catalogue order.
--- Each entry is { id, label } ready for the picker. An unknown prefix yields an
--- empty list rather than the whole key space, so a typo in a group definition
--- shows as a group with nothing in it instead of five identical groups.
--- @param prefix string One of M.SLOT_GROUPS' prefixes.
--- @return table
function M.available_slots(prefix)
	local known = false
	for _, entry in ipairs(SLOT_MODS) do
		if entry[1] == prefix then known = true; break end
	end
	if not known then
		Logger.error(LOG, "available_slots(): '%s' is not a slot prefix.", tostring(prefix))
		return {}
	end

	local out = {}
	for _, key in ipairs(catalogue_keys() or {}) do
		out[#out + 1] = { id = prefix .. key.id, label = key.label or key.id }
	end
	return out
end

--- Lists the slots of a group that currently hold an action, in catalogue order.
--- Iterating the catalogue rather than the assignment table is what makes the
--- menu order stable: pairs() over _actions would reshuffle the rows on every
--- rebuild, and a menu whose items move between two openings is unusable.
--- @param prefix string
--- @return table Array of { id, label, action } for assigned slots only.
function M.assigned_slots(prefix)
	local out = {}
	for _, slot in ipairs(M.available_slots(prefix)) do
		local action = _actions[slot.id]
		if action and action ~= "none" then
			out[#out + 1] = { id = slot.id, label = slot.label, action = action }
		end
	end
	return out
end

--- Configures the action for a slot without replacing an already-owned chord.
--- Persists the assignment in hs.settings so it survives reloads.
--- @param slot_id string
--- @param action_id string
function M.set_action(slot_id, action_id)
	if type(slot_id) ~= "string" or type(action_id) ~= "string" then
		Logger.error(LOG, "set_action(): both arguments must be strings.")
		return false
	end
	local old_action = _actions[slot_id] or "none"
	if old_action == action_id then return true end

	local setting_key = _settings_prefix .. slot_id
	local snap_ok, persisted_snapshot = read_setting(setting_key)
	if not snap_ok then return false end

	local native_transition = nil
	if _started and old_action == "none" and action_id ~= "none" then
		if bind_slot(slot_id, action_id) ~= true then return false end
		native_transition = "enabled"
	elseif _started and old_action ~= "none" and action_id == "none" then
		if set_slot_enabled(slot_id, false) ~= true then return false end
		native_transition = "disabled"
	end

	if persist_setting(setting_key, action_id, persisted_snapshot) ~= true then
		if native_transition == "enabled" then
			if set_slot_enabled(slot_id, false) ~= true then
				Logger.error(LOG,
					"Slot '%s' publication rollback is incomplete; retained handle remains fenced for retry.",
					slot_id)
			end
		elseif native_transition == "disabled" then
			if set_slot_enabled(slot_id, true) ~= true then
				Logger.error(LOG,
					"Slot '%s' rollback could not restore delivery; exact handle retained for retry.",
					slot_id)
			end
		end
		return false
	end

	_actions[slot_id] = action_id
	Logger.debug(LOG, "Slot '%s' → '%s' persisted.", slot_id, action_id)

	return true
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

--- Starts the keyboard shortcuts module and owns every configured binding.
--- @return boolean committed True only when every required slot was bound.
function M.start()
	if _started then
		Logger.debug(LOG, "M.start() called again after menu-state synchronization; bindings already active.")
		return true
	end
	if next(_hotkeys) ~= nil and M.stop() ~= true then
		Logger.error(LOG, "Keyboard shortcuts cannot start while native cleanup is pending.")
		return false
	end
	Logger.start(LOG, "Starting keyboard shortcuts…")
	local assignments_ok, assignments_err = xpcall(load_assignments, debug.traceback)
	if not assignments_ok then
		Logger.error(LOG, "Keyboard shortcut assignments could not be loaded: %s.",
			tostring(assignments_err))
		return false
	end
	for slot, action in pairs(_actions) do
		if action ~= "none" and bind_slot(slot, action) ~= true then
			Logger.error(LOG, "Keyboard shortcuts startup rolled back after slot '%s'.", slot)
			M.stop()
			return false
		end
	end
	_started = true
	local count = 0
	for _ in pairs(_hotkeys) do count = count + 1 end
	Logger.success(LOG, "Keyboard shortcuts started (%d active binding(s)).", count)
	return true
end

--- Stops the keyboard shortcuts module and releases all hotkeys.
--- @return boolean settled True only when every native owner was released.
function M.stop()
	if not _started and next(_hotkeys) == nil then
		Logger.debug(LOG, "stop() called before start() — nothing to stop.")
		return true
	end
	Logger.start(LOG, "Stopping keyboard shortcuts…")
	_started = false
	local slots = {}
	for slot in pairs(_hotkeys) do slots[#slots + 1] = slot end
	local settled = true
	for _, slot in ipairs(slots) do
		if unbind_slot(slot) ~= true then settled = false end
	end
	if not settled then
		Logger.error(LOG, "Keyboard shortcuts stop is incomplete and remains retryable.")
		return false
	end
	Logger.success(LOG, "Keyboard shortcuts stopped.")
	return true
end

return M
