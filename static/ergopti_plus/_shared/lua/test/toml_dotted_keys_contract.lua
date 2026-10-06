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
		test("changed section dotted scalar has an exact owned image before publication", function()
			local replacement = '# retained\n[settings]\npersonal.future.enabled = true\n'
				.. 'personal.future.text = "001"\nowned = 1 # own comment\n[foreign]\nkeep = [1, 2]\n'
			local deletion = '# retained\n[settings]\npersonal.future.text = "001"\n'
				.. 'owned = 1 # own comment\n[foreign]\nkeep = [1, 2]\n'
			for _, vector in ipairs({
				{ row = { section = "settings.personal.future", key = "enabled", value = true }, expected = replacement, value = true },
				{ row = { section = "settings.personal.future", key = "enabled", delete = true }, expected = deletion },
			}) do
				local ok, detail, content = prepare({ vector.row })
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, vector.expected)
				helpers.assert_eq(Codec.decode(content).settings.personal.future.enabled, vector.value)
				helpers.assert_eq(Codec.decode(content).settings.personal.future.text, "001")
				helpers.assert_eq(Codec.decode(content).foreign.keep, { 1, 2 })
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
		helpers.it("updates the newly supported root-inline scalar without claiming its parent", function()
			local source = 'llm={agent_mode="auto"}\n'
			local okay, detail, content = root_prepare(source, { section = "llm", key = "agent_mode", value = "action" })
			helpers.assert_eq(okay, true, detail)
			helpers.assert_eq(content, 'llm={agent_mode="action"}\n')
			helpers.assert_eq(Codec.decode(content).llm.agent_mode, "action")
		end)
		helpers.it("refuses root container mutation and subtree collisions without manufacturing authority", function()
			for _, source in ipairs({ 'llm="obsolete"\n', 'llm=[]\n',
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

	helpers.describe("shared finite header scalar publication", function()
		local function header_prepare(source, rows)
			local writes = 0
			local okay, detail, content = Writer.prepare_batch("/controlled/header-finite-scalar.toml", rows, {
				read_with_status = function() return source, "ok" end,
				write = function() writes = writes + 1; return false end,
			})
			helpers.assert_eq(writes, 0, "numeric candidate admission never publishes")
			return okay, detail, content
		end
		local vectors = {
			{ name = "precise decimal", value = 0.12345678901234567, literal = "0.12345678901234566" },
			{ name = "representable large integer", value = 9007199254740992, literal = "9007199254740992" },
			{ name = "negative zero", value = -0.0, literal = "-0.0" },
		}
		for _, vector in ipairs(vectors) do
			helpers.it("publishes exact " .. vector.name .. " under an existing header", function()
				local source = '# before\n[a]\nsetting=0.25 # owned\nfuture=1.234567890123456789\ninteger=9223372036854775807\nempty=[]\n# after\n'
				local okay, detail, content = header_prepare(source, { { section = "a", key = "setting", value = vector.value } })
				helpers.assert_eq(okay, true, detail)
				helpers.assert_eq(content, '# before\n[a]\nsetting = ' .. vector.literal .. '\nfuture=1.234567890123456789\ninteger=9223372036854775807\nempty=[]\n# after\n')
				local actual = Codec.decode(content).a.setting
				helpers.assert_eq(actual, vector.value)
				if vector.value == 0 then helpers.assert_eq(1 / actual, -math.huge) end
			end)
		end
		helpers.it("uses the same precise numeric capability for a new key under its existing header", function()
			local okay, detail, content = header_prepare('[a]\nfuture=0.1\n', { { section = "a", key = "setting", value = 0.12345678901234567 } })
			helpers.assert_eq(okay, true, detail)
			helpers.assert_eq(content, '[a]\nsetting = 0.12345678901234566\nfuture=0.1\n')
		end)
		helpers.it("refuses a valid wrong numeric literal, keeps source and permits an explicit repaired retry", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local source = '[a]\nsetting=0.25\nfuture=0.1\n'
			local row = { section = "a", key = "setting", value = 0.12345678901234567 }
			local called, detail = pcall(function()
				LeafRows.value_literal = function() return "0.12345678901235" end
				local okay, reason, content = header_prepare(source, { row })
				helpers.assert_eq(okay, false)
				helpers.assert_contains(reason, "differs from the requested value")
				helpers.assert_nil(content)
			end)
			LeafRows.value_literal = original
			if not called then error(detail, 0) end
			local okay, reason, content = header_prepare(source, { row })
			helpers.assert_eq(okay, true, reason)
			helpers.assert_eq(content, '[a]\nsetting = 0.12345678901234566\nfuture=0.1\n')
		end)
		helpers.it("refuses an optional numeric encoder exception before candidate admission", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			LeafRows.value_literal = function() error("controlled optional encoder failure") end
			local called, okay, reason, content = pcall(header_prepare, '[a]\nsetting=0.25\n', { { section = "a", key = "setting", value = 0.12345678901234567 } })
			LeafRows.value_literal = original
			helpers.assert_eq(called, true, "the optional encoder exception is a typed refusal")
			helpers.assert_eq(okay, false)
			helpers.assert_nil(content)
			helpers.assert_contains(reason, "cannot be encoded exactly")
		end)
	end)
	helpers.describe("shared authentic root inline scalar publication", function()
		local function inline_prepare(source, rows, expected)
			local writes = 0
			local okay, detail, content = Writer.prepare_batch("/controlled/root-inline-scalar.toml", rows, {
				read_with_status = function() return source, "ok" end,
				write = function() writes = writes + 1; error("preparation cannot publish") end,
			}, expected)
			helpers.assert_eq(writes, 0)
			return okay, detail, content
		end
		local vectors = {
			{ name = "nested numeric", source = 'llm = { generation = { temperature=0.25, future=9007199254740993 }, private="untouched" } # tail\n',
				rows = { { section = "llm.generation", key = "temperature", value = 0.12345678901234567 } },
				expected = 'llm = { generation = { temperature=0.12345678901234566, future=9007199254740993 }, private="untouched" } # tail\n' },
			{ name = "first removal", source = 'a = { first=false , second="keep" , third=9007199254740993 } # tail\n',
				rows = { { section = "a", key = "first", delete = true } }, expected = 'a = { second="keep" , third=9007199254740993 } # tail\n' },
			{ name = "middle removal", source = 'a = { first=false , second="keep" , third=9007199254740993 } # tail\n',
				rows = { { section = "a", key = "second", delete = true } }, expected = 'a = { first=false , third=9007199254740993 } # tail\n' },
			{ name = "last removal", source = 'a = { first=false , second="keep" , third=9007199254740993 } # tail\n',
				rows = { { section = "a", key = "third", delete = true } }, expected = 'a = { first=false , second="keep" } # tail\n' },
			{ name = "only removal", source = 'a={only=false} # retained\n', rows = { { section = "a", key = "only", delete = true } }, expected = 'a={} # retained\n' },
			{ name = "adjacent removals", source = 'a={one=false, two=true, three="keep"}\n', rows = { { section = "a", key = "one", delete = true }, { section = "a", key = "two", delete = true } }, expected = 'a={ three="keep"}\n' },
			{ name = "all removals", source = 'a={one=false, two=true, three="keep"}\n', rows = { { section = "a", key = "one", delete = true }, { section = "a", key = "two", delete = true }, { section = "a", key = "three", delete = true } }, expected = 'a={}\n' },
			{ name = "nested empty parent retained", source = 'a={child={only=false}, foreign=[]}\n', rows = { { section = "a.child", key = "only", delete = true } }, expected = 'a={child={}, foreign=[]}\n' },
			{ name = "nested dotted inline member", source = 'a={child.setting=false, child.future=0.1, "literal.dot"={v=[]}}\n', rows = { { section = "a.child", key = "setting", value = true } }, expected = 'a={child.setting=true, child.future=0.1, "literal.dot"={v=[]}}\n' },
			{ name = "disjoint edits", source = 'a={one=false, child={setting=0.25, future=0.1}, last="keep"}\n', rows = { { section = "a", key = "one", delete = true }, { section = "a.child", key = "setting", value = -0.0 }, { section = "a", key = "last", value = "changed" } }, expected = 'a={ child={setting=-0.0, future=0.1}, last="changed"}\n' },
			{ name = "opaque escaped delimiters", source = 'a = { setting=false, "literal=key"="comma, hash# braces{}", text="escaped\\\"comma,", arrays=[{v=0.1}, []], map={n=9223372036854775807} } # keep\n', rows = { { section = "a", key = "setting", value = true } }, expected = 'a = { setting=true, "literal=key"="comma, hash# braces{}", text="escaped\\\"comma,", arrays=[{v=0.1}, []], map={n=9223372036854775807} } # keep\n' },
			{ name = "quoted root owner", source = '"team=name" = { setting=false, future=1_234.500e-2 }', rows = { { section = '"team=name"', key = "setting", value = true } }, expected = '"team=name" = { setting=true, future=1_234.500e-2 }' },
		}
		for _, vector in ipairs(vectors) do
			helpers.it("splices only the authentic " .. vector.name .. " owned span", function()
				local okay, detail, content = inline_prepare(vector.source, vector.rows)
				helpers.assert_eq(okay, true, detail)
				helpers.assert_eq(content, vector.expected, "complete independent physical image")
			end)
		end
		helpers.it("retains every byte and signed zero of an exact root-inline no-op", function()
			local source = 'a  =  { setting = -0.0 , future=9007199254740993 } # comment\n'
			local okay, detail, content = inline_prepare(source, { { section = "a", key = "setting", value = -0.0 } })
			helpers.assert_eq(okay, true, detail)
			helpers.assert_eq(content, source)
			local changed, reason, updated = inline_prepare(source, { { section = "a", key = "setting", value = 0 } })
			helpers.assert_eq(changed, true, reason)
			helpers.assert_eq(updated, 'a  =  { setting = 0 , future=9007199254740993 } # comment\n')
		end)
		helpers.it("preserves BOM and exact trailing newline ownership", function()
			local bom = string.char(239, 187, 191)
			local source = bom .. 'a={setting=false, future=[]}'
			local okay, detail, content = inline_prepare(source, { { section = "a", key = "setting", value = true } })
			helpers.assert_eq(okay, true, detail)
			helpers.assert_eq(content, bom .. 'a={setting=true, future=[]}')
		end)
		helpers.it("strict canonical span evidence refuses malformed and non-inline values", function()
			for _, raw in ipairs({ '[]', 'false', '{a=1,a=2}', '{a=1,}', '{a={b=1}, a.b=2}', '{"\\q"=1}', '{a=[1,2}', '{a="unclosed}', '{a=1}\n', '{a=1} junk' }) do
				helpers.assert_nil(Codec.inline_member_spans(raw), raw)
			end
			local raw = ' { "key=,hash#" = [1, {v="{}"}], setting=false } # tail'
			local spans = Codec.inline_member_spans(raw)
			helpers.assert_true(type(spans) == "table")
			helpers.assert_eq(#spans.members, 2)
			helpers.assert_eq(spans.members[1].segments, { "key=,hash#" })
			helpers.assert_eq(raw:sub(spans.members[1].value_first, spans.members[1].value_last), '[1, {v="{}"}]')
			helpers.assert_eq(raw:sub(spans.members[2].value_first, spans.members[2].value_last), 'false')
			spans.members[2].value_first = 1
			helpers.assert_eq(raw:sub(Codec.inline_member_spans(raw).members[2].value_first, Codec.inline_member_spans(raw).members[2].value_last), 'false', "each descriptive result is detached")
		end)
		helpers.it("keeps source collisions, closed parents and new-member additions refused", function()
			local vectors = {
				{ source = 'a={setting=false, Setting=true}\n', rows = { { section = "a", key = "setting", value = true } } },
				{ source = 'a={setting=false}\nA={setting=true}\n', rows = { { section = "a", key = "setting", value = true } } },
				{ source = 'a={setting=false, setting=true}\n', rows = { { section = "a", key = "setting", value = true } } },
				{ source = 'a={setting=false}\n[a]\nother=1\n', rows = { { section = "a", key = "setting", value = true } } },
				{ source = 'a={child="obsolete", setting=false}\n', rows = { { section = "a.child", key = "setting", value = true } } },
				{ source = 'a={child=[], setting=false}\n', rows = { { section = "a.child", key = "setting", value = true } } },
				{ source = 'a={setting=false}\n', rows = { { section = "a", key = "other", value = true } }, expected = 'a={setting=false,other = true}\n' },
				{ source = 'a={"literal.dot"=false}\n', rows = { { section = "a", key = "literal.dot", literal_key = true, value = true } } },
				{ source = 'a={child={setting=false}}\n', rows = { { section = "a", key = "child", value = { setting = false } }, { section = "a.child", key = "setting", value = true } } },
				{ source = 'a={setting=false}\n', rows = { { section = "a", key = "setting", value = "changed type" } } },
			}
			for _, vector in ipairs(vectors) do
				local okay, _, content = inline_prepare(vector.source, vector.rows)
				if vector.expected then
					helpers.assert_eq(okay, true, vector.source); helpers.assert_eq(content, vector.expected)
					local decoded = Codec.decode(content)
					helpers.assert_eq(decoded.a.setting, false); helpers.assert_eq(decoded.a.other, true)
				else
					helpers.assert_eq(okay, false, vector.source)
					helpers.assert_nil(content)
				end
			end
		end)
		helpers.it("refuses stale source before any inline edit", function()
			local source = 'a={setting=false, future=0.1}\n'
			local okay, detail, content = inline_prepare(source, { { section = "a", key = "setting", value = true } }, { status = "ok", content = source .. '# successor\n' })
			helpers.assert_eq(okay, false)
			helpers.assert_contains(detail, "source changed")
			helpers.assert_nil(content)
		end)
		helpers.it("rejects an authenticated but wrong string literal before candidate ACK", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local source = 'a={text="old", future=0.1}\n'
			LeafRows.value_literal = function(value)
				if type(value) == "string" then return '"wrong"' end
				return original(value)
			end
			local called, okay, reason, content = pcall(function()
				local rows = LeafRows.prepare(source, { { path = { "a", "text" }, value = "wanted" } })
				return inline_prepare(source, rows)
			end)
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(okay, false)
			helpers.assert_contains(reason, "differs from the requested value")
			helpers.assert_nil(content)
		end)
		helpers.it("refuses a wrong numeric token before publication and permits explicit repaired retry", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local source = 'a={setting=0.25, future=0.1}\n'
			local rows = { { section = "a", key = "setting", value = 0.12345678901234567 } }
			LeafRows.value_literal = function() return "0.12345678901235" end
			local called, okay, reason, content = pcall(inline_prepare, source, rows)
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(okay, false)
			helpers.assert_contains(reason, "differs from the requested value")
			helpers.assert_nil(content)
			local accepted, detail, repaired = inline_prepare(source, rows)
			helpers.assert_eq(accepted, true, detail)
			helpers.assert_eq(repaired, 'a={setting=0.12345678901234566, future=0.1}\n')
		end)
	end)

	helpers.describe("shared section-relative dotted scalar publication", function()
		local function section_prepare(source, rows, expected)
			local writes = 0
			local okay, detail, content = Writer.prepare_batch("/controlled/section-dotted-scalar.toml", rows, {
				read_with_status = function() return source, "ok" end,
				write = function() writes = writes + 1; error("preparation cannot publish") end,
			}, expected)
			helpers.assert_eq(writes, 0)
			return okay, detail, content
		end
		local vectors = {
			{ name = "boolean leaf", source = '[a]\nchild.setting=false # owned\nchild.future=9007199254740993 # foreign\n', rows = { { section = "a.child", key = "setting", value = true } }, expected = '[a]\nchild.setting = true\nchild.future=9007199254740993 # foreign\n' },
			{ name = "string leaf", source = '[a]\nchild.setting="001"\nchild.future=[]\n', rows = { { section = "a.child", key = "setting", value = "002" } }, expected = '[a]\nchild.setting = "002"\nchild.future=[]\n' },
			{ name = "nested header", source = '[a.parent]\nchild.setting=false\nfuture={}\n', rows = { { section = "a.parent.child", key = "setting", value = true } }, expected = '[a.parent]\nchild.setting = true\nfuture={}\n' },
			{ name = "quoted header", source = '["a"."parent"] # header\nchild.setting=false\nfuture="unchanged"\n', rows = { { section = "a.parent.child", key = "setting", value = true } }, expected = '["a"."parent"] # header\nchild.setting = true\nfuture="unchanged"\n' },
			{ name = "quoted literal header segment", source = '["literal.dot"]\nchild.setting=false\nfuture=0.1\n', rows = { { section = '"literal.dot".child', key = "setting", value = true } }, expected = '["literal.dot"]\nchild.setting = true\nfuture=0.1\n' },
			{ name = "precise finite number", source = '[a]\nchild.setting=0.25\nchild.future=9007199254740993\n', rows = { { section = "a.child", key = "setting", value = 0.12345678901234567 } }, expected = '[a]\nchild.setting = 0.12345678901234566\nchild.future=9007199254740993\n' },
			{ name = "negative zero", source = '[a]\nchild.setting=0.25\nchild.future=1.0\n', rows = { { section = "a.child", key = "setting", value = -0.0 } }, expected = '[a]\nchild.setting = -0.0\nchild.future=1.0\n' },
			{ name = "explicit leaf deletion", source = '[a]\nchild.setting=false\nchild.future=0.1 # foreign\n', rows = { { section = "a.child", key = "setting", delete = true } }, expected = '[a]\nchild.future=0.1 # foreign\n' },
			{ name = "multiline scalar record", source = '[a]\nchild.setting="""line one\nline two"""\nchild.future=[]\n', rows = { { section = "a.child", key = "setting", value = "replacement" } }, expected = '[a]\nchild.setting = "replacement"\nchild.future=[]\n' },
			{ name = "two separate scalar owners", source = '[a]\nchild.first=false\nchild.second="001"\nchild.future={}\n', rows = { { section = "a.child", key = "first", value = true }, { section = "a.child", key = "second", delete = true } }, expected = '[a]\nchild.first = true\nchild.future={}\n' },
		}
		for _, vector in ipairs(vectors) do
			helpers.it("publishes exact section scalar image: " .. vector.name, function()
				local okay, detail, content = section_prepare(vector.source, vector.rows)
				helpers.assert_eq(okay, true, detail)
				helpers.assert_eq(content, vector.expected)
				helpers.assert_true(type(Codec.decode(content)) == "table")
			end)
		end
		helpers.it("retains the complete original section scalar no-op image", function()
			local source = '["a"] # exact header\n child.setting = -0.0 # exact scalar\nchild.future=9007199254740993\n'
			local okay, detail, content = section_prepare(source, { { section = "a.child", key = "setting", value = -0.0 } })
			helpers.assert_eq(okay, true, detail)
			helpers.assert_eq(content, source)
			helpers.assert_eq(1 / Codec.decode(content).a.child.setting, -math.huge)
		end)
		local refused = {
			{ source = '[a]\nchild.setting=false\n', row = { section = "a.child", key = "setting", value = "wrong type" } },
			{ source = '[a]\nchild.setting=[]\n', row = { section = "a.child", key = "setting", value = false } },
			{ source = '[a]\nchild.setting={}\n', row = { section = "a.child", key = "setting", delete = true } },
			{ source = '[a]\nchild=7\n', row = { section = "a.child", key = "setting", value = true } },
			{ source = '[a]\nchild."literal.dot"=false\n', row = { section = "a.child", key = "literal.dot", value = true } },
			{ source = '[[a]]\nchild.setting=false\n', row = { section = "a.child", key = "setting", value = true } },
			{ source = '[a]\nChild.setting=false\nchild.future=true\n', row = { section = "a.Child", key = "setting", value = true } },
			{ source = '[a]\nchild.setting=false\n', row = { section = "A.child", key = "setting", value = true } },
			{ source = '[a]\nchild.setting=0.25\n', row = { section = "a.child", key = "setting", value = math.huge } },
			{ source = '[a]\nchild.setting=0.25\n', row = { section = "a.child", key = "setting", value = 0 / 0 } },
			{ source = '[a]\nchild.setting=false\nchild.setting=true\n', row = { section = "a.child", key = "setting", value = true } },
		}
		for index, vector in ipairs(refused) do
			helpers.it("retains scoped scalar safety refusal " .. index, function()
				local okay, _, content = section_prepare(vector.source, { vector.row })
				helpers.assert_eq(okay, false)
				helpers.assert_nil(content)
			end)
		end
		helpers.it("refuses stale section source before preparing an owned scalar", function()
			local source = '[a]\nchild.setting=false\nchild.future=[]\n'
			local okay, detail, content = section_prepare(source, { { section = "a.child", key = "setting", value = true } }, { status = "ok", content = source .. '# successor\n' })
			helpers.assert_eq(okay, false)
			helpers.assert_eq(detail, "source changed before preparing the batch")
			helpers.assert_nil(content)
		end)
		helpers.it("refuses overlapping section scalar and ancestor requests", function()
			local okay, _, content = section_prepare('[a]\nchild.setting=false\nchild.future=[]\n', {
				{ section = "a.child", key = "setting", value = true },
				{ section = "a", key = "child", value = "replaced" },
			})
			helpers.assert_eq(okay, false)
			helpers.assert_nil(content)
		end)
		helpers.it("refuses an inexact section literal and permits an explicit repaired retry", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local source = '[a]\nchild.setting=0.25\nchild.future=9007199254740993\n'
			local rows = { { section = "a.child", key = "setting", value = 0.12345678901234567 } }
			LeafRows.value_literal = function() return "0.12345678901235" end
			local called, okay, _, content = pcall(section_prepare, source, rows)
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(okay, false)
			helpers.assert_nil(content)
			local accepted, detail, repaired = section_prepare(source, rows)
			helpers.assert_eq(accepted, true, detail)
			helpers.assert_eq(repaired, '[a]\nchild.setting = 0.12345678901234566\nchild.future=9007199254740993\n')
		end)
	end)
end
