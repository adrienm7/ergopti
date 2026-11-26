--- _shared/tests/lua/physical_conflicts_vectors_contract.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Collision Vectors Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/shortcuts/physical_conflict_vectors.json
--- through the shared policy (_shared/shortcuts/engine/physical_conflicts.lua).
--- The Windows AutoHotkey port replays the same file, so the three drivers
--- answer every vector alike. macOS and Linux both register it.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
--- @param corpus_path string Absolute path of physical_conflict_vectors.json.
function M.register(helpers, corpus_path)
	local Json = require("core.text.engine.json")
	local Policy = require("shortcuts.engine.physical_conflicts")

	local handle = assert(io.open(corpus_path, "rb"))
	local corpus = Json.decode(handle:read("*a"))
	handle:close()

	--- JSON objects decode as tables; empty ones too, which the policy needs plain.
	local function plain(value)
		if type(value) ~= "table" then return value end
		local copy = {}
		for key, item in pairs(value) do copy[key] = plain(item) end
		return copy
	end

	helpers.describe("physical shortcut collision vectors (physical-conflict-vectors)", function()
		helpers.it("(physical-conflict-vectors) the shared policy answers every vector", function()
			helpers.assert_true(#corpus.vectors >= 10, "the corpus lists its vectors")
			for _, vector in ipairs(corpus.vectors) do
				local claims = plain(vector.claims)
				local collision, binding = Policy.conflicts(plain(vector.request), claims)
				-- JSON null (refused input) decodes as a sentinel; the policy answers nil.
				local expected = vector.expect
				if expected ~= true and expected ~= false then expected = nil end
				helpers.assert_eq(collision, expected, vector.name)
				if expected == true then helpers.assert_eq(binding, vector.binding, vector.name .. " (binding)") end
			end
		end)
	end)
end

return M
