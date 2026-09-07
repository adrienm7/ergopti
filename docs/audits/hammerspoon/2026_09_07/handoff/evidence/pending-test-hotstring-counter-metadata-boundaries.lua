--- tests/unit/ui/menu/test_hotstring_counter_metadata_boundaries.lua

--- ==============================================================================
--- MODULE: Extension Metadata Count Boundaries
--- DESCRIPTION:
--- Compares real reader entries with menu counts across metadata and table headers.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")
local function with_reader(callback)
	with_counter(function(counter, state, ctx)
		helpers.with_fresh_modules({ "infra.toml.reader", "toml_codec.reader" }, function()
			local reader = require("toml_codec.reader")
			reader.set_cache_provider(nil)
			callback(counter, state, ctx, reader)
		end)
	end)
end

helpers.describe("Extension metadata count boundaries", function()
	for _, header in ipairs({ "[_meta]", "[_meta.sections]", "[_meta.sections.first]",
		"[_meta.section_delays]", "[unknown.table]" }) do
		helpers.it("(counter-metadata-boundary) stops entries at " .. header .. " and resumes", function()
			with_reader(function(counter, state, ctx, reader)
				local metadata_line = header == "[_meta.section_delays]" and '"first" = 0.1'
					or '"description" = "Not a hotstring"'
				state.content = '[[first]]\n"a" = { output = "b" }\n' .. header
					.. '\n' .. metadata_line .. '\n[[second]]\n"c" = { output = "d" }\n'
				local parsed, committed = reader.parse("/virtual/boundary.toml")
				helpers.assert_eq(committed, true)
				helpers.assert_eq(#parsed.sections.first.entries, 1)
				helpers.assert_eq(#parsed.sections.second.entries, 1)
				local result = counter.count_all(ctx, {})
				helpers.assert_eq(result.ext, 2)
				local sections = result.ext_details[1].files[1].sections
				helpers.assert_eq(#sections, 2)
				helpers.assert_eq(sections[1].name, "first")
				helpers.assert_eq(sections[1].count, 1)
				helpers.assert_eq(sections[2].name, "second")
				helpers.assert_eq(sections[2].count, 1)
				local opens = state.opens
				helpers.assert_eq(counter.count_all(ctx, {}).ext, 2)
				helpers.assert_eq(state.opens, opens)
			end)
		end)
	end
	helpers.it("(counter-metadata-boundary) preserves valid simple table entries", function()
		with_reader(function(counter, state, ctx, reader)
			state.content = '[first]\n"a" = { output = "b" }\n[_meta]\n"ignored" = "metadata"\n'
				.. '[second]\n"c" = { output = "d" }\n'
			local parsed, committed = reader.parse("/virtual/simple.toml")
			helpers.assert_eq(committed, true)
			helpers.assert_eq(#parsed.sections.first.entries, 1)
			helpers.assert_eq(#parsed.sections.second.entries, 1)
			local result = counter.count_all(ctx, {})
			helpers.assert_eq(result.ext, 2)
			helpers.assert_eq(#result.ext_details[1].files[1].sections, 2)
		end)
	end)
end)
