--- modules/shortcuts/keyboard_shortcuts.lua

--- ==============================================================================
--- MODULE: Configurable Keyboard Shortcuts (Linux)
--- DESCRIPTION:
--- The user's own modifier chords, bound to the same action catalogue the
--- gestures use. A slot is a modifier prefix plus a key — `ctrl_shift_p` — and
--- the user assigns an action to it from the tray menu.
---
--- WHY THIS DRIVER HAD NONE:
--- `keyboard_slots` is a manifest row restricted to Windows and macOS, and the
--- reason written beside it was accurate: this driver had no chord capture and
--- nowhere to store an assignment. The hook reported every modified keystroke as
--- the bare string "shortcut" — enough to tell the engine the caret had moved,
--- and not enough to say WHICH shortcut, so there was nothing to match and
--- nothing to record. `keylogger.record_shortcut` existed and had no caller for
--- the same reason.
---
--- FEATURES & RATIONALE:
--- 1. The key space is the shared catalogue. `_shared/modules/actions/
---    modifier_chords.json` already lists the forty keys the gesture actions and
---    the Windows driver use; a private list here would be a fourth answer to
---    "which keys exist".
--- 2. The ACTION space is the gestures manager's. One catalogue, one executor,
---    one set of labels — a shortcut that ran a second implementation of
---    "select the word" would drift from the gesture that runs the first.
--- 3. No default bindings. Every slot starts unassigned, for the same reason the
---    gesture slots do: a desktop environment already owns most modifier chords,
---    and a binding the user did not ask for fires alongside the one they
---    expected with nothing on screen to explain it.
--- 4. Matching happens here, not in the kernel. There is no userland API on Linux
---    to reserve a chord — the daemon already sees every key, so it decides. The
---    consequence is that a bound chord ALSO reaches the focused application,
---    which is why nothing is bound by default and why the labels say what they
---    do rather than promising exclusivity.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Paths = require("infra.paths")

local LOG = "modules.shortcuts.keyboard_shortcuts"

-- The modifier prefixes a slot id can start with, longest first.
--
-- Ordered, and iterated with ipairs: "ctrl_shift_x" also starts with "ctrl_",
-- so a shorter prefix reached first would resolve the wrong chord. macOS keeps
-- the same list in the same order for the same reason.
--
-- No `cmd`: there is no command key on a PC keyboard. `super` is what the key
-- between Ctrl and Alt is called on Linux, and calling it cmd here would put a
-- label on screen that names a key the user does not have.
local SLOT_MODS = {
	{ "ctrl_shift_", { "ctrl", "shift" } },
	{ "super_shift_", { "meta", "shift" } },
	{ "alt_shift_", { "alt", "shift" } },
	{ "ctrl_", { "ctrl" } },
	{ "super_", { "meta" } },
	{ "alt_", { "alt" } },
}

-- What each modifier is drawn as in a menu label. Words rather than symbols:
-- Linux desktops have no single convention for modifier glyphs, and a symbol
-- the user's other applications do not use is a puzzle rather than a shorthand.
local MOD_LABELS = {
	ctrl = "Ctrl",
	shift = "Maj",
	alt = "Alt",
	meta = "Super",
}

-- Suffixes that name a key rather than spelling it.
local SPECIAL_KEYS = {
	space = "Espace",
	enter = "Entrée",
	period = ".",
	comma = ",",
}

-- The groups the menu offers, in display order. Every prefix here must be one
-- of SLOT_MODS' prefixes: a group whose prefix is not there would offer rows
-- that resolve to no chord at all.
M.SLOT_GROUPS = {
	{ prefix = "ctrl_", group_key = "menu.shortcuts.ctrl_group", add_key = "menu.shortcuts.ctrl_add" },
	{ prefix = "ctrl_shift_", group_key = "menu.shortcuts.ctrl_shift_group", add_key = "menu.shortcuts.ctrl_shift_add" },
	{ prefix = "alt_", group_key = "menu.shortcuts.alt_group", add_key = "menu.shortcuts.alt_add" },
}

-- Where the assignments live. One key per slot rather than one blob, so a
-- corrupt entry costs one binding instead of all of them.
local PREF_PREFIX = "shortcuts.keyboard."

-- The shared key catalogue.
local CATALOGUE_REL_PATH = "modules/actions/modifier_chords.json"

-- Decoded once. `false` after a failed read, so a missing catalogue is reported
-- once rather than on every menu rebuild.
local _catalogue = nil

-- slot_id → action_id, for the slots the user has assigned.
local _assignments = {}

-- Whether the assignments have been read back from storage.
local _loaded = false




-- =========================================
-- =========================================
-- ======= 1/ The key catalogue ============
-- =========================================
-- =========================================

--- The ordered key entries from the shared catalogue.
--- @return table|nil
local function catalogue_keys()
	if _catalogue == false then return nil end
	if _catalogue ~= nil then return _catalogue end

	local path = Paths.shared(CATALOGUE_REL_PATH)
	if not path then
		_catalogue = false
		Logger.error(LOG, "Cannot locate the shared tree — no key catalogue, so no slots are offered.")
		return nil
	end
	local handle = io.open(path, "r")
	if not handle then
		_catalogue = false
		Logger.error(LOG, "Cannot read '%s' — no slots are offered.", path)
		return nil
	end
	local body = handle:read("*a")
	handle:close()

	local ok_json, Json = pcall(require, "json")
	if not ok_json then
		_catalogue = false
		Logger.error(LOG, "No JSON decoder — the key catalogue cannot be read.")
		return nil
	end
	local ok, parsed = pcall(Json.decode, body)
	if not ok or type(parsed) ~= "table" or type(parsed.keys) ~= "table" then
		_catalogue = false
		Logger.error(LOG, "The key catalogue at '%s' is malformed — no slots are offered.", path)
		return nil
	end
	_catalogue = parsed.keys
	Logger.debug(LOG, "Key catalogue loaded (%d key(s)).", #_catalogue)
	return _catalogue
end




-- =========================================
-- =========================================
-- ======= 2/ Slots ========================
-- =========================================
-- =========================================

--- Splits a slot id into its modifier list and its key suffix.
--- @param slot_id string
--- @return table|nil mods, string|nil suffix
local function split_slot(slot_id)
	if type(slot_id) ~= "string" then return nil, nil end
	for _, entry in ipairs(SLOT_MODS) do
		local prefix, mods = entry[1], entry[2]
		if slot_id:sub(1, #prefix) == prefix then
			return mods, slot_id:sub(#prefix + 1)
		end
	end
	return nil, nil
end

--- The label a menu row shows for a slot, e.g. "Ctrl Maj P".
--- @param slot_id string
--- @return string
function M.get_slot_label(slot_id)
	local mods, suffix = split_slot(slot_id)
	if not mods then return tostring(slot_id) end
	local parts = {}
	for _, mod in ipairs(mods) do parts[#parts + 1] = MOD_LABELS[mod] or mod end
	local key_label = SPECIAL_KEYS[suffix]
	if not key_label then
		for _, entry in ipairs(catalogue_keys() or {}) do
			if entry.id == suffix then key_label = entry.label end
		end
	end
	parts[#parts + 1] = key_label or (suffix:sub(1, 1):upper() .. suffix:sub(2))
	return table.concat(parts, " ")
end

--- The modifier set a chord must hold EXACTLY for a slot to match.
---
--- Exactly, not at least: Ctrl+Shift+P is not Ctrl+P with something extra held.
--- Matching a subset would make the first binding the user creates swallow every
--- longer chord that starts the same way.
--- @param slot_id string
--- @return table|nil { ctrl?, shift?, alt?, meta? }
local function required_modifiers(slot_id)
	local mods = split_slot(slot_id)
	if not mods then return nil end
	local set = {}
	for _, mod in ipairs(mods) do set[mod] = true end
	return set
end




-- =========================================
-- =========================================
-- ======= 3/ Assignments ==================
-- =========================================
-- =========================================

--- Reads every stored assignment. Idempotent.
local function load_assignments()
	if _loaded then return end
	_loaded = true
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage or type(Storage.keys) ~= "function" then return end
	local count = 0
	for _, key in ipairs(Storage.keys()) do
		if key:sub(1, #PREF_PREFIX) == PREF_PREFIX then
			local slot = key:sub(#PREF_PREFIX + 1)
			local action = Storage.get(key, nil)
			if type(action) == "string" and action ~= "" and action ~= "none" then
				_assignments[slot] = action
				count = count + 1
			end
		end
	end
	Logger.info(LOG, "Keyboard shortcut assignments loaded (%d bound).", count)
end

--- Every assignment the user has made.
--- @return table slot_id → action_id
function M.get_assignments()
	load_assignments()
	local copy = {}
	for slot, action in pairs(_assignments) do copy[slot] = action end
	return copy
end

--- The action bound to a slot, or "none".
--- @param slot_id string
--- @return string
function M.get_action(slot_id)
	load_assignments()
	return _assignments[slot_id] or "none"
end

--- Binds a slot to an action, or clears it with "none".
--- @param slot_id string
--- @param action_id string
--- @return boolean Whether the assignment was stored.
function M.set_action(slot_id, action_id)
	if not required_modifiers(slot_id) then
		Logger.error(LOG, "set_action(): '%s' is not a slot this driver knows — nothing bound.",
			tostring(slot_id))
		return false
	end
	load_assignments()

	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then
		Logger.error(LOG, "set_action(): no storage — '%s' would be forgotten at the next start.", slot_id)
		return false
	end

	if type(action_id) ~= "string" or action_id == "" or action_id == "none" then
		if not Storage.delete(PREF_PREFIX .. slot_id) then
			Logger.error(LOG, "set_action(): could not persist the removal of '%s'.", slot_id)
			return false
		end
		_assignments[slot_id] = nil
		Logger.info(LOG, "Unbound %s.", M.get_slot_label(slot_id))
		return true
	end

	if not Storage.set(PREF_PREFIX .. slot_id, action_id) then
		Logger.error(LOG, "set_action(): could not persist '%s'.", slot_id)
		return false
	end
	_assignments[slot_id] = action_id
	Logger.info(LOG, "Bound %s → %s.", M.get_slot_label(slot_id), action_id)
	return true
end

--- Every slot a group offers, whether bound or not.
--- @param prefix string One of SLOT_GROUPS' prefixes.
--- @return table Array of slot ids.
function M.available_slots(prefix)
	local out = {}
	for _, entry in ipairs(catalogue_keys() or {}) do
		if type(entry.id) == "string" then out[#out + 1] = prefix .. entry.id end
	end
	return out
end

--- The slots of a group the user has actually bound.
--- @param prefix string
--- @return table Array of slot ids, sorted so the menu order is stable.
function M.assigned_slots(prefix)
	load_assignments()
	local out = {}
	for slot in pairs(_assignments) do
		if slot:sub(1, #prefix) == prefix then out[#out + 1] = slot end
	end
	table.sort(out)
	return out
end




-- =========================================
-- =========================================
-- ======= 4/ Dispatch =====================
-- =========================================
-- =========================================

--- Runs the action bound to the chord that was just pressed, if any.
---
--- Called from the daemon's control-key callback with what the hook reported.
--- Returns whether anything fired, so the caller can tell an unbound chord from
--- a handled one — the difference matters for the metrics, not for the user.
--- @param detail table|nil { key = string, mods = table } from the hook.
--- @return boolean fired, string|nil slot_id
function M.dispatch(detail)
	if type(detail) ~= "table" then return false, nil end
	local key = detail.key
	local held = type(detail.mods) == "table" and detail.mods or {}
	if type(key) ~= "string" or key == "" then return false, nil end
	load_assignments()

	for slot, action in pairs(_assignments) do
		local mods, suffix = split_slot(slot)
		if mods and suffix == key then
			-- Every required modifier held, and no other. AltGr is excluded from
			-- the comparison because it selects a layout level rather than forming
			-- a chord: on a French layout the user holds it to type "@", and a
			-- shortcut that fired on that would be unusable.
			local required = required_modifiers(slot)
			local matches = true
			for _, name in ipairs({ "ctrl", "shift", "alt", "meta" }) do
				if (required[name] == true) ~= (held[name] == true) then matches = false end
			end
			if matches then
				Logger.debug(LOG, "Keyboard shortcut fired: %s → %s.", slot, action)
				local ok_gestures, Gestures = pcall(require, "modules.gestures.manager")
				if ok_gestures and type(Gestures.execute_action) == "function" then
					pcall(Gestures.execute_action, action, "keyboard__" .. slot)
				else
					Logger.error(LOG,
						"No action executor — '%s' is bound to %s and cannot run.", slot, action)
				end
				return true, slot
			end
		end
	end
	return false, nil
end

--- The chord a slot represents, as a string for the metrics.
---
--- Persisted as the shortcut's identity, so the dashboard groups two presses of
--- the same chord together whatever the user has bound to it at the time.
--- @param detail table { key, mods }
--- @return string|nil
function M.chord_name(detail)
	if type(detail) ~= "table" or type(detail.key) ~= "string" then return nil end
	local held = type(detail.mods) == "table" and detail.mods or {}
	local parts = {}
	-- Fixed order, so Ctrl+Shift+P and Shift+Ctrl+P are one row rather than two.
	for _, name in ipairs({ "ctrl", "alt", "meta", "shift" }) do
		if held[name] then parts[#parts + 1] = MOD_LABELS[name] or name end
	end
	if #parts == 0 then return nil end
	parts[#parts + 1] = detail.key
	return table.concat(parts, "+")
end

--- Test seam: forgets what was loaded so a fresh storage can be read.
function M._reset()
	_assignments = {}
	_loaded = false
	_catalogue = nil
end

return M
