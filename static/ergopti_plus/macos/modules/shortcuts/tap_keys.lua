--- modules/shortcuts/tap_keys.lua

--- ==============================================================================
--- MODULE: Number-Row Tap Keys (macOS)
--- DESCRIPTION:
--- The three keys at the edges of the number row, the key left of 1 and the two
--- right of 0, each assignable to any catalogue action. A plain tap runs the
--- action and the key is swallowed; with a modifier held (Option is this
--- platform's AltGr), or while the key is unassigned, it types as usual.
---
--- FEATURES & RATIONALE:
--- 1. Key identity is shared data (_shared/modules/actions/tap_keys.json). The
---    key left of 1 has two macOS keycodes: kVK_ANSI_Grave (50) on an ANSI
---    keyboard and behind Karabiner's ANSI virtual keyboard, kVK_ISO_Section
---    (10) on a bare ISO one. Each event's native keyboard model chooses one
---    code, so the extra ISO key is never mistaken for the key left of 1.
--- 2. Assignments live in canonical config.toml, beside the
---    keyboard slots, and are cached by load(): the shortcut layer's eventtap
---    asks decide() on every press of these keys, and an eventtap callback may
---    only do bounded in-memory work. A key never stored takes the manifest
---    neutral default (shortcuts.tap_keys.<id>), leaving native keys untouched
---    until the user explicitly assigns an action.
--- 3. This module decides; the raw eventtap (actions/system.lua bind_tap_keys)
---    consumes the event and runs the action behind the callback.
--- 4. The menu uses the physical position for a key whose virtual code depends
---    on its keyboard, and the current input-source character for stable codes.
--- ==============================================================================

local M = {}
local BindingPublication = require("config_binding_publication")

local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local Manifest   = require("infra.manifest_reader")
local ConfigOutdated = require("config_outdated")
local Keycodes   = require("infra.keycodes")
local FileSystem = require("adapters.file_system")
local JsonCodec  = require("adapters.json_codec")
local Geometry   = require("adapters.keyboard_geometry")
local Writer     = require("toml_codec.writer")
local Codec      = require("toml_codec")
local Preferences = require("infra.preferences")
local ConfigPaths = require("infra.config_paths")

local LOG = "shortcuts.tap_keys"

-- The canonical assignment section, and the binding its action runs
-- under (and stores its parameter under).
local CONFIG_SECTION = "shortcuts.tap_keys"
local BINDING_PREFIX  = "tap_key__"

-- The shared key list, relative to the shared tree.
local KEYS_REL_PATH = "modules/actions/tap_keys.json"

-- Decoded tap_keys.json entries in menu order; nil until read.
local _keys = nil
local _binding_source = nil
local _binding_catalogue = nil

-- tap key id -> action id, filled by load(); nil until then.
local _assignments = nil




-- ====================================
-- ====================================
-- ======= 1/ Keys and assignments ====
-- ====================================
-- ====================================

--- The shared key list, read once. A missing or malformed file raises: the menu
--- would otherwise show no tap key and nothing would say why.
--- @return table Array of { id, hs = { keycode... } }.
function M.keys()
	if _keys then return _keys end
	local path = Paths.shared(KEYS_REL_PATH)
	local raw = FileSystem.read(path)
	local decoded = raw and JsonCodec.decode(raw) or nil
	if type(decoded) ~= "table" or type(decoded.keys) ~= "table" or #decoded.keys == 0 then
		error("tap_keys: " .. tostring(path) .. " is unreadable or malformed")
	end
	for _, entry in ipairs(decoded.keys) do
		if type(entry.id) ~= "string" or type(entry.hs) ~= "table" or #entry.hs == 0 then
			error("tap_keys: an entry of " .. tostring(path) .. " lacks its id or keycodes")
		end
	end
	local publication = require("config_binding_identity").tap_binding_catalogue(decoded.keys)
	_keys, _binding_source, _binding_catalogue = decoded.keys, decoded.keys, publication
	return _keys
end

--- Returns only the detached identity of the acknowledged current native source.
--- A changed source withdraws publication; this accessor performs no IO.
--- @return table|nil catalogue
function M.published_binding_catalogue()
	if not BindingPublication.owner_is_current("tap", "modules.shortcuts.tap_keys", M) then return nil end
	if _binding_catalogue == nil or not rawequal(_keys, _binding_source) then return nil end
	local current = require("config_binding_identity").tap_binding_catalogue(_keys)
	for id in pairs(current.slots) do
		if _binding_catalogue.slots[id] ~= true then return nil end
	end
	for id in pairs(_binding_catalogue.slots) do
		if current.slots[id] ~= true then return nil end
	end
	return current
end


--- The binding a tap key dispatches under.
--- @param id string
--- @return string
function M.binding_id(id)
	return BINDING_PREFIX .. tostring(id)
end

--- Reads a complete canonical source without consulting or migrating legacy storage.
--- @return table decoded
--- @return table source Classified source for conditional publication.
local function read_config(on_error)
	local content, status, detail = Writer.read_classified(ConfigPaths.get("ConfigTomlPath"), FileSystem, on_error)
	assert(status == "ok" or status == "absent", "tap-key configuration unavailable: " .. tostring(detail))
	local decoded = Codec.decode(content or "")
	assert(type(decoded) == "table", "tap-key configuration is malformed")
	return decoded, { status = status, content = content }
end

--- Visits the stored assignments of the catalogue's tap keys. A [shortcuts]
--- or tap_keys value of another shape in config.toml is outdated
--- configuration: reported once, walked as empty and left unmarked for the
--- cleanup. A scope candidate is built by the scope itself, so the same shape
--- there is its own failure and is refused.
--- @param decoded table Decoded configuration.
--- @param consume function consume(id, action).
--- @param candidate boolean|nil True for a scope candidate.
local function walk_assignments(decoded, consume, candidate)
	if candidate then
		assert(decoded.shortcuts == nil or type(decoded.shortcuts) == "table", "shortcuts must be a table")
		assert(decoded.shortcuts == nil or decoded.shortcuts.tap_keys == nil
			or type(decoded.shortcuts.tap_keys) == "table", "tap-key assignments must be a table")
	end
	local shortcuts = ConfigOutdated.settings_table(decoded.shortcuts, { "shortcuts" }, Logger)
	if shortcuts == nil then return end
	local assignments = ConfigOutdated.settings_table(shortcuts.tap_keys, { "shortcuts", "tap_keys" }, Logger)
	if assignments == nil then return end
	for _, key in ipairs(M.keys()) do
		if assignments[key.id] ~= nil then consume(key.id, assignments[key.id]) end
	end
end

--- Marks precisely the assignment leaves consumed by the actual loader.
--- @param decoded table Parsed canonical configuration.
--- @param mark function Segment-based ownership collector.
function M.mark_config_reads(decoded, mark)
	walk_assignments(decoded, function(id, action)
		-- A retired action is reported and left unmarked, so the cleanup
		-- offers it even when the setup wizard also reads the key.
		local retired, detail = Preferences.action_is_retired(action)
		if retired then
			ConfigOutdated.report({ "shortcuts", "tap_keys", id }, detail, Logger)
		else
			mark("shortcuts", "tap_keys", id)
		end
	end)
end

--- Loads canonical assignments, using manifest defaults only for absent leaves.
--- @param is_assignable function Authoritative action catalogue check.
local function load_configuration(is_assignable, candidate)
	assert(type(is_assignable) == "function", "tap_keys.load() needs the catalogue check")
	local decoded = candidate
	if decoded == nil then decoded = read_config() end
	assert(type(decoded) == "table", "tap-key candidate must be a table")
	local configured, loaded = {}, {}
	walk_assignments(decoded, function(id, value) configured[id] = value end, candidate ~= nil)
	for _, key in ipairs(M.keys()) do
		local action = configured[key.id]
		if action == nil then action = Manifest.default_for(CONFIG_SECTION .. "." .. key.id) end
		if action ~= "none" and is_assignable(action) ~= true then
			assert(candidate == nil, "tap-key candidate contains an invalid action")
			if configured[key.id] ~= nil then
				-- Outdated configuration: named once (the cleanup reports the
				-- same detail) and offered by the cleanup.
				local _, detail = Preferences.action_is_retired(action)
				ConfigOutdated.report({ "shortcuts", "tap_keys", key.id },
					detail or ("action '" .. tostring(action) .. "' no longer exists"), Logger)
			else
				Logger.warn(LOG, "Tap key '%s' holds unknown action '%s' — left alone.", key.id, tostring(action))
			end
			action = "none"
		end
		loaded[key.id] = action
	end
	_assignments = loaded
	Logger.info(LOG, "Tap keys loaded.")
end

--- Loads desired assignments from the canonical file.
--- @param is_assignable function Authoritative action catalogue check.
function M.load(is_assignable)
	load_configuration(is_assignable)
end

--- Applies candidate intent while the aggregate owner has fenced native dispatch.
--- This assignment owner does not acquire input or publish files.
--- @param decoded table Complete candidate configuration.
--- @param is_assignable function Authoritative action catalogue check.
--- @return boolean committed
function M.apply_configuration(decoded, is_assignable)
	if type(decoded) ~= "table" then return false end
	local called, detail = xpcall(load_configuration, debug.traceback, is_assignable, decoded)
	if not called then Logger.error(LOG, "Tap-key candidate was refused: %s.", tostring(detail)) end
	return called
end

--- Loads the assignments once; later calls keep the cached table, which
--- set_action keeps current.
--- @param is_assignable function The catalogue check.
function M.ensure_loaded(is_assignable)
	if not _assignments then M.load(is_assignable) end
end

--- The action a tap key runs, or "none".
--- @param id string
--- @return string
function M.get_action(id)
	if not _assignments then error("tap_keys.get_action() before load()") end
	return _assignments[id] or "none"
end

--- Captures the private tap assignment without calling a public getter at seal.
--- @param binding string Canonical tap binding.
--- @param action string Exact selected action.
--- @return function|nil guard Pure terminal seal.
function M.capture_action_delivery_guard(binding, action)
	if type(binding) ~= "string" or binding:sub(1, 9) ~= "tap_key__" then return nil end
	local id, assignments = binding:sub(10), _assignments
	if not assignments or assignments[id] ~= action then return nil end
	return function() return _assignments == assignments and assignments[id] == action end
end

--- Whether a loaded explicit assignment requires the shared native dispatcher.
--- @return boolean assigned
function M.has_assignments()
	if not _assignments then error("tap_keys.has_assignments() before load()") end
	for _, action in pairs(_assignments) do
		if action ~= "none" then return true end
	end
	return false
end

--- Assigns an action to a tap key ("none" gives the key back to the layout).
--- @param id string
--- @param action_id string
--- @param is_assignable function The catalogue check.
--- @return boolean Whether the assignment was stored.
function M.set_action(id, action_id, is_assignable, on_error, publication_observer)
	M.ensure_loaded(is_assignable)
	if _assignments[id] == nil then
		Logger.error(LOG, "set_action(): '%s' is not a tap key.", tostring(id))
		return false
	end
	if action_id ~= "none" and is_assignable(action_id) ~= true then
		Logger.warn(LOG, "set_action(): refusing unknown action '%s' for tap key '%s'.",
			tostring(action_id), id)
		return false
	end
	local called, committed = pcall(function()
		local _, source = read_config(on_error)
		local rows = Preferences.prepare_shortcut_updates(source,
			{ Manifest.sparse_operation(CONFIG_SECTION .. "." .. id, action_id) }, { "tap_keys" })
		return Preferences.publish_owned(ConfigPaths.get("ConfigTomlPath"), rows, source, on_error, publication_observer)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "set_action(): tap key '%s' could not be persisted.", id)
		return false
	end
	_assignments[id] = action_id
	Logger.info(LOG, "Tap key '%s' → '%s'.", id, action_id)
	return true
end

--- The tap key a keycode belongs to.
--- @param keycode integer
--- @param keyboard_type integer|nil Originating keyboard model.
--- @return string|nil id
function M.key_for_keycode(keycode, keyboard_type)
	if type(keycode) ~= "number" then return nil end
	for _, key in ipairs(M.keys()) do
		local code = Geometry.native_code(key.hs[1], key.hs[2] or key.hs[1], keyboard_type)
		if code == keycode then return key.id end
	end
	return nil
end

--- What a plain tap on a keycode should run: the tap key's action, or nil when
--- the keycode is no tap key or its key is unassigned. Memory only: it runs in
--- the eventtap callback.
--- @param keycode integer
--- @param keyboard_type integer|nil Originating keyboard model.
--- @return string|nil action, string|nil binding
function M.decide(keycode, keyboard_type)
	local id = M.key_for_keycode(keycode, keyboard_type)
	if not id or not _assignments then return nil, nil end
	local action = _assignments[id] or "none"
	if action == "none" then return nil, nil end
	return action, M.binding_id(id)
end




-- ====================================
-- ====================================
-- ======= 2/ Live key labels =========
-- ====================================
-- ====================================

--- The key's name in a menu row: the character the current input source puts
--- on an unambiguous code, or a localized physical position when its code
--- depends on the originating keyboard or produces nothing printable.
--- @param id string
--- @param i18n table The i18n module.
--- @return string
function M.display_name(id, i18n)
	local code = nil
	for _, key in ipairs(M.keys()) do
		-- A menu has no originating keyboard event. Prefer its physical position
		-- over labelling the swapped key with another keyboard's character.
		if key.id == id and #key.hs == 1 then code = key.hs[1] end
	end
	local char = code and Keycodes.character_for(code) or nil
	if type(char) ~= "string" or char == "" or char:match("^%s*$") then
		return i18n.get("menu.shortcuts.tap_keys." .. tostring(id))
	end
	return char
end

--- Test seam: forgets the key list and the assignments.
function M._reset()
	_binding_source = nil
	_binding_catalogue = nil
	_keys = nil
	_assignments = nil
end

BindingPublication.register("tap", "modules.shortcuts.tap_keys", M, M.published_binding_catalogue)

return M
