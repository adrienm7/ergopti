--- _shared/tests/lua/hotstrings/caret_steps_contract.lua

--- ==============================================================================
--- MODULE: Caret Steps Vectors Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/caret_steps_vectors.json through a
--- driver's user-perceived character count: the Linux injector's caret_steps
--- and the macOS composed-text walk. The AutoHotkey port replays the same file,
--- so the three hotstring Undos erase an expansion by the same characters.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
--- @param corpus_path string Absolute path of caret_steps_vectors.json.
--- @param count function The driver's character count, text -> steps.
--- @param driver string The driver's name, for the case title.
function M.register(helpers, corpus_path, count, driver)
	local Json = require("core.text.engine.json")
	local handle = assert(io.open(corpus_path, "rb"))
	local corpus = Json.decode(handle:read("*a"))
	handle:close()

	helpers.describe("caret steps vectors (caret-steps-vectors)", function()
		helpers.it("(caret-steps-vectors) " .. driver .. " counts every vector by character", function()
			helpers.assert_true(#corpus.vectors >= 10, "the corpus lists its vectors")
			for _, vector in ipairs(corpus.vectors) do
				helpers.assert_eq(count(vector.text), vector.steps, vector.name)
			end
		end)
	end)
end

return M
