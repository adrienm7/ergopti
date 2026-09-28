--- tests/unit/ui/menu/test_menu_about_frequency_rows.lua

--- ==============================================================================
--- MODULE: The About Submenu Owns The Check Frequency (macOS)
--- DESCRIPTION:
--- macOS had no check frequency: Sparkle checked once a day whatever the user
--- wanted, and the About submenu offered nothing to change it. The frequency
--- picker now follows the check row, as on Windows and Linux: one row per
--- shared preset, labelled in words and ticked on the interval in force, and a
--- click persists through the automatic-check owner. The check row names a
--- release the last automatic check found. Built through the real builder and
--- renderer, so a row the renderer drops fails here.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local function presets()
	local handle = assert(io.open(helpers.shared("modules/updater/defaults.json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded.timing.check_interval_presets
end

local function fake_owner(subscribed)
	return {
		get = function() return subscribed end,
		set = function() return true end,
		subscribe = function() end,
	}
end

--- An automatic-check owner double recording the interval the menu sets.
local function fake_checks(code, latest)
	local calls = {}
	local list = presets()
	return {
		presets = function() return list end,
		interval_code = function() return code end,
		set_interval = function(seconds) calls[#calls + 1] = seconds; return true end,
		latest = function() return latest end,
	}, calls
end

--- Builds the About submenu of a packaged build through the real renderer.
local function build(checks)
	local Updater = require("modules.updater")
	local real_local = Updater.is_local_source
	Updater.is_local_source = function() return false end
	package.loaded["ui.menu.menu_about"] = nil
	local ok, rows = pcall(function()
		local About = helpers.load_with_stubs("ui.menu.menu_about")
		return About.build({ channel_owner = fake_owner("dev"), update_checks = checks }).submenu
	end)
	Updater.is_local_source = real_local
	package.loaded["ui.menu.menu_about"] = nil
	if not ok then error(rows, 0) end
	return rows
end

--- The row whose submenu is the frequency picker.
local function picker(rows)
	local prefix = require("infra.i18n").get("menu.about.frequency_menu") .. ": "
	for _, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:find(prefix, 1, true) == 1 then return row end
	end
	return nil
end

helpers.describe("menu_about: the check frequency (macOS)", function()
	helpers.it("lists the shared presets after the check row, ticked on the interval in force", function()
		local checks = fake_checks("1d")
		local rows = build(checks)
		local i18n = require("infra.i18n")
		local row = picker(rows)
		helpers.assert_not_nil(row, "the About submenu must offer the check frequency")
		helpers.assert_eq(row.title, i18n.get("menu.about.frequency_menu") .. ": " .. i18n.get("menu.about.frequency.1d"),
			"the parent row names the preset in force in words")
		local list = presets()
		helpers.assert_eq(#row.menu, #list, "one row per shared preset")
		local ticked = 0
		for index, preset in ipairs(list) do
			helpers.assert_eq(row.menu[index].title, i18n.get("menu.about.frequency." .. preset.code),
				"preset row " .. index .. " reads its translated label")
			if row.menu[index].checked == true then
				ticked = ticked + 1
				helpers.assert_eq(preset.code, "1d", "the interval in force is the ticked row")
			end
		end
		helpers.assert_eq(ticked, 1, "exactly one preset is ticked")
		local check_at, picker_at = nil, nil
		for index, candidate in ipairs(rows) do
			if candidate.title == i18n.get("menu.about.check_for_updates") then check_at = index end
			if candidate == row then picker_at = index end
		end
		helpers.assert_true(check_at ~= nil and picker_at == check_at + 1, "the picker follows the check row")
	end)

	helpers.it("a preset row sets the interval through the owner", function()
		local checks, calls = fake_checks("1d")
		local row = picker(build(checks))
		local list = presets()
		row.menu[1].fn()
		helpers.assert_eq(calls, { list[1].seconds }, "the first preset's seconds are persisted")
	end)

	helpers.it("the check row names the release the last automatic check found", function()
		local checks = fake_checks("1d", { tag = "v0.0.0-dev.150", channel = "dev" })
		local rows = build(checks)
		local picker_row = picker(rows)
		local check_row = nil
		for index, row in ipairs(rows) do
			if rows[index + 1] == picker_row then check_row = row end
		end
		helpers.assert_not_nil(check_row, "the check row precedes the picker")
		helpers.assert_true(check_row.title:find("v0.0.0-dev.150", 1, true) ~= nil,
			"the check row names the found release: " .. tostring(check_row.title))
		local idle = build(fake_checks("1d"))
		for _, row in ipairs(idle) do
			helpers.assert_true(row.title:find("v0.0.0-dev.150", 1, true) == nil,
				"without a found release no row names one")
		end
	end)
end)
