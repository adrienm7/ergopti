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
--- 3. Neutral defaults leave desktop chords untouched. Explicit restoration
---    projects the manifest recommendations, including Ctrl+G for ChatGPT and
---    Super+Space for an AI prediction, into the same assignment map as edits.
--- 4. Matching happens here, not in the kernel. There is no userland API on Linux
---    to reserve a chord — the daemon already sees every key, so it decides.
---    Under the grab (the default) a bound chord is claimed in the keyboard
---    hook's consumption callback (consume) and never reaches the focused
---    application. Without the grab only dispatch runs, after the key was
---    forwarded, so the chord ALSO reaches the application there.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Paths = require("infra.paths")
local ScriptActions = require("modules.shortcuts.script_actions")
local Manifest = require("infra.manifest_reader")
local Codec = require("toml_codec")
local Writer = require("toml_codec.writer")
local MagicEditor = require("shortcuts.magic_editor")
local KeyboardPublication = require("config_keyboard_publication")

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

-- The groups the menu offers, in display order. Ordinary groups use the
-- catalogue prefixes; contextual slots retain their stable logical identity.
M.SLOT_GROUPS = {
	{ prefix = "contextual", group_key = "menu.shortcuts.group_contextual" },
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
local _binding_publication = nil

-- slot_id → action_id, for the slots the user has assigned.
local _assignments = {}

-- Whether the assignments have been read back from config.toml.
local _loaded = false
local _configuration_owner = nil
local _dispatch_generation = 0
local _explicit_assignments = {}

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
	local read_ok, body = pcall(handle.read, handle, "*a")
	local close_ok, closed = pcall(handle.close, handle)
	if not read_ok or type(body) ~= "string" or not close_ok or closed ~= true then
		_catalogue = false
		Logger.error(LOG, "The key catalogue at '%s' was not completely read and closed — no slots are offered.", path)
		return nil
	end

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
	local admitted, publication = pcall(KeyboardPublication.publish, _catalogue, SLOT_MODS, MagicEditor.SLOT_ID)
	if admitted then
		_binding_publication = publication
	else
		Logger.error(LOG, "The complete keyboard source cannot publish its binding catalogue.")
	end
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
function M.get_slot_label(slot_id, reason)
	if slot_id == MagicEditor.SLOT_ID then
		local label = MOD_LABELS.meta .. " + " .. require("modules.hotstrings.magic_key").get()
		if reason then label = label .. " (" .. require("infra.i18n").get("menu.shortcuts.keyboard.magic_editor_reason." .. reason) .. ")" end
		return label
	end
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
	if slot_id == MagicEditor.SLOT_ID then return true end
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

--- Visits canonical assignments whose chord belongs to this owner. A
--- [shortcuts] or keyboard value of another shape is outdated configuration:
--- reported once and walked as empty, so the cleanup offers it.
--- @param decoded table Decoded configuration.
--- @param consume function Consumer receiving slot and stored value.
local function walk_assignments(decoded, consume)
	local shortcuts = ConfigOutdated.settings_table(decoded.shortcuts, { "shortcuts" }, Logger) or {}
	local assignments = ConfigOutdated.settings_table(shortcuts.keyboard, { "shortcuts", "keyboard" }, Logger) or {}
	for slot, value in pairs(assignments) do
		if owns_slot(slot) then consume(slot, value) end
	end
end

--- Whether a stored assignment still names something this build runs. An
--- action retired by an update is outdated configuration: ignored, warned
--- about once and offered by the config cleanup, never an error or a refusal.
--- @param slot string Keyboard slot id.
--- @param action any Stored value.
--- @param catalogue table Action catalogue owner.
--- @return boolean known
local function stored_assignment_known(slot, action, catalogue)
	if action == "none" or (type(action) == "string" and catalogue.is_assignable(action)) then return true end
	ConfigOutdated.report({ "shortcuts", "keyboard", slot },
		"action '" .. tostring(action) .. "' no longer exists", Logger)
	return false
end

--- Marks the same recognized entries that the runtime reader consumes. A slot
--- whose action no longer exists is left unmarked, so the cleanup offers it.
--- @param decoded table Decoded configuration.
--- @param mark function Segment-based ownership collector.
function M.mark_config_reads(decoded, mark)
	local catalogue = action_catalogue()
	walk_assignments(decoded, function(slot, action)
		-- Without a catalogue nothing can be proved outdated: keep every slot.
		if not catalogue or stored_assignment_known(slot, action, catalogue) then
			mark("shortcuts", "keyboard", slot)
		end
	end)
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
	local explicit = {}
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
		if stored_assignment_known(slot, action, Gestures) and action ~= "none" then
			loaded[slot] = action
			explicit[slot] = action
		else
			loaded[slot] = nil
			explicit[slot] = "none"
		end
	end)
	_assignments = loaded
	_explicit_assignments = explicit
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

	if type(action_id) ~= "string" or action_id == "" then action_id = "none" end
	local Gestures = action_catalogue()
	if not Gestures then
		Logger.error(LOG, "set_action(): '%s' not bound without the action catalogue.", slot_id)
		return false
	end
	if not Gestures.is_assignable(action_id) then
		Logger.warn(LOG, "set_action(): refusing unknown action '%s' for %s.", action_id, slot_id)
		return false
	end
	-- Explicit None is a personal native-behavior claim. Scope removal alone
	-- restores absence; it must never be confused with selecting this action.
	local operation = require("shortcuts.assignment").operation(slot_id, action_id, owns_slot, Gestures.is_assignable)
	local committed, detail = Writer.batch_write(path, { operation })
	if committed ~= true then
		Logger.error(LOG, "set_action(): could not persist '%s': %s.", slot_id, tostring(detail))
		return false
	end
	_assignments[slot_id] = action_id ~= "none" and action_id or nil
	_explicit_assignments[slot_id] = action_id
	_dispatch_generation = _dispatch_generation + 1
	Logger.info(LOG, "Bound %s → %s.", M.get_slot_label(slot_id), action_id)
	return true
end

--- Every slot a group offers, whether bound or not.
--- @param prefix string One of SLOT_GROUPS' prefixes.
--- @return table Array of slot ids.
function M.available_slots(prefix)
	if prefix == "contextual" then return { MagicEditor.SLOT_ID } end
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
	if prefix == "contextual" then return { MagicEditor.SLOT_ID } end
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

--- Resolves the ordinary contextual slot through shared physical-source policy.
--- @param admission table Live master, pause and capture-inhibition proof.
--- @return table decision Shared policy receipt.
function M.magic_editor_decision(admission)
	load_assignments()
	local Source = require("modules.hotstrings.magic_key_source")
	local source, claims = Source.editor_source(), {}
	for _, candidate in ipairs(source.candidates) do
		if candidate.direct and not candidate.dead then
			local suffix = suffix_of(candidate.native_text or candidate.text)
			local slot = suffix and ("super_" .. suffix) or nil
			local action = slot and _explicit_assignments[slot] or nil
			if action ~= nil then claims[candidate.identity] = { action = action, binding_id = M.binding_id(slot) } end
		end
	end
	local catalogue = assert(action_catalogue(), "magic editor action catalogue is unavailable")
	return MagicEditor.resolve({ default_action = Manifest.default_for(MagicEditor.PATH),
		stored_action = _explicit_assignments[MagicEditor.SLOT_ID], is_action = catalogue.is_assignable,
		trigger = require("modules.hotstrings.magic_key").get(), source = source, known_codes = Source.known_codes(),
		explicit_claims = claims, configuration_generation = _dispatch_generation, admission = admission })
end

--- A physical recommendation claims exactly Super plus its actual plain source.
local function contextual_match(detail, opts)
	if type(opts.admission) ~= "function" or type(detail) ~= "table" or detail.physical ~= true then return nil end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	if mods.meta ~= true or mods.ctrl or mods.shift or mods.alt or mods.altgr then return nil end
	local decision = M.magic_editor_decision(opts.admission())
	if not decision.active or decision.source.native_code ~= detail.code then return nil end
	return { slot = MagicEditor.SLOT_ID, action = decision.action, decision = decision }
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
--- @return table|nil { slot, action, held_back }.
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
--- @param detail table { key, code, physical, mods } from the hook.
--- @param opts table { only_script = boolean, defer = function(fn): boolean,
---   admission = function(): { master, paused, inhibited } Optional live native gates. }
--- @return boolean consumed, string|nil slot_id
function M.consume(detail, opts)
	if _configuration_owner ~= nil then return false, nil end
	if type(opts) ~= "table" or type(opts.defer) ~= "function" then
		Logger.error(LOG, "consume(): no deferral seam — bound chords reach the application.")
		return false, nil
	end
	local hit = contextual_match(detail, opts) or match(detail, opts.only_script == true)
	if not hit or hit.held_back then return false, nil end
	local generation = _dispatch_generation
	if opts.defer(function()
		if _configuration_owner ~= nil or generation ~= _dispatch_generation then return end
		if hit.decision then
			local admission = opts.admission()
			local current = M.magic_editor_decision(admission)
			if not MagicEditor.can_deliver(hit.decision, { source_generation = current.source_generation,
				configuration_generation = _dispatch_generation, action = current.action,
				master = admission.master, paused = admission.paused, inhibited = admission.inhibited }) then return end
		end
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
	_explicit_assignments = {}
	_loaded = false
	_catalogue = nil
	_binding_publication = nil
end


--- Resolves a detached candidate with the same slot catalogue as the reader.
--- @param document table Decoded configuration.
--- @param written boolean|nil True for the document a scope just wrote: every
---   walked slot is then its own output, so an unassignable one is a real
---   failure and raises instead of being read as outdated configuration.
--- @return table state
function M.configuration_candidate(document, written)
	local catalogue = assert(action_catalogue(), "keyboard action catalogue is unavailable")
	local assignments, explicit = {}, {}
	for slot, action in pairs(manifest_defaults()) do
		assert(type(action) == "string" and (action == "none" or catalogue.is_assignable(action)), "invalid keyboard default")
		if action ~= "none" then assignments[slot] = action end
	end
	walk_assignments(document, function(slot, action)
		assert(not written or action == "none" or (type(action) == "string" and catalogue.is_assignable(action)),
			"invalid keyboard assignment: " .. slot)
		-- The loader's rule: an outdated action leaves the slot unbound.
		local known = stored_assignment_known(slot, action, catalogue)
		assignments[slot] = known and action ~= "none" and action or nil
		explicit[slot] = known and action or "none"
	end)
	return { assignments = assignments, explicit_assignments = explicit }
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
	local assignments, explicit = M.get_assignments(), {}
	for slot, action in pairs(_explicit_assignments) do explicit[slot] = action end
	return { assignments = assignments, explicit_assignments = explicit }
end

--- Applies an acknowledged detached assignment map without persistence.
--- @param owner table Exact acquisition token.
--- @param state table Validated candidate or saved state.
--- @return boolean acknowledged
function M.apply_configuration(owner, state)
	if _configuration_owner ~= owner or type(state) ~= "table" or type(state.assignments) ~= "table"
		or (state.explicit_assignments ~= nil and type(state.explicit_assignments) ~= "table") then return false end
	local copy = {}
	local catalogue = action_catalogue()
	if not catalogue then return false end
	for slot, action in pairs(state.assignments) do
		if not owns_slot(slot) or type(action) ~= "string" or not catalogue.is_assignable(action) then return false end
		copy[slot] = action
	end
	local explicit = {}
	for slot, action in pairs(state.explicit_assignments or state.assignments) do
		if not owns_slot(slot) or type(action) ~= "string" or (action ~= "none" and not catalogue.is_assignable(action)) then return false end
		explicit[slot] = action
	end
	_assignments, _loaded = copy, true
	_explicit_assignments = explicit
	_dispatch_generation = _dispatch_generation + 1
	return true
end


--- Returns a detached complete native publication without reading or dispatching input.
--- @return table|nil catalogue Unavailable or withdrawn sources remain unjudged.
function M.published_binding_catalogue()
	if not KeyboardPublication.owner_is_current(M)
		or _binding_publication == nil then return nil end
	return _binding_publication(_catalogue, SLOT_MODS, MagicEditor.SLOT_ID)
end

KeyboardPublication.register(M, M.published_binding_catalogue)

return M
