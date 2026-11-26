--- tests/unit/hotstrings/engine/catalogue/test_category_glyph.lua

--- The category glyph resolver and the shipped categories' glyphs, pinned by the
--- vectors every driver reads, then the glyph the real config resolver hands the
--- preview for each tint category.
local helpers = require("tests.helpers")
require("tests.lua.hotstrings.category_glyph_contract")(helpers)

helpers.describe("hotstrings config: category glyph", function()
	helpers.it("resolves a declared glyph, the personal default and the shared default", function()
		local Config = helpers.load_module("hotstrings.engine.catalogue.config")
		Config._set_categories_for_test({
			magickey = { glyph = "✦", glyph_name_key = "hs_config.cat_magickey", sections = {} },
			autocorrection = { glyph = "✓", glyph_name_key = "hs_config.cat_autocorrection", sections = {} },
			rolls = { sections = {} },
		})
		local magic = Config.resolve("magickey", nil)
		helpers.assert_eq(magic.glyph, "✦", "magic-key glyph")
		helpers.assert_eq(magic.glyph_name_key, "hs_config.cat_magickey", "magic-key name")
		helpers.assert_eq(Config.resolve("autocorrection", nil).glyph, "✓", "autocorrection glyph")
		local personal = Config.resolve("personal", nil)
		helpers.assert_eq(personal.glyph, "✎", "personal glyph")
		helpers.assert_eq(personal.glyph_name_key, "hs_config.cat_personal", "personal name")
		local other = Config.resolve("rolls", nil)
		helpers.assert_eq(other.glyph, "•", "shared default glyph")
		helpers.assert_eq(other.glyph_name_key, "hs_config.cat_other", "shared default name")
		Config._set_categories_for_test(nil)
	end)
end)
