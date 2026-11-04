--- _shared/lua/test/keystats_correction_erased_contract.lua

--- ==============================================================================
--- MODULE: Keystats Erased and Synthetic N-gram Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/keystats/correction_erased_vectors.json: which
--- n-grams a Backspace flags as erased (e), that a Backspace never flags
--- another Backspace, and that a synthetic correction carries its source (esrc)
--- instead of counting as the user's mistake. The macOS and Linux walkers replay
--- it through their own harness; the AHK replayer is written on the PC.
--- ==============================================================================

local FAMILIES = {
	"ngram_chars", "ngram_bigrams", "ngram_trigrams", "ngram_quadgrams",
	"ngram_pentagrams", "ngram_hexagrams", "ngram_heptagrams",
}

--- Registers the replay.
--- @param helpers table Driver test helpers.
--- @param data table The decoded corpus.
--- @param replay function Given a vector, returns the walked batch's `ngram` tables.
--- @param expected_count number The vector count the contract was written for.
return function(helpers, data, replay, expected_count)
	assert(#data.vectors == expected_count,
		"correction_erased_vectors.json holds " .. #data.vectors .. " vectors, the contract expects " .. expected_count)
	local prefix = data.date .. "\1" .. data.app .. "\1"

	helpers.describe("shared erased and synthetic n-gram vectors", function()
		for _, vec in ipairs(data.vectors) do
			helpers.it(vec.id, function()
				local ngram = replay(vec)
				for _, family in ipairs(FAMILIES) do
					local expected = vec.expected[family] or {}
					local seen = {}
					for key, row in pairs(ngram[family] or {}) do
						if key:sub(1, #prefix) == prefix and (row.c > 0 or row.e > 0) then
							local token = key:sub(#prefix + 1)
							local want = expected[token]
							helpers.assert_true(want ~= nil, vec.id .. ": " .. family .. " counts an unexpected " .. token)
							if want ~= nil then
								helpers.assert_eq(row.c, want.c, vec.id .. ": " .. family .. " " .. token .. " c")
								helpers.assert_eq(row.e, want.e, vec.id .. ": " .. family .. " " .. token .. " e")
								local sources = {}
								for source, count in pairs(row.esrc or {}) do sources[source] = count end
								helpers.assert_eq(sources, want.esrc or {}, vec.id .. ": " .. family .. " " .. token .. " esrc")
							end
							seen[token] = true
						end
					end
					for token in pairs(expected) do
						helpers.assert_true(seen[token] == true, vec.id .. ": " .. family .. " misses " .. token)
					end
				end
			end)
		end
	end)
end
