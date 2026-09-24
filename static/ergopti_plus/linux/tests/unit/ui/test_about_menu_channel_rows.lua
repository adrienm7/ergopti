--- tests/unit/ui/test_about_menu_channel_rows.lua

--- ==============================================================================
--- MODULE: The About Submenu Owns The Updater Rows (Linux tray)
--- DESCRIPTION:
--- Linux had its updater as a separate top-level "Updates" submenu with its own
--- 'stable'/'dev' rows, where the other two drivers keep it under About. The
--- About submenu now carries the same block on all three: the version, one row
--- per channel of the shared registry (ticked on the subscribed one) right
--- before the check row, then the check frequency. Built through the real tray
--- builder and renderer, so a row the renderer drops fails here.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The submenu of the top-level row whose title is the translation of `key`.
local function submenu_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if item.title == label then return item.menu end
	end
	return nil
end

--- An updater double over the real shared channel registry.
local function fake_updater(subscribed)
	local real = require("modules.updater.manager")
	local calls = { set = {}, checks = 0 }
	local up = {
		CHANNELS = real.CHANNELS,
		INTERVAL_PRESETS = real.INTERVAL_PRESETS,
		TIMING = real.TIMING,
		current_version = function() return "0.0.0-dev.140" end,
		get_channel = function() return subscribed end,
		set_channel = function(id)
			calls.set[#calls.set + 1] = id
			subscribed = id
			return true
		end,
		get_check_interval = function() return real.INTERVAL_PRESETS[1].seconds end,
		get_menu_label = function() return require("infra.i18n").get("menu.about.check_for_updates") end,
		get_state = function() return "idle" end,
		get_cached_release = function() return nil end,
		check_for_updates = function() calls.checks = calls.checks + 1 return true end,
		releases_page_url = function() return real.releases_page_url() end,
	}
	return up, calls
end

local function build(up, changed)
	local mb = helpers.load_module("ui.menu.menu_builder")
	return mb.build({
		_version = "0.0.0-dev.140",
		updater = up,
		on_quit = function() end,
		on_menu_changed = function() if changed then changed.count = changed.count + 1 end end,
	})
end

helpers.describe("tray (linux): the About submenu owns the updater rows", function()
	helpers.it("has no separate top-level Updates submenu", function()
		local up = fake_updater("dev")
		for _, item in ipairs(build(up)) do
			helpers.assert_true(item.title ~= "🔄 Updates" and item.title ~= "🔄 Mises à jour",
				"the Updates submenu folded into About")
		end
	end)

	helpers.it("lists one ticked row per registry channel right before the check row", function()
		local up = fake_updater("dev")
		local rows = submenu_of(build(up), "menu.about.title")
		helpers.assert_true(rows ~= nil, "the About submenu must be drawn")
		local i18n = require("infra.i18n")
		helpers.assert_eq(rows[1].title, "ErgoptiPlus 0.0.0-dev.140", "the version row comes first")
		helpers.assert_eq(rows[2].title, "-", "a separator follows the version")
		local ids = up.CHANNELS.ids()
		helpers.assert_true(#ids >= 2, "the registry must declare the channels")
		for index, id in ipairs(ids) do
			local row = rows[2 + index]
			helpers.assert_eq(row.title, i18n.get(up.CHANNELS.channel(id).menu_label_key),
				"channel row " .. index .. " reads its registry label")
			helpers.assert_eq(row.checked == true, id == "dev", "only the subscribed channel is ticked")
		end
		helpers.assert_eq(rows[3 + #ids].title, i18n.get("menu.about.check_for_updates"),
			"the check row comes right after the channel rows")
		helpers.assert_true(type(rows[4 + #ids].menu) == "table" and #rows[4 + #ids].menu > 0,
			"the check-frequency picker follows the check row")
	end)

	helpers.it("a channel row subscribes to its own channel and redraws the tray", function()
		local up, calls = fake_updater("dev")
		local changed = { count = 0 }
		local rows = submenu_of(build(up, changed), "menu.about.title")
		local ids = up.CHANNELS.ids()
		for index = 1, #ids do rows[2 + index].fn() end
		helpers.assert_eq(calls.set, ids, "each row must subscribe to its own channel, in registry order")
		helpers.assert_eq(changed.count, #ids, "the tray is redrawn so the tick follows the channel")
	end)

	helpers.it("keeps checking separate from consent to the displayed release", function()
		local up, calls = fake_updater("dev")
		local release = { tag = "v9.9.9", download_url = "https://example.invalid/displayed.tar.gz" }
		local downloads = {}
		up.get_state = function() return "available" end
		up.get_cached_release = function() return release end
		up.download_update = function(url) downloads[#downloads + 1] = url return true end
		local rows = submenu_of(build(up), "menu.about.title")
		local check_index = 3 + #up.CHANNELS.ids()
		rows[check_index].fn()
		helpers.assert_eq(calls.checks, 1, "checking must still check after a release was found")
		helpers.assert_eq(#downloads, 0, "checking never authorizes a download")
		helpers.assert_true(rows[check_index + 1].title:find(release.tag, 1, true) ~= nil,
			"the separate install row must name the release it offers")
		rows[check_index + 1].fn()
		helpers.assert_eq(downloads, { release.download_url },
			"consent must retain the displayed URL so the manager can reject stale offers")
	end)

	-- The picker lists the shared presets (defaults.json, never last), and its
	-- parent row names the preset in force in words. A value outside the presets
	-- read as raw seconds ("Check frequency: 600") with no ticked row.
	helpers.it("the frequency picker lists the shared presets with translated labels", function()
		local Json = require("json")
		local handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/updater/defaults.json", "rb"))
		local presets = Json.decode(handle:read("*a")).timing.check_interval_presets
		handle:close()
		helpers.assert_true(#presets >= 5, "the shared presets must be present")
		local i18n = require("infra.i18n")
		for _, pair in ipairs({ { 86400, "1d" }, { 600, "5m" }, { 0, "never" } }) do
			local up = fake_updater("dev")
			up.get_check_interval = function() return pair[1] end
			local rows = submenu_of(build(up), "menu.about.title")
			local picker = rows[4 + #up.CHANNELS.ids()]
			helpers.assert_eq(picker.title,
				i18n.get("menu.about.frequency_menu") .. ": " .. i18n.get("menu.about.frequency." .. pair[2]),
				"the parent row names the preset in force for " .. pair[1] .. " s")
			helpers.assert_eq(#picker.menu, #presets, "one row per shared preset")
			local ticked = 0
			for index, preset in ipairs(presets) do
				helpers.assert_eq(picker.menu[index].title, i18n.get("menu.about.frequency." .. preset.code),
					"preset row " .. index .. " reads its translated label")
				if picker.menu[index].checked == true then
					ticked = ticked + 1
					helpers.assert_eq(preset.code, pair[2], "the preset in force is the ticked row")
				end
			end
			helpers.assert_eq(ticked, 1, "exactly one preset row is ticked for " .. pair[1] .. " s")
		end
	end)

	-- A menu change used to leave an open Versions page offering the channel the
	-- user had just picked.
	helpers.it("a channel row tells an open Versions page", function()
		local up = fake_updater("dev")
		local Bridge = require("ui.changelog.bridge")
		local previous_push = Bridge._push
		local pushed = {}
		Bridge._push = function(payload) pushed[#pushed + 1] = payload; return true end
		local ok, err = pcall(function()
			local rows = submenu_of(build(up), "menu.about.title")
			local ids = up.CHANNELS.ids()
			rows[3].fn()
			helpers.assert_eq(#pushed, 1, "the page must hear of the change once")
			helpers.assert_eq(pushed[1].action, "channel_changed")
			helpers.assert_eq(pushed[1].channel, ids[1])
		end)
		Bridge._push = previous_push
		if not ok then error(err, 0) end
	end)
end)
