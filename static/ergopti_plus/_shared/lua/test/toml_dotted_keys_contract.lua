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

	helpers.describe("shared root dotted scalar publication", function()
		local function root_prepare(source, row, expected)
			local writes = 0
			local okay, detail, content = Writer.prepare_batch("/controlled/root-dotted-scalar.toml", { row }, {
				read_with_status = function() return source, "ok" end,
				write = function() writes = writes + 1; return false end,
			}, expected)
			helpers.assert_eq(writes, 0, "preparation never publishes")
			return okay, detail, content
		end
		local vectors = {
			{ name = "bare", key = "llm.agent_mode", section = "llm" },
			{ name = "quoted leaf", key = 'llm."agent_mode"', section = "llm" },
			{ name = "quoted parent", key = '"team.name".agent_mode', section = '"team.name"' },
			{ name = "literal parent", key = "'team=name'.agent_mode", section = '"team=name"' },
			{ name = "Unicode escaped parent", key = '"\\u00C9quipe".agent_mode', section = '"Équipe"' },
		}
		for _, vector in ipairs(vectors) do
			local source = '# exact before\n' .. vector.key .. ' = "auto" # owned comment\n'
				.. 'future.precise = 0.1\nfuture.long = 1.234567890123456789\nfuture.integer = 9007199254740993\nfuture.empty = []\n# exact after\n'
			helpers.it("updates only the authentic " .. vector.name .. " root scalar record", function()
				local okay, detail, content = root_prepare(source, { section = vector.section, key = "agent_mode", value = "action" })
				helpers.assert_eq(okay, true, detail)
				helpers.assert_eq(content, '# exact before\n' .. vector.key .. ' = "action"\n'
					.. 'future.precise = 0.1\nfuture.long = 1.234567890123456789\nfuture.integer = 9007199254740993\nfuture.empty = []\n# exact after\n')
			end)
			helpers.it("removes only the authentic " .. vector.name .. " root scalar record", function()
				local okay, detail, content = root_prepare(source, { section = vector.section, key = "agent_mode", delete = true })
				helpers.assert_eq(okay, true, detail)
				helpers.assert_eq(content, '# exact before\nfuture.precise = 0.1\nfuture.long = 1.234567890123456789\nfuture.integer = 9007199254740993\nfuture.empty = []\n# exact after\n')
			end)
			helpers.it("retains every byte of an unchanged " .. vector.name .. " root scalar", function()
				local okay, detail, content = root_prepare(source, { section = vector.section, key = "agent_mode", value = "auto" })
				helpers.assert_eq(okay, true, detail)
				helpers.assert_eq(content, source)
			end)
		end
		helpers.it("retains case-distinct root neighbors and replaces a multiline scalar through its complete physical range", function()
			local source = 'a.text = """before\n[looks.like.a.header]\nafter"""\nA.text = "untouched" # case owner\n'
			local okay, detail, content = root_prepare(source, { section = "a", key = "text", value = "changed" })
			helpers.assert_eq(okay, true, detail)
			helpers.assert_eq(content, 'a.text = "changed"\nA.text = "untouched" # case owner\n')
		end)
		helpers.it("preserves stream BOM and final newline ownership while updating or deleting a first root leaf", function()
			local bom = string.char(239, 187, 191)
			local source = bom .. 'a.setting=false\nfuture.keep=0.1'
			local okay, detail, content = root_prepare(source, { section = "a", key = "setting", value = true })
			helpers.assert_eq(okay, true, detail)
			helpers.assert_eq(content, bom .. 'a.setting = true\nfuture.keep=0.1')
			local removed, why, survivor = root_prepare(source, { section = "a", key = "setting", delete = true })
			helpers.assert_eq(removed, true, why)
			helpers.assert_eq(survivor, bom .. 'future.keep=0.1')
			local last, last_detail, last_content = root_prepare('future.keep=0.1\na.setting=0.25', { section = "a", key = "setting", value = 0.75 })
			helpers.assert_eq(last, true, last_detail)
			helpers.assert_eq(last_content, 'future.keep=0.1\na.setting = 0.75')
		end)
		helpers.it("refuses root container mutation and subtree collisions without manufacturing authority", function()
			for _, source in ipairs({ 'llm={agent_mode="auto"}\n', 'llm="obsolete"\n', 'llm=[]\n',
				'[[llm]]\nagent_mode="auto"\n', 'llm.agent_mode=["auto"]\n', 'llm.agent_mode={value="auto"}\n' }) do
				local okay, _, content = root_prepare(source, { section = "llm", key = "agent_mode", value = "action" })
				helpers.assert_eq(okay, false, source)
				helpers.assert_nil(content, "a refused candidate cannot reach publication")
			end
		end)
		helpers.it("refuses replacing a root scalar while publishing a descendant in the same batch", function()
			local writes = 0
			local okay, detail, content = Writer.prepare_batch("/controlled/root-collision.toml", {
				{ section = "a", key = "setting", delete = true },
				{ section = "a.setting", key = "child", value = true },
			}, { read_with_status = function() return 'a.setting="obsolete"\nfuture.keep=0.1\n', "ok" end,
				write = function() writes = writes + 1; return false end })
			helpers.assert_eq(okay, false)
			helpers.assert_contains(detail, "a.setting")
			helpers.assert_nil(content)
			helpers.assert_eq(writes, 0)
		end)
		helpers.it("retains root scalar refusal for nonfinite requested values", function()
			for _, value in ipairs({ math.huge, -math.huge, 0 / 0 }) do
				local okay, _, content = root_prepare('a.setting=0.25\nfuture.keep=0.1\n', { section = "a", key = "setting", value = value })
				helpers.assert_eq(okay, false)
				helpers.assert_nil(content)
			end
		end)
		helpers.it("refuses duplicate aliases, stale source and a changed root scalar into a dictionary", function()
			local row = { section = "llm", key = "agent_mode", value = "action" }
			helpers.assert_eq(root_prepare('llm.agent_mode="auto"\nllm."agent_mode"="other"\n', row), false)
			helpers.assert_eq(root_prepare('llm.agent_mode="auto"\n', row, { status = "ok", content = 'llm.agent_mode="foreign"\n' }), false)
			helpers.assert_eq(root_prepare('llm.agent_mode="auto"\n', { section = "llm", key = "agent_mode", value = { child = true } }), false)
		end)

		helpers.it("preserves precise requested root numbers and signed zero through the optional scalar encoder", function()
			local vectors = {
				{ value = 0.12345678901234567, literal = "0.12345678901234566" },
				{ value = 9007199254740992, literal = "9007199254740992" },
				{ value = -0.0, literal = "-0.0" },
			}
			for _, vector in ipairs(vectors) do
				local okay, detail, content = root_prepare('a.setting=0.25\nfuture.precise=0.1\nfuture.integer=9007199254740993\n',
					{ section = "a", key = "setting", value = vector.value })
				helpers.assert_eq(okay, true, detail)
				helpers.assert_eq(content, 'a.setting = ' .. vector.literal .. '\nfuture.precise=0.1\nfuture.integer=9007199254740993\n')
				local actual = Codec.decode(content).a.setting
				helpers.assert_eq(actual, vector.value)
				if vector.value == 0 then helpers.assert_eq(1 / actual, -math.huge) end
			end
		end)
		helpers.it("refuses an encodable but wrong owned scalar before publication", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local called, detail = pcall(function()
				for _, replacement in ipairs({ "0.12345678901235", '"wrong kind"', "0.0" }) do
					LeafRows.value_literal = function() return replacement end
					local value = replacement == "0.0" and -0.0 or 0.12345678901234567
					local okay, reason, content = root_prepare('a.setting=0.25\nfuture.keep=0.1\n', { section = "a", key = "setting", value = value })
					helpers.assert_eq(okay, false, "valid syntax alone cannot acknowledge a wrong scalar")
					helpers.assert_contains(reason, "differs from the requested value")
					helpers.assert_nil(content)
				end
			end)
			LeafRows.value_literal = original
			if not called then error(detail, 0) end
		end)
	end)
end
