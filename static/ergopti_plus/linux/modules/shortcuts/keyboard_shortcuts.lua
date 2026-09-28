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
--- 3. Few default bindings. Ctrl+G keeps the product's cross-driver ChatGPT
---    shortcut, and the manifest's shortcuts.keyboard entries for Linux bind
---    Super+Space to an AI prediction; every other catalogue slot starts
---    unassigned because desktop environments already own many modifier chords.
--- 4. Matching happens here, not in the kernel. There is no userland API on Linux
---    to reserve a chord — the daemon already sees every key, so it decides.
---    Under the grab (the default) a bound chord is claimed in the keyboard
---    hook's consumption callback (consume) and never reaches the focused
---    application. Without the grab only dispatch runs, after the key was
---    forwarded, so the chord ALSO reaches the application there.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Paths = require("infra.paths")
local ChatGPT = require("modules.shortcuts.chatgpt")
local ScriptActions = require("modules.shortcuts.script_actions")
local Manifest = require("infra.manifest_reader")
local Codec = require("toml_codec")
local Writer = require("toml_codec.writer")

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

-- The slot suffix of a key the hook reports by the character it types.
local SUFFIX_OF_IDENTITY = {
	[" "] = "space",
	["."] = "period",
	[","] = "comma",
	["\r"] = "enter",
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
	{ prefix = "super_", group_key = "menu.shortcuts.super_group", add_key = "menu.shortcuts.super_add" },
}

-- The manifest section whose entries are this driver's shipped slot bindings
-- (Super+Space generates an AI prediction).
-- tools/test/test-keyboard-slot-recommended-bindings.cjs pins what it holds.
local KEYBOARD_SECTION = "shortcuts.keyboard"

-- The shared key catalogue.
local CATALOGUE_REL_PATH = "modules/actions/modifier_chords.json"

-- Decoded once. `false` after a failed read, so a missing catalogue is reported
-- once rather than on every menu rebuild.
local _catalogue = nil

-- slot_id → action_id, for the slots the user has assigned.
local _assignments = {}

-- Whether the assignments have been read back from config.toml.
local _loaded = false
local _configuration_owner = nil
local _dispatch_generation = 0

--- Exclusively owns mutations and cancels previously queued actions.
--- @param owner table Exact token retained through runtime compensation.
--- @return boolean acquired
function M.acquire_configuration(owner)
	if type(owner) ~= "table" or _configuration_owner ~= nil then return false end
	_configuration_owner = owner
	_dispatch_generation = _dispatch_generation + 1
	return true
end

--- Releases the same owner without reviving its canceled callbacks.
--- @param owner table Exact acquisition token.
--- @return boolean released
function M.release_configuration(owner)
	if type(owner) ~= "table" or _configuration_owner ~= owner then return false end
	_configuration_owner = nil
	return true
end





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

--- Whether the modifier prefix and key suffix both belong to the catalogue.
--- @param slot_id string Candidate slot identity.
--- @return boolean owned
local function owns_slot(slot_id)
	local mods, suffix = split_slot(slot_id)
	if not mods then return false end
	for _, entry in ipairs(catalogue_keys() or {}) do
		if entry.id == suffix then return true end
	end
	return false
end




-- =========================================
-- =========================================
-- ======= 3/ Assignments ==================
-- =========================================
-- =========================================

--- The gestures manager, whose catalogue decides which action ids a slot may
--- hold. Required lazily: the daemon loads it after this module.
--- @return table|nil The manager, or nil (logged) when its catalogue is unavailable.
local function action_catalogue()
	local ok, Gestures = pcall(require, "modules.gestures.manager")
	if not ok or type(Gestures) ~= "table" or type(Gestures.is_assignable) ~= "function" then
		Logger.error(LOG, "The action catalogue is unavailable: %s", tostring(Gestures))
		return nil
	end
	return Gestures
end

--- The shipped bindings: every manifest shortcuts.keyboard entry for Linux.
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

--- Visits canonical assignments whose chord belongs to this owner.
--- @param decoded table Decoded configuration.
--- @param consume function Consumer receiving slot and stored value.
local function walk_assignments(decoded, consume)
	local shortcuts = type(decoded.shortcuts) == "table" and decoded.shortcuts or {}
	local assignments = type(shortcuts.keyboard) == "table" and shortcuts.keyboard or {}
	for slot, value in pairs(assignments) do
		if owns_slot(slot) then consume(slot, value) end
	end
end

--- Marks the same recognized entries that the runtime reader consumes.
--- @param decoded table Decoded configuration.
--- @param mark function Segment-based ownership collector.
function M.mark_config_reads(decoded, mark)
	walk_assignments(decoded, function(slot) mark("shortcuts", "keyboard", slot) end)
end

--- Reads the manifest defaults, then every stored assignment over them: a
--- stored "none" clears a default the user removed. Idempotent.
local function load_assignments()
	if _loaded then return end
	local path = require("infra.config_paths").config("config.toml")
	local content, status, detail = Writer.read_classified(path)
	if status ~= "ok" and status ~= "absent" then
		error("keyboard_shortcuts: cannot read configuration: " .. tostring(detail))
	end
	local decoded = {}
	if status == "ok" then
		local ok, parsed = pcall(Codec.decode, content)
		if not ok or type(parsed) ~= "table" then
			error("keyboard_shortcuts: malformed configuration: " .. tostring(parsed))
		end
		decoded = parsed
	end
	-- The check set_action applies, applied to what was stored: an id the
	-- catalogue does not offer (hand-edited, or retired by an update) would bind
	-- the chord to a no-op. Windows drops it at load the same way.
	local Gestures = action_catalogue()
	if not Gestures then
		error("Keyboard shortcut assignments not loaded: no catalogue to check them against.")
	end
	local loaded = {}
	for slot, action in pairs(manifest_defaults()) do
		if action ~= "none" then
			if Gestures.is_assignable(action) then
				loaded[slot] = action
			else
				Logger.error(LOG, "Manifest default '%s' for %s is not in the catalogue — left unbound.",
					action, slot)
			end
		end
	end
	walk_assignments(decoded, function(slot, action)
		if action == "none" then
			loaded[slot] = nil
		elseif type(action) == "string" and Gestures.is_assignable(action) then
			loaded[slot] = action
		else
			loaded[slot] = nil
			Logger.warn(LOG, "Keyboard slot '%s' holds unknown action '%s' — left unbound.", slot, tostring(action))
		end
	end)
	_assignments = loaded
	_loaded = true
	local count = 0
	for _ in pairs(_assignments) do count = count + 1 end
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
	if _configuration_owner ~= nil then return false end
	if not owns_slot(slot_id) then
		Logger.error(LOG, "set_action(): '%s' is not a slot this driver knows — nothing bound.",
			tostring(slot_id))
		return false
	end
	load_assignments()

	local path = require("infra.config_paths").config("config.toml")

	if type(action_id) ~= "string" or action_id == "" or action_id == "none" then
		-- A slot the manifest binds keeps an explicit "none": deleting the entry
		-- would bring the default back at the next start.
		local operation = { section = KEYBOARD_SECTION, key = slot_id }
		if manifest_defaults()[slot_id] ~= nil then operation.value = "none" else operation.delete = true end
		local committed, detail = Writer.batch_write(path, { operation })
		if committed ~= true then
			Logger.error(LOG, "set_action(): could not persist the removal of '%s': %s.", slot_id, tostring(detail))
			return false
		end
		_assignments[slot_id] = nil
		_dispatch_generation = _dispatch_generation + 1
		Logger.info(LOG, "Unbound %s.", M.get_slot_label(slot_id))
		return true
	end

	-- The same catalogue check the gesture slots apply, and Windows applies to
	-- both: an unknown id would be stored, fire on the chord, and do nothing.
	local Gestures = action_catalogue()
	if not Gestures then
		Logger.error(LOG, "set_action(): '%s' not bound without the action catalogue.", slot_id)
		return false
	end
	if not Gestures.is_assignable(action_id) then
		Logger.warn(LOG, "set_action(): refusing unknown action '%s' for %s.", action_id, slot_id)
		return false
	end

	local committed, detail = Writer.batch_write(path, {
		{ section = KEYBOARD_SECTION, key = slot_id, value = action_id },
	})
	if committed ~= true then
		Logger.error(LOG, "set_action(): could not persist '%s': %s.", slot_id, tostring(detail))
		return false
	end
	_assignments[slot_id] = action_id
	_dispatch_generation = _dispatch_generation + 1
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

--- The slot suffix a reported key stands for. The hook reports a key by its XKB
--- identity: the space bar as " ", the punctuation keys as their character, and
--- a letter in upper case while Shift is held. Slot suffixes name those keys
--- ("space", "period") and spell letters in lower case.
--- @param key string|nil
--- @return string|nil
local function suffix_of(key)
	if type(key) ~= "string" or key == "" then return nil end
	return SUFFIX_OF_IDENTITY[key] or key:lower()
end

--- The binding a chord would fire right now, or nil.
---
--- While the script is paused, and while the shortcuts feature is switched off,
--- only the script-control actions (pause, reload, quit) may fire: they are how
--- the user gets the script back, and every other binding firing through a pause
--- is the pause not working. A binding held back that way is reported, so the
--- caller can leave its key alone.
--- @param detail table|nil { key = string, mods = table } from the hook.
--- @param only_script boolean
--- @return table|nil { slot, action, held_back }; action is nil for the default Ctrl+G.
local function match(detail, only_script)
	if type(detail) ~= "table" then return nil end
	local key = suffix_of(detail.key)
	if not key then return nil end
	local held = type(detail.mods) == "table" and detail.mods or {}
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
				return {
					slot = slot,
					action = action,
					held_back = only_script and not ScriptActions.is_script_action(action),
				}
			end
		end
	end

	-- Ctrl+G is the one shipped binding shared with macOS. A user assignment for
	-- this slot wins because the loop above returns first; otherwise the canonical
	-- ChatGPT URL is useful immediately without claiming that every desktop-safe
	-- chord can be chosen for the user.
	if not only_script and key == "g" and held.ctrl == true
		and held.shift ~= true and held.alt ~= true and held.meta ~= true then
		return { slot = "ctrl_g", action = nil, held_back = false }
	end
	return nil
end

--- The parameter-store identity used when a keyboard slot dispatches an action.
--- @param slot string Keyboard slot id.
--- @return string
function M.binding_id(slot)
	return "keyboard__" .. slot
end

--- Runs a matched binding.
--- @param hit table The record match() returned.
local function fire(hit)
	if hit.action == nil then
		Logger.debug(LOG, "Default keyboard shortcut fired: ctrl_g → ChatGPT.")
		pcall(ChatGPT.open)
		return
	end
	Logger.debug(LOG, "Keyboard shortcut fired: %s → %s.", hit.slot, hit.action)
	local ok_gestures, Gestures = pcall(require, "modules.gestures.manager")
	if ok_gestures and type(Gestures.execute_action) == "function" then
		pcall(Gestures.execute_action, hit.action, M.binding_id(hit.slot))
	else
		Logger.error(LOG,
			"No action executor — '%s' is bound to %s and cannot run.", hit.slot, hit.action)
	end
end

--- Runs the action bound to the chord that was just pressed, if any.
---
--- Called from the daemon's control-key callback with what the hook reported,
--- which happens after the key was forwarded: without the grab this is the only
--- path, and the chord also reaches the application. Returns whether anything
--- fired, so the caller can tell an unbound chord from a handled one — the
--- difference matters for the metrics, not for the user.
--- @param detail table|nil { key = string, mods = table } from the hook.
--- @param opts table|nil { only_script = boolean }
--- @return boolean fired, string|nil slot_id
function M.dispatch(detail, opts)
	if _configuration_owner ~= nil then return false, nil end
	local hit = match(detail, type(opts) == "table" and opts.only_script == true)
	if not hit then return false, nil end
	if hit.held_back then
		Logger.debug(LOG, "Keyboard shortcut %s → %s held back: only script control runs now.",
			hit.slot, hit.action)
		return false, hit.slot
	end
	fire(hit)
	return true, hit.slot
end

--- Claims a bound chord from the keyboard hook's consumption callback.
---
--- Under the grab the hook asks this BEFORE forwarding the key, which is the one
--- place a chord can be kept from the focused application: a bound Super+Space
--- must not also switch the input source. The action runs on the next loop tick,
--- never inside the callback, because the hook is mid-decision about a physical
--- event. A chord that is unbound or held back is left to the application, and a
--- key whose action cannot be queued is typed rather than lost.
--- @param detail table { key, mods } from the hook.
--- @param opts table { only_script = boolean, defer = function(fn): boolean }
--- @return boolean consumed, string|nil slot_id
function M.consume(detail, opts)
	if _configuration_owner ~= nil then return false, nil end
	if type(opts) ~= "table" or type(opts.defer) ~= "function" then
		Logger.error(LOG, "consume(): no deferral seam — bound chords reach the application.")
		return false, nil
	end
	local hit = match(detail, opts.only_script == true)
	if not hit or hit.held_back then return false, nil end
	local generation = _dispatch_generation
	if opts.defer(function()
		if _configuration_owner ~= nil or generation ~= _dispatch_generation then return end
		fire(hit)
	end) ~= true then
		Logger.error(LOG, "Keyboard shortcut %s could not be queued — the key is typed instead.", hit.slot)
		return false, nil
	end
	return true, hit.slot
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
	_configuration_owner = nil
	_dispatch_generation = _dispatch_generation + 1
	_assignments = {}
	_loaded = false
	_catalogue = nil
end


--- Resolves a detached candidate with the same slot catalogue as the reader.
--- @param document table Decoded configuration.
--- @return table state
function M.configuration_candidate(document)
	assert(document.shortcuts == nil or type(document.shortcuts) == "table", "shortcut section is malformed")
	local section = document.shortcuts or {}
	assert(section.keyboard == nil or type(section.keyboard) == "table", "keyboard assignments are malformed")
	local catalogue = assert(action_catalogue(), "keyboard action catalogue is unavailable")
	local assignments = {}
	for slot, action in pairs(manifest_defaults()) do
		assert(type(action) == "string" and (action == "none" or catalogue.is_assignable(action)), "invalid keyboard default")
		if action ~= "none" then assignments[slot] = action end
	end
	walk_assignments(document, function(slot, action)
		assert(type(action) == "string" and (action == "none" or catalogue.is_assignable(action)), "invalid keyboard assignment: " .. slot)
		assignments[slot] = action ~= "none" and action or nil
	end)
	return { assignments = assignments }
end

--- Enumerates only dynamic slots recognized by this runtime owner.
--- @param document table Decoded configuration.
--- @return table paths
function M.configuration_paths(document)
	local found = {}
	walk_assignments(document, function(slot) found[slot] = true end)
	for slot in pairs(_assignments) do found[slot] = true end
	local paths = {}
	for slot in pairs(found) do paths[#paths + 1] = KEYBOARD_SECTION .. "." .. slot end
	return paths
end

--- Identifies an actual keyboard parameter binding without inventing slots.
--- @param binding string Runtime binding identity.
--- @return string|nil domain
function M.configuration_domain(binding)
	local slot = type(binding) == "string" and binding:match("^keyboard__(.+)$") or nil
	if slot and owns_slot(slot) then return "keyboard" end
	return nil
end

--- Captures desired assignments after dispatch admission has closed.
--- @param owner table Exact acquisition token.
--- @return table|nil state
function M.configuration_snapshot(owner)
	if _configuration_owner ~= owner then return nil end
	return { assignments = M.get_assignments() }
end

--- Applies an acknowledged detached assignment map without persistence.
--- @param owner table Exact acquisition token.
--- @param state table Validated candidate or saved state.
--- @return boolean acknowledged
function M.apply_configuration(owner, state)
	if _configuration_owner ~= owner or type(state) ~= "table" or type(state.assignments) ~= "table" then return false end
	local copy = {}
	local catalogue = action_catalogue()
	if not catalogue then return false end
	for slot, action in pairs(state.assignments) do
		if not owns_slot(slot) or type(action) ~= "string" or not catalogue.is_assignable(action) then return false end
		copy[slot] = action
	end
	_assignments, _loaded = copy, true
	_dispatch_generation = _dispatch_generation + 1
	return true
end

return M
