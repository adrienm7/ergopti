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

--- Builds a complete private layout around the numeric attribute under test.
local function numeric_fixture(attribute, raw, output)
	local default_index = attribute == "defaultIndex" and raw or "0"
	local map_index = attribute == "mapIndex" and raw or "0"
	local index = attribute == "index" and raw or "0"
	local base_index = attribute == "baseIndex" and raw or "0"
	local code = attribute == "code" and raw or "3"
	return '<keyboard name="Numeric"><layouts><layout first="0" modifiers="mods" mapSet="maps"/></layouts>'
		.. '<modifierMap id="mods" defaultIndex="' .. default_index .. '"><keyMapSelect mapIndex="' .. map_index
		.. '"><modifier keys=""/></keyMapSelect></modifierMap><keyMapSet id="maps"><keyMap index="' .. index
		.. '" baseMapSet="base" baseIndex="' .. base_index .. '"><key code="' .. code .. '" output="'
		.. (output or "A") .. '"/></keyMap></keyMapSet><keyMapSet id="base"><keyMap index="0"/></keyMapSet></keyboard>'
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

		helpers.it("refuses wrapped hexadecimal attributes without changing ordinary numeric grammar", function()
			for _, attribute in ipairs({"code", "defaultIndex", "mapIndex", "index", "baseIndex"}) do
				for _, raw in ipairs({"0x10000000000000003", "-0xFFFFFFFFFFFFFFFD", "0x8000000000000000", "-0x8000000000000001"}) do
					local parsed, err = Keylayout.parse(numeric_fixture(attribute, raw))
					helpers.assert_true(parsed == nil and type(err) == "string", attribute .. ": " .. raw .. " refused")
				end
				for _, raw in ipairs({"3", "0003", "+3", "0x3", "0X0003", " +0x0003 ", "3.5", "3e0"}) do
					local parsed, err = Keylayout.parse(numeric_fixture(attribute, raw))
					helpers.assert_true(parsed ~= nil, attribute .. ": " .. raw .. " retained: " .. tostring(err))
				end
			end
		end)

		helpers.it("keeps both exact signed native hexadecimal edges", function()
			for _, raw in ipairs({"0x7FFFFFFFFFFFFFFF", "-0x8000000000000000", "0x000000000000000000000003"}) do
				local parsed, err = Keylayout.parse(numeric_fixture("code", raw))
				helpers.assert_true(parsed ~= nil, raw .. ": " .. tostring(err))
				helpers.assert_true(parsed.key_map_sets[1].key_maps[1].keys[1].code == tonumber(raw), raw .. " keeps its value")
			end
		end)

		helpers.it("refuses overflowing and surrogate XML entities before output", function()
			for _, output in ipairs({"&#x10000000000000041;", "&#18446744073709551681;", "&#4294967361;", "&#x100000041;",
				"&#1114112;", "&#x110000;", "&#55296;", "&#xD800;", "&#57343;", "&#xDFFF;"}) do
				local ok, parsed, err = pcall(Keylayout.parse, numeric_fixture("", "", output))
				helpers.assert_true((not ok and type(parsed) == "string" and parsed:find("character reference", 1, true) ~= nil) or (parsed == nil and type(err) == "string"), output .. " cannot publish an invalid scalar")
			end
		end)

		helpers.it("preserves scalar edges, leading zeros and control placeholders", function()
			local vectors = {
				{"&#00065;", "A"}, {"&#x000041;", "A"}, {"&#0;", string.char(0)}, {"&#x10;", string.char(16)},
				{"&#xD7FF;", string.char(0xED, 0x9F, 0xBF)}, {"&#xE000;", string.char(0xEE, 0x80, 0x80)},
				{"&#x10FFFF;", string.char(0xF4, 0x8F, 0xBF, 0xBF)},
			}
			for _, vector in ipairs(vectors) do
				local parsed, err = Keylayout.parse(numeric_fixture("", "", vector[1]))
				helpers.assert_true(parsed ~= nil, vector[1] .. ": " .. tostring(err))
				helpers.assert_true(parsed.key_map_sets[1].key_maps[1].keys[1].output == vector[2], vector[1] .. " stays exact")
			end
		end)
	end)
end

return M
