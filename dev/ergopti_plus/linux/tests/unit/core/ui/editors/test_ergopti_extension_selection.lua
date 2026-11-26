--- tests/unit/core/ui/editors/test_ergopti_extension_selection.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Selection (Linux)
--- DESCRIPTION:
--- Replays the shared exact-section policy with the native manifest declarations.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.ergopti_extension_selection_contract").run(helpers)

--- Finds an exact rendered row anywhere in the native menu tree.
--- @param rows table Rendered native rows.
--- @param title string Expected localized title.
--- @return table|nil
local function find_row(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local found = find_row(row.menu, title)
		if found then return found end
	end
end

--- Reserves one actual file per process instead of a seconds/PRNG fixture name.
--- Two native containers can start in the same second with the same LuaJIT
--- random seed; sharing their preferences would test another container's gates.
--- @param Config table Actual configuration owner.
--- @param content string Initial canonical preferences.
--- @param body function Callback receiving the reserved path.
local function with_private_choices(Config, content, body)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write(content))
	assert(file:close())
	helpers.assert_true(Config._set_config_file_for_test(path))
	local ok, err = pcall(body, path)
	Config._set_config_file_for_test(nil)
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

helpers.describe("Shipped Ergopti native menu (Linux)", function()
	helpers.it("(ergopti-extension-selection) controls real shipped metadata without an installed layout", function()
		local names = { "hotstrings.engine.catalogue.config", "hotstrings.engine.loader",
			"hotstrings.engine.matcher.preferences", "menu.ui.builder.builder" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local ok, err = pcall(function()
			local Config = require("hotstrings.engine.catalogue.config")
			local Choices = require("tests.support.hotstring_choices")
			local source = '[hotstrings]\n'
				.. 'groups = { magickey = true, french_distancesreduction = true }\n'
				.. '[hotstrings.modules.magickey]\nrepeat_corrections = false\ntext_expansion_symbols = true\n'
				.. '[hotstrings.modules.french_distancesreduction]\nsuffixes_a = true\n'
			with_private_choices(Config, source, function(path)
				local Preferences = require("hotstrings.engine.matcher.preferences")
				helpers.assert_true(Preferences._set_file_for_test(path))
				Config.init(require("hotstrings.engine.matcher").new(), nil)
				local _, committed = Config.load_all()
				helpers.assert_true(committed, "the real bundled and shipped extension catalogue initializes")
				local category = Config.get_category("magickey")
				-- Nothing is remapped to ★ any more (maintainer's decision of 2026-11-22).
				helpers.assert_nil(category.sections.replace, "no replace section ships")
				local bound = category.sections.repeat_corrections
				helpers.assert_eq(bound.extension.id, "ergopti")
				helpers.assert_eq(Config.get_category("french_distancesreduction").count, 24)
				local I18n = require("core.i18n.engine.i18n")
				local description = bound.description
				local label = description[I18n.get_locale()] or description.en
				local Builder = require("menu.ui.builder.builder")
				local ctx = { config = Config, paused = false }
				local function extension()
					return find_row(Builder.build(ctx), string.format(I18n.get("menu.extensions.hotstrings_of"), "Ergopti+"))
				end
				local item = find_row(assert(extension()).menu, label .. " (" .. bound.count .. ")")
				helpers.assert_type(item, "table", "the actual translated bound feature is inside Ergopti")
				helpers.assert_true(item.fn())
				helpers.assert_eq(Config.is_group_enabled("magickey"), true)
				helpers.assert_eq(Config.is_section_enabled("magickey", "repeat_corrections"), true,
					"the real callback publishes the bound section")
				local saved = require("core.text.engine.toml_codec").decode(Choices.read(path))
				helpers.assert_eq(saved.hotstrings.modules.magickey.repeat_corrections, true)
				helpers.assert_nil(saved.hotstrings.modules.magickey.replace)
				local disable = find_row(extension().menu, I18n.get("menu.hotstrings.uncheck_all"))
				helpers.assert_true(disable.fn())
				helpers.assert_eq(Config.is_section_checked("magickey", "repeat_corrections"), false)
				helpers.assert_eq(Config.is_section_checked("magickey", "text_expansion_symbols"), true,
					"the extension does not own common symbol choices")
				helpers.assert_eq(Config.is_group_enabled("magickey"), true, "an extension does not close another category")
				local enable = find_row(extension().menu, I18n.get("menu.hotstrings.check_all"))
				helpers.assert_true(enable.fn())
				helpers.assert_eq(Config.is_section_checked("magickey", "repeat_corrections"), true)
				helpers.assert_eq(Config.is_section_checked("french_distancesreduction", "suffixes_a"), true)
				-- A pause stops typing, not configuration (EDD-1, edd1-paused-writes).
				local before = Choices.read(path); ctx.paused = true
				helpers.assert_true(disable.fn(), "the retained bulk callback still writes after a pause")
				helpers.assert_true(Choices.read(path) ~= before, "the paused bulk change is saved")
				Preferences._set_file_for_test(nil)
			end)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)
end)
