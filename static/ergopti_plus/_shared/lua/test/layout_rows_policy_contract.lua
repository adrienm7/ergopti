--- _shared/lua/test/layout_rows_policy_contract.lua

--- ==============================================================================
--- MODULE: Layout Rows Policy Contract
--- DESCRIPTION:
--- Replays the hand-written layout-rows corpus through the shared Lua policy:
--- the keys of each emulated row read from the physical-key registry, and each
--- row switch's decision. The Windows driver replays the same corpus.
--- ==============================================================================

local M = {}
local Policy = require("layout.layout_rows_policy")
local Json = require("json")

-- Lossless, so a JSON null (a character key's Send name) stays Json.is_null.
local function read_json(path)
	local file = assert(io.open(path, "rb"))
	local content = file:read("*a")
	assert(file:close())
	return Json.decode_lossless(content)
end

--- Registers the row-key and switch cases.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string The shared tests/corpus/layouts/layout_rows.json.
function M.run(helpers, corpus_path)
	local corpus = read_json(corpus_path)
	local shared = corpus_path:gsub("tests/corpus/layouts/layout_rows%.json$", "")
	helpers.describe("Shared layout rows policy", function()
		helpers.it("reads each emulated row's keys from the physical-key registry (layout-row-scopes)", function()
			local registry = read_json(shared .. "data/keycodes/physical_keys.json")
			local rows = Policy.keys(registry, Json.is_null)
			helpers.assert_eq(#Policy.IDS, 4, "four row switches")
			for _, row in ipairs(Policy.IDS) do
				local expected = corpus.rows[row]
				helpers.assert_eq(#rows[row], #expected, row .. ": key count")
				for index, code in ipairs(expected) do
					helpers.assert_eq(rows[row][index], code, row .. " key " .. index)
				end
			end
			helpers.assert_eq(pcall(Policy.keys, {}), false, "a registry without keys is refused")
		end)
		helpers.it("decides each row from its own switch (layout-row-scopes)", function()
			helpers.assert_eq(#corpus.switches, 4, "every switch case is represented")
			for _, case in ipairs(corpus.switches) do
				for _, row in ipairs(Policy.IDS) do
					helpers.assert_eq(Policy.emulates(case.layout, row), case.emulated[row], case.id .. ": " .. row)
				end
				helpers.assert_eq(Policy.number_row_source(true, case.layout), case.number_row_source.active,
					case.id .. ": the ordering's row under an active emulation")
				helpers.assert_eq(Policy.number_row_source(false, case.layout), case.number_row_source.inactive,
					case.id .. ": the ordering's row without an emulation")
			end
			for _, case in ipairs(corpus.invalid) do
				helpers.assert_eq(pcall(Policy.emulates, case.layout, case.row), false, case.id .. " is refused")
			end
		end)
	end)
end

return M
