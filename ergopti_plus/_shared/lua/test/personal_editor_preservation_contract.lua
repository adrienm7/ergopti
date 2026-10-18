--- _shared/lua/test/personal_editor_preservation_contract.lua

--- ==============================================================================
--- MODULE: Personal Editor Preservation Contract
--- DESCRIPTION:
--- Independent source ownership vectors replayed through the acknowledged writer.
--- ==============================================================================

--- Independently authored source ownership vectors replayed through the writer.
local M = {}
function M.run(helpers, corpus)
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec")
	assert(#corpus.vectors == 23, "personal editor preservation inventory must contain twenty-three vectors")
	helpers.describe("personal editor source preservation", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(personal-editor-preservation) " .. vector.name, function()
				local source = vector.source ~= nil and { status = "ok", content = vector.source } or { status = "absent" }
				local committed, writes = nil, 0
				local adapter = {
					read_with_status = function() return source.content, source.status end,
					write_if_unchanged = function(_, content, expected)
						helpers.assert_eq(expected, source)
						committed, writes = content, writes + 1
						return true
					end,
				}
				local ok, detail, payload = Writer.write("/controlled/personal-editor.toml", vector.model, adapter, false, source, true)
				if vector.refusal then
					helpers.assert_eq(ok, false); helpers.assert_eq(detail, vector.refusal); helpers.assert_eq(writes, 0)
					return
				end
				helpers.assert_eq(ok, true, detail); helpers.assert_eq(writes, 1); helpers.assert_eq(payload, committed)
				for _, text in ipairs(vector.contains or {}) do helpers.assert_contains(committed, text) end
				for _, text in ipairs(vector.absent or {}) do helpers.assert_eq(committed:find(text, 1, true), nil) end
				if vector.ends_with_newline ~= nil then helpers.assert_eq(committed:sub(-1) == "\n", vector.ends_with_newline) end
				local decoded, shapes = Codec.decode_with_shapes(committed)
				helpers.assert_not_nil(decoded)
				for _, path in ipairs(vector.arrays or {}) do
					local value = decoded
					for part in path:gmatch("[^%.]+") do value = value[tonumber(part) or part] end
					helpers.assert_eq(shapes.arrays[value], true, path .. " must remain an array")
				end
				for path, expected in pairs(vector.decoded or {}) do
					local actual = decoded
					for part in path:gmatch("[^%.]+") do actual = actual[tonumber(part) or part] end
					helpers.assert_eq(actual, expected, path)
				end
			end)
		end
	end)
end
return M
