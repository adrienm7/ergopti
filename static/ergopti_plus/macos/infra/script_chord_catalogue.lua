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
local _binding_catalogue = nil





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
	local read_ok, raw = pcall(handle.read, handle, "*a")
	local close_ok, closed = pcall(handle.close, handle)
	if not read_ok or type(raw) ~= "string" or not close_ok or closed ~= true then
		error("script chords: cannot complete read of " .. tostring(path))
	end
	local ok, decoded = pcall(Json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		error("script chords: " .. tostring(path) .. " is malformed")
	end
	local catalogue = ScriptChords.catalogue(decoded)
	local binding = { prefix = "script__", slots = {} }
	for _, slot in ipairs(catalogue.slots) do binding.slots[slot.id] = true end
	require("config_binding_identity").script_binding_fits("script__", binding)
	_catalogue, _binding_catalogue = catalogue, binding
	return _catalogue
end

--- Returns only a detached, already acknowledged complete binding publication.
--- This accessor performs no IO or runtime initialization.
--- @return table|nil catalogue
function M.published_binding_catalogue()
	if _binding_catalogue == nil then return nil end
	local publication = { prefix = _binding_catalogue.prefix, slots = {} }
	for id in pairs(_binding_catalogue.slots) do publication.slots[id] = true end
	return publication
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
	_binding_catalogue = nil
end

return M
