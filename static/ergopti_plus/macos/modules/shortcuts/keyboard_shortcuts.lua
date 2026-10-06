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
--- 2. Manifest Defaults: absent assignments remain neutral. Canonical choices
---    in config.toml are visible even with the master stopped; only start()
---    acquires native chords for explicitly assigned catalogue slots.
--- 3. Registrar Lifecycle: bindings are created by start(), released by stop(),
---    and rebuilt after any assignment change + reload. The OS call itself lives
---    in adapters/hotkey_registrar.lua, so this module never names hs.hotkey.
--- ==============================================================================

local M = {}

local JsonCodec   = require("adapters.json_codec")
local Chord       = require("chord")
local Registrar   = require("adapters.hotkey_registrar")
local FileSystem  = require("adapters.file_system")
local Paths       = require("infra.paths")
local Logger      = require("infra.logger")
local GestActions = nil
local Codec       = require("toml_codec")
local Writer      = require("toml_codec.writer")
local Preferences = require("infra.preferences")
local ConfigPaths = require("infra.config_paths")
local Manifest    = require("infra.manifest_reader")
local ConfigOutdated = require("config_outdated")
local MagicPolicy = require("shortcuts.magic_editor")
local KeyboardPublication = require("config_keyboard_publication")
local Assignment = require("shortcuts.assignment")
local i18n = require("infra.i18n")

local LOG = "shortcuts.keyboard_shortcuts"

-- Ownership inspection needs only key identities; action initialization belongs
-- to assignment validation and delivery, not the cleanup reader.
local function action_catalogue()
	if GestActions == nil then GestActions = require("modules.gestures.actions") end
	return GestActions
end

-- The binding a slot's action is dispatched under. Action parameters are stored
-- under it too, so a menu that asks for one must use this spelling.
local BINDING_PREFIX = "keyboard__"

local _hotkeys   = {}  -- slot_id → registrar handle
local _actions   = {}  -- slot_id → action_id
local _started   = false
local _loaded    = false
local _editing = false
local _delivery_enabled = false
local _lifecycle_paused = false
local _lifecycle_epoch = 0
local _start_attempt = nil
local _native_acquisition_depth = 0
local _explicit_actions = {}
local _physical_assignments = {}
local _magic_context = nil
local _magic_owner = nil
local _configuration_generation = 0

local function invalidate_lifecycle()
	_lifecycle_epoch = _lifecycle_epoch + 1
end

local function start_is_current(attempt)
	return _start_attempt == attempt
		and _lifecycle_epoch == attempt.epoch
		and _lifecycle_paused ~= true
end





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

-- Resolved from the shared modifier catalogue after its first acknowledged read.
local SLOT_MODS = nil
local SPECIAL_KEYS = nil

-- The groups the menu offers, in display order, each with the i18n keys for its
-- submenu title and its "add a binding" row. Physical groups use SLOT_MODS;
-- the contextual group owns one logical slot whose numeric source is measured.
M.SLOT_GROUPS = {
	{ prefix = "contextual", fixed = true, group_key = "menu.shortcuts.group_contextual", add_key = "menu.shortcuts.add_contextual" },
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

-- The manifest section whose entries are this driver's shipped slot bindings.
-- tools/test/test-keyboard-slot-recommended-bindings.cjs pins what it holds.
local KEYBOARD_SECTION = "shortcuts.keyboard"

--- The shipped bindings: every manifest shortcuts.keyboard entry for macOS (the
--- generated manifest lists only this driver's entries with their defaults).
--- @return table slot_id → action_id
local function manifest_defaults()
	local defaults = {}
	for _, entry in ipairs(Manifest.features()) do
		if entry.section == KEYBOARD_SECTION and type(entry.id) == "string"
			and type(entry.default) == "string" then
			defaults[entry.id] = entry.default
		end
	end
	return defaults
end




-- ====================================
-- ====================================
-- ======= 2/ Slot Resolution =========
-- ====================================
-- ====================================

-- The catalogue, decoded once. Nil until the first read; false once a read has
-- failed, so a missing file is reported once rather than on every menu rebuild.
local _catalogue = nil
local _binding_publication = nil

--- Reads the shared key catalogue.
--- @return table|nil keys The ordered key entries, or nil when unavailable.
local function catalogue_keys()
	if _catalogue == false then return nil end
	if _catalogue == nil then
		local raw = FileSystem.read(KEY_CATALOGUE_PATH)
		local decoded, decode_error = JsonCodec.decode(raw or "")
		if not raw or decode_error or type(decoded) ~= "table" or type(decoded.keys) ~= "table" then
			-- No local fallback list: an unsynchronised private copy of the key
			-- space is exactly what the shared catalogue exists to prevent, so an
			-- unreadable catalogue means an empty picker, not a made-up one.
			Logger.error(LOG, "Shared key catalogue unreadable at %s — no slots can be offered.", tostring(KEY_CATALOGUE_PATH))
			_catalogue = false
			return nil
		end
		local platform = assert(decoded.platforms and decoded.platforms.macos,
			"keyboard modifier catalogue lacks macOS metadata")
		assert(type(platform.shortcut_groups) == "table" and type(platform.modifiers) == "table",
			"keyboard modifier catalogue lacks ordinary shortcut groups")
		local aliases, groups, keys = {}, {}, {}
		for _, modifier in ipairs(platform.modifiers) do
			aliases[modifier.id] = assert(modifier.hammerspoon, "native modifier alias unavailable")
		end
		for _, group in ipairs(platform.shortcut_groups) do
			local mods = {}
			for _, modifier in ipairs(group.modifiers) do
				mods[#mods + 1] = assert(aliases[modifier], "ordinary modifier is not owned")
			end
			groups[#groups + 1] = { group.prefix, mods }
		end
		for _, key in ipairs(decoded.keys) do keys[key.id] = key.chord_key or key.id end
		SLOT_MODS, SPECIAL_KEYS = groups, keys
		_catalogue = decoded
		local admitted, publication = pcall(KeyboardPublication.publish, decoded.keys, SLOT_MODS, MagicPolicy.SLOT_ID)
		if admitted then
			_binding_publication = publication
		else
			Logger.error(LOG, "The complete keyboard source cannot publish its binding catalogue.")
		end
	end
	return _catalogue.keys
end

local function slot_mods()
	assert(catalogue_keys(), "keyboard modifier catalogue unavailable")
	return SLOT_MODS
end

--- Reads the canonical source without migrating or consulting legacy storage.
--- @return table decoded
--- @return table source Exact classification for conditional publication.
local function read_config()
	local content, status, detail = Writer.read_classified(ConfigPaths.get("ConfigTomlPath"), FileSystem)
	assert(status == "ok" or status == "absent", "keyboard configuration unavailable: " .. tostring(detail))
	local decoded = Codec.decode(content or "")
	assert(type(decoded) == "table", "keyboard configuration is malformed")
	return decoded, { status = status, content = content }
end

--- Builds exact host identities from the existing modifier and key catalogues.
--- @return table index Set of canonical slot IDs.
local function owned_slots()
	local keys = assert(catalogue_keys(), "keyboard key catalogue unavailable")
	local index = { [MagicPolicy.SLOT_ID] = true }
	for _, group in ipairs(slot_mods()) do
		for _, key in ipairs(keys) do index[group[1] .. key.id] = true end
	end
	return index
end

--- Visits the stored assignments of the owned slots. A [shortcuts] or
--- keyboard value of another shape in config.toml (an older build's
--- `keyboard = "…"`) is outdated configuration: reported once, walked as empty
--- and left unmarked, never an assertion that stops the whole shortcut layer.
--- A scope candidate is built by the scope itself, so the same shape there is
--- its own failure and is refused.
--- @param decoded table Decoded configuration.
--- @param consume function consume(slot, action).
--- @param candidate boolean|nil True for a scope candidate.
local function walk_assignments(decoded, consume, candidate)
	if candidate then
		assert(decoded.shortcuts == nil or type(decoded.shortcuts) == "table", "shortcuts must be a table")
		assert(decoded.shortcuts == nil or decoded.shortcuts.keyboard == nil
			or type(decoded.shortcuts.keyboard) == "table", "keyboard assignments must be a table")
	end
	local shortcuts = ConfigOutdated.settings_table(decoded.shortcuts, { "shortcuts" }, Logger)
	if shortcuts == nil then return end
	local assignments = ConfigOutdated.settings_table(shortcuts.keyboard, { "shortcuts", "keyboard" }, Logger)
	if assignments == nil then return end
	local known = owned_slots()
	for slot, action in pairs(assignments) do
		if known[slot] then consume(slot, action) end
	end
end

--- Loads a complete canonical candidate before replacing desired assignments.
local function load_assignments(candidate, raw_claims)
	local decoded = candidate
	if decoded == nil then decoded = read_config() end
	assert(type(decoded) == "table", "keyboard candidate must be a table")
	local loaded = manifest_defaults()
	local explicit = {}
	local physical = {}
	walk_assignments(decoded, function(slot, action)
		physical[slot] = action
		if type(action) == "string" and action_catalogue().is_assignable(action) then
			loaded[slot] = action
			explicit[slot] = action
		else
			assert(candidate == nil, "keyboard candidate contains an invalid action")
			-- Outdated configuration: the slot keeps its manifest action, and
			-- the entry is named once (the cleanup reports the same detail)
			-- and offered by the cleanup.
			local _, detail = Preferences.action_is_retired(action)
			ConfigOutdated.report({ "shortcuts", "keyboard", slot },
				detail or ("action '" .. tostring(action) .. "' no longer exists"), Logger)
		end
	end, candidate ~= nil)
	if raw_claims ~= nil then
		assert(type(raw_claims) == "table", "keyboard raw claims must be a table")
		local known = owned_slots()
		for slot, claimed in pairs(raw_claims) do
			assert(known[slot] and claimed == true, "keyboard raw claim is not owned")
			if physical[slot] == nil then physical[slot] = false end
		end
	end
	_actions, _explicit_actions, _loaded = loaded, explicit, true
	_physical_assignments = physical
	_configuration_generation = _configuration_generation + 1
end

local function ensure_loaded()
	if not _loaded then load_assignments() end
end

--- Marks only exact host slots consumed by the canonical loader.
--- @param decoded table Parsed configuration.
--- @param mark function Segment-based ownership collector.
function M.mark_config_reads(decoded, mark)
	walk_assignments(decoded, function(slot, action)
		-- A retired action is reported and left unmarked, so the cleanup
		-- offers it even when the setup wizard also reads the slot.
		local retired, detail = Preferences.action_is_retired(action)
		if retired then
			ConfigOutdated.report({ "shortcuts", "keyboard", slot }, detail, Logger)
		else
			mark("shortcuts", "keyboard", slot)
		end
	end)
end

--- Lists disk and live owned slots for scoped restore/clear without a namespace sweep.
--- @return table paths Sorted canonical leaf paths.
function M.get_owned_config_paths()
	local decoded, found = read_config(), {}
	walk_assignments(decoded, function(slot) found[slot] = true end)
	local known = owned_slots()
	for slot, action in pairs(_actions) do
		if known[slot] and action ~= "none" then found[slot] = true end
	end
	local result = {}
	for slot in pairs(found) do result[#result + 1] = KEYBOARD_SECTION .. "." .. slot end
	table.sort(result)
	return result
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
	for _, entry in ipairs(slot_mods()) do
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
	if slot_id == MagicPolicy.SLOT_ID then
		local label = i18n.get("menu.shortcuts.keyboard.magic_editor")
		local reason = _magic_owner and _magic_owner.reason()
		if reason then return label .. " (" .. i18n.get("menu.shortcuts.keyboard.magic_editor_reason." .. reason) .. ")" end
		return label
	end
	for _, entry in ipairs(slot_mods()) do
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

local function refresh_claims(assignments)
	if _magic_context == nil then return true end
	local rows = {}
	for slot, action in pairs(assignments or _physical_assignments) do
		if slot ~= MagicPolicy.SLOT_ID then
			local chord = slot_to_chord(slot)
			if chord then rows[#rows + 1] = {
				chord = chord, action = action, binding_id = BINDING_PREFIX .. slot,
			} end
		end
	end
	return Registrar.replace_physical_claims(LOG, rows)
end

local function start_magic(action)
	if _magic_context == nil then return true end
	if _magic_owner == nil then _magic_owner = require("modules.shortcuts.magic_editor") end
	local epoch = _lifecycle_epoch
	local context = {}
	for key, value in pairs(_magic_context) do context[key] = value end
	context.assignment_unavailable = action == nil and _physical_assignments[MagicPolicy.SLOT_ID] ~= nil
	return _magic_owner.start({
		action = action,
		configuration_generation = _configuration_generation,
		context = context,
		is_action = action_catalogue().is_assignable,
		is_current = function()
			return _lifecycle_epoch == epoch and _lifecycle_paused ~= true
				and (_started and _delivery_enabled or _start_attempt ~= nil)
		end,
		execute = function(action_id, binding)
			if _editing or _started ~= true or _delivery_enabled ~= true or _lifecycle_paused == true then return false end
			local ok, handled = Logger.callback(LOG, "Conditional configurable shortcut",
				action_catalogue().execute_single, action_id, binding)
			return ok and handled == true
		end,
	})
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
		local retained_handle = _hotkeys[slot_id]
		local acquisition_epoch = _lifecycle_epoch
		_native_acquisition_depth = _native_acquisition_depth + 1
		local ok_enable, enabled = xpcall(Registrar.setEnabled, debug.traceback,
			retained_handle, true)
		_native_acquisition_depth = _native_acquisition_depth - 1
		if ok_enable and enabled == true
			and _lifecycle_paused ~= true
			and _lifecycle_epoch == acquisition_epoch then return true end
		if _lifecycle_paused == true or _lifecycle_epoch ~= acquisition_epoch then
			local ok_release, released = xpcall(
				Registrar.unbind, debug.traceback, retained_handle)
			if ok_release and released == true
				and _hotkeys[slot_id] == retained_handle then
				_hotkeys[slot_id] = nil
			end
		end
		Logger.error(LOG, "Failed to re-enable retained slot '%s': %s.",
			slot_id, tostring(enabled))
		return false
	end
	local chord = slot_to_chord(slot_id)
	if not chord then
		Logger.error(LOG, "Slot '%s' has no valid chord mapping — startup refused.", slot_id)
		return false
	end
	local acquisition_epoch = _lifecycle_epoch
	_native_acquisition_depth = _native_acquisition_depth + 1
	local ok_bind, handle = xpcall(Registrar.bind, debug.traceback, chord, function()
		if _delivery_enabled ~= true or _lifecycle_paused == true then return false end
		local current_action = _actions[slot_id] or "none"
		if current_action == "none" then
			Logger.debug(LOG, "Ignored inactive configurable shortcut slot '%s'.", slot_id)
			return false
		end
		Logger.debug(LOG, "Keyboard shortcut fired: %s → %s.", slot_id, current_action)
		local ok_action, handled = Logger.callback(LOG,
			"Configurable shortcut '" .. tostring(slot_id) .. "'",
			action_catalogue().execute_single, current_action, M.binding_id(slot_id))
		if not ok_action then return false end
		if handled ~= true then
			Logger.error(LOG, "Configurable shortcut '%s' was not handled by action '%s'.",
				tostring(slot_id), tostring(current_action))
			return false
		end
		return true
	end)
	_native_acquisition_depth = _native_acquisition_depth - 1
	if ok_bind and handle then
		_hotkeys[slot_id] = handle
		if _lifecycle_paused == true or _lifecycle_epoch ~= acquisition_epoch then
			local ok_release, released = xpcall(
				Registrar.unbind, debug.traceback, handle)
			if ok_release and released == true then _hotkeys[slot_id] = nil end
			Logger.error(LOG,
				"Slot '%s' acquisition was superseded; exact candidate retained only on cleanup refusal.",
				tostring(slot_id))
			return false
		end
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
	ensure_loaded()
	return _actions
end

--- Captures raw owned intent separately from resolved neutral defaults.
--- Invalid raw choices retain a claim without becoming executable actions.
--- @return table assignments Detached valid explicit actions.
--- @return table claims Detached physical-presence identities.
function M.get_configuration_intent()
	ensure_loaded()
	local assignments, claims = {}, {}
	for slot, action in pairs(_explicit_actions) do assignments[slot] = action end
	for slot in pairs(_physical_assignments) do claims[slot] = true end
	return assignments, claims
end

--- Returns the current action id for a given slot.
--- @param slot_id string
--- @return string action_id or "none".
function M.get_action(slot_id)
	ensure_loaded()
	return _actions[slot_id] or "none"
end

--- Returns a human-readable label for a slot.
--- @param slot_id string
--- @return string
function M.get_slot_label(slot_id)
	return slot_label(slot_id)
end

--- The chord a slot binds, as canonical modifier names and key name.
--- @param slot_id string
--- @return table|nil mods, string|nil key Nil when the slot has no known prefix.
function M.get_slot_chord(slot_id)
	if slot_id == MagicPolicy.SLOT_ID then return { "ctrl" }, nil end
	if type(slot_id) ~= "string" then return nil, nil end
	for _, entry in ipairs(slot_mods()) do
		local prefix, mods = entry[1], entry[2]
		if slot_id:sub(1, #prefix) == prefix then
			local suffix = slot_id:sub(#prefix + 1)
			return mods, SPECIAL_KEYS[suffix] or suffix
		end
	end
	return nil, nil
end

--- Lists every slot a group can offer, in catalogue order.
--- Each entry is { id, label } ready for the picker. An unknown prefix yields an
--- empty list rather than the whole key space, so a typo in a group definition
--- shows as a group with nothing in it instead of five identical groups.
--- @param prefix string One of M.SLOT_GROUPS' prefixes.
--- @return table
function M.available_slots(prefix)
	if prefix == "contextual" then
		return { { id = MagicPolicy.SLOT_ID, label = slot_label(MagicPolicy.SLOT_ID) } }
	end
	local known = false
	for _, entry in ipairs(slot_mods()) do
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
	ensure_loaded()
	if prefix == "contextual" then
		return { { id = MagicPolicy.SLOT_ID, label = slot_label(MagicPolicy.SLOT_ID),
			action = _actions[MagicPolicy.SLOT_ID] or "none" } }
	end
	local out = {}
	for _, slot in ipairs(M.available_slots(prefix)) do
		local action = _actions[slot.id]
		if action and action ~= "none" then
			out[#out + 1] = { id = slot.id, label = slot.label, action = action }
		end
	end
	return out
end

--- The binding a slot's action is dispatched under, and its parameter stored under.
--- @param slot_id string
--- @return string
function M.binding_id(slot_id)
	return BINDING_PREFIX .. tostring(slot_id)
end

--- Configures the action for a slot without replacing an already-owned chord.
--- Publishes the canonical sparse assignment only after native admission.
--- @param slot_id string
--- @param action_id string
local function set_action(slot_id, action_id)
	if type(slot_id) ~= "string" or type(action_id) ~= "string" then
		Logger.error(LOG, "set_action(): both arguments must be strings.")
		return false
	end
	-- The same catalogue check the gesture slots and the Windows driver apply: an
	-- unknown id would be persisted, bound, and then do nothing on every press.
	if not action_catalogue().is_assignable(action_id) then
		Logger.warn(LOG, "set_action(): refusing unknown action '%s' for slot '%s'.", action_id, slot_id)
		return false
	end
	if _lifecycle_paused == true or _start_attempt ~= nil then return false end
	if not owned_slots()[slot_id] then return false end
	ensure_loaded()
	local old_action = _actions[slot_id] or "none"
	local _, source = read_config()
	local operation = Assignment.operation(slot_id, action_id, function(id)
		return owned_slots()[id] == true
	end, action_catalogue().is_assignable)
	local rows = Preferences.prepare_shortcut_updates(source, { operation }, { "keyboard" })

	local native_transition = nil
	local conditional = slot_id == MagicPolicy.SLOT_ID
	if _started and not conditional and old_action == "none" and action_id ~= "none" then
		if bind_slot(slot_id, action_id) ~= true then return false end
		native_transition = "enabled"
	elseif _started and not conditional and old_action ~= "none" and action_id == "none" then
		if set_slot_enabled(slot_id, false) ~= true then return false end
		native_transition = "disabled"
	end

	local candidate_explicit = operation.delete ~= true and action_id or nil
	local previous_physical = _physical_assignments[slot_id]
	_physical_assignments[slot_id] = candidate_explicit
	_configuration_generation = _configuration_generation + 1
	local candidate_magic = _explicit_actions[MagicPolicy.SLOT_ID]
	if conditional then candidate_magic = candidate_explicit end
	local function restore_conditional()
		_physical_assignments[slot_id] = previous_physical
		_configuration_generation = _configuration_generation + 1
		refresh_claims()
		if _started and start_magic(_explicit_actions[MagicPolicy.SLOT_ID]) ~= true then
			Logger.error(LOG, "Conditional shortcut publication rollback has native cleanup debt.")
		end
	end
	local conditional_admitted = refresh_claims() == true
		and (not _started or start_magic(candidate_magic) == true)
	if not conditional_admitted
		or Preferences.publish_owned(ConfigPaths.get("ConfigTomlPath"), rows, source) ~= true then
		restore_conditional()
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
	_explicit_actions[slot_id] = candidate_explicit
	Logger.debug(LOG, "Slot '%s' → '%s' persisted.", slot_id, action_id)

	return true
end

--- Serializes one domain edit across native acquisition and exact-source publication.
--- @param slot_id string Canonical catalogue slot.
--- @param action_id string Catalogue action identifier.
--- @return boolean committed
function M.set_action(slot_id, action_id)
	if _editing then return false end
	_editing = true
	local called, committed = xpcall(set_action, debug.traceback, slot_id, action_id)
	_editing = false
	if not called then Logger.error(LOG, "Keyboard assignment failed: %s.", tostring(committed)) end
	return called and committed == true
end

--- Stages exact native intent while the input owner is quiescent. No file is published.
--- @param decoded table Complete candidate configuration.
--- @param raw_claims table|nil Detached owned physical-presence snapshot.
--- @return boolean committed
function M.apply_configuration(decoded, raw_claims)
	if type(decoded) ~= "table" or _editing or _started or _start_attempt ~= nil
		or _native_acquisition_depth ~= 0 or next(_hotkeys) ~= nil then return false end
	if _magic_owner and _magic_owner.stop() ~= true then return false end
	_editing = true
	local called, detail = xpcall(load_assignments, debug.traceback, decoded, raw_claims)
	_editing = false
	if not called then Logger.error(LOG, "Keyboard candidate was refused: %s.", tostring(detail)) end
	return called
end

--- Reports actual native ownership, independently of desired assignment state.
--- @return boolean started
function M.is_started()
	return _started and _delivery_enabled
end

--- Supplies live editor-source gates without owning a second UI hotkey.
--- @param context table Native trigger, physical replacement and lifecycle readers.
--- @return boolean applied
function M.configure_magic_editor(context)
	if type(context) ~= "table" then return false end
	for _, key in ipairs({ "trigger", "magic_source", "replace_active", "paused", "inhibited" }) do
		if type(context[key]) ~= "function" then return false end
	end
	_magic_context = context
	_configuration_generation = _configuration_generation + 1
	if refresh_claims() ~= true then return false end
	if _started then return start_magic(_explicit_actions[MagicPolicy.SLOT_ID]) end
	return true
end

--- Retargets the contextual owner after an acknowledged effective-source edit.
--- A stopped category remains stopped; no setting or native owner is invented.
--- @return boolean accepted
function M.refresh_magic_editor()
	if not _started or _magic_context == nil then return true end
	_configuration_generation = _configuration_generation + 1
	return start_magic(_explicit_actions[MagicPolicy.SLOT_ID])
end

--- Starts the keyboard shortcuts module and owns every configured binding.
--- @param candidate table|nil Validated transaction source; nil reads the canonical file.
--- @param raw_claims table|nil Detached owned physical-presence snapshot.
--- @return boolean committed True only when every required slot was bound.
function M.start(candidate, raw_claims)
	if candidate ~= nil and type(candidate) ~= "table" then return false end
	if _editing then return false end
	if _started and candidate ~= nil then return false end
	if _lifecycle_paused == true or _start_attempt ~= nil then
		_delivery_enabled = false
		return false
	end
	if _started then
		_delivery_enabled = true
		Logger.debug(LOG, "M.start() called again after menu-state synchronization; bindings already active.")
		return true
	end
	if next(_hotkeys) ~= nil and M.stop() ~= true then
		Logger.error(LOG, "Keyboard shortcuts cannot start while native cleanup is pending.")
		return false
	end
	if _lifecycle_paused == true then return false end
	local attempt = { epoch = _lifecycle_epoch }
	_start_attempt = attempt
	_delivery_enabled = false
	Logger.start(LOG, "Starting keyboard shortcuts…")
	local assignments_ok, assignments_err = xpcall(load_assignments, debug.traceback, candidate, raw_claims)
	if not assignments_ok then
		Logger.error(LOG, "Keyboard shortcut assignments could not be loaded: %s.",
			tostring(assignments_err))
		if _start_attempt == attempt then _start_attempt = nil end
		return false
	end
	if not start_is_current(attempt) then
		M.stop()
		return false
	end
	if refresh_claims() ~= true then M.stop(); return false end
	for slot, action in pairs(_actions) do
		if slot ~= MagicPolicy.SLOT_ID and action ~= "none" and bind_slot(slot, action) ~= true then
			Logger.error(LOG, "Keyboard shortcuts startup rolled back after slot '%s'.", slot)
			M.stop()
			return false
		end
		if not start_is_current(attempt) then
			Logger.error(LOG,
				"Keyboard shortcuts startup superseded during slot '%s'.", tostring(slot))
			M.stop()
			return false
		end
	end
	if start_magic(_explicit_actions[MagicPolicy.SLOT_ID]) ~= true then M.stop(); return false end
	if not start_is_current(attempt) then
		M.stop()
		return false
	end
	_started = true
	_delivery_enabled = true
	_start_attempt = nil
	local count = 0
	for _ in pairs(_hotkeys) do count = count + 1 end
	Logger.success(LOG, "Keyboard shortcuts started (%d active binding(s)).", count)
	return true
end

--- Stops the keyboard shortcuts module and releases all hotkeys.
--- @return boolean settled True only when every native owner was released.
function M.stop()
	_delivery_enabled = false
	invalidate_lifecycle()
	_start_attempt = nil
	local conditional_settled = _magic_owner == nil or _magic_owner.stop() == true
	if not _started and next(_hotkeys) == nil and _native_acquisition_depth == 0 and conditional_settled then
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
	if _native_acquisition_depth ~= 0 or not settled or not conditional_settled then
		Logger.error(LOG, "Keyboard shortcuts stop is incomplete and remains retryable.")
		return false
	end
	Logger.success(LOG, "Keyboard shortcuts stopped.")
	return true
end

--- Admission-authoritative PAUSE edge used by the aggregate shortcuts owner.
function M.pause()
	_lifecycle_paused = true
	_delivery_enabled = false
	invalidate_lifecycle()
	_start_attempt = nil
	return M.stop()
end

--- Releases the local PAUSE fence and starts one guarded replacement set.
function M.resume_after_pause(candidate, raw_claims)
	_lifecycle_paused = false
	invalidate_lifecycle()
	return M.start(candidate, raw_claims)
end

--- Releases only the local PAUSE fence.  The aggregate Shortcuts owner calls
--- this inside its guarded start transaction after all external claims have
--- been checked; stop() itself must not silently reopen a paused subsystem.
function M.release_pause_admission()
	_lifecycle_paused = false
	invalidate_lifecycle()
	return true
end


--- Returns a detached complete native publication without reading or binding input.
--- @return table|nil catalogue Unavailable or withdrawn sources remain unjudged.
function M.published_binding_catalogue()
	if not KeyboardPublication.owner_is_current(M)
		or _binding_publication == nil or type(_catalogue) ~= "table" then return nil end
	return _binding_publication(rawget(_catalogue, "keys"), SLOT_MODS, MagicPolicy.SLOT_ID)
end

KeyboardPublication.register(M, M.published_binding_catalogue)

return M
