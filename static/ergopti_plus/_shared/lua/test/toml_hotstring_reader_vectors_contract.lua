--- _shared/lua/test/toml_hotstring_reader_vectors_contract.lua

--- ==============================================================================
--- MODULE: Hotstring TOML Reader Vector Replay
--- DESCRIPTION:
--- Replays _shared/tests/corpus/toml/hotstring_reader_vectors.json through the
--- hotstring reader's parse_text on macOS and Linux: which headers and logical
--- values the reader accepts, which it refuses whole, and how a literal group
--- name is kept apart from a metadata path. The cases are data (a text and what
--- the reader answers), so a port in another language replays the same file.
--- ==============================================================================

--- Registers the vector replay.
--- @param helpers table Driver test helpers.
--- @param corpus table The decoded corpus (Json.decode_lossless).
--- @param expected_count number The vector count the contract was written for.
return function(helpers, corpus, expected_count)
	local Reader = require("toml_codec.reader")
	assert(#corpus.vectors == expected_count,
		"hotstring_reader_vectors.json holds " .. #corpus.vectors .. " vectors, the contract expects " .. expected_count)

	helpers.describe("shared hotstring reader vectors", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(" .. vector.group .. ") " .. vector.id, function()
				local expect = vector.expect
				local document, committed = Reader.parse_text(vector.text)
				helpers.assert_eq(committed, expect.committed, "the source receipt")
				if not expect.committed then
					helpers.assert_eq(next(document.sections), nil, "a refused source exposes no partial entries")
				end
				if expect.source_entries ~= nil then helpers.assert_eq(#document.source_entries, expect.source_entries) end
				for _, section in ipairs(expect.sections or {}) do
					helpers.assert_eq(document.sections[section.name].entries[1].output, section.output, section.name)
				end
				if expect.first_section ~= nil then helpers.assert_eq(document.sections_order[1], expect.first_section) end
				for _, meta in ipairs(expect.meta_delays or {}) do
					helpers.assert_eq(document.meta.sections[meta.name].delay, meta.delay)
				end
			end)
		end
	end)
end
