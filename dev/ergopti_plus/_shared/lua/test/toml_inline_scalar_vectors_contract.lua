--- _shared/lua/test/toml_inline_scalar_vectors_contract.lua

--- ==============================================================================
--- MODULE: TOML Inline Scalar Vector Replay
--- DESCRIPTION:
--- Replays _shared/tests/corpus/toml/inline_scalar_vectors.json through the batch
--- writer's source hint step and prepare step on macOS and Linux. The cases are
--- data (file bytes, rows, the inline parents the hint names, the candidate
--- bytes), so a port in another language replays the same file.
--- ==============================================================================

--- Revives the number spellings JSON cannot carry ({"$number": "text"}).
--- @param value any A decoded JSON value.
--- @return any revived
local function revive(value)
	if type(value) ~= "table" then return value end
	if value["$number"] ~= nil then
		local text = value["$number"]
		if text == "inf" then return math.huge end
		if text == "-inf" then return -math.huge end
		if text == "nan" then return 0 / 0 end
		return tonumber(text)
	end
	local copy = {}
	for key, child in pairs(value) do copy[key] = revive(child) end
	return copy
end

--- Registers the vector replay.
--- @param helpers table Driver test helpers.
--- @param corpus table The decoded corpus (Json.decode_lossless).
--- @param expected_count number The vector count the contract was written for.
return function(helpers, corpus, expected_count)
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec")
	assert(#corpus.vectors == expected_count,
		"inline_scalar_vectors.json holds " .. #corpus.vectors .. " vectors, the contract expects " .. expected_count)

	local function prepare(source, rows)
		return Writer.prepare_batch("/controlled/inline-scalar-vector.toml", rows, {
			read_with_status = function() return source, "ok" end,
			write = function() error("preparation must never publish") end,
		})
	end

	helpers.describe("shared TOML inline scalar vectors", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(" .. vector.group .. ") " .. vector.id, function()
				local rows, expect = revive(vector.rows), vector.expect
				if expect.hint_parents ~= nil then
					local expected = {}
					for _, parent in ipairs(expect.hint_parents) do expected[parent] = true end
					helpers.assert_eq(Writer.source_inline_scalar_parents(vector.source, rows), expected)
				end
				if expect.ok == nil then return end
				local called, ok, _, content = pcall(prepare, vector.source, rows)
				if not expect.ok then
					helpers.assert_true(not called or ok == false, "the preparation is refused")
					helpers.assert_nil(content)
					return
				end
				helpers.assert_eq(called, true, tostring(ok))
				helpers.assert_eq(ok, true)
				if expect.content ~= nil then helpers.assert_eq(content, expect.content) end
				if expect.decoded then
					local decoded = Codec.decode(content)
					for _, check in ipairs(expect.decoded) do
						local node = decoded
						for _, key in ipairs(check.path) do
							if type(node) == "table" then node = node[key] else node = nil end
						end
						helpers.assert_eq(node, revive(check.value), table.concat(check.path, "."))
						if check.negative_zero then helpers.assert_eq(1 / node, -math.huge) end
					end
				end
				if expect.idempotent then
					local again, why, unchanged = prepare(content, rows)
					helpers.assert_eq(again, true, tostring(why))
					helpers.assert_eq(unchanged, content)
				end
			end)
		end
	end)
end
