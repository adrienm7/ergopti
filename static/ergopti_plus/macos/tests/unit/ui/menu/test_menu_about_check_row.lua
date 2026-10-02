--- tests/unit/ui/menu/test_menu_about_check_row.lua

--- ==============================================================================
--- MODULE: The About Check Row Opens The Update-Check Window (macOS)
--- DESCRIPTION:
--- "Check for updates" used to hand the check to Sparkle, whose English,
--- left-aligned alert named no channel. The row now opens the shared
--- update-check window over the menu session's automatic-check and channel
--- owners; a row that already names a found release is the user's consent and
--- still goes straight to Sparkle. Built through the real builder and renderer.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the About submenu of a packaged build and returns its check row with
--- the recorded window opens and Sparkle requests.
local function build(latest)
	local recorded = { opens = {}, requests = {} }
	local saved = {
		window = package.loaded["ui.update_check"],
		launcher = package.loaded["adapters.update_launcher"],
	}
	package.loaded["ui.update_check"] = {
		open = function(opts) recorded.opens[#recorded.opens + 1] = opts; return true end,
	}
	package.loaded["adapters.update_launcher"] = {
		request_check = function(channel) recorded.requests[#recorded.requests + 1] = channel; return true end,
		select_channel = function() return true end,
	}
	local Updater = require("modules.updater")
	local real_local = Updater.is_local_source
	Updater.is_local_source = function() return false end
	package.loaded["ui.menu.menu_about"] = nil
	local owner = { get = function() return "dev" end, set = function() return true end, subscribe = function() end }
	local checks = {
		presets = function() return {} end,
		interval_code = function() return "1d" end,
		set_interval = function() return true end,
		latest = function() return latest end,
	}
	local refresh = function() end
	local ok, rows = pcall(function()
		local About = helpers.load_with_stubs("ui.menu.menu_about")
		return About.build({ channel_owner = owner, update_checks = checks, updateMenu = refresh }, {
			start_at_login = function() error("Building About must not change startup.") end,
			uninstall = function() error("Building About must not uninstall the application.") end,
		}).submenu
	end)
	Updater.is_local_source = real_local
	package.loaded["ui.menu.menu_about"] = nil
	local function restore()
		package.loaded["ui.update_check"] = saved.window
		package.loaded["adapters.update_launcher"] = saved.launcher
	end
	if not ok then restore(); error(rows, 0) end
	recorded.owner, recorded.checks, recorded.refresh, recorded.restore = owner, checks, refresh, restore
	local i18n = require("infra.i18n")
	for _, row in ipairs(rows) do
		if row.title == i18n.get("menu.about.check_for_updates")
			or (latest and type(row.title) == "string" and row.title:find(latest.tag, 1, true)) then
			recorded.row = row
		end
	end
	return recorded
end

helpers.describe("menu_about: the check row (macOS)", function()
	helpers.it("opens the update-check window over the menu session's owners", function()
		local recorded = build(nil)
		local ok, err = pcall(function()
			helpers.assert_not_nil(recorded.row, "the About submenu offers the check row")
			recorded.row.fn()
			helpers.assert_eq(#recorded.opens, 1, "the click opens the update-check window")
			helpers.assert_eq(#recorded.requests, 0, "Sparkle is not asked to check")
			helpers.assert_true(recorded.opens[1].checks == recorded.checks, "the window checks through the Lua owner")
			helpers.assert_true(recorded.opens[1].channel_owner == recorded.owner, "switches go through the channel owner")
			helpers.assert_true(recorded.opens[1].on_change == recorded.refresh, "the menu refreshes after an answer")
		end)
		recorded.restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("a row that names a found release installs it through Sparkle", function()
		local recorded = build({ tag = "v0.0.0-dev.150", channel = "dev" })
		local ok, err = pcall(function()
			helpers.assert_not_nil(recorded.row, "the row names the found release")
			recorded.row.fn()
			helpers.assert_eq(recorded.requests, { "dev" }, "Sparkle installs from the release's channel")
			helpers.assert_eq(#recorded.opens, 0, "no second check before the consented install")
		end)
		recorded.restore()
		if not ok then error(err, 0) end
	end)
end)
