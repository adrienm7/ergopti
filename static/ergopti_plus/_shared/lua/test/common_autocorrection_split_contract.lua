--- _shared/lua/test/common_autocorrection_split_contract.lua

--- ==============================================================================
--- MODULE: Common Autocorrection Split Reader Contract
--- DESCRIPTION:
--- Projects the immutable pre-split rules through the independently reviewed
--- editorial assignment, preserving physical order, flags and common metadata.
--- ==============================================================================

local M = {}
local Json = require("json")
local Reader = require("toml_codec.reader")
local Codec = require("toml_codec")

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local content = assert(handle:read("*a")); assert(handle:close())
	return content
end

--- Immutable source expectations and independent editorial assignment.
--- @param shared function Shared-tree resolver.
--- @return table reference
--- @return table assignment Trigger to current section.
--- @return table classification
function M.reference(shared)
	local reference = Json.decode(read(shared("tests/corpus/hotstrings/common_autocorrection_entries.json")))
	local classification = Json.decode(read(shared("data/hotstrings/common_autocorrection_sections.json")))
	local assignment = {}
	for _, section in ipairs(classification.sections) do
		for _, trigger in ipairs(section.triggers) do
			assert(assignment[trigger] == nil, "the independent classification must assign each trigger once")
			assignment[trigger] = section.id
		end
	end
	return reference, assignment, classification
end

--- Register real source-reader assertions in each driver suite.
--- @param helpers table Native test harness.
--- @param shared function Shared-tree resolver.
function M.register(helpers, shared)
	helpers.describe("common autocorrection shipped split reader", function()
		helpers.it("(common-autocorrection-split) preserves all independent rules and global order under the three runtime identities", function()
			local reference, assignment, classification = M.reference(shared)
			local path = shared("modules/hotstrings/autocorrection.toml")
			local parsed, committed = Reader.parse(path)
			helpers.assert_true(committed)
			helpers.assert_eq(parsed.sections_order, { "names", "abbreviations", "technical_terms" })
			helpers.assert_nil(parsed.sections.caps)
			local order = Reader.registration_order(parsed, "autocorrection")
			helpers.assert_eq(#order, 140)
			for index, row in ipairs(reference.entries) do
				local record = order[index]
				helpers.assert_eq(record.section, assignment[row.trigger])
				local actual = parsed.sections[record.section].entries[record.index]
				for _, key in ipairs({ "trigger", "output", "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
					helpers.assert_eq(actual[key], row[key], row.trigger .. "/" .. key)
				end
				helpers.assert_nil(actual.priority)
			end
			local meta = Codec.decode(read(path))._meta
			for _, key in ipairs({ "color", "delay", "show_tooltip", "description" }) do
				helpers.assert_eq(meta[key], reference.meta[key])
			end
			for _, section in ipairs(classification.sections) do
				helpers.assert_eq(#parsed.sections[section.id].entries, #section.triggers)
				local languages = 0
				for locale, label in pairs(meta.sections[section.id]) do
					helpers.assert_true(reference.meta.sections.caps[locale] ~= nil)
					helpers.assert_true(type(label) == "string" and label ~= "")
					languages = languages + 1
				end
				helpers.assert_eq(languages, 21)
			end
		end)
	end)
end

return M
