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
local function bind_slot(slot_id, action_id)
	if action_id == "none" then return end
	local chord = slot_to_chord(slot_id)
	if not chord then
		Logger.debug(LOG, "Slot '%s' has no valid chord mapping — skipped.", slot_id)
		return
	end
	local handle = Registrar.bind(chord, function()
		Logger.debug(LOG, "Keyboard shortcut fired: %s → %s.", slot_id, action_id)
		pcall(GestActions.execute_single, action_id, "keyboard__" .. slot_id)
	end)
	if handle then
		_hotkeys[slot_id] = handle
		Logger.done(LOG, "Bound %s → %s.", slot_label(slot_id), action_id)
	else
		Logger.warn(LOG, "Failed to bind slot '%s' (chord: %s).", slot_id, chord)
	end
end

--- Releases the hotkey for a slot if active.
--- @param slot_id string
local function unbind_slot(slot_id)
	local handle = _hotkeys[slot_id]
	if handle then
		Registrar.unbind(handle)
		_hotkeys[slot_id] = nil
	end
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
	if _started then
		Logger.debug(LOG, "M.start() called again after menu-state synchronization; bindings already active.")
		return
	end
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
	if not _started then
		Logger.warn(LOG, "stop() called before start() — nothing to stop.")
		return
	end
	Logger.start(LOG, "Stopping keyboard shortcuts…")
	for slot in pairs(_hotkeys) do
		unbind_slot(slot)
	end
	_started = false
	Logger.success(LOG, "Keyboard shortcuts stopped.")
end

return M
