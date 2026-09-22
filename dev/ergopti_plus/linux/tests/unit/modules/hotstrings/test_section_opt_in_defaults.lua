--- tests/unit/modules/hotstrings/test_section_opt_in_defaults.lua

--- ==============================================================================
--- MODULE: Hotstring Sections Are Opt-In
--- DESCRIPTION:
--- Every bundled hotstring section ships disabled and the user opts in. This
--- driver persists section state as one set of "switched off" keys, where an
--- absent key used to mean ENABLED — so without a positive record of the user's
--- opt-in, a section could never be turned on over its disabled default, and a
--- missed manifest lookup would have switched the whole corpus back on.
---
--- Also pins the language-pack bulk action: « tout activer » on the French
--- submenu enables every section of every French category in one write.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A fresh config manager with no persisted state and two known categories.
--- @return table
local function fresh_config()
	local Storage = require("adapters.storage")
	Storage.set("hotstrings.disabled_categories", "")
	local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
	Config.init({ load_mappings = function() end }, os.tmpname() .. "_absent.toml", nil)
	Config._set_categories_for_test({
		french_autocorrection = { id = "french_autocorrection", sections = { accents = { count = 1 }, minus = { count = 1 } } },
		french_magickey = { id = "french_magickey", sections = { text_expansion = { count = 1 } } },
	})
	return Config
end

helpers.describe("hotstrings config: sections are opt-in", function()

	helpers.it("(hs-opt-in-linux) an untouched bundled section is off, a personal one is on", function()
		local Config = fresh_config()
		helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false,
			"the manifest ships every bundled section disabled")
		helpers.assert_eq(Config.is_section_checked("distancesreduction", "qu"), false,
			"the file-stem spelling of a manifest category must find its row")
		helpers.assert_eq(Config.is_section_checked("personal", "anything"), true,
			"a pack the manifest does not declare is the user's own")
	end)

	helpers.it("(hs-opt-in-linux) the language bulk action switches every French section on, then off", function()
		local Config = fresh_config()
		helpers.assert_true(Config.set_categories_sections({ "french_autocorrection", "french_magickey" }, true))
		helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), true)
		helpers.assert_eq(Config.is_section_checked("french_autocorrection", "minus"), true)
		helpers.assert_eq(Config.is_section_checked("french_magickey", "text_expansion"), true)
		helpers.assert_true(Config.set_categories_sections({ "french_autocorrection", "french_magickey" }, false))
		helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false)
		helpers.assert_eq(Config.is_section_checked("french_magickey", "text_expansion"), false)
	end)

	helpers.it("(hs-opt-in-linux) an unknown category refuses the whole language write", function()
		local Config = fresh_config()
		helpers.assert_eq(Config.set_categories_sections({ "french_autocorrection", "nope" }, true), false)
		helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false,
			"a refused language write must not publish a partial candidate")
	end)
end)
