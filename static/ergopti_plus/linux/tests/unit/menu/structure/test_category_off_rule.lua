--- tests/unit/menu/structure/test_category_off_rule.lua

--- ==============================================================================
--- MODULE: The Category-Off Rule on the Built Linux Tray
--- DESCRIPTION:
--- Renders every gated manifest menu through this driver's bound renderer, off
--- then on, and builds the real tray through the real builders: only each enable
--- row and the rows flagged `readable_when_off` stay live while off. The layout
--- has no off state here (Windows alone emulates it), so it keeps its rows. The
--- fixture tray has no metrics, shortcut, gesture, tap-hold or agent engine, so
--- those submenus show their absence rows; the manifest probe covers them.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Title key, manifest menu and state key of each category the fixture tray builds.
local CATEGORIES = {
	{ title = "menu.hotstrings.title", menu = "hotstrings_menu", state = "hotstrings_enabled" },
	{ title = "menu.llm.title",        menu = "llm_menu",        state = "llm_enabled" },
}

--- A hotstrings config double with one category.
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
		language_packs = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_base_delay = function() return 0.75 end,
		has_base_delay_override = function() return false end,
	}
end

--- Builds the tray with every category's switch reading `on`.
--- @param on boolean
--- @return table items
local function build_tray(on)
	local ManifestMenu = require("menu.engine.manifest_menu")
	local actual = ManifestMenu.build
	ManifestMenu.build = function(key, category_name, handlers, groups, ctx, providers)
		if type(ctx) == "table" and type(ctx.state_getters) == "table" then
			for _, category in ipairs(CATEGORIES) do
				if ctx.state_getters[category.state] then
					ctx.state_getters[category.state] = function() return on end
				end
			end
		end
		return actual(key, category_name, handlers, groups, ctx, providers)
	end
	local mb = helpers.load_module("menu.ui.builder.builder")
	local ok, items = pcall(mb.build, {
		llm = require("ai.engine.prediction.engine"),
		config = fake_config(),
		_version = "0.0.0-dev.12",
		on_toggle_pause = function() end,
		on_quit = function() end,
	})
	ManifestMenu.build = actual
	if not ok then error(items, 0) end
	return items
end

--- The top-level row whose title starts with the translation of `key`.
--- @param items table
--- @param key string
--- @return table|nil
local function row_for(items, key)
	local label = require("core.i18n.engine.i18n").get(key)
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title:sub(1, #label) == label then return item end
	end
	return nil
end

helpers.describe("tray (linux): the category-off rule", function()
	helpers.it("greys every gated manifest menu but its enable and reader rows", function()
		require("tests.lua.category_off_contract").assert_every_gated_menu(helpers,
			require("menu.engine.manifest_menu"), require("core.i18n.engine.i18n"), "linux")
	end)
	for _, on in ipairs({ false, true }) do
		for _, category in ipairs(CATEGORIES) do
			helpers.it("the built " .. category.menu .. " with its category on " .. tostring(on), function()
				local parent = row_for(build_tray(on), category.title)
				helpers.assert_true(parent ~= nil, category.title .. " must be in the tray")
				require("tests.lua.category_off_contract").assert_category(helpers, require("core.i18n.engine.i18n"),
					require("menu.engine.manifest_menu").get_array(category.menu), parent, not on)
			end)
		end
	end
end)
