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
		-- The ten hint-withheld groups are data (toml/inline_scalar_vectors.json); these two
		-- accept a new member and also read the decoder's shape evidence of the candidate.
		for index, requests in ipairs({
			{ { section = "a.child", key = "new", value = true } },
			{ { section = "a.child", key = "first", value = true }, { section = "a.child", key = "new", value = true } },
		}) do
			helpers.it("admits a new inline member next to existing ones " .. index, function()
				helpers.assert_eq(Writer.source_inline_scalar_parents(source, requests), { ["a.child"] = true })
				local expected = index == 1
					and '[a] # header\nchild = { first=false, middle="001", last=0.25, future=9007199254740993, empty=[], map={} ,new = true} # trailer\n'
					or '[a] # header\nchild = { first=true, middle="001", last=0.25, future=9007199254740993, empty=[], map={} ,new = true} # trailer\n'
				local okay, detail, content = prepare(source, requests)
				helpers.assert_eq(okay, true, detail); helpers.assert_eq(content, expected)
				local decoded, shapes = require("toml_codec.leaf_rows").decode_source(content)
				helpers.assert_eq(decoded.a.child.new, true)
				helpers.assert_eq(decoded.a.child.first, index == 2)
				helpers.assert_true(shapes.arrays[decoded.a.child.empty] == true)
				helpers.assert_true(shapes.arrays[decoded.a.child.map] ~= true)
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
		helpers.it("refuses an inserted scalar emitted with the wrong exact native integer intent",function()
			local LeafRows=require("toml_codec.leaf_rows");local original=LeafRows.value_literal
			LeafRows.value_literal=function(value) if value==9007199254740992 then return "9007199254740993" end return original(value) end
			local called,ok,_,bytes=pcall(prepare,'[a]\nchild={future=[]}\n',{{section="a.child",key="number",value=9007199254740992}})
			LeafRows.value_literal=original
			helpers.assert_eq(called,true);helpers.assert_eq(ok,false);helpers.assert_nil(bytes)
		end)
	end)
end
