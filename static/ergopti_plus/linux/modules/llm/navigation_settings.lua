--- modules/llm/navigation_settings.lua

--- ==============================================================================
--- MODULE: LLM Navigation Settings (Linux)
--- DESCRIPTION:
--- Owns the durable modifier chord used to accept prediction slots 1 through 10.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")

local LOG = "modules.llm.navigation_settings"
local KEY = "llm.navigation.val_modifiers"
local ALLOWED = { alt = true, ctrl = true, shift = true, cmd = true }
local ORDER = { "ctrl", "alt", "shift", "cmd" }
local _value = nil
local _default = nil

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

local function shipped()
	if _default then return _default end
	local ok, value = pcall(Manifest.default_for, KEY)
	_default = ok and normalise(value) or nil
	if not _default then Logger.error(LOG, "Manifest default for '%s' is unavailable.", KEY) end
	return _default
end

function M.get()
	if _value then return _value end
	local fallback = shipped()
	if not fallback then return {} end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	local stored = ok and Storage and Storage.get(KEY, nil) or nil
	_value = normalise(stored) or fallback
	if stored ~= nil and not normalise(stored) then
		Logger.warn(LOG, "Stored validation modifiers are invalid; using the manifest default.")
	end
	return _value
end

function M.set(value)
	local candidate = normalise(value)
	local fallback = shipped()
	if not candidate or not fallback then return false end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage then return false end
	local persisted = Storage.set(KEY, candidate)
	if persisted ~= true then return false end
	_value = candidate
	Logger.info(LOG, "Validation modifiers: %s.", #candidate > 0 and table.concat(candidate, "+") or "none")
	return true
end

function M.matches(held)
	held = type(held) == "table" and held or {}
	local required = {}
	for _, modifier in ipairs(M.get()) do required[modifier] = true end
	return (held.alt == true) == (required.alt == true)
		and (held.ctrl == true) == (required.ctrl == true)
		and (held.shift == true) == (required.shift == true)
		and (held.meta == true) == (required.cmd == true)
		and held.altgr ~= true
end

function M.options()
	return {
		{}, { "alt" }, { "ctrl" }, { "shift" }, { "cmd" },
		{ "ctrl", "alt" }, { "ctrl", "shift" }, { "alt", "shift" },
		{ "shift", "cmd" },
	}
end

function M._reset()
	_value = nil
	_default = nil
end

--- Marks the exact validation chord consumed by this owner.
--- @param document table Parsed canonical configuration.
--- @param mark function Consumed-key collector.
function M.mark_config_reads(document, mark)
	require("infra.llm_preferences").mark_config_read(document, KEY, mark)
end

--- Captures the resolved modifier chord without file effects.
--- @return table snapshot
function M.configuration_snapshot() return { value = _value, default = _default } end

--- Restores the exact resolved chord after a refused transaction.
--- @param snapshot table Owner-issued snapshot.
--- @return boolean restored
function M.restore_configuration(snapshot)
	_value, _default = snapshot.value, snapshot.default
	return true
end

--- Resolves a detached candidate using the canonical navigation reader.
--- @return boolean applied
function M.reload_configuration()
	_value = nil
	return normalise(M.get()) ~= nil
end

return M
