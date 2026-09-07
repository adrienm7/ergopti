--- tests/unit/ui/menu/test_hotstring_counter_semantics.lua

--- ==============================================================================
--- MODULE: Hotstring Counter Semantics Tests
--- DESCRIPTION:
--- Verifies canonical entry classification and rejection before count publication.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

helpers.describe("hotstring counter semantics", function()
	helpers.it("(hs-271-projection) counts each canonical section once and omits placeholders", function()
		with_counter(function(counter, state, context)
			state.content = '[_meta]\nsections_order = ["arrows", "arrows", "-", "placeholder"]\n'
				.. '[_meta.sections]\nplaceholder = "Module"\n'
				.. '[[arrows]]\n"a" = { output = "A" }\n'
				.. '[[symbols]]\n"s" = { output = "S" }\n'
				.. '[[arrows]]\n"b" = { output = "B" }\n'
			local result = counter.count_all(context, {})
			local sections = result.ext_details[1].files[1].sections
			helpers.assert_eq(result.ext, 3)
			helpers.assert_eq(#sections, 2)
			helpers.assert_eq(sections[1], { name = "arrows", count = 2 })
			helpers.assert_eq(sections[2], { name = "symbols", count = 1 })
			helpers.assert_eq(counter.count_all(context, {}).ext_details[1].files[1].sections, sections)
			helpers.assert_eq(state.opens, 1)
		end)
	end)

	for _, newline in ipairs({ "\n", "\r\n" }) do
		helpers.it("(hs-271-snapshot) accepts initial BOM with newline width " .. #newline, function()
			with_counter(function(counter, state, context)
				local bom = string.char(239, 187, 191)
				state.content = bom .. '# comment' .. newline .. '[[arrows]]' .. newline
					.. '"' .. bom .. 'a" = { output = "A" }'
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.closes, 1)
			end)
		end)
	end

	for _, key in ipairs({ "description", '"description"' }) do
		helpers.it("(hs-271-properties) excludes " .. key .. " before and after entries", function()
			with_counter(function(counter, state, context)
				state.content = '[[empty]]\n' .. key .. ' = "Only a property"\n'
					.. '[[arrows]]\n"a" = { output = "A" }\n' .. key .. ' = "Arrow shortcuts"\n'
				local result = counter.count_all(context, {})
				helpers.assert_eq(result.ext, 1)
				helpers.assert_eq(result.ext_details[1].files[1].sections[1].count, 0)
				helpers.assert_eq(result.ext_details[1].files[1].sections[2].count, 1)
			end)
		end)
	end

	helpers.it("(hs-271-triggers) counts description and escaped trigger entries", function()
		with_counter(function(counter, state, context)
			state.content = '[[arrows]]\n"description" = { output = "A" }\n'
				.. '"a\\\"b" = { output = "quoted" }\n'
			helpers.assert_eq(counter.count_all(context, {}).ext, 2)
		end)
	end)

	for _, invalid in ipairs({
		'"description" = "Private property"\n"description" = { output = "A" }',
		'"a" = { output = "A" }\n"a" = { output = "B" }',
		'description = "first"\n"description" = "second"',
	}) do
		helpers.it("(hs-271-rejection) rejects semantic failure and retries without cached counts " .. #invalid, function()
			with_counter(function(counter, state, context)
				state.content = '[[arrows]]\n' .. invalid
				local ok, failure = pcall(counter.count_all, context, {})
				helpers.assert_eq(ok, false)
				helpers.assert_eq(failure, "Extension TOML semantic parse failed; hotstring counts were not published")
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_eq(state.errors[1]:find("Private", 1, true), nil)
				state.content = '[[arrows]]\n"fixed" = { output = "OK" }'
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(state.opens, 2)
				helpers.assert_eq(state.closes, 2)
			end)
		end)
	end
end)
