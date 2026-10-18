--- modules/llm/navigation_settings.lua

--- ==============================================================================
--- MODULE: LLM Navigation Settings (Linux)
--- DESCRIPTION:
--- Owns the two durable modifier chords of the prediction tooltip: the
--- validation chord that accepts prediction slots 1 through 10 with a digit,
--- and the navigation chord that moves the active slot with Up and Down.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Manifest = require("infra.manifest_reader")

local LOG = "modules.llm.navigation_settings"
local KEY = "llm.navigation.val_modifiers"
local NAVIGATION_KEY = "llm.navigation.nav_modifiers"
local KEYS = { KEY, NAVIGATION_KEY }
local LABELS = { [KEY] = "Validation modifiers", [NAVIGATION_KEY] = "Navigation modifiers" }
local ALLOWED = { alt = true, ctrl = true, shift = true, cmd = true }
local ORDER = { "ctrl", "alt", "shift", "cmd" }
local _values = {}
local _defaults = {}
local collision_epoch = 0
local function collision_dependency(name)
	local loaded, owner = pcall(require, name)
	return loaded and type(owner) == "table" and owner or nil
end
local CollisionPreferences = collision_dependency("infra.llm_preferences")
local CollisionRoutes = collision_dependency("infra.config_paths")
local CollisionWriter = collision_dependency("toml_codec.writer")
local collision_many = CollisionPreferences and CollisionPreferences.get_many
local collision_revision = CollisionPreferences and CollisionPreferences.is_current_revision
local collision_generation = CollisionPreferences and CollisionPreferences.generation
local collision_route = CollisionRoutes and CollisionRoutes.config
local collision_read = CollisionWriter and CollisionWriter.read_classified
local CollisionCodec = collision_dependency("toml_codec")
local collision_decode = CollisionCodec and CollisionCodec.decode
local collision_default = Manifest.default_for
local collision_factory

local function normalise(value)
	if type(value) ~= "table" then return nil end
	local present = {}
	for _, modifier in ipairs(value) do
		if not ALLOWED[modifier] or present[modifier] then return nil end
		present[modifier] = true
	end
	local result = {}
	for _, modifier in ipairs(ORDER) do
		if present[modifier] then result[#result + 1] = modifier end
	end
	return result
end

local function shipped(key)
	if _defaults[key] then return _defaults[key] end
	local ok, value = pcall(Manifest.default_for, key)
	_defaults[key] = ok and normalise(value) or nil
	if not _defaults[key] then Logger.error(LOG, "Manifest default for '%s' is unavailable.", key) end
	return _defaults[key]
end

local function read(key)
	if _values[key] then return _values[key] end
	local fallback = shipped(key)
	if not fallback then return {} end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	local stored = ok and Storage and Storage.get(key, nil) or nil
	_values[key] = normalise(stored) or fallback
	if stored ~= nil and not normalise(stored) then
		-- Outdated configuration: named once, offered by the cleanup.
		ConfigOutdated.report(key, ConfigOutdated.REFUSED, Logger)
	end
	return _values[key]
end

local function write(key, value)
	local candidate = normalise(value)
	local fallback = shipped(key)
	if not candidate or not fallback then return false end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage then return false end
	local persisted = Storage.set(key, candidate)
	if persisted ~= true then return false end
	_values[key] = candidate
	collision_epoch = collision_epoch + 1
	Logger.info(LOG, "%s: %s.", LABELS[key], #candidate > 0 and table.concat(candidate, "+") or "none")
	return true
end

--- Whether the held modifiers are exactly a chord's: none missing, none extra.
--- AltGr is a layout level, never part of a chord.
local function chord_matches(chord, held)
	held = type(held) == "table" and held or {}
	local required = {}
	for _, modifier in ipairs(chord) do required[modifier] = true end
	return (held.alt == true) == (required.alt == true)
		and (held.ctrl == true) == (required.ctrl == true)
		and (held.shift == true) == (required.shift == true)
		and (held.meta == true) == (required.cmd == true)
		and held.altgr ~= true
end

--- @return table The validation chord's modifiers ({} = bare digits).
function M.get() return read(KEY) end

--- Persists the validation chord, then publishes it.
--- @param value table Modifier names.
--- @return boolean committed
function M.set(value) return write(KEY, value) end

--- Whether the held modifiers are exactly the validation chord's.
--- @param held table keyboard_hook.held_modifiers()
--- @return boolean
function M.matches(held) return chord_matches(read(KEY), held) end

--- @return table The navigation chord's modifiers ({} = bare Up and Down).
function M.get_navigation() return read(NAVIGATION_KEY) end

--- Persists the navigation chord, then publishes it.
--- @param value table Modifier names.
--- @return boolean committed
function M.set_navigation(value) return write(NAVIGATION_KEY, value) end

--- Whether the held modifiers are exactly the navigation chord's.
--- @param held table keyboard_hook.held_modifiers()
--- @return boolean
function M.matches_navigation(held) return chord_matches(read(NAVIGATION_KEY), held) end

function M.options()
	return {
		{}, { "alt" }, { "ctrl" }, { "shift" }, { "cmd" },
		{ "ctrl", "alt" }, { "ctrl", "shift" }, { "alt", "shift" },
		{ "shift", "cmd" },
	}
end

function M._reset()
	collision_epoch = collision_epoch + 1
	_values = {}
	_defaults = {}
end

--- Marks the exact chords consumed by this owner.
--- @param document table Parsed canonical configuration.
--- @param mark function Consumed-key collector.
function M.mark_config_reads(document, mark)
	local Preferences = require("infra.llm_preferences")
	for _, key in ipairs(KEYS) do
		Preferences.mark_config_read(document, key, mark,
			function(value) return normalise(value) ~= nil end)
	end
end

--- Captures the resolved modifier chords without file effects.
--- @return table snapshot
function M.configuration_snapshot()
	local snapshot = { values = {}, defaults = {} }
	for _, key in ipairs(KEYS) do
		snapshot.values[key], snapshot.defaults[key] = _values[key], _defaults[key]
	end
	return snapshot
end

--- Restores the exact resolved chords after a refused transaction.
--- @param snapshot table Owner-issued snapshot.
--- @return boolean restored
function M.restore_configuration(snapshot)
	collision_epoch = collision_epoch + 1
	_values, _defaults = {}, {}
	for _, key in ipairs(KEYS) do
		_values[key], _defaults[key] = snapshot.values[key], snapshot.defaults[key]
	end
	return true
end

--- Resolves a detached candidate using the canonical navigation reader.
--- @return boolean applied
function M.reload_configuration()
	collision_epoch = collision_epoch + 1
	_values = {}
	for _, key in ipairs(KEYS) do
		if normalise(read(key)) == nil then return false end
	end
	return true
end

local collision_get, collision_nav = M.get, M.get_navigation
local collision_matches, collision_nav_matches = M.matches, M.matches_navigation

local function detached_chord(value)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local copy, fields = normalise(value), 0
	if not copy or #copy ~= #value then return nil end
	for index, modifier in pairs(value) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value
			or copy[index] ~= modifier then return nil end
		fields = fields + 1
	end
	return fields == #copy and copy or nil
end

local function same_chord(value, copy)
	local detached = detached_chord(value)
	if not detached or #detached ~= #copy then return false end
	for index, modifier in ipairs(copy) do if detached[index] ~= modifier then return false end end
	return true
end

--- Captures actual configured tooltip chords and the original preference source.
--- No offer, overlay, provider or runtime observer is queried.
--- @return table|nil frame Original source/runtime guards and detached modifiers.
function M.capture_collision_configuration()
	if type(collision_many) ~= "function" or type(collision_revision) ~= "function"
		or type(collision_generation) ~= "function" or type(collision_route) ~= "function"
		or type(collision_read) ~= "function" or type(collision_decode) ~= "function"
		or type(collision_default) ~= "function" then return nil end
	local function ports_current()
		return rawequal(package.loaded["modules.llm.navigation_settings"], M) and getmetatable(M) == nil
			and M.get == collision_get and M.get_navigation == collision_nav
			and M.matches == collision_matches and M.matches_navigation == collision_nav_matches
			and M.capture_collision_configuration == collision_factory
			and rawequal(package.loaded["infra.llm_preferences"], CollisionPreferences)
			and CollisionPreferences.get_many == collision_many and CollisionPreferences.is_current_revision == collision_revision
			and CollisionPreferences.generation == collision_generation
			and rawequal(package.loaded["infra.config_paths"], CollisionRoutes) and CollisionRoutes.config == collision_route
			and rawequal(package.loaded["toml_codec.writer"], CollisionWriter) and CollisionWriter.read_classified == collision_read
			and rawequal(package.loaded["infra.manifest_reader"], Manifest) and Manifest.default_for == collision_default
			and rawequal(package.loaded["toml_codec"], CollisionCodec) and CollisionCodec.decode == collision_decode
	end
	if not ports_current() then return nil end
	local path = collision_route("config.toml")
	local observed, validation = pcall(read, KEY)
	if not observed then return nil end
	local navigated, navigation = pcall(read, NAVIGATION_KEY)
	if not navigated then return nil end
	validation, navigation = detached_chord(validation), detached_chord(navigation)
	if not validation or not navigation then return nil end
	local captured, values, source = pcall(collision_many, { KEY, NAVIGATION_KEY, "llm.enabled" })
	if not captured or type(values) ~= "table" or type(source) ~= "table"
		or source.status ~= "ok" and source.status ~= "absent"
		or source.status == "ok" and type(source.content) ~= "string"
		or type(values["llm.enabled"]) ~= "boolean" then return nil end
	local expected_validation = normalise(values[KEY]) or normalise(collision_default(KEY))
	local expected_navigation = normalise(values[NAVIGATION_KEY]) or normalise(collision_default(NAVIGATION_KEY))
	if not expected_validation or not expected_navigation or not same_chord(validation, expected_validation)
		or not same_chord(navigation, expected_navigation) then return nil end
	local generated, revision = pcall(collision_generation)
	if not generated or not ports_current() then return nil end
	local epoch, actual, defaults = collision_epoch, _values, _defaults
	local bytes, status, enabled = source.content, source.status, values["llm.enabled"]
	local function runtime()
		return ports_current() and collision_epoch == epoch and rawequal(_values, actual) and rawequal(_defaults, defaults)
			and same_chord(actual[KEY], validation) and same_chord(actual[NAVIGATION_KEY], navigation)
			and collision_revision(revision) == true
	end
	local function current()
		if not runtime() or collision_route("config.toml") ~= path then return false end
		local queried, _, fresh = pcall(collision_many, { KEY, NAVIGATION_KEY, "llm.enabled" })
		return queried and type(fresh) == "table" and fresh.content == bytes and fresh.status == status
			and collision_route("config.toml") == path and runtime()
	end
	if not current() then return nil end
	return { path = path, content = bytes, status = status, enabled = enabled,
		validation = validation, navigation = navigation, current = current, sealed = runtime }
end
collision_factory = M.capture_collision_configuration

return M
