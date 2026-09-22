--- tests/unit/meta/test_shared_hotstring_languages.lua

--- ==============================================================================
--- MODULE: Hotstring Language Packs (shared)
--- DESCRIPTION:
--- Covers _shared/lua/hotstrings/languages.lua, which both Lua drivers use to
--- turn _index.toml [languages] into language packs and to answer the shipped
--- default of a bundled section.
---
--- WHY THIS EXISTS:
--- French hotstrings moved out of the neutral packs into french/<stem>.toml and
--- load as the group "french_<stem>". A second spelling of that id on either
--- driver would key config, menu and manifest differently and the section would
--- silently never load. And every bundled section now ships disabled: a default
--- lookup that missed the manifest row and answered "enabled" would switch the
--- whole corpus back on for a user who never asked for it.
--- ==============================================================================

local helpers = require("tests.helpers")

local Languages = helpers.load_module("hotstrings.languages")


helpers.describe("hotstring languages: the index declares the packs", function()

	helpers.it("(language-packs) reads packs in declared order with their categories", function()
		local packs = Languages.packs({
			languages = {
				order = { "french", "german" },
				french = { locale = "fr", categories_order = { "autocorrection", "magickey" } },
				german = { locale = "de", categories_order = { "autocorrection" } },
			},
		})
		helpers.assert_eq(#packs, 2)
		helpers.assert_eq(packs[1].id, "french")
		helpers.assert_eq(packs[1].locale, "fr")
		helpers.assert_eq(packs[1].categories, { "autocorrection", "magickey" })
		helpers.assert_eq(packs[2].id, "german")
	end)

	helpers.it("(language-packs) an index without languages has no packs", function()
		helpers.assert_eq(#Languages.packs({ menu = {} }), 0)
	end)

	helpers.it("(language-packs) refuses a declared language with no locale", function()
		local ok = pcall(Languages.packs, {
			languages = { order = { "french" }, french = { categories_order = { "autocorrection" } } },
		})
		helpers.assert_eq(ok, false, "a language the menu cannot name must fail loudly")
	end)

	helpers.it("(language-packs) group ids are <language>_<stem>, one spelling for every driver", function()
		helpers.assert_eq(Languages.group_id("french", "autocorrection"), "french_autocorrection")
		local groups = Languages.groups({ { id = "french", locale = "fr", categories = { "magickey" } } })
		helpers.assert_true(groups.french_magickey ~= nil)
		helpers.assert_eq(groups.french_magickey.stem, "magickey")
	end)

	helpers.it("(language-packs) the shipped index declares French", function()
		local fh = assert(io.open(require("infra.paths").shared("modules/hotstrings/_index.toml"), "r"))
		local raw = fh:read("*a")
		fh:close()
		local packs = Languages.packs(require("toml_codec.codec").decode(raw))
		helpers.assert_eq(packs[1].id, "french")
		helpers.assert_eq(packs[1].locale, "fr")
	end)
end)


helpers.describe("hotstring languages: shipped section defaults", function()

	local FEATURES = {
		{ section = "hotstrings.distances_reduction", id = "qu", default = { enabled = false } },
		{ section = "hotstrings.french_autocorrection", id = "accents", default = { enabled = false } },
		{ section = "hotstrings.rolls", id = "hc", default = { enabled = true } },
	}

	helpers.it("(section-default) matches the file-stem spelling of a manifest category", function()
		helpers.assert_eq(Languages.section_default(FEATURES, "distancesreduction", "qu"), false)
		helpers.assert_eq(Languages.section_default(FEATURES, "rolls", "hc"), true)
	end)

	helpers.it("(section-default) keys a language group by its full id, not its stem", function()
		helpers.assert_eq(Languages.section_default(FEATURES, "french_autocorrection", "accents"), false)
		helpers.assert_nil(Languages.section_default(FEATURES, "autocorrection", "accents"),
			"the neutral autocorrection file has no accents row any more")
	end)

	helpers.it("(section-default) answers nil for a pack the manifest does not declare", function()
		helpers.assert_nil(Languages.section_default(FEATURES, "personal", "anything"))
	end)
end)
