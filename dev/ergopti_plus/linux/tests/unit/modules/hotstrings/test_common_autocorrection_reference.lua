--- tests/unit/modules/hotstrings/test_common_autocorrection_reference.lua

--- ==============================================================================
--- MODULE: Common Autocorrection Historical Reference (Linux)
--- DESCRIPTION:
--- Pins the actual shipped-file reader and catalogue loader to the independent
--- pre-split reference, including registration order and collision priority.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Json = require("json")
local Reader = require("toml_codec.reader")
local Codec = require("toml_codec.codec")

--- Reads one required source or independent reference file.
--- @param path string
--- @return string
local function read_file(path)
	local handle = assert(io.open(path, "r"))
	local text = handle:read("*a")
	handle:close()
	return text
end

helpers.describe("common autocorrection historical reference", function()
	helpers.it("(common-autocorrection-reference) preserves the complete source and all 140 historical reader entries", function()
		local expected = Json.decode(read_file(Paths.shared("tests/corpus/hotstrings/common_autocorrection_entries.json")))
		helpers.assert_eq(#expected.entries, 140)
		helpers.assert_eq(expected.source, "common")
		helpers.assert_eq(expected.source_priority, 10)
		helpers.assert_eq(expected.legacy_section, "caps")
		local path = Paths.shared("modules/hotstrings/autocorrection.toml")
		helpers.assert_eq(Codec.decode(read_file(path))._meta, expected.meta)
		local parsed, committed = Reader.parse(path)
		helpers.assert_true(committed)
		helpers.assert_eq(parsed.sections_order, { "caps" })
		helpers.assert_eq(#parsed.sections.caps.entries, 140)
		local sections = 0
		for _ in pairs(parsed.sections) do sections = sections + 1 end
		helpers.assert_eq(sections, 1, "the editorial catalogue does not change runtime selection")
		for index, row in ipairs(expected.entries) do
			helpers.assert_eq(row.ordinal, index)
			helpers.assert_eq(row.section, "caps")
			local actual = parsed.sections.caps.entries[index]
			for _, field in ipairs({ "trigger", "output", "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
				helpers.assert_eq(actual[field], row[field], row.trigger .. "/" .. field)
			end
			helpers.assert_nil(actual.priority)
			helpers.assert_true(actual.is_case_sensitive_strict ~= true)
		end
	end)

	helpers.it("(common-autocorrection-reference) loads every mapping exactly once with its historical flags, order and common tier", function()
		local expected = Json.decode(read_file(Paths.shared("tests/corpus/hotstrings/common_autocorrection_entries.json")))
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local catalogue = Loader.load_catalogue({ Paths.shared("modules/hotstrings/autocorrection.toml") })
		helpers.assert_true(catalogue.committed)
		helpers.assert_eq(catalogue.errors, 0)
		helpers.assert_eq(#catalogue.mappings, 140)
		local category = catalogue.categories.autocorrection
		helpers.assert_true(category ~= nil)
		helpers.assert_eq(category.sections_order, expected.meta.sections_order)
		helpers.assert_eq(category.count, 140)
		helpers.assert_eq(category.sections.caps.count, 140)
		helpers.assert_eq(category.description, expected.meta.description)
		helpers.assert_eq(category.delay, expected.meta.delay)
		helpers.assert_eq(category.color, expected.meta.color)
		helpers.assert_eq(category.show_tooltip, expected.meta.show_tooltip)
		for index, row in ipairs(expected.entries) do
			local actual = catalogue.mappings[index]
			helpers.assert_eq(row.ordinal, index)
			helpers.assert_eq(actual.group, expected.category)
			helpers.assert_eq(actual.section, row.section)
			helpers.assert_eq(actual.trigger, row.trigger)
			helpers.assert_eq(actual.replacement, row.output)
			helpers.assert_eq(actual.priority, expected.source_priority)
			for _, flag in ipairs({ "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
				helpers.assert_eq(actual[flag], row[flag], row.trigger .. "/" .. flag)
			end
			helpers.assert_eq(actual.is_case_sensitive_strict, false)
			helpers.assert_eq(actual.is_private, false)
		end
	end)
end)
