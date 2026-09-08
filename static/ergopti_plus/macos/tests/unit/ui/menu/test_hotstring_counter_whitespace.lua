--- tests/unit/ui/menu/test_hotstring_counter_whitespace.lua

--- ==============================================================================
--- MODULE: Hotstring Counter Whitespace Tests
--- DESCRIPTION:
--- Compares extension previews with canonical readers for indented TOML content.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

helpers.describe("hotstring counter whitespace", function()
	for _, case in ipairs({
		{ label = "plain LF", header = "", entry = "", newline = "\n" },
		{ label = "space header LF", header = "  ", entry = "", newline = "\n" },
		{ label = "space entry LF", header = "", entry = "  ", newline = "\n" },
		{ label = "tab header CRLF", header = "\t", entry = "", newline = "\r\n" },
		{ label = "tab entry CRLF", header = "", entry = "\t", newline = "\r\n" },
		{ label = "mixed indentation CRLF", header = " \t", entry = "\t ", newline = "\r\n" },
	}) do
		helpers.it("(counter-whitespace) matches canonical entries for " .. case.label, function()
			with_counter(function(counter, state, context)
				state.content = case.header .. "[[arrows]]" .. case.newline .. case.entry
					.. '"-->demo" = { output = "right", is_word = false, auto_expand = false, is_case_sensitive = true, final_result = true }'
					.. case.newline
				local reader = require("infra.toml.reader")
				local parsed, committed = reader.parse("/virtual/extensions/demo/hotstrings/demo.toml")
				helpers.assert_eq(committed, true)
				helpers.assert_eq(#parsed.sections.arrows.entries, 1)
				helpers.assert_eq(parsed.sections.arrows.entries[1].trigger, "-->demo")
				local opens, closes = state.opens, state.closes
				local result = counter.count_all(context, {})
				helpers.assert_eq(result.ext, #parsed.sections.arrows.entries)
				helpers.assert_eq(result.has_ext, true)
				helpers.assert_eq(result.ext_details[1].files[1].sections[1].name, "arrows")
				helpers.assert_eq(result.ext_details[1].files[1].sections[1].count, 1)
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(state.opens - opens, 1)
				helpers.assert_eq(state.closes - closes, 1)
				helpers.assert_eq(#state.errors, 0)
			end)
		end)
	end
	for _, indent in ipairs({ "", "  ", "\t" }) do
		helpers.it("(counter-whitespace) matches manifest discovery with indentation length " .. #indent, function()
			with_counter(function(counter, state, context)
				state.manifest_content = '[extension]\r\n' .. indent .. 'name = "Demo Pack"\r\n'
				local extensions = require("hotstrings.extensions")
				local packs = extensions.scan({ "/virtual/extensions" }, {
					list_dirs = function() return { "/virtual/extensions/demo" } end,
					list_files = function() return { "/virtual/extensions/demo/hotstrings/demo.toml" } end,
					read_file = function() return state.manifest_content end,
				})
				helpers.assert_eq(#packs, 1)
				helpers.assert_eq(packs[1].name, "Demo Pack")
				state.target = "manifest"
				local result = counter.count_all(context, {})
				helpers.assert_eq(result.ext_details[1].name, packs[1].name)
				helpers.assert_eq(counter.count_all(context, {}).ext_details[1].name, "Demo Pack")
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.closes, 1)
				helpers.assert_eq(#state.errors, 0)
			end)
		end)
	end
end)
