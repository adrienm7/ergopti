--- _shared/lua/test/toml_dotted_keys_contract.lua

--- Replays independent assignment identities without deriving expected trees
--- from the production decoder. Writes retain their byte and refusal owners.
--- @param helpers table Driver test helpers.
return function(helpers)
	-- Source literals can lose their zero sign on some LuaJIT builds.
	-- Establish the intended IEEE sign before calling any producer under test.
	local function negative_zero()
		local value = tonumber("-0.0")
		helpers.assert_eq(type(value), "number", "negative-zero request must be numeric")
		helpers.assert_eq(1 / value, -math.huge, "negative-zero request must retain its actual sign")
		return value
	end
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
		local Projection = require("script_override_projection")
		test("script projection keeps exact paths and ignores every other table", function()
			local rows = assert(Projection.prepare(Codec.decode('[script]\nordinary="001"\n[features]\nllm.enabled=false\n"literal.dot"=true\n[other]\nignored=true\n')))
			helpers.assert_eq(rows, {
				{ section = "script", key = "ordinary", path = { "ordinary" }, value = "001", accepted = true },
			})
		end)
		test("script tables and arrays stay non-scalar", function()
			local rows = assert(Projection.prepare(Codec.decode('[script]\nchild={enabled=true}\nitems=[1,2]\nempty={}\n')))
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
		helpers.it("refuses an encodable but wrong owned scalar before publication", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local called, detail = pcall(function()
				for _, replacement in ipairs({ "0.12345678901235", '"wrong kind"', "0.0" }) do
					LeafRows.value_literal = function() return replacement end
					local value = replacement == "0.0" and negative_zero() or 0.12345678901234567
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
