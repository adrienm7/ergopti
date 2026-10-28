--- _shared/lua/test/toml_leaf_rows_vectors_contract.lua

--- ==============================================================================
--- MODULE: TOML Leaf Rows Vector Replay
--- DESCRIPTION:
--- Replays _shared/tests/corpus/toml/leaf_rows_vectors.json through the leaf-row
--- planner and the batch writer on macOS and Linux. The cases are data (source
--- bytes, operations, expected decoded leaves), so a port in another language
--- replays the same file through its own planner and writer.
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
	local LeafRows = require("toml_codec.leaf_rows")
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec")
	assert(#corpus.vectors == expected_count,
		"leaf_rows_vectors.json holds " .. #corpus.vectors .. " vectors, the contract expects " .. expected_count)

	helpers.describe("shared TOML leaf rows vectors", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(toml-leaf-rows) " .. vector.id, function()
				-- A JSON null decodes to nil or a driver's null sentinel: both mean an absent file.
				local source = type(vector.source) == "string" and vector.source or nil
				local planned, rows = pcall(LeafRows.prepare, source or "", revive(vector.operations))
				local ok, content = false, nil
				if planned then
					local prepared, _, candidate = Writer.prepare_batch("/virtual/leaf_rows_vector.toml", rows, {
						read_with_status = function()
							if source == nil then return nil, "absent" end
							return source, "ok"
						end,
					})
					ok, content = prepared == true, candidate
				end
				helpers.assert_eq(ok, vector.expect.ok)
				if not ok then return end
				local decoded = Codec.decode(content)
				for _, check in ipairs(vector.expect.decoded or {}) do
					local node = decoded
					for _, key in ipairs(check.path) do
						if type(node) == "table" then node = node[key] else node = nil end
					end
					if check.absent then helpers.assert_nil(node, table.concat(check.path, "."))
					else helpers.assert_eq(node, check.value, table.concat(check.path, ".")) end
				end
				if vector.expect.content ~= nil then helpers.assert_eq(content, vector.expect.content) end
				for _, part in ipairs(vector.expect.contains or {}) do
					helpers.assert_true(content:find(part, 1, true) ~= nil, "contains " .. part)
				end
			end)
		end
	end)
end
