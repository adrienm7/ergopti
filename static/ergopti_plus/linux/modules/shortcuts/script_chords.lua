--- modules/shortcuts/script_chords.lua

--- ==============================================================================
--- MODULE: Script-Management Chords (Linux)
--- DESCRIPTION:
--- AltGr with Enter, Backspace, Delete or Escape, the four chords every driver
--- shares (_shared/modules/actions/script_chords.json), each running the action
--- of its slot of [shortcuts.script_control]: by default pause, reload, open
--- the personal shortcuts and quit. The submenu's switch (chords_enabled) turns
--- them all off and keeps every slot's action.
---
--- FEATURES & RATIONALE:
--- 1. A chord belongs to the daemon only while its slot runs an action
---    (_shared/lua/script_chords.lua): an unassigned slot, every slot while the
---    switch is off, and while paused every action outside script management
---    reach the application untouched, as on Windows and macOS.
--- 2. Decided in the keyboard hook's consumption callback, the one place this
---    daemon can keep a key from the application; the hook then swallows the
---    release and the auto-repeats of the consumed press too. AltGr is the
---    level-3 key of the loaded keymap, so a layout whose right Alt is a plain
---    Alt has no chord: Alt+Escape stays Alt+Escape there.
--- 3. The action runs on the next loop tick, not inside the callback, and is
---    judged again there: a pause that began in between keeps it from running.
--- 4. A missing key is the slot's preset (the maintainer's decision of
---    2026-09-30), so a clear writes "none" explicitly; the Shortcuts scope
---    owns restore and clear through the configuration_* ports below.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Paths = require("infra.paths")
local Manifest = require("infra.manifest_reader")
local ScriptChords = require("script_chords")
local TomlCodec = require("toml_codec")
local TomlWriter = require("toml_codec.writer")

local LOG = "modules.shortcuts.script_chords"

-- The manifest section of the slots and of the switch.
local SECTION = "shortcuts.script_control"
local SWITCH_KEY = "chords_enabled"

-- The binding a slot's action runs under and stores its parameter under, the
-- same on every driver.
local BINDING_PREFIX = "script__"

-- The shared catalogue, relative to the shared tree.
local CATALOGUE_REL_PATH = "modules/actions/script_chords.json"

-- A chord is AltGr with the slot's key. Shift may ride along, as on Windows;
-- any other modifier makes it another chord, which stays the application's.
local BLOCKING_MODIFIERS = { "ctrl", "alt", "meta" }

-- The validated catalogue; nil until read.
local _catalogue = nil
local _binding_catalogue = nil

-- Slot id -> action id and the switch, read once from config.toml over the
-- manifest defaults; nil until then.
local _assignments = nil
local _chords_on = nil

-- Injected by init(): whether the daemon is paused, and the next-tick queue.
local function NEVER_PAUSED() return false end
local _is_paused = NEVER_PAUSED
local _defer = nil

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





-- ========================================
-- ========================================
-- ======= 1/ Slots and assignments =======
-- ========================================
-- ========================================

--- The validated shared catalogue, read once. A missing or malformed file
--- raises: the daemon must not run without its way back from a pause.
--- @return table catalogue See ScriptChords.catalogue.
function M.catalogue()
	if _catalogue then return _catalogue end
	local path = Paths.shared(CATALOGUE_REL_PATH)
	local handle = path and io.open(path, "r")
	if not handle then error("script_chords: cannot read " .. tostring(path)) end
	local read_ok, body = pcall(handle.read, handle, "*a")
	local close_ok, closed = pcall(handle.close, handle)
	if not read_ok or type(body) ~= "string" or not close_ok or closed ~= true then
		error("script_chords: cannot complete read of " .. tostring(path))
	end
	local ok, parsed = pcall(require("json").decode, body)
	if not ok or type(parsed) ~= "table" then
		error("script_chords: " .. tostring(path) .. " is malformed")
	end
	for _, slot in ipairs(parsed.slots or {}) do
		if type(slot.linux) ~= "number" then
			error("script_chords: a slot of " .. tostring(path) .. " lacks its evdev code")
		end
	end
	local catalogue = ScriptChords.catalogue(parsed)
	local binding = { prefix = "script__", slots = {} }
	for _, slot in ipairs(catalogue.slots) do binding.slots[slot.id] = true end
	require("config_binding_identity").script_binding_fits("script__", binding)
	_catalogue, _binding_catalogue = catalogue, binding
	return _catalogue
end

--- Returns a detached complete publication without reading or initializing an owner.
--- @return table|nil catalogue
function M.published_binding_catalogue()
	if _binding_catalogue == nil then return nil end
	local publication = { prefix = _binding_catalogue.prefix, slots = {} }
	for id in pairs(_binding_catalogue.slots) do publication.slots[id] = true end
	return publication
end

--- The chord slots in menu order, as catalogue rows (id, linux...).
--- @return table slots
function M.slots()
	return M.catalogue().slots
end

--- The binding id a slot dispatches under.
--- @param slot_id string
--- @return string
function M.binding_id(slot_id)
	return BINDING_PREFIX .. tostring(slot_id)
end

--- The gestures manager, whose catalogue decides which ids a slot may hold.
--- @return table|nil
local function action_catalogue()
	local ok, Gestures = pcall(require, "modules.gestures.manager")
	if not ok or type(Gestures) ~= "table" or type(Gestures.is_assignable) ~= "function" then
		Logger.error(LOG, "The action catalogue is unavailable: %s", tostring(Gestures))
		return nil
	end
	return Gestures
end

--- Visits the canonical values this owner consumes: each slot and the switch.
--- @param decoded table Decoded config.toml.
--- @param consume function Consumer receiving key and value.
local function walk_values(decoded, consume)
	-- Another shape is outdated configuration: reported once, walked as empty.
	local shortcuts = ConfigOutdated.settings_table(decoded.shortcuts, { "shortcuts" }, Logger) or {}
	local section = ConfigOutdated.settings_table(shortcuts.script_control,
		{ "shortcuts", "script_control" }, Logger) or {}
	for _, slot in ipairs(M.slots()) do
		if section[slot.id] ~= nil then consume(slot.id, section[slot.id]) end
	end
	if section[SWITCH_KEY] ~= nil then consume(SWITCH_KEY, section[SWITCH_KEY]) end
end

--- Whether a stored value is one this build runs. A retired action or a
--- switch that is not a boolean is outdated configuration: warned about once,
--- read as its manifest default and offered by the config cleanup.
--- @param key string Slot id or the switch.
--- @param value any Stored value.
--- @param catalogue table|nil Action catalogue owner.
--- @return boolean known
local function stored_value_known(key, value, catalogue)
	if key == SWITCH_KEY then
		if type(value) == "boolean" then return true end
		ConfigOutdated.report({ "shortcuts", "script_control", key }, "the switch is not a boolean", Logger)
		return false
	end
	if value == "none" or (type(value) == "string" and catalogue and catalogue.is_assignable(value)) then
		return true
	end
	ConfigOutdated.report({ "shortcuts", "script_control", key },
		"action '" .. tostring(value) .. "' no longer exists", Logger)
	return false
end

--- Marks exactly the preferences read by the loader. A value no longer
--- understood is left unmarked, so the cleanup offers it.
--- @param decoded table Decoded config.toml.
--- @param mark function Segment-based ownership collector.
function M.mark_config_reads(decoded, mark)
	local catalogue = action_catalogue()
	walk_values(decoded, function(key, value)
		-- Without a catalogue no action can be proved outdated: keep every slot.
		if (key ~= SWITCH_KEY and not catalogue) or stored_value_known(key, value, catalogue) then
			mark("shortcuts", "script_control", key)
		end
	end)
end

--- Resolves a decoded document into every slot's action and the switch, over
--- the manifest defaults (each slot's preset).
--- @param decoded table Decoded config.toml.
--- @param catalogue table|nil Action catalogue owner.
--- @param written boolean|nil True for a document a scope just wrote.
--- @return table assignments, boolean chords_on
local function resolve(decoded, catalogue, written)
	local configured, chords_on = {}, Manifest.default_for(SECTION .. "." .. SWITCH_KEY)
	walk_values(decoded, function(key, value)
		local known = stored_value_known(key, value, catalogue)
		assert(not written or known, "invalid script chord value: " .. key)
		if key == SWITCH_KEY then
			if known then chords_on = value end
		elseif known then
			configured[key] = value
		end
	end)
	local assignments = {}
	for _, slot in ipairs(M.slots()) do
		local action = configured[slot.id]
		if action == nil then action = Manifest.default_for(SECTION .. "." .. slot.id) end
		assignments[slot.id] = action
	end
	assert(type(chords_on) == "boolean", "script chords: the switch must be a boolean")
	return assignments, chords_on
end

--- Reads every slot and the switch from config.toml, or the manifest defaults.
local function load_assignments()
	if _assignments then return end
	local path = require("infra.config_paths").config("config.toml")
	local content, status, detail = TomlWriter.read_classified(path)
	if status ~= "ok" and status ~= "absent" then
		error("script_chords: cannot read configuration: " .. tostring(detail))
	end
	local decoded = {}
	if status == "ok" then
		local ok, parsed = pcall(TomlCodec.decode, content)
		if not ok or type(parsed) ~= "table" then
			error("script_chords: malformed configuration: " .. tostring(parsed))
		end
		decoded = parsed
	end
	_assignments, _chords_on = resolve(decoded, action_catalogue())
	Logger.info(LOG, "Script chords loaded (%s).", _chords_on and "on" or "off")
end

--- The action a slot runs, or "none".
--- @param slot_id string
--- @return string
function M.get_action(slot_id)
	load_assignments()
	return _assignments[slot_id] or "none"
end

--- Whether the chords' switch is on.
--- @return boolean
function M.chords_enabled()
	load_assignments()
	return _chords_on
end

--- Persists one row, deleting it when it equals the manifest default.
--- @param key string Slot id or the switch.
--- @param value any
--- @return boolean committed
local function persist(key, value)
	local path = require("infra.config_paths").config("config.toml")
	local committed, detail = TomlWriter.batch_write(path, {
		Manifest.sparse_operation(SECTION .. "." .. key, value),
	})
	if committed ~= true then
		Logger.error(LOG, "Could not persist script chord '%s': %s.", key, tostring(detail))
		return false
	end
	return true
end

--- Assigns an action to a slot ("none" gives the chord back to the system).
--- @param slot_id string
--- @param action_id string
--- @return boolean Whether the assignment was stored.
function M.set_action(slot_id, action_id)
	if _configuration_owner ~= nil then return false end
	load_assignments()
	if _assignments[slot_id] == nil then
		Logger.error(LOG, "set_action(): '%s' is not a script chord slot — nothing bound.", tostring(slot_id))
		return false
	end
	local Gestures = action_catalogue()
	if action_id ~= "none" and not (Gestures and Gestures.is_assignable(action_id)) then
		Logger.warn(LOG, "set_action(): refusing unknown action '%s' for script chord '%s'.",
			tostring(action_id), slot_id)
		return false
	end
	if not persist(slot_id, action_id) then return false end
	_assignments[slot_id] = action_id
	_dispatch_generation = _dispatch_generation + 1
	Logger.info(LOG, "Script chord '%s' → '%s'.", slot_id, action_id)
	return true
end

--- Turns the chords' switch on or off. Off leaves every chord to the system
--- and keeps every slot's action.
--- @param on boolean
--- @return boolean Whether the switch was stored.
function M.set_chords_enabled(on)
	if _configuration_owner ~= nil then return false end
	if type(on) ~= "boolean" then
		Logger.error(LOG, "set_chords_enabled(): the switch must be a boolean.")
		return false
	end
	load_assignments()
	if not persist(SWITCH_KEY, on) then return false end
	_chords_on = on
	_dispatch_generation = _dispatch_generation + 1
	Logger.info(LOG, "Script chords switched %s.", on and "on" or "off")
	return true
end

--- Whether a slot runs its action now (switch, assignment, pause).
--- @param slot_id string
--- @param paused boolean|nil The pause state to judge by; the daemon's by default.
--- @return boolean
function M.slot_runs(slot_id, paused)
	load_assignments()
	if paused == nil then paused = _is_paused() end
	return ScriptChords.runs(M.catalogue(), _assignments[slot_id], _chords_on, paused)
end





-- ===========================================
-- ===========================================
-- ======= 2/ The consumption decision =======
-- ===========================================
-- ===========================================

--- Wires the daemon's state in.
--- @param opts table { is_paused = fn() -> boolean, defer = fn(fn) -> boolean }
function M.init(opts)
	if _configuration_owner ~= nil then return false end
	if type(opts) ~= "table" or type(opts.is_paused) ~= "function" or type(opts.defer) ~= "function" then
		error("script_chords.init() needs is_paused and defer functions")
	end
	_is_paused = opts.is_paused
	_defer = opts.defer
	-- Read at boot, not at the first AltGr chord: a malformed catalogue stops
	-- the daemon instead of a key press.
	M.catalogue()
	return true
end

--- Decides one key press from the keyboard hook's consumption callback.
--- @param detail table { code, mods } as the hook reports it.
--- @return boolean consumed True when the press is a chord whose slot runs an
---   action; it then never reaches the application.
function M.on_key(detail)
	if _configuration_owner ~= nil then return false end
	if type(detail) ~= "table" or type(detail.code) ~= "number" then return false end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	if not mods.altgr then return false end
	for _, name in ipairs(BLOCKING_MODIFIERS) do
		if mods[name] then return false end
	end
	local slot_id = nil
	for _, slot in ipairs(M.slots()) do
		if slot.linux == detail.code then slot_id = slot.id break end
	end
	if not slot_id or not M.slot_runs(slot_id) then return false end
	if not _defer then
		Logger.error(LOG, "Script chord '%s' pressed before init() — the key goes to the application.", slot_id)
		return false
	end
	local generation = _dispatch_generation
	local action = _assignments[slot_id]
	local queued = _defer(function()
		if _configuration_owner ~= nil or generation ~= _dispatch_generation then return end
		-- A pause that began after the press: the chord was taken, and only a
		-- script-management action may still run.
		if not M.slot_runs(slot_id) then
			Logger.info(LOG, "Script chord '%s' no longer runs '%s' — nothing done.", slot_id, action)
			return
		end
		local Gestures = action_catalogue()
		if not Gestures then return end
		Logger.debug(LOG, "Script chord '%s' fired → '%s'.", slot_id, action)
		Gestures.execute_action(action, M.binding_id(slot_id))
	end)
	if queued ~= true then
		Logger.error(LOG, "Script chord '%s' could not queue '%s' — the key goes to the application.",
			slot_id, action)
		return false
	end
	return true
end

--- Test seam: forgets what was loaded.
function M._reset()
	_configuration_owner = nil
	_dispatch_generation = _dispatch_generation + 1
	_catalogue = nil
	_binding_catalogue = nil
	_assignments = nil
	_chords_on = nil
	_is_paused = NEVER_PAUSED
	_defer = nil
end





-- ========================================
-- ========================================
-- ======= 3/ Scope ownership ports =======
-- ========================================
-- ========================================

--- Resolves the exact chords against a detached configuration.
--- @param document table Decoded configuration.
--- @param written boolean|nil True for the document a scope just wrote: an
---   unassignable slot there is that write's failure and raises.
--- @return table state { assignments, chords_on }
function M.configuration_candidate(document, written)
	local catalogue = assert(action_catalogue(), "script chord action catalogue is unavailable")
	local assignments, chords_on = resolve(document, catalogue, written)
	for id, action in pairs(assignments) do
		assert(type(action) == "string" and (action == "none" or catalogue.is_assignable(action)),
			"invalid script chord assignment: " .. id)
	end
	return { assignments = assignments, chords_on = chords_on }
end

--- Identifies a script chord's parameter binding.
--- @param binding string Runtime binding identity.
--- @return string|nil domain
function M.configuration_domain(binding)
	for _, slot in ipairs(M.slots()) do if binding == M.binding_id(slot.id) then return "script" end end
	return nil
end

--- Captures the current chords under exclusive ownership.
--- @param owner table Exact acquisition token.
--- @return table|nil state
function M.configuration_snapshot(owner)
	if _configuration_owner ~= owner then return nil end
	load_assignments()
	local copy = {}
	for id, action in pairs(_assignments) do copy[id] = action end
	return { assignments = copy, chords_on = _chords_on }
end

--- Applies a complete detached state without writing the source file.
--- @param owner table Exact acquisition token.
--- @param state table Candidate or saved state.
--- @return boolean acknowledged
function M.apply_configuration(owner, state)
	if _configuration_owner ~= owner or type(state) ~= "table" or type(state.assignments) ~= "table"
		or type(state.chords_on) ~= "boolean" then return false end
	local catalogue = action_catalogue()
	if not catalogue then return false end
	local slots, copy = {}, {}
	for _, slot in ipairs(M.slots()) do
		local action = state.assignments[slot.id]
		if type(action) ~= "string" or (action ~= "none" and not catalogue.is_assignable(action)) then return false end
		slots[slot.id], copy[slot.id] = true, action
	end
	for id in pairs(state.assignments) do if not slots[id] then return false end end
	_assignments, _chords_on = copy, state.chords_on
	_dispatch_generation = _dispatch_generation + 1
	return true
end

return M
