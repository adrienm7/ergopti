--- _shared/lua/test/toml_quoted_headers_contract.lua

--- Exercises quoted table identities through the real shared batch writer.
--- @param helpers table Driver test helpers.
return function(helpers)
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec.codec")
	local Scanner = require("toml_codec.record_scanner")
	local function prepare(source, rows)
		return Writer.prepare_batch("/controlled/quoted-headers.toml", rows, {
			read_with_status = function() return source, "ok" end,
			write = function() error("preparation must never publish") end,
		})
	end
	local section = "hotstrings.modules.ext:ergopti:rolls"
	helpers.describe("shared TOML quoted headers", function()
		helpers.it("updates deletes and inserts quoted literal dotted leaves without touching nested paths", function()
			for _, key in ipairs({ "b.c", "dotted.Équipe" }) do
				local quoted = require("toml_codec.key_path").render({ key })
				local source = '[a]\n' .. quoted .. ' = 1\nb.c = 2\nunknown = "retained"\n'
				local updated, detail, content = prepare(source, { { section = "a", key = key, value = 3, literal_key = true } })
				helpers.assert_eq(updated, true, detail)
				helpers.assert_eq(Codec.decode(content).a[key], 3)
				helpers.assert_eq(Codec.decode(content).a.b.c, 2)
				local deleted, delete_detail, without = prepare(content, { { section = "a", key = key, delete = true, literal_key = true } })
				helpers.assert_eq(deleted, true, delete_detail)
				helpers.assert_eq(without, '[a]\nb.c = 2\nunknown = "retained"\n')
				local inserted, insert_detail, again = prepare(without, { { section = "a", key = key, value = false, literal_key = true } })
				helpers.assert_eq(inserted, true, insert_detail)
				helpers.assert_eq(Codec.decode(again).a[key], false)
				helpers.assert_eq(Codec.decode(again).a.b.c, 2)
				helpers.assert_eq(Scanner.scan_records(source).records[1].quoted, nil)
				for _, row in ipairs({ { section = "a", key = key, delete = true },
					{ section = "a", key = key, delete = true, literal_key = false },
					{ section = "a", key = key, delete = true, literal_key = "true" },
					{ section = "a", key = key, delete = true, literal_key = 1 } }) do
					helpers.assert_eq(prepare(source, { row }), false)
				end
			end
			for _, source in ipairs({ 'a = { "b.c" = 1 }\n', 'a."b.c" = 1\n', '[[a]]\n"b.c" = 1\n' }) do
				helpers.assert_eq(prepare(source, { { section = "a", key = "b.c", delete = true, literal_key = true } }), false)
			end
		end)
		helpers.it("deletes an owned extension leaf while preserving all neighboring bytes", function()
			local prefix = '# retained\n[hotstrings.modules."ext:ergopti:rolls"] # identity\n'
			local tail = 'unknown = [\n  "[quoted.data]",\n]\n[neighbor]\ncustom = true\n'
			local ok, detail, content = prepare(prefix .. 'custom = true\n' .. tail, {
				{ section = section, key = "custom", delete = true },
			})
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, prefix .. tail)
		end)
		helpers.it("inserts and updates through equivalent literal and escaped section spellings", function()
			for _, header in ipairs({ "'ext:ergopti:rolls'", '"ext:ergopti:rolls"', '"ext:ergopti:roll\\u0073"' }) do
				local ok, detail, content = prepare('[hotstrings.modules.' .. header .. ']\ncustom = false\n', {
					{ section = section, key = "custom", value = true },
					{ section = section, key = "other", value = "configured" },
				})
				helpers.assert_eq(ok, true, detail)
				local group = Codec.decode(content).hotstrings.modules["ext:ergopti:rolls"]
				helpers.assert_eq(group.custom, true)
				helpers.assert_eq(group.other, "configured")
			end
		end)
		helpers.it("renders canonical colon segments as valid quoted TOML on first insertion", function()
			local ok, detail, content = prepare("", { { section = section, key = "custom", value = true } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_true(content:find('[hotstrings.modules."ext:ergopti:rolls"]', 1, true) ~= nil)
			helpers.assert_eq(Codec.decode(content).hotstrings.modules["ext:ergopti:rolls"].custom, true)
		end)
		helpers.it("preserves sparse defaults under equivalent quoted owner paths", function()
			local path = "/controlled/quoted-sparse-defaults.toml"
			Writer.set_sparse_defaults(path, require("infra.manifest_reader"))
			local source = '[hotstrings.modules."ext:ergopti:rolls"]\ncustom = true\n'
			local ok, detail, content = Writer.prepare_batch(path, {
				{ section = 'hotstrings.modules."ext:ergopti:rolls"', key = "custom", value = false },
			}, { read_with_status = function() return source, "ok" end })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(Codec.decode(content).hotstrings.modules["ext:ergopti:rolls"].custom, nil)
			local literal_ok, literal_detail, literal_content = Writer.prepare_batch(path, {
				{ section = '"hotstrings.modules".literal', key = "custom", value = false },
			}, { read_with_status = function() return "", "ok" end })
			helpers.assert_eq(literal_ok, true, literal_detail)
			helpers.assert_eq(Codec.decode(literal_content)["hotstrings.modules"].literal.custom, false)
		end)
		helpers.it("rejects equivalent batch rows before reading and preserves unrelated case variants", function()
			local reads = 0
			local ok = Writer.prepare_batch("/controlled/duplicate-quoted.toml", {
				{ section = 'a."x"', key = "v", delete = true },
				{ section = "a.x", key = "v", value = true },
			}, { read_with_status = function() reads = reads + 1; return "", "ok" end })
			helpers.assert_eq(ok, false)
			helpers.assert_eq(reads, 0)
			local source = '[untouched]\nv = true\n[UNTOUCHED]\nv = false\n[a.x]\nv = true\n'
			local prepared, detail, content = prepare(source, { { section = 'a."x"', key = "v", delete = true } })
			helpers.assert_eq(prepared, true, detail)
			helpers.assert_eq(content, source:sub(1, #source - #'v = true\n'))
		end)
		helpers.it("keeps quoted dots and bracket characters distinct from nested sections", function()
			local source = '[a."b.c]"]\nvalue = true\n[a.b.c]\nvalue = true\n'
			local ok, detail, content = prepare(source, { { section = 'a."b.c]"', key = "value", delete = true } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[a."b.c]"]\n[a.b.c]\nvalue = true\n')
		end)
		helpers.it("rejects malformed table paths before acquiring a snapshot", function()
			for _, bad in ipairs({ 'a..b', '.a', 'a.', 'a."open', 'a."x"tail', 'a."bad\\q"', 'a.[]', 'a. bad space' }) do
				local reads = 0
				local ok = Writer.prepare_batch("/controlled/malformed.toml", { { section = bad, key = "value", delete = true } }, {
					read_with_status = function() reads = reads + 1; return "", "ok" end,
				})
				helpers.assert_eq(ok, false, bad)
				helpers.assert_eq(reads, 0, bad)
			end
		end)
		helpers.it("refuses malformed source headers and equivalent duplicate tables", function()
			for _, source in ipairs({ '[a..b]\nv = true\n', '[a."open]\nv = true\n', '[a."x"]\nv = true\n[a.\'x\']\nv = false\n' }) do
				local ok = prepare(source, { { section = "a.x", key = "v", delete = true } })
				helpers.assert_eq(ok, false, source)
			end
		end)
		helpers.it("refuses ambiguous case-folded targets and array-of-table targets", function()
			for _, source in ipairs({ '[a."x"]\nv = true\n[A.x]\nv = false\n',
				'[a."x"]\nv = true\n[A.x]\nneighbor = false\n', '[[a."x"]]\nv = true\n' }) do
				local ok = prepare(source, { { section = "a.x", key = "v", delete = true } })
				helpers.assert_eq(ok, false, source)
			end
		end)
		helpers.it("keeps cleanup conservative while the batch deletes a quoted assignment key", function()
			local source = '[a."x"]\nv = true\n'
			helpers.assert_eq(Scanner.scan_records(source).records[1].addressable, false)
			helpers.assert_eq(Scanner.scan_records('[a]\n"v" = true\n').records[1].addressable, false)
			local ok, detail, content = prepare('[a."x"]\n"v" = true\nw = 1\n', { { section = "a.x", key = "v", delete = true } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[a."x"]\nw = 1\n')
		end)
	end)

	helpers.describe("shared physical TOML equals boundary", function()
		for _, vector in ipairs({
			{ source = '"x=y" = true', key = '"x=y"', value = 'true', rhs = ' true', identity = { 'x=y' } },
			{ source = "'x=y'=false", key = "'x=y'", value = 'false', rhs = 'false', identity = { 'x=y' } },
			{ source = ' "x\\\"=y".z  =  [1, 2]  ', key = '"x\\\"=y".z', value = '[1, 2]', rhs = '  [1, 2]  ', identity = { 'x"=y', 'z' } },
			{ source = '"x\\u003dy"=0.1', key = '"x\\u003dy"', value = '0.1', rhs = '0.1', identity = { 'x=y' } },
			{ source = 'a = "right=side" # = comment', key = 'a', value = '"right=side" # = comment', rhs = ' "right=side" # = comment', identity = { 'a' } },
			{ source = 'a\t=\t\'literal=rhs\'', key = 'a', value = "'literal=rhs'", rhs = "\t'literal=rhs'", identity = { 'a' } },
		}) do
			helpers.it("equals-boundary: authentic splitter keeps key and raw RHS " .. vector.source, function()
				local key, value, rhs = Scanner.split_assignment(vector.source)
				helpers.assert_eq(key, vector.key); helpers.assert_eq(value, vector.value); helpers.assert_eq(rhs, vector.rhs)
				local record = Scanner.scan_records(vector.source .. '\n').records[1]
				helpers.assert_eq(record.key_text, vector.key)
				helpers.assert_eq(require('toml_codec.key_path').parse(record.key_text), vector.identity)
				helpers.assert_eq(record.value_parts[1], vector.value)
			end)
		end
		helpers.it("equals-boundary: an unclosed quoted key never invents a separator", function()
			for _, source in ipairs({ '"open=x=1', "'open=x=1", '"closed=x"', 'no_assignment' }) do
				local key, value, rhs = Scanner.split_assignment(source)
				helpers.assert_nil(key); helpers.assert_nil(value); helpers.assert_nil(rhs)
				-- Preserve the canonical decoder's existing ignored-line semantics.
				helpers.assert_eq(Codec.decode(source .. '\n'), {})
			end
		end)
		helpers.it("equals-boundary: actual quoted leaf batch uses its original physical owner", function()
			for _, spelling in ipairs({ '"x=y"', "'x=y'", '"x\\u003dy"' }) do
				local source = '[a]\n' .. spelling .. ' = true\nneighbor=1\n'
				local admitted, detail, content = prepare(source, { { section = 'a', key = 'x=y', value = false } })
				helpers.assert_eq(admitted, true, detail)
				helpers.assert_eq(content, '[a]\n"x=y" = false\nneighbor=1\n')
				helpers.assert_eq(Codec.decode(content), { a = { ['x=y'] = false, neighbor = 1 } })
				-- Physical-boundary support does not make quoted leaves ordinary
				-- unused-key rows or enable array-of-table writes.
				helpers.assert_eq(Scanner.scan_records(source).records[1].addressable, false)
				helpers.assert_eq(prepare('[[a]]\n' .. spelling .. '=true\n', { { section = 'a', key = 'x=y', value = false } }), false)
			end
		end)
		helpers.it("equals-boundary: complete physical multiline span stays attached to the quoted owner", function()
			local source = '"x=y"=[\n  "[not=a.header]",\n  { text="right=side" },\n]\n[neighbor]\nkeep=false\n'
			local scan = Scanner.scan_records(source, { quoted_headers = true })
			helpers.assert_eq(#scan.records, 2); helpers.assert_eq(#scan.headers, 1)
			helpers.assert_eq(scan.records[1].key_text, '"x=y"')
			helpers.assert_eq(scan.records[1].first, 1); helpers.assert_eq(scan.records[1].last, 4)
			helpers.assert_eq(scan.headers[1].index, 5); helpers.assert_eq(scan.headers[1].segments, { 'neighbor' })
			helpers.assert_eq(Codec.decode(source), { ['x=y'] = { '[not=a.header]', { text = 'right=side' } }, neighbor = { keep = false } })
		end)
	end)
end
