--- _shared/tests/lua/keyboard/script_chord_hint_contract.lua

--- ==============================================================================
--- MODULE: Script Chord Hint Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/shortcuts/script_chord_hint_vectors.json through
--- keyboard.engine.layers.script_chords (hint_slot) on both Lua drivers, against
--- the real script_chords.json catalogue. Windows replays the same vectors
--- through _shared/keyboard/engine/layers/script_chord_hint.ahk.
--- ==============================================================================

local M = {}

--- Reads one shared JSON document.
--- @param json table The driver's JSON codec.
--- @param path string Absolute path.
--- @return table document
local function read_json(json, path)
	local handle = assert(io.open(path, "rb"))
	local body = handle:read("*a")
	handle:close()
	return assert(json.decode(body))
end

--- Registers the hint checks in a driver's existing owner.
--- @param helpers table The driver's describe/it/assertion functions.
--- @param json table The driver's JSON codec.
--- @param shared_root string Absolute shared source directory.
function M.register(helpers, json, shared_root)
	local ScriptChords = require("keyboard.engine.layers.script_chords")
	local catalogue = ScriptChords.catalogue(read_json(json, shared_root .. "/shortcuts/data/actions/script_chords.json"))
	local corpus = read_json(json, shared_root .. "/tests/corpus/shortcuts/script_chord_hint_vectors.json")
	assert(type(corpus.vectors) == "table" and #corpus.vectors >= 9,
		"script_chord_hint_vectors.json must hold its nine vectors")
	helpers.describe("script chord tray hint (script-chord-tray-hint)", function()
		for _, vector in ipairs(corpus.vectors) do
			local case = vector
			helpers.it("(script-chord-tray-hint) " .. case.id, function()
				local assignments = {}
				for _, slot in ipairs(catalogue.slots) do
					assignments[slot.id] = case.assignments[slot.id] or "none"
				end
				local slot = ScriptChords.hint_slot(catalogue, assignments, case.chords_on, case.action)
				helpers.assert_eq(slot or "", case.expected)
			end)
		end
		helpers.it("(script-chord-tray-hint) refuses a row without an action id", function()
			helpers.assert_eq(pcall(ScriptChords.hint_slot, catalogue, {}, true, "none"), false)
			helpers.assert_eq(pcall(ScriptChords.hint_slot, catalogue, nil, true, "script_quit"), false)
		end)
	end)
end

return M
