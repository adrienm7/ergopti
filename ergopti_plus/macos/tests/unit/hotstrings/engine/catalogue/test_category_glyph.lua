--- tests/unit/hotstrings/engine/catalogue/test_category_glyph.lua

--- The category glyph resolver and the shipped categories' glyphs, pinned by the
--- vectors every driver reads, then the glyph the real config resolver reads
--- from a category TOML and the shared defaults.
local helpers = require("tests.helpers")
require("tests.lua.hotstrings.category_glyph_contract")(helpers)

--- Writes a category TOML holding only its [_meta] table.
--- @param lines table The [_meta] lines.
--- @return string path
local function category_file(lines)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	file:write("[_meta]\n" .. table.concat(lines, "\n") .. "\n")
	file:close()
	return path
end

helpers.describe("hotstrings config: category glyph", function()
	helpers.it("reads a declared glyph, refuses a word and falls to the defaults", function()
		local files = {
			magickey = category_file({ 'glyph = "✦"', 'glyph_name_key = "hs_config.cat_magickey"' }),
			autocorrection = category_file({ 'glyph = "fix"' }),
		}
		package.loaded["hotstrings.engine.catalogue.config"] = nil
		local Config = require("hotstrings.engine.catalogue.config")
		Config.init({
			override_path = os.tmpname(),
			toml_resolver = function(category) return files[category] end,
		})
		local magic = Config.resolve("magickey", nil)
		helpers.assert_eq(magic.glyph, "✦", "declared glyph")
		helpers.assert_eq(magic.glyph_name_key, "hs_config.cat_magickey", "declared name")
		local refused = Config.resolve("autocorrection", nil)
		helpers.assert_eq(refused.glyph, "•", "a refused glyph falls to the shared default")
		helpers.assert_eq(refused.glyph_rejected.glyph, "fix", "the refusal is reported")
		local personal = Config.resolve("personal", nil)
		helpers.assert_eq(personal.glyph, "✎", "personal default glyph")
		helpers.assert_eq(personal.glyph_name_key, "hs_config.cat_personal", "personal default name")
		for _, path in pairs(files) do os.remove(path) end
		package.loaded["hotstrings.engine.catalogue.config"] = nil
	end)
end)
