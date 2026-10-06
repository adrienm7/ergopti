-- static/ergopti_plus/macos/tests/unit/lib/test_toml_source_shape_publication.lua

--- Actual-file source-kind retention and exact prepared-row publication ownership.
local helpers = require("tests.helpers")
local output = require("tests.support.toml_output_fixture")
local function read(path)
	local handle = assert(io.open(path, "rb")); local bytes = assert(handle:read("*a")); assert(handle:close()); return bytes
end
local function write(path, bytes)
	local handle = assert(io.open(path, "wb")); assert(handle:write(bytes)); assert(handle:close())
end
local function with_source(source, callback)
	return helpers.with_stub_scope({ "infra.logger", "adapters.file_system", "infra.fs_dir" }, function()
		helpers.load_with_stubs("infra.logger")
		local writer = require("toml_codec.writer")
		return output.with_output(function(path)
			write(path, source)
			return callback(path, writer, require("adapters.file_system"), require("toml_codec.leaf_rows"))
		end)
	end)
end
helpers.describe("TOML source shape publication ownership", function()
	helpers.it("retains actual empty arrays, maps, scalar tokens and literal dot identities", function()
		local source = '[owner]\nvalue={future=[],dictionary={},scientific=1e2,states={"."=false},pairs=[{left="a",right="b",future=[]}]}\n'
		with_source(source, function(path, writer, files, rows)
			local prepared = rows.prepare(source, { { path = { "owner", "value", "states", "." }, value = true } })
			helpers.assert_eq(writer.batch_write(path, prepared, files, { status = "ok", content = source }), true)
			local bytes = read(path)
			local document, shapes = require("toml_codec").decode_with_shapes(bytes)
			local value = document.owner.value
			helpers.assert_eq(value.states["."], true)
			helpers.assert_eq(shapes.arrays[value.future], true)
			helpers.assert_nil(shapes.arrays[value.dictionary])
			helpers.assert_eq(shapes.arrays[value.pairs[1].future], true)
			helpers.assert_true(bytes:find("scientific = 1e2", 1, true) ~= nil, "untouched source numeric token is retained")
		end)
	end)
	helpers.it("writes a literal dot key under an actual quoted table header", function()
		local source = '[owner.states]\n"."=false\n'
		with_source(source, function(path, writer, files, rows)
			helpers.assert_eq(writer.batch_write(path, rows.prepare(source,
				{ { path = { "owner", "states", "." }, value = true } }), files, { status = "ok", content = source }), true)
			helpers.assert_eq(require("toml_codec").decode(read(path)).owner.states["."], true)
		end)
	end)
	helpers.it("retains shape provenance through actual detached clones", function()
		with_source('[owner]\nvalue={future=[]}\n', function(path, writer, files, rows)
			local source = read(path)
			local original = rows.decode_source(source)
			local candidate = rows.clone_value(original.owner.value)
			candidate.enabled = false
			local prepared = rows.prepare(source, { { path = { "owner", "value" }, value = candidate } })
			helpers.assert_eq(writer.batch_write(path, prepared, files, { status = "ok", content = source }), true)
			local doc, shapes = require("toml_codec").decode_with_shapes(read(path))
			helpers.assert_eq(shapes.arrays[doc.owner.value.future], true)
			helpers.assert_eq(doc.owner.value.enabled, false)
		end)
	end)
	for _, invalid in ipairs({ "fabricated", "stolen", "changed-source", "changed-value", "changed-key", "changed-kind", "changed-token" }) do
		helpers.it("refuses " .. invalid .. " source capability without physical publication", function()
			local source = '[owner]\nvalue={future=[],enabled=false}\n'
			with_source(source, function(path, writer, files, rows)
				local prepared = rows.prepare(source, { { path = { "owner", "value", "enabled" }, value = true } })
				local row = prepared[1]
				if invalid == "fabricated" then row = { section = row.section, key = row.key, value = row.value, source_shape = {} }
				elseif invalid == "stolen" then row = { section = row.section, key = row.key, value = row.value, source_shape = rows.publication_capability(row) }
				elseif invalid == "changed-source" then write(path, source .. '# actual physical successor\n')
				elseif invalid == "changed-value" then row.value.enabled = false
				elseif invalid == "changed-key" then row.key = "another"
				elseif invalid == "changed-kind" then row.value.future = {}
				elseif invalid == "changed-token" then row.source_shape = {} end
				local before = read(path)
				helpers.assert_eq(writer.batch_write(path, { row }, files), false, "no fallback to plain encoding for a refused capability")
				helpers.assert_eq(read(path), before)
			end)
		end)
	end
	helpers.it("retains ordinary direct-row empty dictionary behavior without inferred array receipt", function()
		with_source('[owner]\nvalue=[]\n', function(path, writer, files)
			helpers.assert_eq(writer.batch_write(path, { { section = "owner", key = "value", value = {} } }, files), true)
			local doc, shapes = require("toml_codec").decode_with_shapes(read(path))
			helpers.assert_eq(doc.owner.value, {})
			helpers.assert_nil(shapes.arrays[doc.owner.value])
		end)
	end)
	helpers.it("refuses a prepared receipt from another actual module session", function()
		local source = '[owner]\nvalue={future=[],enabled=false}\n'
		with_source(source, function(path, writer, files, rows)
			local prepared = rows.prepare(source, { { path = { "owner", "value", "enabled" }, value = true } })
			local previous = package.loaded["toml_codec.leaf_rows"]
			package.loaded["toml_codec.leaf_rows"] = nil
			local receipt = table.pack(pcall(writer.batch_write, path, prepared, files))
			package.loaded["toml_codec.leaf_rows"] = previous
			helpers.assert_eq(receipt[1], true, "refusal returns normally")
			helpers.assert_eq(receipt[2], false, "different owner session cannot reconstruct an array receipt from the model")
			helpers.assert_eq(read(path), source)
		end)
	end)
	helpers.it("keeps private numeric and temporal source tokens independent of exposed shape maps", function()
		local source = '[owner]\nvalue={scientific=1e2,date=2026-10-05,future=[]}\n'
		with_source(source, function(path, writer, files, rows)
			local document, exposed = rows.decode_source(source)
			exposed.numbers[document.owner.value].scientific.token = "100"
			exposed.strings[document.owner.value].date.token = '"2026-10-05"'
			exposed.arrays[document.owner.value.future] = nil
			local candidate = rows.clone_value(document.owner.value)
			candidate.enabled = false
			helpers.assert_eq(writer.batch_write(path, rows.prepare(source,
				{ { path = { "owner", "value" }, value = candidate } }), files), true)
			local bytes = read(path)
			helpers.assert_true(bytes:find("scientific = 1e2", 1, true) ~= nil, "physical numeric source kind does not trust mutable exposed evidence")
			helpers.assert_true(bytes:find("date = 2026-10-05", 1, true) ~= nil, "physical temporal token stays unquoted")
			local after, shapes = require("toml_codec").decode_with_shapes(bytes)
			helpers.assert_eq(shapes.arrays[after.owner.value.future], true)
		end)
	end)

	for _, kind in ipairs({ "source-owned", "explicit-literal" }) do
		helpers.it("keeps " .. kind .. " final dotted identity independent of actual Manifest sparse defaults", function()
			local source = '[hotstrings]\n"autocorrection.names"={enabled=true,time_activation_seconds=0.5}\n[hotstrings.autocorrection]\nnames={enabled=true,time_activation_seconds=0.75}\n'
			with_source(source, function(path, writer, files, rows)
				local manifest = require("infra.manifest_reader")
				helpers.assert_true(manifest.has_default("hotstrings.autocorrection.names"), "actual declared default is the aliasing prerequisite")
				writer.set_sparse_defaults(path, manifest)
				local neutral = { enabled = false, time_activation_seconds = 0.5 }
				local prepared = kind == "source-owned" and rows.prepare(source,
					{ { path = { "hotstrings", "autocorrection.names" }, value = neutral } })
					or { { section = "hotstrings", key = "autocorrection.names", literal_key = true, value = neutral } }
				helpers.assert_eq(writer.batch_write(path, prepared, files, { status = "ok", content = source }), true)
				local document = require("toml_codec").decode(read(path))
				helpers.assert_eq(document.hotstrings["autocorrection.names"], neutral, "literal final dot must not become a semantic deletion")
				helpers.assert_eq(document.hotstrings.autocorrection.names, { enabled = true, time_activation_seconds = 0.75 }, "independent nested source remains intact")
			end)
		end)
	end
	helpers.it("retains ordinary nested direct-row Manifest neutral deletion", function()
		local source = '[hotstrings]\n"autocorrection.names"={enabled=true,time_activation_seconds=0.75}\n[hotstrings.autocorrection]\nnames={enabled=true,time_activation_seconds=0.75}\n'
		with_source(source, function(path, writer, files)
			local manifest = require("infra.manifest_reader")
			helpers.assert_true(manifest.has_default("hotstrings.autocorrection.names"))
			writer.set_sparse_defaults(path, manifest)
			helpers.assert_eq(writer.batch_write(path, { { section = "hotstrings.autocorrection", key = "names",
				value = { enabled = false, time_activation_seconds = 0.5 } } }, files), true)
			local document = require("toml_codec").decode(read(path))
			helpers.assert_nil(document.hotstrings.autocorrection.names, "existing ordinary nested default is still sparse")
			helpers.assert_eq(document.hotstrings["autocorrection.names"], { enabled = true, time_activation_seconds = 0.75 })
		end)
	end)
end)
