--- _shared/lua/test/toml_batch_write_vectors_contract.lua

--- ==============================================================================
--- MODULE: TOML Batch Writer Vector Replay
--- DESCRIPTION:
--- Replays _shared/tests/corpus/toml/batch_write_vectors.json through the batch
--- writer's prepare step on macOS and Linux. The cases are data (file bytes, rows,
--- expected acceptance and bytes), so a port in another language replays the same
--- file through its own writer; this module is only the Lua reader of it.
---
--- FEATURES & RATIONALE:
--- 1. One case per vector, named by its id and group, so a replay failure names
---    the vector to open.
--- 2. The writer is called with a read-only source and a write that raises: a
---    preparation never publishes.
--- 3. The corpus declares how many vectors it holds; a replayer that silently read
---    fewer would fail instead of passing less.
--- ==============================================================================

--- Revives the number spellings JSON cannot carry ({"$number": "text"}).
--- @param value any A decoded JSON value.
--- @return any revived
local function revive(value)
	if type(value) ~= "table" then return value end
	if value["$number"] ~= nil then return tonumber(value["$number"]) end
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
	local Codec = require("toml_codec.codec")
	assert(#corpus.vectors == expected_count,
		"batch_write_vectors.json holds " .. #corpus.vectors .. " vectors, the contract expects " .. expected_count)

	helpers.describe("shared TOML batch writer vectors", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(" .. vector.group .. ") " .. vector.id, function()
				local reads = 0
				local ok, detail, content = Writer.prepare_batch("/controlled/batch-vector.toml", revive(vector.rows), {
					read_with_status = function() reads = reads + 1; return vector.source, "ok" end,
					write = function() error("preparation must never publish") end,
				})
				local expect = vector.expect
				helpers.assert_eq(ok, expect.ok, tostring(detail))
				if expect.reads ~= nil then helpers.assert_eq(reads, expect.reads, "reads of the source") end
				for _, part in ipairs(expect.detail_contains or {}) do
					helpers.assert_true(tostring(detail):find(part, 1, true) ~= nil,
						"the refusal names " .. part .. ": " .. tostring(detail))
				end
				if not expect.ok then
					helpers.assert_eq(content, nil, "a refused batch yields no bytes")
					return
				end
				if expect.content ~= nil then helpers.assert_eq(content, expect.content) end
				if expect.unchanged then helpers.assert_eq(content, vector.source) end
				for _, part in ipairs(expect.contains or {}) do
					helpers.assert_true(content:find(part, 1, true) ~= nil, "contains " .. part)
				end
				for _, part in ipairs(expect.not_contains or {}) do
					helpers.assert_true(content:find(part, 1, true) == nil, "does not contain " .. part)
				end
				if expect.decoded then
					local decoded = Codec.decode(content)
					for _, check in ipairs(expect.decoded) do
						local node = decoded
						for _, key in ipairs(check.path) do
						if type(node) == "table" then node = node[key] else node = nil end
					end
						helpers.assert_eq(node, revive(check.value), table.concat(check.path, "."))
					end
				end
			end)
		end
	end)
end
