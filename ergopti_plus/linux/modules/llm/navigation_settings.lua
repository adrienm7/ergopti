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
	_values, _defaults = {}, {}
	for _, key in ipairs(KEYS) do
		_values[key], _defaults[key] = snapshot.values[key], snapshot.defaults[key]
	end
	return true
end

--- Resolves a detached candidate using the canonical navigation reader.
--- @return boolean applied
function M.reload_configuration()
	_values = {}
	for _, key in ipairs(KEYS) do
		if normalise(read(key)) == nil then return false end
	end
	return true
end

return M
