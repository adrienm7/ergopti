--- _shared/lua/test/release_parser_contract.lua

--- ==============================================================================
--- MODULE: Shared Lua Release Metadata Contract
--- DESCRIPTION:
--- Pins selected-object metadata, tag-wrapper order and established CR removal.
--- Windows still scans raw tag and publication-time fields and has historical notes wrapper/CR
--- differences. Universal notes escapes remain in the cross-driver corpus;
--- this owner pins the Lua metadata contract without hiding those differences.
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

local TAGS = {
	{ id = "escaped_digit",
		body = "{\"tag_name\":\"v\\u0031.2.0\"}",
		expected = "v1.2.0" },
	{ id = "escaped_prefix",
		body = "{\"tag_name\":\"\\u0076\\u0031.2.0\"}",
		expected = "v1.2.0" },
	{ id = "escaped_key",
		body = "{\"tag_\\u006eame\":\"v1.2.0\"}",
		expected = "v1.2.0" },
	{ id = "nested_tag_not_release",
		body = "{\"author\":{\"tag_name\":\"v9.9.9\"},\"tag_name\":\"v1.2.0\"}",
		expected = "v1.2.0" },
	{ id = "nested_only",
		body = "{\"author\":{\"tag_name\":\"v9.9.9\"}}",
		expected = "" },
	{ id = "single_wrapper",
		body = "[{\"tag_name\":\"v1.2.0\"}]",
		expected = "v1.2.0" },
	{ id = "multi_wrapper_first_entry",
		body = "[{\"tag_name\":\"v1.2.0\"},{\"tag_name\":\"v9.9.9\"}]",
		expected = "v1.2.0" },
	{ id = "wrapper_missing_first_tag",
		body = "[{},{\"tag_name\":\"v9.9.9\"}]",
		expected = "" },
	{ id = "wrapper_nonstring_first_tag",
		body = "[{\"tag_name\":123},{\"tag_name\":\"v9.9.9\"}]",
		expected = "" },
	{ id = "wrapper_nonobject_first",
		body = "[false,{\"tag_name\":\"v9.9.9\"}]",
		expected = "" },
	{ id = "wrapper_null_first",
		body = "[null,{\"tag_name\":\"v9.9.9\"}]",
		expected = "" },
	{ id = "wrapper_nested_first",
		body = "[{\"author\":{\"tag_name\":\"v9.9.9\"}},{\"tag_name\":\"v2.0.0\"}]",
		expected = "" },
	{ id = "malformed_trailing",
		body = "{\"tag_name\":\"v1.2.0\"} trailing",
		expected = "" },
	{ id = "number_field",
		body = "{\"tag_name\":123}",
		expected = "" },
	{ id = "boolean_field",
		body = "{\"tag_name\":true}",
		expected = "" },
	{ id = "object_field",
		body = "{\"tag_name\":{\"tag_name\":\"v9.9.9\"}}",
		expected = "" },
	{ id = "empty_wrapper",
		body = "[]",
		expected = "" },
	{ id = "null_release",
		body = "null",
		expected = "" },
	{ id = "literal_whitespace_retained",
		body = "{\"tag_name\":\" v1.2.0 \"}",
		expected = " v1.2.0 " },
	{ id = "unicode_identity",
		body = "{\"tag_name\":\"\\u03b1\"}",
		expected = "α" },
}

local PUBLISHED = {
	{ id = "escaped_digit",
		body = "{\"published_at\":\"2026-10-0\\u0031T00:00:00Z\"}",
		expected = "2026-10-01T00:00:00Z" },
	{ id = "escaped_key",
		body = "{\"published_\\u0061t\":\"2026-10-01T00:00:00Z\"}",
		expected = "2026-10-01T00:00:00Z" },
	{ id = "nested_time_not_release",
		body = "{\"author\":{\"published_at\":\"2026-09-29T00:00:00Z\"},\"published_at\":\"2026-10-01T00:00:00Z\"}",
		expected = "2026-10-01T00:00:00Z" },
	{ id = "nested_only",
		body = "{\"author\":{\"published_at\":\"2026-09-29T00:00:00Z\"}}",
		expected = "" },
	{ id = "number_field",
		body = "{\"published_at\":123}",
		expected = "" },
	{ id = "boolean_field",
		body = "{\"published_at\":true}",
		expected = "" },
	{ id = "null_field",
		body = "{\"published_at\":null}",
		expected = "" },
	{ id = "object_field",
		body = "{\"published_at\":{\"published_at\":\"2026-09-29T00:00:00Z\"}}",
		expected = "" },
	{ id = "array_field",
		body = "{\"published_at\":[\"2026-09-29T00:00:00Z\"]}",
		expected = "" },
	{ id = "object_only_wrapper",
		body = "[{\"published_at\":\"2026-09-29T00:00:00Z\"}]",
		expected = "" },
	{ id = "null_release",
		body = "null",
		expected = "" },
	{ id = "number_release",
		body = "123",
		expected = "" },
	{ id = "malformed_trailing",
		body = "{\"published_at\":\"2026-10-01T00:00:00Z\"} trailing",
		expected = "" },
	{ id = "malformed_delimiter",
		body = "{\"published_at\":\"2026-10-01T00:00:00Z\"",
		expected = "" },
	{ id = "literal_escape_retained",
		body = "{\"published_at\":\"2026-10-0\\\\u0031T00:00:00Z\"}",
		expected = "2026-10-0\\u0031T00:00:00Z" },
	{ id = "date_policy_unchanged",
		body = "{\"published_at\":\"not a timestamp\"}",
		expected = "not a timestamp" },
	{ id = "offset_identity",
		body = "{\"published_at\":\"2026-10-01T00:00:00+01:00\"}",
		expected = "2026-10-01T00:00:00+01:00" },
	{ id = "whitespace_identity",
		body = "{\"published_at\":\" 2026-10-01T00:00:00Z \"}",
		expected = " 2026-10-01T00:00:00Z " },
	{ id = "unicode_identity",
		body = "{\"published_at\":\"\\u03b1\"}",
		expected = "α" },
	{ id = "empty_field",
		body = "{\"published_at\":\"\"}",
		expected = "" },
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
	helpers.describe("shared Lua release tag contract", function()
		helpers.it("parse_tag: refuses nonstring input without changing version validation", function()
			helpers.assert_eq(#TAGS, 20, "every selected-tag and wrapper vector is retained")
			for _, value in ipairs({ false, true, 1, {}, function() end }) do
				helpers.assert_eq(Parser.parse_tag(value), "", "release JSON must be a string")
			end
			helpers.assert_eq(Parser.parse_tag(nil), "")
			helpers.assert_eq(Parser.parse_tag(""), "")
			helpers.assert_eq(select("#", Parser.parse_tag('{"tag_name":"v1.2.0"}')), 1)
		end)
		for _, row in ipairs(TAGS) do
			helpers.it("parse_tag: " .. row.id, function()
				helpers.assert_eq(Parser.parse_tag(row.body), row.expected, row.id)
			end)
		end
	end)
	helpers.describe("shared Lua release publication time contract", function()
		helpers.it("parse_published_at: refuses nonstring input without changing date validation", function()
			helpers.assert_eq(#PUBLISHED, 20, "every publication metadata vector is retained")
			for _, value in ipairs({ false, true, 1, {}, function() end }) do
				helpers.assert_eq(Parser.parse_published_at(value), "", "release JSON must be a string")
			end
			helpers.assert_eq(Parser.parse_published_at(nil), "")
			helpers.assert_eq(Parser.parse_published_at(""), "")
			helpers.assert_eq(select("#", Parser.parse_published_at('{"published_at":"not a timestamp"}')), 1)
		end)
		for _, row in ipairs(PUBLISHED) do
			helpers.it("parse_published_at: " .. row.id, function()
				helpers.assert_eq(Parser.parse_published_at(row.body), row.expected, row.id)
			end)
		end
	end)
end

return M
