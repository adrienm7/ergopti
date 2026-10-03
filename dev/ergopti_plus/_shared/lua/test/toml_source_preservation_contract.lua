--- _shared/lua/test/toml_source_preservation_contract.lua

--- Replays independently handwritten unowned bytes through the real batch owner.
--- @param helpers table Native driver assertions.
--- @param fixture table Shared source-preservation vectors.
return function(helpers, fixture)
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec.codec")
	helpers.describe("shared TOML foreign physical source ownership", function()
		for _, vector in ipairs(fixture.cases) do
			helpers.it("toml-foreign-source " .. vector.id, function()
				local rows = {}
				for _, row in ipairs(vector.updates) do
					if row.kind == "delete" then
						helpers.assert_eq(row.delete, true)
						rows[#rows + 1] = { section = row.section, key = row.key, delete = true }
					else
						helpers.assert_true(row.kind == "boolean" or row.kind == "integer")
						rows[#rows + 1] = { section = row.section, key = row.key, value = row.value }
					end
				end
				local writes = 0
				local ok, detail, content = Writer.prepare_batch("/controlled/foreign-source.toml", rows, {
					read_with_status = function() return vector.source, "ok" end,
					write = function() writes = writes + 1; return false end,
				})
				helpers.assert_eq(writes, 0, "preparation never publishes")
				if vector.lua_admission ~= nil then
					helpers.assert_eq(vector.lua_admission, "refused_unaddressable")
					helpers.assert_eq(ok, false, "the existing literal-dot refusal remains explicit")
					helpers.assert_eq(content, nil, "a refusal returns no publishable candidate")
					helpers.assert_true(detail:find(vector.lua_refusal, 1, true) ~= nil)
					local committed, commit_detail = Writer.batch_write("/controlled/foreign-source.toml", rows, {
						read_with_status = function() return vector.source, "ok" end,
						write = function() writes = writes + 1; return false end,
					})
					helpers.assert_eq(committed, false)
					helpers.assert_true(commit_detail:find(vector.lua_refusal, 1, true) ~= nil)
					helpers.assert_eq(writes, 0, "the real publication owner preserves refusal before IO")
					return
				end
				helpers.assert_eq(ok, true, detail)
				for _, raw in ipairs(vector.retained) do
					helpers.assert_true(content:find(raw, 1, true) ~= nil,
						"unowned physical records must retain their independent original bytes")
				end
				local decoded = Codec.decode(content)
				for _, expected in ipairs(vector.owned) do
					helpers.assert_true(expected.kind == "boolean" or expected.kind == "integer")
					helpers.assert_eq(decoded[expected.section][expected.key], expected.value,
						"the complete candidate must include the requested owned value")
				end
			end)
		end
	end)
end
