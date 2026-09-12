--- tests/unit/lib/test_toml_reader_string_failures.lua

--- ==============================================================================
--- MODULE: TOML Reader Quoted-Value Failure Propagation
--- DESCRIPTION:
--- Invalid recognized strings must reject the entire document, never silently
--- disappear or authorize a partial disk/preview cache entry.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

local recipes = {
	function(q) return '[[s]]\n' .. q .. ' = { output = "A" }' end,
	function(q) return '[[s]]\n"a" = { output = ' .. q .. ' }' end,
	function(q) return '[[s]]\ncolor = ' .. q end,
	function(q) return '[_meta]\n' .. q .. ' = "Description"' end,
	function(q) return '[_meta]\ncolor = ' .. q end,
	function(q) return '[_meta]\ndescription = { en = ' .. q .. ' }' end,
	function(q) return '[_meta.sections]\n' .. q .. ' = "Description"' end,
	function(q) return '[_meta.sections]\ns = ' .. q end,
	function(q) return '[_meta.sections]\ns = { en = ' .. q .. ' }' end,
	function(q) return '[_meta.sections.s]\ncolor = ' .. q end,
	function(q) return '[_meta.section_delays]\n' .. q .. ' = 0.5' end,
	function(q) return '[_meta]\nsections_order = [' .. q .. ']' end,
	function(q) return '[_meta]\nsections_order = ["s", ' .. q .. ']' end,
}

helpers.describe("TOML reader quoted failure propagation", function()
	for variant, quoted in ipairs({ '"PRIVATE_DETAIL\\q"', '"PRIVATE_DETAIL\\uD800"', '"PRIVATE_DETAIL' }) do
		for index, recipe in ipairs(recipes) do
			helpers.it("(reader-string-failure) rejects recognized string " .. variant .. "/" .. index, function()
				helpers.with_fresh_modules({ "toml_codec.reader" }, function()
					local reader = require("toml_codec.reader")
					local empty = reader.parse_text("")
					local parsed, committed = reader.parse_text('[[before]]\n"b" = { output = "B" }\n' .. recipe(quoted))
					helpers.assert_eq(committed, false)
					helpers.assert_eq(parsed, empty)
				end)
			end)
		end
	end

	helpers.it("(reader-string-cache) closes rejected files and retries previews without cached partial results", function()
		with_counter(function(counter, state, context)
			helpers.with_fresh_modules({ "toml_codec.reader" }, function()
				local reader = require("toml_codec.reader")
				local stores = 0
				reader.set_cache_provider({ load = function() return nil end,
					capture_source = function() return {} end,
					store = function() stores = stores + 1 end })
				state.content = '[_meta]\nsections_order = ["s", "PRIVATE_DETAIL\\q"]\n[[s]]\n"a" = { output = "A" }'
				local rejected, committed = reader.parse('/virtual/extensions/demo/hotstrings/demo.toml')
				helpers.assert_eq(committed, false)
				helpers.assert_eq(next(rejected.sections), nil)
				helpers.assert_eq(stores, 0)
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.closes, 1)
				local ok, failure = pcall(counter.count_all, context, {})
				helpers.assert_eq(ok, false)
				helpers.assert_true(not tostring(failure):find("PRIVATE_DETAIL", 1, true))
				state.content = '[[s]]\n"a" = { output = "A" }'
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(state.opens, 3)
				helpers.assert_eq(state.closes, 3)
			end)
		end)
	end)

	helpers.it("(reader-string-empty) retains valid empty strings", function()
		helpers.with_fresh_modules({ "toml_codec.reader" }, function()
			local reader = require("toml_codec.reader")
			local parsed, committed = reader.parse_text('[_meta]\ndescription = ""\nsections_order = ["s"]\n'
				.. '[_meta.sections]\ns = { en = "" }\n[[s]]\n"a" = { output = "" }')
			helpers.assert_eq(committed, true)
			helpers.assert_eq(parsed.meta.description, "")
			helpers.assert_eq(parsed.meta.sections.s.description.en, "")
			helpers.assert_eq(parsed.sections.s.entries[1].output, "")
		end)
	end)
end)
