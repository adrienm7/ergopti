--- tests/unit/ui/test_menu_pause_greys_features.lua

--- ==============================================================================
--- MODULE: A Paused Script Greys The Feature Rows (Linux tray)
--- DESCRIPTION:
--- The menu builder never read the pause state: while paused every feature row
--- stayed live, and the title row was a disabled label with no action, so the
--- tray offered no way back. It now greys and strips every feature row, keeps
--- the tail (global actions, language, about, reload, quit, debug) live, and
--- the title row resumes the script, as on macOS.
--- ==============================================================================

local helpers = require("tests.helpers")

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
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
end

--- The top-level row whose title starts with the translation of `key`.
--- @param items table
--- @param key string
--- @return table|nil
local function row_for(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title:find(label, 1, true) then return item end
	end
	return nil
end

--- Builds the tray for a paused or running script.
--- @param paused boolean
--- @param resumed table|nil Receives a `count` of resume calls.
--- @return table items
local function build(paused, resumed)
	local mb = helpers.load_module("ui.menu.menu_builder")
	return mb.build({
		config = fake_config(),
		_version = "0.0.0-dev.12",
		paused = paused,
		on_toggle_pause = function() if resumed then resumed.count = resumed.count + 1 end end,
		on_quit = function() end,
	})
end

-- The features a pause switches off, by their title key.
local FEATURE_KEYS = {
	"menu.hotstrings.title",
	"menu.llm.title",
	"menu.metrics.title",
	"menu.shortcuts.title",
	"menu.gestures.title",
}

-- The rows that must stay usable while paused.
local LIVE_KEYS = {
	"menu.global.title",
	"menu.debug.title",
}

helpers.describe("tray (linux): a pause greys every feature row", function()
	helpers.it("greys and strips every feature row while paused", function()
		local items = build(true)
		for _, key in ipairs(FEATURE_KEYS) do
			local row = row_for(items, key)
			helpers.assert_true(row ~= nil, "row " .. key .. " must still be drawn while paused")
			helpers.assert_eq(row.disabled, true, key .. " must be greyed while paused")
			helpers.assert_nil(row.menu, key .. " must not open a submenu while paused")
			helpers.assert_nil(row.fn, key .. " must not act while paused")
		end
	end)

	helpers.it("keeps the global actions and the debug submenu live while paused", function()
		local items = build(true)
		for _, key in ipairs(LIVE_KEYS) do
			local row = row_for(items, key)
			helpers.assert_true(row ~= nil, key .. " must be drawn")
			helpers.assert_true(row.disabled ~= true, key .. " must stay enabled while paused")
			helpers.assert_true(type(row.menu) == "table" and #row.menu > 0, key .. " keeps its submenu")
		end
	end)

	helpers.it("turns the title row into a resume action while paused", function()
		local resumed = { count = 0 }
		local items = build(true, resumed)
		local title = items[1]
		local paused_label = require("infra.i18n").get("menu.builder.title_paused")
		helpers.assert_true(title.title:find(paused_label, 1, true) ~= nil, "title says paused: " .. title.title)
		helpers.assert_true(title.title:find("v0.0.0-dev.12", 1, true) ~= nil, "title keeps the version")
		helpers.assert_true(title.disabled ~= true, "the paused title row must be clickable")
		helpers.assert_eq(type(title.fn), "function", "the paused title row must act")
		title.fn()
		helpers.assert_eq(resumed.count, 1, "clicking the paused title resumes the script")
	end)

	helpers.it("leaves every row live and the title a label while running", function()
		local items = build(false)
		helpers.assert_eq(items[1].disabled, true, "the running title row is a label")
		for _, key in ipairs(FEATURE_KEYS) do
			local row = row_for(items, key)
			helpers.assert_true(row ~= nil and row.disabled ~= true, key .. " must be live while running")
		end
	end)

	helpers.it("shows a source run's version without a stray v", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local items = mb.build({ config = fake_config(), _version = "local", on_quit = function() end })
		helpers.assert_eq(items[1].title, "Ergopti — local")
	end)
end)
