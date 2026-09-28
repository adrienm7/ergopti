--- tests/unit/ui/menu/test_menu_about_channel_rows.lua

--- ==============================================================================
--- MODULE: The About Submenu Lists The Update Channels (macOS)
--- DESCRIPTION:
--- macOS showed no channel at all: the feed was fixed when the app was built.
--- The About submenu now lists one row per channel of the shared registry,
--- ticked on the subscribed one, right before the check row, and a click
--- subscribes through the menu session's channel owner. Built through the real
--- builder and renderer, so a row the renderer drops fails here.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A channel-owner double recording what the menu asks of it.
local function fake_owner(subscribed)
	local calls = {}
	return {
		get = function() return subscribed end,
		set = function(id) calls[#calls + 1] = id return true end,
		subscribe = function() end,
	}, calls
end

--- Builds the About submenu through the real module and renderer.
local function build(owner)
	package.loaded["ui.menu.menu_about"] = nil
	local About = helpers.load_with_stubs("ui.menu.menu_about")
	local item = About.build({ channel_owner = owner })
	return item.submenu
end

helpers.describe("menu_about: one row per registry channel", function()
	helpers.it("lists the channels, ticked on the subscribed one, after the version", function()
		local owner = fake_owner("dev")
		local rows = build(owner)
		local Updater = require("modules.updater")
		local i18n = require("infra.i18n")
		local ids = Updater.channels().ids()
		helpers.assert_true(#ids >= 2, "the registry must declare the channels")
		helpers.assert_true(type(rows[1].title) == "string" and rows[1].title:find("ErgoptiPlus", 1, true) == 1,
			"the version row comes first")
		helpers.assert_eq(rows[2].title, "-", "a separator follows the version")
		for index, id in ipairs(ids) do
			local row = rows[2 + index]
			helpers.assert_eq(row.title, i18n.get(Updater.channels().channel(id).menu_label_key),
				"channel row " .. index .. " reads its registry label")
			helpers.assert_eq(row.checked == true, id == "dev", "only the subscribed channel is ticked")
		end
	end)

	helpers.it("a channel row subscribes through the owner", function()
		local owner, calls = fake_owner("main")
		local rows = build(owner)
		local ids = require("modules.updater").channels().ids()
		for index = 1, #ids do rows[2 + index].fn() end
		helpers.assert_eq(calls, ids, "each row subscribes to its own channel, in registry order")
	end)

	-- The Versions window's banner used to have no owner to subscribe through.
	helpers.it("the Versions row opens on the subscribed channel with the owner", function()
		local owner = fake_owner("dev")
		local previous = package.loaded["ui.changelog"]
		local opened = {}
		package.loaded["ui.changelog"] = { open = function(opts) opened[#opened + 1] = opts return true end }
		local ok, err = pcall(function()
			local rows = build(owner)
			local label = require("infra.i18n").get("menu.about.changelog")
			local versions = nil
			for _, row in ipairs(rows) do
				if row.title == label then versions = row end
			end
			helpers.assert_not_nil(versions, "the About submenu must list the Versions row")
			versions.fn()
			helpers.assert_eq(#opened, 1, "the Versions window must open once")
			helpers.assert_eq(opened[1].channel, "dev", "it opens on the subscribed channel")
			helpers.assert_true(opened[1].channel_owner == owner, "its banner subscribes through the same owner")
		end)
		package.loaded["ui.changelog"] = previous
		package.loaded["ui.menu.menu_about"] = nil
		if not ok then error(err, 0) end
	end)

	helpers.it("without an owner the rows are left out rather than drawn dead", function()
		local rows = build(nil)
		local Updater = require("modules.updater")
		local i18n = require("infra.i18n")
		for _, row in ipairs(rows) do
			for _, id in ipairs(Updater.channels().ids()) do
				helpers.assert_true(row.title ~= i18n.get(Updater.channels().channel(id).menu_label_key),
					"a channel row with nobody to persist it must not be offered")
			end
		end
	end)
end)
