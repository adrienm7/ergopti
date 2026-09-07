--- tests/unit/lib/test_toml_reader_text.lua

--- ==============================================================================
--- MODULE: TOML Reader Text Snapshot Tests
--- DESCRIPTION:
--- Pins semantic parity without rereading a validated snapshot or consulting cache.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

helpers.describe("TOML reader text snapshots", function()
	for _, newline in ipairs({ "\n", "\r\n" }) do
		helpers.it("(hs-271-text) matches file parsing with newline width " .. #newline, function()
			with_counter(function(_, state)
				helpers.with_fresh_modules({ "toml_codec.reader" }, function()
					local reader = require("toml_codec.reader")
					state.content = table.concat({ '[_meta]', 'sections_order = ["arrows"]',
						'[[arrows]]', '"a\\\"b" = { output = "A" }', 'description = "Arrows"' }, newline)
					local file, file_ok = reader.parse("/virtual/extensions/demo/hotstrings/demo.toml")
					local text, text_ok = reader.parse_text(state.content)
					helpers.assert_eq(file_ok, true)
					helpers.assert_eq(text_ok, true)
					helpers.assert_eq(#text.sections_order, #file.sections_order)
					helpers.assert_eq(text.sections_order[1], "arrows")
					helpers.assert_eq(text.sections.arrows.description, file.sections.arrows.description)
					helpers.assert_eq(text.sections.arrows.entries[1].trigger, 'a"b')
					helpers.assert_eq(text.sections.arrows.entries[1].output, file.sections.arrows.entries[1].output)
					helpers.assert_eq(state.opens, 1)
					helpers.assert_eq(state.closes, 1)
				end)
			end)
		end)
	end

	helpers.it("(hs-271-text) bypasses disk cache and rejects non-text input", function()
		helpers.with_fresh_modules({ "toml_codec.reader" }, function()
			local reader = require("toml_codec.reader")
			local calls = 0
			local function touched() calls = calls + 1 end
			reader.set_cache_provider({ load = touched, capture_source = touched, store = touched })
			local empty, committed = reader.parse_text("")
			helpers.assert_eq(committed, true)
			helpers.assert_eq(next(empty.sections), nil)
			local rejected, accepted = reader.parse_text({})
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(next(rejected.sections), nil)
			helpers.assert_eq(calls, 0)
		end)
	end)
end)
