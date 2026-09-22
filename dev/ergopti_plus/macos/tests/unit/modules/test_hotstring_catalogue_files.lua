--- tests/unit/modules/test_hotstring_catalogue_files.lua

--- ==============================================================================
--- MODULE: Hotstring Catalogue Discovery Skips Metadata (macOS)
--- DESCRIPTION:
--- The packaged app showed an empty « défauts (0) » row among the common
--- hotstrings. The boot scan of _shared/modules/hotstrings/ skipped only
--- "_"-prefixed files, so defaults.toml — the resolver's fallback delays and
--- colours, not a category — loaded as a hotstring group with no entry. Linux
--- already excluded it with its own copy of the rule. Both scans now go through
--- _shared/lua/hotstrings/catalogue_files.lua; these cases pin the rule and that
--- this driver's scan uses it.
--- ==============================================================================

local helpers = require("tests.helpers")
local CatalogueFiles = require("hotstrings.catalogue_files")
local TomlCodec = require("toml_codec.codec")

helpers.describe("hotstring catalogue (macos): metadata is never a category", function()
	helpers.it("catalogue files: defaults.toml and _index.toml are not categories", function()
		helpers.assert_eq(CatalogueFiles.is_category_file("defaults.toml"), false,
			"defaults.toml holds the resolver's fallbacks; loading it drew « défauts (0) »")
		helpers.assert_eq(CatalogueFiles.is_category_file("/x/_index.toml"), false,
			"_index.toml is the menu index")
		helpers.assert_eq(CatalogueFiles.is_category_file("README.md"), false, "not a TOML file")
		helpers.assert_eq(CatalogueFiles.is_category_file(nil), false, "no name at all")
	end)

	helpers.it("catalogue files: every category the shared index orders is accepted", function()
		local fh = assert(io.open(helpers.shared("modules/hotstrings/_index.toml"), "r"))
		local index = TomlCodec.decode(fh:read("*a"))
		fh:close()
		local order = index.menu and index.menu.categories_order or {}
		helpers.assert_true(#order > 0, "the index must order the neutral categories")
		for _, stem in ipairs(order) do
			helpers.assert_eq(CatalogueFiles.is_category_file(stem .. ".toml"), true,
				"'" .. stem .. "' is a category the menu lists")
		end
	end)

	helpers.it("catalogue files: the boot scan filters through the shared rule", function()
		local body, err = helpers.read_driver_unit("local function hotstring_category_stem(")
		helpers.assert_true(body ~= nil, tostring(err))
		helpers.assert_true(body:find("HotstringCatalogueFiles.is_category_file(fname)", 1, true) ~= nil,
			"the stem filter must ask the shared catalogue rule")
		helpers.assert_nil(body:find('not fname:match("^_")', 1, true),
			"a local underscore-only filter is the copy that let defaults.toml through")
		local _, mentions = body:gsub("hotstring_category_stem%(fname%)", "")
		helpers.assert_eq(mentions - 1, 2, "both directory scans (probe and load) must use the filter")
	end)
end)
