--- _shared/lua/test/toml_batch_existing_key_contract.lua

--- The batch writer addresses a key whatever spelling already holds it: a
--- table header (the empty headers older macOS builds wrote for every empty
--- map, a structured value such as a shortcut), an array of tables, or a quoted
--- bare-compatible key. It used to refuse each of them with "the batch cannot
--- address an existing quoted or nested key", which failed every macOS menu
--- save, the Hotstrings switch included, on such a config.toml
--- (toml-batch-existing-key).
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
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec.codec")
	local function prepare(source, rows)
		return Writer.prepare_batch("/controlled/existing-key.toml", rows, {
			read_with_status = function() return source, "ok" end,
			write = function() error("preparation must never publish") end,
		})
	end

	helpers.describe("shared TOML batch over existing key spellings (toml-batch-existing-key)", function()
		helpers.it("deletes a table declared by an empty header and keeps every comment", function()
			local source = '# head\n[llm.models]\nselected = "mlx"\n\n[llm.models.user_models]\n'
				.. '# user-added entries here\n\n\n# ===== 3.4 Profiles =====\n[llm.profiles]\nactive = "basic"\n'
			local ok, detail, content = prepare(source, {
				{ section = "llm.models", key = "user_models", delete = true },
			})
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, (source:gsub("%[llm%.models%.user_models%]\n", "", 1)))
		end)

		helpers.it("replaces a header table, its descendants and interleaved blocks by one scalar", function()
			local source = '[metrics]\nenabled = true\n[metrics.shortcut]\nmods = ["cmd"]\nkey = "m"\n'
				.. '[other]\nx = 1\n[metrics.shortcut.extra]\ny = 2\n'
			local ok, detail, content = prepare(source, {
				{ section = "metrics", key = "shortcut", value = false },
			})
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[metrics]\nshortcut = false\nenabled = true\n[other]\nx = 1\n')
		end)

		helpers.it("removes a header table whose parent has no header of its own", function()
			local source = '[metrics.shortcut]\nmods = ["cmd"]\nkey = "m"\n[neighbor]\nkeep = true\n'
			local ok, detail, content = prepare(source, { { section = "metrics", key = "shortcut", delete = true } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[neighbor]\nkeep = true\n')
			local set_ok, set_detail, set_content = prepare(source, {
				{ section = "metrics", key = "shortcut", value = { key = "k", mods = { "alt" } } },
			})
			helpers.assert_eq(set_ok, true, set_detail)
			local decoded = Codec.decode(set_content)
			helpers.assert_eq(decoded.metrics.shortcut, { key = "k", mods = { "alt" } })
			helpers.assert_eq(decoded.neighbor.keep, true)
		end)

		helpers.it("leaves a value another spelling already holds byte-for-byte", function()
			local list = '[hotstrings]\nexpansion_delay = 0.5\n\n# mine\n[[hotstrings.terminators]]\n'
				.. 'key = "custom_a"\nchar = "a"\nlabel = "a"\nconsume = true\n\n[[hotstrings.terminators]]\n'
				.. 'key = "custom_b"\nchar = "b"\nlabel = "b"\nconsume = false\n'
			local same = {
				{ key = "custom_a", char = "a", label = "a", consume = true },
				{ key = "custom_b", char = "b", label = "b", consume = false },
			}
			for _, case in ipairs({
				{ list, { section = "hotstrings", key = "terminators", value = same } },
				{ '[hotstrings.delays]\n# none yet\n', { section = "hotstrings", key = "delays", value = {} } },
				{ 'hotstrings = { enabled = false }\n', { section = "hotstrings", key = "enabled", value = false } },
			}) do
				local ok, detail, content = prepare(case[1], { case[2] })
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, case[1])
			end
		end)

		helpers.it("rewrites a changed array of tables as one inline list and keeps its comments", function()
			local source = '[hotstrings]\nexpansion_delay = 0.5\n\n# mine\n[[hotstrings.terminators]]\n'
				.. 'key = "custom_a"\nchar = "a"\nlabel = "a"\nconsume = true\n[next]\nv = 1\n'
			local list = {
				{ key = "custom_a", char = "a", label = "a", consume = false },
				{ key = "custom_c", char = "c", label = "c", consume = true },
			}
			local ok, detail, content = prepare(source, { { section = "hotstrings", key = "terminators", value = list } })
			helpers.assert_eq(ok, true, detail)
			local decoded = Codec.decode(content)
			helpers.assert_eq(decoded.hotstrings.terminators, list)
			helpers.assert_eq(decoded.hotstrings.expansion_delay, 0.5)
			helpers.assert_eq(decoded.next.v, 1)
			helpers.assert_true(content:find("# mine\n", 1, true) ~= nil, "a comment is never dropped")
			helpers.assert_true(content:find("[[", 1, true) == nil, "no array-of-tables header is left")
		end)

		helpers.it("updates and deletes a quoted bare-compatible key in place", function()
			for _, spelling in ipairs({ '"enabled"', "'enabled'" }) do
				local source = '[shortcuts]\n' .. spelling .. ' = true\nother = 1\n'
				local ok, detail, content = prepare(source, { { section = "shortcuts", key = "enabled", value = false } })
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, '[shortcuts]\nenabled = false\nother = 1\n')
				local deleted, delete_detail, remaining = prepare(source, { { section = "shortcuts", key = "enabled", delete = true } })
				helpers.assert_eq(deleted, true, delete_detail)
				helpers.assert_eq(remaining, '[shortcuts]\nother = 1\n')
			end
			local ok, detail, content = prepare('[hotstrings.groups]\n"autocorrection" = false\n', {
				{ section = "hotstrings.groups", key = "autocorrection", value = true },
			})
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[hotstrings.groups]\nautocorrection = true\n')
		end)

		helpers.it("names the key an inline table holds when its value changes", function()
			for _, source in ipairs({ 'hotstrings = { enabled = false }\n' }) do
				local section = source:find("hotstrings", 1, true) and "hotstrings" or "metrics.shortcut"
				local key = section == "hotstrings" and "enabled" or "key"
				local ok, detail = prepare(source, { { section = section, key = key, value = "changed" } })
				helpers.assert_eq(ok, false, source)
				helpers.assert_true(tostring(detail):find(section .. "." .. key, 1, true) ~= nil, tostring(detail))
				helpers.assert_true(tostring(detail):find("inline", 1, true) ~= nil, tostring(detail))
			end
		end)

		helpers.it("updates the existing section-inline string without owning its parent", function()
			local source = '[metrics]\nshortcut = { key = "m" }\n'
			local ok, detail, content = prepare(source, { { section = "metrics.shortcut", key = "key", value = "changed" } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[metrics]\nshortcut = { key = "changed" }\n')
			helpers.assert_eq(Codec.decode(content).metrics.shortcut.key, "changed")
		end)

		helpers.it("refuses a batch that replaces a header table and writes inside it", function()
			local source = '[metrics.shortcut]\nmods = ["cmd"]\nkey = "m"\n'
			local ok, detail = prepare(source, {
				{ section = "metrics", key = "shortcut", delete = true },
				{ section = "metrics.shortcut", key = "key", value = "x" },
			})
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("metrics.shortcut", 1, true) ~= nil, tostring(detail))
		end)
	end)

	helpers.describe("shared section-relative inline scalar ownership", function()
		local source = '[a] # header\nchild = { first=false, middle="001", last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n'
		local rows = { { section = "a.child", key = "first", value = true } }
		helpers.it("describes the complete eligible parent and retains fresh detached hints", function()
			local parents = assert(Writer.source_inline_scalar_parents(source, rows))
			helpers.assert_eq(parents, { ["a.child"] = true })
			parents["a.child"] = false
			helpers.assert_eq(Writer.source_inline_scalar_parents(source, rows), { ["a.child"] = true })
		end)
		local images = {
			{ name = "existing boolean", rows = rows, expected = '[a] # header\nchild = { first=true, middle="001", last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n' },
			{ name = "existing string", rows = { { section = "a.child", key = "middle", value = "002" } }, expected = '[a] # header\nchild = { first=false, middle="002", last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n' },
			{ name = "precise number", rows = { { section = "a.child", key = "last", value = 0.12345678901234567 } }, expected = '[a] # header\nchild = { first=false, middle="001", last=0.12345678901234566, future=9007199254740993, empty=[], map={} } # trailer\n' },
			{ name = "negative zero", rows = { { section = "a.child", key = "last", value = negative_zero() } }, expected = '[a] # header\nchild = { first=false, middle="001", last=-0.0, future=9007199254740993, empty=[], map={} } # trailer\n' },
			{ name = "first deletion", rows = { { section = "a.child", key = "first", delete = true } }, expected = '[a] # header\nchild = { middle="001", last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n' },
			{ name = "middle deletion", rows = { { section = "a.child", key = "middle", delete = true } }, expected = '[a] # header\nchild = { first=false, last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n' },
			{ name = "existing no-op", rows = { { section = "a.child", key = "first", value = false } }, expected = source },
			{ name = "authored absent deletion", rows = { { section = "a.child", key = "missing", delete = true } }, expected = source },
			{ name = "scalar and absent sibling deletion", rows = { { section = "a.child", key = "first", value = true }, { section = "a.child", key = "missing", delete = true } }, expected = '[a] # header\nchild = { first=true, middle="001", last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n' },
		}
		for _, vector in ipairs(images) do
			helpers.it("publishes complete inline source: " .. vector.name, function()
				helpers.assert_eq(Writer.source_inline_scalar_parents(source, vector.rows), { ["a.child"] = true })
				local ok, detail, content = prepare(source, vector.rows)
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, vector.expected)
			end)
		end
		local not_admitted = {
			{ { section = "a.child", key = "first", value = "wrong type" } },
			{ { section = "a.child", key = "empty", delete = true } },
			{ { section = "a.child.empty", key = "missing", delete = true } },
			{ { section = "a.child.first", key = "missing", delete = true } },
			{ { section = "a.child", key = "new", value = true } },
			{ { section = "a", key = "child", value = false } },
			{ { section = "a.child", key = "last", value = math.huge } },
			{ { section = "a.child", key = "last", value = 0 / 0 } },
			{ { section = "A.child", key = "first", value = true } },
			{ { section = "a.child", key = "first", value = true }, { section = "a.child", key = "new", value = true } },
			{ { section = "a.child", key = "first", value = true }, { section = "a", key = "child", value = {} } },
			{ { section = "a.child", key = "missing", delete = true }, { section = "a.child.missing", key = "child", delete = true } },
		}
		for index, requests in ipairs(not_admitted) do
			helpers.it("withholds the entire mixed inline group " .. index, function()
				if index == 5 or index == 10 then
					helpers.assert_eq(Writer.source_inline_scalar_parents(source, requests), { ["a.child"] = true })
					local expected = index == 5
						and '[a] # header\nchild = { first=false, middle="001", last=0.25, future=9007199254740993, empty=[], map={} ,new = true} # trailer\n'
						or '[a] # header\nchild = { first=true, middle="001", last=0.25, future=9007199254740993, empty=[], map={} ,new = true} # trailer\n'
					local okay, detail, content = prepare(source, requests)
					helpers.assert_eq(okay, true, detail); helpers.assert_eq(content, expected)
					local decoded, shapes = require("toml_codec.leaf_rows").decode_source(content)
					helpers.assert_eq(decoded.a.child.new, true)
					helpers.assert_eq(decoded.a.child.first, index == 10)
					helpers.assert_true(shapes.arrays[decoded.a.child.empty] == true)
					helpers.assert_true(shapes.arrays[decoded.a.child.map] ~= true)
				else
					helpers.assert_eq(Writer.source_inline_scalar_parents(source, requests), {})
				end
			end)
		end
		helpers.it("retains exact nested dotted and quoted member fragments under a quoted header", function()
			local input = '["a"]\nchild={nested.setting=false,nested.future=0.1,"literal.dot"={keep=[]}} # exact\n'
			local requests = { { section = "a.child.nested", key = "setting", value = true } }
			helpers.assert_eq(Writer.source_inline_scalar_parents(input, requests), { ["a.child"] = true })
			local ok, detail, content = prepare(input, requests)
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '["a"]\nchild={nested.setting=true,nested.future=0.1,"literal.dot"={keep=[]}} # exact\n')
		end)
		helpers.it("preserves the explicit empty inline parent after its last scalar deletion", function()
			local input = '[a]\nchild={last=false} # retained\n'
			local requests = { { section = "a.child", key = "last", delete = true } }
			local ok, detail, content = prepare(input, requests)
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[a]\nchild={} # retained\n')
		end)
		helpers.it("rejects malformed source, sparse and duplicate descriptions", function()
			for _, input in ipairs({ '[a]\nchild={bad=false,bad=true}\n', '[a]\nchild={bad=false\n' }) do helpers.assert_nil(Writer.source_inline_scalar_parents(input, rows)) end
			for _, requests in ipairs({ { [2] = rows[1] }, { rows[1], rows[1] }, { { section = "a.child", key = "first", delete = true, value = false } }, { { section = "a.child", key = "first" } }, { { section = "a..child", key = "first", value = true } } }) do helpers.assert_nil(Writer.source_inline_scalar_parents(source, requests)) end
		end)
		helpers.it("withholds hints when the canonical decoder does not publish shape evidence", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.decode_source
			LeafRows.decode_source = function(content)
				local decoded = original(content)
				return decoded
			end
			local called, parents = pcall(Writer.source_inline_scalar_parents, source, rows)
			LeafRows.decode_source = original
			helpers.assert_eq(called, true)
			helpers.assert_nil(parents)
		end)
		helpers.it("withholds array-table and literal-dot scalar source hints", function()
			helpers.assert_eq(Writer.source_inline_scalar_parents('[[a]]\nchild={first=false}\n', rows), {})
			helpers.assert_eq(Writer.source_inline_scalar_parents('[a]\nchild={"literal.dot"=false}\n', { { section = "a.child", key = "literal.dot", value = true } }), {})
		end)
		helpers.it("keeps an empty literal identity on its existing native whole-parent route", function()
			helpers.assert_eq(Writer.source_inline_scalar_parents('[a]\nchild={""=false,setting=false}\n', { { section = "a.child", key = "", value = true } }), {})
			local ok = prepare('[a]\nchild={""=false,setting=false}\n', { { section = "a.child", key = "", value = true } })
			helpers.assert_eq(ok, false, "a descriptive empty source identity cannot authorize a direct writer row")
		end)
		helpers.it("refuses a wrong scalar candidate even after a hint is forged", function()
			local hint = assert(Writer.source_inline_scalar_parents(source, rows)); hint["a.child"] = true
			local ok = prepare(source, { { section = "a.child", key = "first", value = "wrong type" } })
			helpers.assert_eq(ok, false)
		end)
		helpers.it("checks the actual typed scalar candidate after an eligible encoder is interposed", function()
			-- Mac's original owning fixture reloads the codec after its writer.
			-- Reload this actual producer once so the mutated codec is its owner.
			local retained = package.loaded["toml_codec.writer"]
			package.loaded["toml_codec.writer"] = nil
			local loaded, producer = pcall(require, "toml_codec.writer")
			package.loaded["toml_codec.writer"] = retained
			helpers.assert_eq(loaded, true, producer)
			local function owned_prepare()
				return producer.prepare_batch('/controlled/typed-inline.toml', rows, {
					read_with_status = function() return source, "ok" end,
					write = function() error("preparation cannot publish") end,
				})
			end
			local original = Codec.encode_value
			Codec.encode_value = function(value)
				if value == true then return "false" end
				return original(value)
			end
			local called, ok, _, content = pcall(owned_prepare)
			Codec.encode_value = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(ok, false)
			helpers.assert_nil(content)
			local accepted, detail, repaired = owned_prepare()
			helpers.assert_eq(accepted, true, detail)
			helpers.assert_eq(repaired, '[a] # header\nchild = { first=true, middle="001", last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n')
		end)
		helpers.it("retains the strict actual source precondition after hint creation", function()
			helpers.assert_eq(Writer.source_inline_scalar_parents(source, rows), { ["a.child"] = true })
			local ok, detail = Writer.prepare_batch('/controlled/stale-inline.toml', rows, { read_with_status = function() return source .. '# successor\n', 'ok' end }, { status = 'ok', content = source })
			helpers.assert_eq(ok, false)
			helpers.assert_eq(detail, 'source changed before preparing the batch')
		end)
	end)

	helpers.describe("exact source integers above the double precision boundary", function()
		local cases = {
			{ name="root inline", source='a={number=9007199254740993,foreign=[]} # exact\n', section="a", expected='a={number=9007199254740992,foreign=[]} # exact\n' },
			{ name="root dotted", source='a.number=9007199254740993 # owned\nfuture=[] # exact\n', section="a", expected='a.number = 9007199254740992\nfuture=[] # exact\n' },
			{ name="section dotted", source='[a]\nchild.number=9007199254740993 # owned\nfuture=[] # exact\n', section="a.child", expected='[a]\nchild.number = 9007199254740992\nfuture=[] # exact\n' },
			{ name="header leaf", source='[a]\nnumber=9007199254740993 # owned\nfuture=[] # exact\n', section="a", expected='[a]\nnumber = 9007199254740992\nfuture=[] # exact\n' },
			{ name="section inline", source='[a]\nchild={number=9007199254740993,foreign=[]} # exact\n', section="a.child", expected='[a]\nchild={number=9007199254740992,foreign=[]} # exact\n' },
		}
		for _, vector in ipairs(cases) do
			helpers.it("publishes exact requested integer through " .. vector.name, function()
				local rows = { { section=vector.section, key="number", value=9007199254740992 } }
				local ok, detail, content = prepare(vector.source, rows)
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, vector.expected)
			end)
		end
		local literals = {
			{ token="-9007199254740993", value=-9007199254740992, expected="-9007199254740992" },
			{ token="9_007_199_254_740_993", value=9007199254740992, expected="9007199254740992" },
			{ token="0x20000000000001", value=9007199254740992, expected="9007199254740992" },
			{ token="0o400000000000000001", value=9007199254740992, expected="9007199254740992" },
			{ token="0b100000000000000000000000000000000000000000000000000001", value=9007199254740992, expected="9007199254740992" },
			{ token="9007199254740991", value=9007199254740991, expected="9007199254740991" },
			{ token="+9_007_199_254_740_992", value=9007199254740992, expected="+9_007_199_254_740_992" },
			{ token="9007199254740994", value=9007199254740994, expected="9007199254740994" },
			{ token="-9007199254740991", value=-9007199254740991, expected="-9007199254740991" },
			{ token="-9_007_199_254_740_992", value=-9007199254740992, expected="-9_007_199_254_740_992" },
			{ token="-9007199254740994", value=-9007199254740994, expected="-9007199254740994" },
			{ token="1.0000000000000001e16", value=10000000000000000, expected="1.0000000000000001e16" },
			{ token="0.1", value=0.1, expected="0.1" },
			{ token="-0.0", value=negative_zero(), expected="-0.0" },
		}
		for _, vector in ipairs(literals) do
			helpers.it("retains exact numeric intent for canonical token " .. vector.token, function()
				local source = '[a]\nchild={number=' .. vector.token .. ',foreign=9223372036854775807,empty=[]} # exact\n'
				local rows = { { section="a.child", key="number", value=vector.value } }
				helpers.assert_eq(Writer.source_inline_scalar_parents(source, rows), { ["a.child"]=true })
				local ok, detail, content = prepare(source, rows)
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, '[a]\nchild={number=' .. vector.expected .. ',foreign=9223372036854775807,empty=[]} # exact\n')
			end)
		end
		helpers.it("keeps genuine source-shaped scalar requests exact despite decoded integer aliasing", function()
			local LeafRows = require("toml_codec.leaf_rows")
			local source='a.number=9007199254740993\nfuture=9223372036854775807 # exact\n'
			local rows=LeafRows.prepare(source, { { path={"a","number"}, value=9007199254740992 } })
			local ok, detail, content=prepare(source, rows)
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, 'a.number = 9007199254740992\nfuture=9223372036854775807 # exact\n')
		end)
		helpers.it("preserves authentic unrelated numeric tokens inside a source-shaped carried model", function()
			local LeafRows=require("toml_codec.leaf_rows")
			local source='[a]\nchild={number=9007199254740993,flag=false,empty=[]}\n'
			local rows=LeafRows.prepare(source, { { path={"a","child","flag"}, value=true } })
			local ok, detail, content=prepare(source, rows)
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[a]\nchild = { empty = [], flag = true, number = 9007199254740993 }\n')
		end)
		helpers.it("refuses a malicious decoded-equal integer literal before a native publisher", function()
			local LeafRows=require("toml_codec.leaf_rows")
			local original=LeafRows.value_literal
			LeafRows.value_literal=function(value) if value==9007199254740992 then return "9007199254740993" end return original(value) end
			local called, ok, _, content=pcall(prepare, '[a]\nnumber=0\n', { { section="a", key="number", value=9007199254740992 } })
			LeafRows.value_literal=original
			helpers.assert_eq(called, true)
			helpers.assert_eq(ok, false)
			helpers.assert_nil(content)
			local repaired, detail, bytes=prepare('[a]\nnumber=0\n', { { section="a", key="number", value=9007199254740992 } })
			helpers.assert_eq(repaired, true, detail)
			helpers.assert_eq(bytes, '[a]\nnumber = 9007199254740992\n')
		end)
	end)

	helpers.describe("source-shaped scalar numeric intent remains independently exact", function()
		helpers.it("refuses an authentic scalar row minted by a decoded-equal wrong encoder", function()
			local LeafRows=require("toml_codec.leaf_rows")
			local source='[a]\nnumber=0\nfuture=9223372036854775807 # exact\n'
			local original=LeafRows.value_literal
			LeafRows.value_literal=function(value)
				if value==9007199254740992 then return "9007199254740993" end
				return original(value)
			end
			local capability
			local called, accepted, detail, content=pcall(function()
				local rows=LeafRows.prepare(source,{ {path={"a","number"},value=9007199254740992} })
				capability=LeafRows.publication_capability(rows[1])
				return prepare(source,rows)
			end)
			LeafRows.value_literal=original
			helpers.assert_eq(called,true,accepted)
			helpers.assert_true(capability~=nil)
			helpers.assert_eq(accepted,false)
			helpers.assert_nil(content)
			local rows=LeafRows.prepare(source,{ {path={"a","number"},value=9007199254740992} })
			local repaired,why,bytes=prepare(source,rows)
			helpers.assert_eq(repaired,true,why)
			helpers.assert_eq(bytes,'[a]\nnumber = 9007199254740992\nfuture=9223372036854775807 # exact\n')
		end)
	end)

	helpers.describe("authentic inline parents admit absent scalar members", function()
		local vectors = {
			{ name="root nested scalar", source='a={child={foreign=9223372036854775807,empty=[]}} # keep\n', section="a.child", key="number", value=0.25,
				expected='a={child={foreign=9223372036854775807,empty=[],number = 0.25}} # keep\n' },
			{ name="relative scalar", source='[a] # keep\nchild={foreign=[],map={}} # tail\n', section="a.child", key="number", value=0.25,
				expected='[a] # keep\nchild={foreign=[],map={},number = 0.25} # tail\n' },
			{ name="empty source object", source='[a]\nchild={ } # tail\n', section="a.child", key="flag", value=false,
				expected='[a]\nchild={ flag = false} # tail\n' },
			{ name="precise finite number", source='[a]\nchild={future=9007199254740993}\n', section="a.child", key="number", value=0.12345678901234567,
				expected='[a]\nchild={future=9007199254740993,number = 0.12345678901234566}\n' },
			{ name="negative zero", source='[a]\nchild={future=[]}\n', section="a.child", key="number", value=-1 / math.huge,
				expected='[a]\nchild={future=[],number = -0.0}\n' },
			{ name="quoted key and string", source='[a]\nchild={future="001"}\n', section="a.child", key="new key", value="literal",
				expected='[a]\nchild={future="001","new key" = "literal"}\n' },
		}
		for _, vector in ipairs(vectors) do
			helpers.it("inserts " .. vector.name .. " while retaining the complete foreign image", function()
				local rows={{section=vector.section,key=vector.key,value=vector.value}}
				if vector.section=="a.child" and vector.source:sub(1,1)=="[" then
					helpers.assert_eq(Writer.source_inline_scalar_parents(vector.source,rows),{["a.child"]=true})
				end
				local ok,detail,bytes=prepare(vector.source,rows)
				helpers.assert_eq(ok,true,detail);helpers.assert_eq(bytes,vector.expected)
				local decoded=require("toml_codec").decode(bytes)
				helpers.assert_eq(decoded.a.child[vector.key],vector.value)
				if vector.name=="negative zero" then helpers.assert_eq(1/decoded.a.child.number,-math.huge) end
				local again,why,unchanged=prepare(bytes,rows)
				helpers.assert_eq(again,true,why);helpers.assert_eq(unchanged,bytes)
			end)
		end
		helpers.it("sorts only new sibling members and retains mixed replacement deletion and foreign spans",function()
			local source='[a]\nchild={old=1,drop=false,future=[]} # keep\n'
			local rows={{section="a.child",key="z",value=true},{section="a.child",key="old",value=2},
				{section="a.child",key="drop",delete=true},{section="a.child",key="b",value="new"}}
			helpers.assert_eq(Writer.source_inline_scalar_parents(source,rows),{["a.child"]=true})
			local ok,detail,bytes=prepare(source,rows)
			helpers.assert_eq(ok,true,detail);helpers.assert_eq(bytes,'[a]\nchild={old=2,future=[],b = "new",z = true} # keep\n')
		end)
		local refused = {
			{ name="scalar parent", source='[a]\nchild=7\n', section="a.child", key="number", value=0.25 },
			{ name="array parent", source='[a]\nchild=[]\n', section="a.child", key="number", value=0.25 },
			{ name="missing intermediate parent", source='[a]\nchild={future=[]}\n', section="a.child.missing", key="number", value=0.25 },
			{ name="existing scalar intermediate", source='[a]\nchild={nested=7}\n', section="a.child.nested", key="number", value=0.25 },
			{ name="array intermediate", source='[a]\nchild={nested=[]}\n', section="a.child.nested", key="number", value=0.25 },
			{ name="new structured value", source='[a]\nchild={future=[]}\n', section="a.child", key="number", value={} },
			{ name="literal dotted key", source='[a]\nchild={future=[]}\n', section="a.child", key="new.dot", value=0.25 },
			{ name="source case twin", source='[a]\nchild={Number=7}\n', section="a.child", key="number", value=0.25 },
			{ name="dotted implicit parent", source='[a]\nchild={nested.old=7}\n', section="a.child.nested", key="number", value=0.25 },
			{ name="nonfinite scalar", source='[a]\nchild={}\n', section="a.child", key="number", value=math.huge },
		}
		for _, vector in ipairs(refused) do
			helpers.it("refuses insertion through " .. vector.name .. " without source authority",function()
				local rows={{section=vector.section,key=vector.key,value=vector.value}}
				local parents=Writer.source_inline_scalar_parents(vector.source,rows)
				helpers.assert_eq(parents,{})
				local called,ok,_,bytes=pcall(prepare,vector.source,rows)
				helpers.assert_true(not called or ok==false);helpers.assert_nil(bytes)
			end)
		end
		helpers.it("withholds a whole group for overlapping new scalar and parent requests",function()
			local source='[a]\nchild={future=[]}\n'
			local rows={{section="a.child",key="number",value=0.25},{section="a",key="child",value={}}}
			helpers.assert_eq(Writer.source_inline_scalar_parents(source,rows),{})
			local ok,_,bytes=prepare(source,rows);helpers.assert_eq(ok,false);helpers.assert_nil(bytes)
		end)
		helpers.it("refuses an inserted scalar emitted with the wrong exact native integer intent",function()
			local LeafRows=require("toml_codec.leaf_rows");local original=LeafRows.value_literal
			LeafRows.value_literal=function(value) if value==9007199254740992 then return "9007199254740993" end return original(value) end
			local called,ok,_,bytes=pcall(prepare,'[a]\nchild={future=[]}\n',{{section="a.child",key="number",value=9007199254740992}})
			LeafRows.value_literal=original
			helpers.assert_eq(called,true);helpers.assert_eq(ok,false);helpers.assert_nil(bytes)
		end)
	end)
end
