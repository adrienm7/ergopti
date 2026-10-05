--- _shared/lua/test/release_parser_contract.lua

--- ==============================================================================
--- MODULE: Shared Lua Release Notes Contract
--- DESCRIPTION:
--- Pins selected-object field lookup and the Lua parser's established CR removal.
--- Windows retains separate historical wrapper/CR behavior; universal JSON
--- string escapes remain in the cross-driver release-parser corpus.
--- ==============================================================================

local M = {}
local NOTES = {
	{
		id = "notes_nested_body_not_notes",
		body = "{\"metadata\":{\"body\":\"Misleading nested notes\"},\"body\":\"Actual release notes\"}",
		expected = "Actual release notes",
	},
	{
		id = "notes_nested_null_not_notes",
		body = "{\"metadata\":{\"body\":null},\"body\":\"Actual release notes\"}",
		expected = "Actual release notes",
	},
	{
		id = "notes_carriage_return_normalization",
		body = "{\"body\":\"Line 1\\r\\nLine 2\\rEnd\"}",
		expected = "Line 1\nLine 2End",
	},
	{
		id = "notes_missing_root_body",
		body = "{\"metadata\":{\"body\":\"Nested only\"}}",
		expected = "",
	},
	{
		id = "notes_number_field",
		body = "{\"body\":123}",
		expected = "",
	},
	{
		id = "notes_boolean_field",
		body = "{\"body\":true}",
		expected = "",
	},
	{
		id = "notes_object_field",
		body = "{\"body\":{\"body\":\"Nested only\"}}",
		expected = "",
	},
	{
		id = "notes_array_wrapper",
		body = "[{\"body\":\"Nested only\"}]",
		expected = "",
	},
	{
		id = "notes_null_release",
		body = "null",
		expected = "",
	},
	{
		id = "notes_malformed_json",
		body = "{\"body\":\"Not a valid release\"} trailing",
		expected = "",
	},
}

--- Registers the shared Lua object and normalization contract in a driver suite.
--- @param helpers table Case registration and assertions.
--- @param Parser table Actual shared release parser under test.
function M.run(helpers, Parser)
	helpers.describe("shared Lua release notes contract", function()
		helpers.it("parse_notes: refuses nonstring arguments and returns one string", function()
			helpers.assert_eq(#NOTES, 10, "every selected-object and normalization vector is retained")
			for _, value in ipairs({ false, true, 1, {}, function() end }) do
				helpers.assert_eq(Parser.parse_notes(value), "", "release JSON must be a string")
			end
			helpers.assert_eq(Parser.parse_notes(nil), "")
			helpers.assert_eq(select("#", Parser.parse_notes('{"body":"Line 1\\r\\nLine 2"}')), 1,
				"normalization does not expose gsub's replacement count")
		end)
		for _, row in ipairs(NOTES) do
			helpers.it("parse_notes: " .. row.id, function()
				helpers.assert_eq(Parser.parse_notes(row.body), row.expected, row.id)
			end)
		end
	end)
end

return M
