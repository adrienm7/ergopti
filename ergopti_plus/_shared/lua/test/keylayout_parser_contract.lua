--- _shared/lua/test/keylayout_parser_contract.lua

--- ==============================================================================
--- MODULE: Keylayout Parser Contract
--- DESCRIPTION:
--- Replays the shared .keylayout corpus against `layouts.keylayout`: the
--- hand-checked edge fixtures (first-wins duplicates, base chains, entities,
--- comments, refused files) and the real composer layout, each compared with the
--- canonical form the corpus pins. Both Lua drivers replay it; the Python
--- converter replays the same files, so the two parsers cannot drift apart.
--- ==============================================================================

local M = {}

--- Structural equality over plain data.
local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not same(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

--- Reads and decodes one JSON file.
local function read_json(path)
	local handle = assert(io.open(path, "rb"))
	local decoded = assert(require("json").decode(handle:read("*a")))
	handle:close()
	return decoded
end

--- Reads a whole file.
local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
--- @param paths table { edge_cases, composed_keylayout, composed_canonical }.
function M.register(helpers, paths)
	local Keylayout = require("layouts.keylayout")

	helpers.describe("keylayout parser (shared contract)", function()
		helpers.it("parses every edge fixture to its canonical form or refuses it", function()
			local corpus = read_json(paths.edge_cases)
			helpers.assert_true(#corpus.vectors >= 6, "the corpus holds its fixtures")
			for _, vector in ipairs(corpus.vectors) do
				local parsed, err = Keylayout.parse(vector.keylayout)
				if vector.error then
					helpers.assert_true(parsed == nil and type(err) == "string", vector.name .. " is refused")
				else
					helpers.assert_true(parsed ~= nil, vector.name .. " parses: " .. tostring(err))
					helpers.assert_true(same(parsed, vector.canonical), vector.name)
				end
			end
		end)

		helpers.it("parses the real composer layout to the pinned canonical form", function()
			local parsed, err = Keylayout.parse(read_all(paths.composed_keylayout))
			helpers.assert_true(parsed ~= nil, "parses: " .. tostring(err))
			helpers.assert_true(same(parsed, read_json(paths.composed_canonical).canonical), "composed layout")
		end)

		helpers.it("refuses a non-string input", function()
			local parsed, err = Keylayout.parse(nil)
			helpers.assert_true(parsed == nil and type(err) == "string", "refused")
		end)
	end)
end

return M
