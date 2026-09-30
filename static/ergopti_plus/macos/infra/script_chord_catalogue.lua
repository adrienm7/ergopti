--- infra/script_chord_catalogue.lua

--- ==============================================================================
--- MODULE: Script Chord Catalogue (macOS)
--- DESCRIPTION:
--- Reads the four script-management chords every driver shares
--- (_shared/modules/actions/script_chords.json) through the shared rule module
--- (_shared/lua/script_chords.lua), and answers what an empty configuration
--- holds for them: each slot on its manifest default, which is its preset, and
--- the submenu's switch on its default.
---
--- FEATURES & RATIONALE:
--- 1. One reader for the two owners of the chords: the script-control eventtap
---    (modules/shortcuts/script_control.lua) and the Karabiner rules that turn
---    each chord into its sentinel (platform/remap/script_chord_rules.lua).
--- 2. Read once and kept: an eventtap callback may only do bounded in-memory
---    work, and a malformed catalogue raises at the first read instead of
---    booting without the chords. Read with the pure-Lua JSON decoder, which
---    needs no Hammerspoon runtime, like the other shared data readers.
--- ==============================================================================

local M = {}

local Paths        = require("infra.paths")
local Json         = require("json")
local ScriptChords = require("script_chords")

-- The shared catalogue, relative to the shared tree.
local CATALOGUE_REL_PATH = "modules/actions/script_chords.json"

-- The manifest section holding the slots and the switch.
local SECTION = "shortcuts.script_control"

-- The validated catalogue; nil until the first read.
local _catalogue = nil





-- ================================
-- ================================
-- ======= 1/ The catalogue =======
-- ================================
-- ================================

--- The validated catalogue, read once.
--- @return table catalogue See ScriptChords.catalogue.
function M.get()
	if _catalogue then return _catalogue end
	local path = Paths.shared(CATALOGUE_REL_PATH)
	local handle = path and io.open(path, "rb")
	if not handle then error("script chords: cannot read " .. tostring(path)) end
	local raw = handle:read("*a")
	handle:close()
	local ok, decoded = pcall(Json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		error("script chords: " .. tostring(path) .. " is malformed")
	end
	_catalogue = ScriptChords.catalogue(decoded)
	return _catalogue
end

--- The manifest path of a slot or of the switch.
--- @param key string A slot id or "chords_enabled".
--- @return string path
function M.path(key)
	return SECTION .. "." .. key
end

--- What an empty configuration holds: every slot on its manifest default and
--- the switch on its own.
--- @return table assignments Slot id -> action id.
--- @return boolean chords_on
function M.defaults()
	-- Required here, not at load: the gesture layer reads only the paused
	-- actions, and must not pull the whole manifest reader in with them.
	local Manifest = require("infra.manifest_reader")
	local assignments = {}
	for _, slot in ipairs(M.get().slots) do
		assignments[slot.id] = Manifest.default_for(M.path(slot.id))
	end
	local chords_on = Manifest.default_for(M.path("chords_enabled"))
	assert(type(chords_on) == "boolean", "script chords: the switch default must be a boolean")
	return assignments, chords_on
end

--- The Karabiner plan of an empty configuration.
--- @return table chords { normal = slot id -> true, paused = slot id -> true }
function M.default_plan()
	local assignments, chords_on = M.defaults()
	return ScriptChords.plan(M.get(), assignments, chords_on)
end

--- Test seam: forgets the catalogue read.
function M._reset()
	_catalogue = nil
end

return M
