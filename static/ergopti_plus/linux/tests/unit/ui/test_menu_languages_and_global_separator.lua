--- tests/unit/ui/test_menu_languages_and_global_separator.lua

--- ==============================================================================
--- MODULE: Hotstring Language Header And Global Actions Separator (Linux)
--- DESCRIPTION:
--- Two layout fixes to menus the three drivers render from the shared manifest.
---
--- The language packs were one bare « Français (n) » row among the neutral
--- categories, which users read as one more category and overlooked. They now
--- sit under a « Hotstrings par langue » header, behind a separator, and each
--- row starts with its locale's flag from the shared locale table.
---
--- The Configuration submenu draws the two rows that rewrite the configuration,
--- then a separator, then the two that open a window: the folders editor, which
--- this driver shows like the other two, and the setup wizard.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A hotstrings config double that declares the French language pack.
--- @return table
local function fake_config()
	return {
		get_groups = function() return { "rolls" } end,
		is_group_enabled = function() return true end,
		toggle_group = function() end,
		enable_all = function() end,
		disable_all = function() end,
		is_section_enabled = function() return true end,
		get_category = function() return nil end,
		get_categories = function() return {} end,
		language_packs = function()
			return { { id = "french", locale = "fr", categories = { "autocorrection" } } }
		end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
end

--- Whether a built row is a separator.
--- @param row table|nil
--- @return boolean
local function is_separator(row)
	return type(row) == "table" and (row.separator == true or row.title == "-")
end

--- The submenu holding a row whose title contains `needle`.
--- @param items table
--- @param needle string
--- @return table|nil rows, number|nil index
local function submenu_with(items, needle)
	for _, item in ipairs(items or {}) do
		if type(item.menu) == "table" then
			for index, row in ipairs(item.menu) do
				if type(row.title) == "string" and row.title:find(needle, 1, true) then
					return item.menu, index
				end
			end
		end
	end
	return nil, nil
end

helpers.describe("tray layout (linux): language header and global separator", function()
	helpers.it("hotstring languages: header, separator and flag before the language row", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local i18n = require("infra.i18n")
		local rows, at = submenu_with(mb.build({ config = fake_config(), _version = "9.9.9" }), "Français")
		helpers.assert_true(rows ~= nil, "the French language pack row must be drawn")
		helpers.assert_eq(rows[at].title:sub(1, #"🇫🇷 Français"), "🇫🇷 Français",
			"the language row starts with the locale's flag, from the shared locale table")
		local header = rows[at - 1] and rows[at - 1].title or ""
		helpers.assert_true(header:find(i18n.get("menu.hotstrings.header_languages"), 1, true) ~= nil,
			"a « Hotstrings par langue » header must precede the language rows, got '" .. header .. "'")
		helpers.assert_true(is_separator(rows[at - 2]), "and a separator must precede that header")
	end)

	helpers.it("configuration: restore and clear, the cleanup, then the two windows", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local i18n = require("infra.i18n")
		local shown = {}
		local items = mb.build({
			_version = "9.9.9",
			on_quit = function() end,
			webview = { show = function(name) shown[#shown + 1] = name end },
		})
		local rows
		for _, item in ipairs(items) do
			if item.title == i18n.get("menu.configuration.title") then rows = item.menu end
		end
		helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
		local drawn = {}
		for index, row in ipairs(rows) do drawn[index] = is_separator(row) and "-" or row.title end
		helpers.assert_eq(table.concat(drawn, " | "), table.concat({
			i18n.get("common.restore_recommended"),
			i18n.get("common.clear_to_system"),
			"-",
			i18n.get("menu.global.clean_unused_keys"),
			"-",
			i18n.get("menu.global.config_folder"),
			i18n.get("menu.global.setup_wizard"),
		}, " | "), "Uninstall moved to the Version / Updates submenu; no separator is left dangling")
		-- The folders editor, as on the other two drivers, not the file manager.
		local folder = rows[6]
		local fn = folder.fn or folder.action
		helpers.assert_eq(type(fn), "function", "the folders row must act")
		fn()
		helpers.assert_eq(table.concat(shown, ","), "paths_editor",
			"the folders row must open the folders editor")
	end)
end)


--- Replays structural admission through the actual complete tray and native window callbacks.
--- @param body function Independent source and finished-row assertions.
local function configuration_parent_fixture(body)
	-- These real modules capture one another. A preceding registered fixture may
	-- reload locale alone; retain a fresh coherent native chain for this case.
	local names = { "locale.core", "infra.locale", "infra.i18n", "infra.manifest_menu", "ui.menu.menu_builder" }
	local previous, original_i18n_safe = {}, rawget(_G, "i18n_safe")
	for module, value in pairs(package.loaded) do previous[module] = value end
	for _, module in ipairs(names) do rawset(package.loaded, module, nil) end
	local completed, failure = xpcall(function()
	-- Complete the genuine discovery/read phase before a requested test locale;
	-- the Language child must not lazily initialize it back to the saved locale.
	require("infra.i18n").init()
	local native = helpers.load_module("ui.menu.menu_builder")
	local renderer, locale = require("infra.manifest_menu"), require("infra.locale")
	local language = locale.current_locale()
	local callbacks = {}
	local context = { on_toggle_pause = function() end, on_quit = function() end,
		on_show_setup_wizard = function() callbacks[#callbacks + 1] = "setup_wizard"; return false end,
		webview = { show = function(name) callbacks[#callbacks + 1] = name; return false end },
		config = { get_groups = function() return {} end, get_categories = function() return {} end,
			language_packs = function() return {} end, resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
			get_global_delay = function() return 0.75 end, has_global_delay_override = function() return false end } }
	local function build(paused) context.paused = paused; return native.build(context) end
	local ok, detail = xpcall(function() body(renderer, build, callbacks, locale) end, debug.traceback)
	locale.set_locale(language)
	if not ok then error(detail, 0) end
	end, debug.traceback)
	for module in pairs(package.loaded) do if previous[module] == nil then rawset(package.loaded, module, nil) end end
	for module, value in pairs(previous) do rawset(package.loaded, module, value) end
	rawset(_G, "i18n_safe", original_i18n_safe)
	helpers.assert_true(rawequal(rawget(_G, "i18n_safe"), original_i18n_safe))
	for _, module in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, module), previous[module]), module) end
	if not completed then error(failure, 0) end
end

local configuration_parent_file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/configuration_parent.json"), "rb"))
local configuration_parent_raw = configuration_parent_file:read("*a")
configuration_parent_file:close()
require("test.configuration_parent_contract").register(helpers, configuration_parent_fixture,
	assert(require("json").decode(configuration_parent_raw)), "linux")
