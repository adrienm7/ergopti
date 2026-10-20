--- infra/capsword_auto_off.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Settings (macOS)
--- DESCRIPTION:
--- Owns the [shortcuts.caps_word] settings on macOS: their menu-state keys,
--- their manifest defaults and the compiled shared policy
--- (_shared/lua/caps_word/auto_off.lua) that platform/remap/watchers.lua asks
--- for every keystroke and pointer event while CapsWord is on.
---
--- FEATURES & RATIONALE:
--- 1. No Local Lists: the pointer kinds are the macOS entries of the manifest
---    section shortcuts.caps_word.pointer, held as one table keyed by kind; the
---    delimiters are the hotstring catalogue's keys (through the policy); the
---    defaults are the manifest's.
--- 2. Live Apply: apply_state() recompiles from the menu state, so a menu change
---    reaches the next event without restarting the Karabiner lease watcher.
--- 3. Fail Fast: a state the policy refuses keeps the previous policy and is
---    reported as an ERROR; the loader has already read an outdated stored value
---    as its default, so a refusal here is a driver defect, never user data.
--- ==============================================================================

local M = {}

local Logger   = require("infra.logger")
local Manifest = require("infra.manifest_reader")
local Policy   = require("caps_word.auto_off")

local LOG = "capsword"
local PLATFORM = "hs"
local SECTION = "shortcuts.caps_word"
local POINTER_SECTION = "shortcuts.caps_word.pointer"

--- Menu-state key of the inactivity delay.
M.IDLE_KEY = "caps_word_idle_timeout_seconds"
--- Menu-state key of the delimiter list.
M.TERMINATORS_KEY = "caps_word_terminators"
--- Menu-state key of the pointer table (kind -> boolean).
M.POINTER_KEY = "caps_word_pointer"

--- Whether a declaration exists on this driver.
--- @param entry table Manifest declaration.
--- @return boolean
local function on_this_platform(entry)
	for _, platform in ipairs(entry.platforms or {}) do
		if platform == PLATFORM then return true end
	end
	return false
end

-- The pointer kinds this driver declares, in manifest order.
local POINTER_KINDS = {}
for _, entry in ipairs(Manifest.declared_section_entries(POINTER_SECTION)) do
	if on_this_platform(entry) then POINTER_KINDS[#POINTER_KINDS + 1] = entry.id end
end
assert(#POINTER_KINDS > 0, "the manifest declares no macOS CapsWord pointer kind")

--- The declared pointer kinds, in manifest order (a detached copy).
--- @return table kinds
function M.pointer_kinds()
	local copy = {}
	for index, kind in ipairs(POINTER_KINDS) do copy[index] = kind end
	return copy
end

--- Detached copy of one setting value.
local function copy_value(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, item in pairs(value) do copy[key] = item end
	return copy
end

--- Detached copy of the owned keys of a menu state.
--- @param state table Menu state (flat keys).
--- @return table values
local function owned_values(state)
	return {
		[M.IDLE_KEY] = copy_value(state[M.IDLE_KEY]),
		[M.TERMINATORS_KEY] = copy_value(state[M.TERMINATORS_KEY]),
		[M.POINTER_KEY] = copy_value(state[M.POINTER_KEY]),
	}
end

--- Detached manifest defaults, keyed by menu-state key (Preferences folds every
--- core module's DEFAULT_STATE into the boot state).
local function manifest_defaults()
	local pointer = {}
	for _, kind in ipairs(POINTER_KINDS) do
		pointer[kind] = Manifest.default_for(POINTER_SECTION .. "." .. kind)
	end
	return {
		[M.IDLE_KEY] = Manifest.default_for(SECTION .. ".idle_timeout_seconds"),
		[M.TERMINATORS_KEY] = Manifest.default_for(SECTION .. ".terminators"),
		[M.POINTER_KEY] = pointer,
	}
end

M.DEFAULT_STATE = manifest_defaults()





-- ========================================
-- ========================================
-- ======= 1/ Compiled Policy Owner =======
-- ========================================
-- ========================================

--- Compiles the policy values a menu-state table holds.
--- @param state table Menu state (flat keys).
--- @return table|nil policy
--- @return string|nil reason
local function compile_state(state)
	if type(state) ~= "table" then return nil, "invalid_settings" end
	return Policy.compile({
		idle_timeout_seconds = state[M.IDLE_KEY],
		terminators = state[M.TERMINATORS_KEY],
		pointer = state[M.POINTER_KEY],
	}, POINTER_KINDS)
end

local _policy = assert(compile_state(M.DEFAULT_STATE), "the manifest CapsWord defaults do not compile")
local _values = owned_values(M.DEFAULT_STATE)

--- Applies the CapsWord settings of one menu state.
--- @param state table Menu state (flat keys).
--- @return boolean applied True when the state compiled and is now current.
function M.apply_state(state)
	local policy, reason = compile_state(state)
	if not policy then
		Logger.error(LOG, "CapsWord auto-off settings refused (%s); the previous ones stay in force.",
			tostring(reason))
		return false
	end
	_policy = policy
	_values = owned_values(state)
	local enabled = {}
	for _, kind in ipairs(POINTER_KINDS) do
		if policy.pointer[kind] then enabled[#enabled + 1] = kind end
	end
	Logger.debug(LOG, "CapsWord auto-off: delay=%ss, delimiters=[%s], pointer=[%s].",
		tostring(state[M.IDLE_KEY]), table.concat(state[M.TERMINATORS_KEY], ","),
		table.concat(enabled, ","))
	return true
end

--- The compiled policy in force.
--- @return table policy
function M.policy()
	return _policy
end

--- The settings in force, by menu-state key (a detached copy), for an owner
--- that must restore exactly what runs (the Shortcuts scope transaction).
--- @return table values
function M.current_values()
	return owned_values(_values)
end

return M
