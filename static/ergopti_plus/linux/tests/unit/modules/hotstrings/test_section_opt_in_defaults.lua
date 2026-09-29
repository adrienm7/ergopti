--- tests/unit/modules/hotstrings/test_section_opt_in_defaults.lua

--- ==============================================================================
--- MODULE: Hotstring Sections Are Opt-In
--- DESCRIPTION:
--- Every bundled hotstring section ships disabled and the user opts in. The
--- choices are canonical config.toml keys read through the manifest's neutral
--- defaults, so an absent key is OFF and a missed lookup cannot switch the
--- corpus back on.
---
--- Also pins the language-pack bulk action: « tout activer » on the French
--- submenu enables every section of every French category in one write.
--- ==============================================================================

local helpers = require("tests.helpers")
local Choices = require("tests.support.hotstring_choices")

local CATEGORIES = {
	french_autocorrection = { id = "french_autocorrection", sections_order = { "accents", "minus" },
		sections = { accents = { count = 1 }, minus = { count = 1 } } },
	french_magickey = { id = "french_magickey", sections_order = { "text_expansion" },
		sections = { text_expansion = { count = 1 } } },
}

--- Runs body against a config manager over two known categories and a private,
--- initially absent config.toml.
--- @param body function body(Config, path)
local function with_config(body)
	local saved_loader = package.loaded["modules.hotstrings.loader"]
	package.loaded["modules.hotstrings.loader"] = {
		find_toml_files = function() return {} end,
		list_subdirs = function() return {} end,
		read_file = function() return nil end,
		load_catalogue = function()
			return { committed = true, errors = 0, categories = CATEGORIES, mappings = {
				{ trigger = "acc", replacement = "accents", group = "french_autocorrection", section = "accents" },
				{ trigger = "exp", replacement = "expansion", group = "french_magickey", section = "text_expansion" },
			} }
		end,
	}
	local ok, err = pcall(function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		Choices.with_file(Config, nil, function(path)
			local published = {}
			Config.init({ load_mappings = function(_, mappings) published[#published + 1] = mappings; return true end },
				"virtual.toml", nil)
			local _, committed = Config.load_all()
			helpers.assert_true(committed, "the fixture catalogue must publish")
			body(Config, path, published)
		end)
	end)
	package.loaded["modules.hotstrings.loader"] = saved_loader
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("hotstrings config: sections are opt-in", function()

	helpers.it("(hs-opt-in-linux) bundled and personal sections require explicit activation", function()
		with_config(function(Config, _, published)
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false,
				"the manifest ships every bundled section disabled")
			helpers.assert_eq(Config.is_section_checked("distancesreduction", "qu"), false,
				"the file-stem spelling of a manifest category must find its row")
			helpers.assert_eq(Config.is_section_checked("personal", "anything"), false,
				"loading a personal pack does not grant activation")
			helpers.assert_eq(Config.is_group_enabled("french_autocorrection"), false,
				"an empty configuration opens no category gate")
			helpers.assert_eq(#published[#published], 0, "nothing reaches the engine without explicit intent")
		end)
	end)

	helpers.it("(hs-opt-in-linux) the language bulk action switches every French section on, then off", function()
		with_config(function(Config, path, published)
			helpers.assert_true(Config.set_categories_sections({ "french_autocorrection", "french_magickey" }, true))
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), true)
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "minus"), true)
			helpers.assert_eq(Config.is_section_checked("french_magickey", "text_expansion"), true)
			helpers.assert_eq(#published[#published], 2, "both activated sections reach the engine")
			local decoded = require("toml_codec").decode(Choices.read(path))
			helpers.assert_eq(decoded.hotstrings.groups.french_autocorrection, true)
			helpers.assert_eq(decoded.hotstrings.modules.french_autocorrection, { accents = true, minus = true })
			helpers.assert_true(Config.set_categories_sections({ "french_autocorrection", "french_magickey" }, false))
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false)
			helpers.assert_eq(Config.is_section_checked("french_magickey", "text_expansion"), false)
			decoded = require("toml_codec").decode(Choices.read(path))
			for category, sections in pairs(decoded.hotstrings.modules or {}) do
				helpers.assert_eq(next(sections), nil, category .. " sections return to neutral absence")
			end
			helpers.assert_eq(decoded.hotstrings.groups.french_autocorrection, true,
				"switching sections off keeps the category's own choice")
		end)
	end)

	helpers.it("(hs-opt-in-linux) an unknown category refuses the whole language write", function()
		with_config(function(Config, path)
			helpers.assert_eq(Config.set_categories_sections({ "french_autocorrection", "nope" }, true), false)
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false,
				"a refused language write must not publish a partial candidate")
			helpers.assert_nil(Choices.read(path), "a refused language write leaves the file absent")
		end)
	end)
end)
