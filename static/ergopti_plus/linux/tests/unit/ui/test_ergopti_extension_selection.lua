--- tests/unit/ui/test_ergopti_extension_selection.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Selection (Linux)
--- DESCRIPTION:
--- Replays the shared exact-section policy with the native manifest declarations.
--- ==============================================================================

local helpers = require("tests.helpers")
require("test.ergopti_extension_selection_contract").run(helpers, require("infra.manifest_reader").features())

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
	helpers.it("(ergopti-extension-selection) controls real shipped metadata and physical replacement without an installed layout", function()
		local names = { "modules.hotstrings.hotstrings_config", "modules.hotstrings.loader",
			"modules.hotstrings.magic_key_source", "infra.hotstring_preferences", "ui.menu.menu_builder" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local ok, err = pcall(function()
			local Config = require("modules.hotstrings.hotstrings_config")
			local Choices = require("tests.support.hotstring_choices")
			local source = '[hotstrings]\nmagic_key_source = "KeyJ"\n'
				.. 'groups = { magickey = true, french_distancesreduction = true }\n'
				.. '[hotstrings.modules.magickey]\nreplace = false\ntext_expansion_symbols = true\n'
				.. '[hotstrings.modules.french_distancesreduction]\nsuffixes_a = true\n'
			with_private_choices(Config, source, function(path)
				local Preferences = require("infra.hotstring_preferences")
				helpers.assert_true(Preferences._set_file_for_test(path))
				local Source = require("modules.hotstrings.magic_key_source")
				local typed, queued, dispatched, gates = {}, {}, {}, {}
				Source.init({
					is_active = function() return true end,
					replace_on = function()
						local admitted = Config.is_section_enabled("magickey", "replace")
						gates[#gates + 1] = admitted
						return admitted
					end,
					magic_key = function() return "★" end,
					can_type = function() return true end,
					type_text = function(text) typed[#typed + 1] = text; return true end,
					end_selection = function() end,
					dispatch_char = function(text, code) dispatched[#dispatched + 1] = { text, code } end,
					can_capture = function() return true end,
					key_text = function(code) return code == 36 and "j" or nil end,
					defer = function(callback) queued[#queued + 1] = callback; return true end,
				})
				Config.init({ load_mappings = function() return true end }, nil)
				local _, committed = Config.load_all()
				helpers.assert_true(committed, "the real bundled and shipped extension catalogue initializes")
				local category = Config.get_category("magickey")
				helpers.assert_eq(category.sections.replace.count, 0, "native replacement has no fabricated mapping")
				helpers.assert_eq(category.sections.replace.extension.id, "ergopti")
				helpers.assert_eq(Config.get_category("french_distancesreduction").count, 24)
				local I18n = require("infra.i18n")
				local description = category.sections.replace.description
				local label = description[I18n.get_locale()] or description.en
				local Builder = require("ui.menu.menu_builder")
				local ctx = { config = Config, paused = false }
				local function extension()
					return find_row(Builder.build(ctx), string.format(I18n.get("menu.extensions.hotstrings_of"), "Ergopti+"))
				end
				local item = find_row(assert(extension()).menu, label .. " (0)")
				helpers.assert_type(item, "table", "the actual translated bound feature is inside Ergopti")
				helpers.assert_nil(find_row(extension().menu, "replace (0)"))
				helpers.assert_eq(Source.on_key({ code = 36, mods = {} }), false)
				helpers.assert_true(item.fn())
				helpers.assert_eq(Config.is_group_enabled("magickey"), true)
				helpers.assert_eq(Config.is_section_enabled("magickey", "replace"), true,
					"the real callback must publish the effective native gate before typing")
				local consumed = Source.on_key({ code = 36, mods = {} })
				helpers.assert_true(consumed, "the real menu opens the physical native-source gate; source="
					.. tostring(Source.get()) .. "; native=" .. tostring(Source.evdev_code())
					.. "; gate=" .. tostring(gates[#gates]) .. "; writes=" .. tostring(#typed))
				helpers.assert_eq(Source.get(), "KeyJ")
				helpers.assert_eq(Source.evdev_code(), 36)
				helpers.assert_eq(typed, { "★" })
				helpers.assert_eq(dispatched, { { "★", 36 } }, "actual injection is handed to the character path")
				local saved = require("toml_codec").decode(Choices.read(path))
				helpers.assert_eq(saved.hotstrings.modules.magickey.replace, true)
				local disable = find_row(extension().menu, I18n.get("menu.hotstrings.uncheck_all"))
				helpers.assert_true(disable.fn())
				helpers.assert_eq(Config.is_section_checked("magickey", "replace"), false)
				helpers.assert_eq(Config.is_section_checked("magickey", "text_expansion_symbols"), true,
					"the extension does not own common symbol choices")
				helpers.assert_eq(Config.is_group_enabled("magickey"), true, "an extension does not close another category")
				helpers.assert_eq(Source.on_key({ code = 36, mods = {} }), false)
				local enable = find_row(extension().menu, I18n.get("menu.hotstrings.check_all"))
				helpers.assert_true(enable.fn())
				helpers.assert_eq(Config.is_section_checked("magickey", "replace"), true)
				helpers.assert_eq(Config.is_section_checked("french_distancesreduction", "suffixes_a"), true)
				local before = Choices.read(path); ctx.paused = true
				helpers.assert_eq(item.fn(), false, "the retained section callback refuses a later pause")
				helpers.assert_eq(disable.fn(), false, "the retained bulk callback refuses a later pause")
				helpers.assert_eq(Choices.read(path), before)
				Source._reset_for_test(); Preferences._set_file_for_test(nil)
			end)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)
end)
