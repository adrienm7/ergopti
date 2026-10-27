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

	helpers.describe("shared section-relative inline scalar ownership", function()
		local source = '[a] # header\nchild = { first=false, middle="001", last=0.25, future=9007199254740993, empty=[], map={} } # trailer\n'
		local rows = { { section = "a.child", key = "first", value = true } }
		helpers.it("describes the complete eligible parent and retains fresh detached hints", function()
			local parents = assert(Writer.source_inline_scalar_parents(source, rows))
			helpers.assert_eq(parents, { ["a.child"] = true })
			parents["a.child"] = false
			helpers.assert_eq(Writer.source_inline_scalar_parents(source, rows), { ["a.child"] = true })
		end)
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
