--- _shared/tests/lua/hotstrings/category_glyph_contract.lua

--- The shared category glyph resolver answers every vector of
--- _shared/tests/corpus/hotstrings/category_glyph_vectors.json, and every
--- shipped category declares a glyph of its own, distinct from the others.
return function(helpers)
	local Json = require("core.text.engine.json")
	local CategoryGlyph = require("hotstrings.engine.category_glyph")
	local NativePath = require("core.fs.engine.native_path")
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local shared = NativePath.dirname(assert(NativePath.dirname(assert(NativePath.dirname(assert(NativePath.dirname(source)))))))
	assert(shared, "the shared tree must enclose this contract")
	local handle = assert(io.open(shared .. "/tests/corpus/hotstrings/category_glyph_vectors.json", "rb"))
	local document = assert(Json.decode(handle:read("*a")))
	handle:close()
	assert(#document.vectors > 0 and #document.row_label_vectors > 0, "the vector corpus must not be empty")

	for _, vector in ipairs(document.vectors) do
		helpers.it("category glyph vector: " .. vector.id, function()
			local result = CategoryGlyph.resolve({
				meta = vector.meta,
				category_glyph = vector.category_glyph,
				category_name_key = vector.category_name_key,
				default_glyph = document.defaults.default_glyph,
				default_name_key = document.defaults.default_name_key,
			})
			helpers.assert_eq(result.glyph, vector.expected.glyph, "glyph")
			helpers.assert_eq(result.name_key, vector.expected.name_key, "name key")
			local expected_rejected = vector.expected.rejected or {}
			local rejected = result.rejected or {}
			for field, value in pairs(expected_rejected) do
				helpers.assert_eq(rejected[field], value, "refused " .. field)
			end
			for field in pairs(rejected) do
				assert(expected_rejected[field] ~= nil, "unexpected refusal of " .. field)
			end
		end)
	end

	for _, vector in ipairs(document.row_label_vectors) do
		helpers.it("row label vector: " .. vector.id, function()
			helpers.assert_eq(CategoryGlyph.row_label(vector.glyph, vector.trigger_label), vector.expected)
		end)
	end

	--- The [_meta] glyph fields of a catalogue file, read from its head: a whole
	--- catalogue parse costs seconds and the table is at the top of the file.
	--- @param relative string Path under the catalogue folder.
	--- @param header string|nil The table to read, "[_meta]" by default.
	--- @return table The table's string fields.
	local function meta_glyph(relative, header)
		local file = assert(io.open(shared .. "/hotstrings/data/catalogue/" .. relative, "rb"))
		local fields, in_meta = {}, false
		for line in file:lines() do
			line = line:gsub("\r$", "")
			if line == (header or "[_meta]") then in_meta = true
			elseif line:match("^%[") then if in_meta then break end
			elseif in_meta then
				local key, value = line:match('^([%w_]+)%s*=%s*"(.-)"%s*$')
				if key then fields[key] = value end
			end
		end
		file:close()
		return fields
	end

	helpers.it("every shipped category declares a valid, distinct glyph and a name key", function()
		local defaults = meta_glyph("defaults.toml", "[glyphs]")
		assert(CategoryGlyph.is_glyph(defaults.global_default) and CategoryGlyph.is_glyph(defaults.personal),
			"defaults.toml [glyphs] must declare the shared and personal glyphs")
		assert(defaults.global_default ~= defaults.personal, "the shared and personal default glyphs must differ")
		local seen = { [defaults.global_default] = "the shared default", [defaults.personal] = "the personal default" }
		for _, relative in ipairs({ "autocorrection.toml", "magickey.toml" }) do
			local meta = meta_glyph(relative)
			assert(CategoryGlyph.is_glyph(meta.glyph), relative .. " must declare a glyph")
			assert(CategoryGlyph.is_name_key(meta.glyph_name_key), relative .. " must declare a glyph name key")
			assert(not seen[meta.glyph], relative .. " reuses the glyph of " .. tostring(seen[meta.glyph]))
			seen[meta.glyph] = relative
			local french = meta_glyph("french/" .. relative)
			helpers.assert_eq(french.glyph, meta.glyph, "the French " .. relative .. " glyph")
			helpers.assert_eq(french.glyph_name_key, meta.glyph_name_key, "the French " .. relative .. " name")
		end
	end)
end
