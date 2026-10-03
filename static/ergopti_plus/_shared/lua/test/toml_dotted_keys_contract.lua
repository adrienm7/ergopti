--- _shared/lua/test/toml_dotted_keys_contract.lua

--- Replays independent assignment identities without deriving expected trees
--- from the production decoder. Writes retain their byte and refusal owners.
--- @param helpers table Driver test helpers.
return function(helpers)
	local Codec = require("toml_codec.codec")
	local Writer = require("toml_codec.writer")
	local Paths = require("infra.paths")
	local Json = require("json")
	local file = assert(io.open(Paths.shared("tests/corpus/toml/dotted_keys.json"), "rb"))
	local corpus = assert(Json.decode_lossless(file:read("*a")))
	file:close()
	local function test(name, body) helpers.it(name .. " (toml-dotted-keys)", body) end
	helpers.describe("shared TOML dotted assignment identities", function()
		for _, row in ipairs(corpus.documents) do
			test(row.name, function()
				local actual = Codec.decode(row.source)
				if row.valid then helpers.assert_eq(actual, row.expected, row.name)
				else helpers.assert_eq(actual, nil, row.name) end
			end)
		end
		for _, row in ipairs(corpus.inline) do
			test("inline " .. row.name, function()
				local actual = Codec.decode("value = " .. row.source .. "\n")
				if row.valid then
					helpers.assert_true(type(actual) == "table", row.name)
					helpers.assert_eq(actual.value, row.expected, row.name)
				else helpers.assert_eq(actual, nil, row.name) end
			end)
		end
		local Projection = require("config_override_projection")
		test("legacy feature projection keeps exact paths and closes arrays", function()
			local rows = assert(Projection.prepare(Codec.decode('[script]\nordinary="001"\n[features]\nllm.enabled=false\n"literal.dot"=true\nitems=[1,2]\n[other]\nignored=true\n')))
			helpers.assert_eq(rows, {
				{ section = "script", key = "ordinary", path = { "ordinary" }, value = "001", accepted = true },
				{ section = "features", key = "items", path = { "items" }, value = { 1, 2 }, accepted = false },
				{ section = "features", key = "literal.dot", path = { "literal.dot" }, value = true, accepted = true },
				{ section = "features", key = "llm.enabled", path = { "llm", "enabled" }, value = false, accepted = true },
			})
		end)
		test("distinct TOML paths cannot compete for one legacy feature setting", function()
			local decoded = Codec.decode('[features]\nllm.enabled=true\n"llm.enabled"=false\n')
			helpers.assert_true(type(decoded) == "table")
			local rows, detail = Projection.prepare(decoded)
			helpers.assert_eq(rows, nil)
			helpers.assert_eq(detail, "Ambiguous legacy feature setting: llm.enabled")
		end)
		test("legacy script tables and feature arrays stay non-scalar", function()
			local rows = assert(Projection.prepare(Codec.decode('[script]\nchild={enabled=true}\n[features]\nitems=[{enabled=true}]\nempty={}\n')))
			helpers.assert_eq(#rows, 3)
			for _, row in ipairs(rows) do helpers.assert_eq(row.accepted, false) end
		end)
		local source = '# retained\n[settings]\npersonal.future.enabled = false # untouched owner\n'
			.. 'personal.future.text = "001"\nowned = 1 # own comment\n[foreign]\nkeep = [1, 2]\n'
		local function prepare(rows, expected)
			local writes = 0
			local ok, detail, content = Writer.prepare_batch("/controlled/dotted-assignment.toml", rows, {
				read_with_status = function() return source, "ok" end,
				write = function() writes = writes + 1; error("preparation cannot publish") end,
			}, expected)
			helpers.assert_eq(writes, 0)
			return ok, detail, content
		end
		test("unchanged dotted value keeps every original byte", function()
			local ok, detail, content = prepare({ { section = "settings.personal.future", key = "enabled", value = false } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, source)
		end)
		test("unrelated owned update preserves dotted unknown records and comments", function()
			local ok, detail, content = prepare({ { section = "settings", key = "owned", value = 2 } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, source:gsub("owned = 1 # own comment", "owned = 2"))
		end)
		test("changed dotted destination remains refused before publication", function()
			for _, row in ipairs({ { section = "settings.personal.future", key = "enabled", value = true },
				{ section = "settings.personal.future", key = "enabled", delete = true } }) do
				local ok, detail = prepare({ row })
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(detail):find("settings.personal.future.enabled", 1, true) ~= nil, detail)
			end
		end)
		test("stale source remains refused without publication", function()
			local ok, detail = prepare({ { section = "settings", key = "owned", value = 2 } },
				{ status = "ok", content = source .. "# changed\n" })
			helpers.assert_eq(ok, false)
			helpers.assert_eq(detail, "source changed before preparing the batch")
		end)
		test("duplicate semantic source cannot publish an unrelated update", function()
			local writes = 0
			local ok = Writer.prepare_batch("/controlled/duplicate-dotted.toml", { { section = "other", key = "v", value = 2 } }, {
				read_with_status = function() return 'a.b=1\na."b"=2\n[other]\nv=1\n', "ok" end,
				write = function() writes = writes + 1 end,
			})
			helpers.assert_eq(ok, false)
			helpers.assert_eq(writes, 0)
		end)
	end)
end
