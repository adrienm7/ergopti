--- linux/tests/unit/meta/test_update_check_feedback.lua

--- ==============================================================================
--- MODULE: A Manual Update Check Answers The User (Linux)
--- DESCRIPTION:
--- "Check for updates" used to answer with log lines, or with a notification
--- that named neither the channel nor the other channels. The updater's check
--- now hands the update-check window a structured answer, and the About row
--- opens that window:
--- 1. up to date, a release to offer, no release on the channel, a release
---    without the Linux bundle, and a failed request each have their phase,
---    with every other channel whose latest release is newer than the build;
--- 2. a failure names the reason the window translates;
--- 3. the check row opens the window over the updater and the menu's hooks,
---    and only a window that cannot open falls back to the notification.
--- ==============================================================================

local helpers = require("tests.helpers")

local BUNDLE = "ergopti-plus-linux.tar.gz"

--- One release object of the GitHub list, with or without the Linux bundle.
local function release(tag, published_at, with_bundle)
	local assets = ""
	if with_bundle then
		local base = "https://github.com/adrienm7/ergopti/releases/download/" .. tag .. "/" .. BUNDLE
		assets = '{"name":"' .. BUNDLE .. '","browser_download_url":"' .. base .. '"},'
			.. '{"name":"' .. BUNDLE .. '.sha256","browser_download_url":"' .. base .. '.sha256"}'
	end
	return '{"tag_name":"' .. tag .. '","prerelease":' .. tostring(tag:find("-dev", 1, true) ~= nil)
		.. ',"published_at":"' .. published_at .. '","assets":[' .. assets .. ']}'
end

--- Runs one manual check over a scripted list and returns the callback's arguments.
local function check(list, channel, current, fetch_error, reason)
	local M = helpers.load_module("modules.updater.manager")
	local real_fetch, real_version = M._fetch_releases, M.current_version
	M._fetch_releases = function(_, callback)
		if fetch_error then callback(nil, 0, fetch_error, reason) else callback(list, 200, nil) end
		return true
	end
	M.current_version = function() return current end
	M.clear_cached_release()
	local told = nil
	local ok, err = pcall(M.check_for_updates, channel, function(...) told = { ... } end)
	M._fetch_releases, M.current_version = real_fetch, real_version
	M.clear_cached_release()
	if not ok then error(err, 0) end
	helpers.assert_not_nil(told, "the check answers")
	return told
end

helpers.describe("updater: a manual check answers the update-check window (Linux)", function()
	helpers.it("offers a newer release with its bundle, and lists a newer other channel", function()
		local list = "[" .. release("v1.0.0", "2026-09-03T00:00:00Z", true) .. ","
			.. release("v0.0.0-dev.150", "2026-09-02T00:00:00Z", true) .. ","
			.. release("v0.0.0-dev.140", "2026-08-01T00:00:00Z", true) .. "]"
		local told = check(list, "dev", "0.0.0-dev.140")
		local result = told[4]
		helpers.assert_eq(told[1], true, "the release is available")
		helpers.assert_eq(result.state, "available")
		helpers.assert_eq(result.latest, "v0.0.0-dev.150")
		helpers.assert_eq(result.current, "0.0.0-dev.140")
		helpers.assert_eq(result.channel, "dev")
		helpers.assert_eq(result.others, { { channel = "main", tag = "v1.0.0" } })
	end)

	helpers.it("says up to date, and a stable release older than the build is not listed", function()
		local list = "[" .. release("v0.0.0-dev.140", "2026-08-01T00:00:00Z", true) .. ","
			.. release("v1.0.0", "2026-07-03T00:00:00Z", true) .. "]"
		local result = check(list, "dev", "0.0.0-dev.140")[4]
		helpers.assert_eq(result.state, "up_to_date")
		helpers.assert_eq(result.others, {})
	end)

	helpers.it("says the channel has no release yet", function()
		local list = "[" .. release("v0.0.0-dev.140", "2026-08-01T00:00:00Z", true) .. "]"
		local result = check(list, "main", "0.0.0-dev.140")[4]
		helpers.assert_eq(result.state, "no_release")
		helpers.assert_eq(result.channel, "main")
	end)

	helpers.it("shows a release without the Linux bundle as a failure naming it", function()
		local list = "[" .. release("v0.0.0-dev.150", "2026-09-02T00:00:00Z", false) .. "]"
		local told = check(list, "dev", "0.0.0-dev.140")
		helpers.assert_eq(told[1], false, "nothing is installable")
		helpers.assert_eq(told[4].state, "error")
		helpers.assert_eq(told[4].reason_key, "update_check.error_no_asset")
		helpers.assert_eq(told[4].latest, "v0.0.0-dev.150", "the reason names the release")
	end)

	helpers.it("names the reason of a failed request", function()
		local offline = check(nil, "dev", "0.0.0-dev.140", "Could not resolve host", "no_connection")[4]
		helpers.assert_eq(offline.state, "error")
		helpers.assert_eq(offline.reason_key, "updater.no_connection")
		helpers.assert_eq(offline.detail, "Could not resolve host")
		local garbled = check(nil, "dev", "0.0.0-dev.140", "invalid release page JSON", "parse_failed")[4]
		helpers.assert_eq(garbled.reason_key, "updater.parse_failed")
		local unclassified = check(nil, "dev", "0.0.0-dev.140", "empty body", nil)[4]
		helpers.assert_eq(unclassified.reason_key, "update_check.error_unexpected",
			"a failure without a reason is not shown as a connection failure")
	end)

	helpers.it("tags every transport failure with a reason the window knows", function()
		local M = helpers.load_module("modules.updater.manager")
		local real_client = M._http_client
		local answers = {}
		M._http_client = { get = function(_, _, _, callback) callback({ ok = false, status = 0, error = "timeout" }); return true end }
		M._http_client = require("tests.support.release_http_fixture").attach(M._http_client)
		local ok, err = pcall(M._fetch_releases, "dev", function(...) answers[#answers + 1] = { ... } end)
		M._http_client = real_client
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(answers[1][4], "no_connection")
	end)
end)

helpers.describe("menu: the check row opens the update-check window (Linux)", function()
	--- The About rows over a fake updater, with the bridge replaced by a recorder.
	local function check_row(opened)
		local recorded = { opens = {}, checks = 0 }
		local saved = package.loaded["ui.update_check.bridge"]
		package.loaded["ui.update_check.bridge"] = {
			open = function(ctx) recorded.opens[#recorded.opens + 1] = ctx; return opened end,
		}
		local real = require("modules.updater.manager")
		local fake = {
			CHANNELS = real.CHANNELS, TIMING = real.TIMING, INTERVAL_PRESETS = {},
			get_channel = function() return "dev" end,
			get_check_interval = function() return 3600 end,
			current_version = function() return "0.0.0-dev.133" end,
			get_menu_label = function() return "check" end,
			get_state = function() return "idle" end,
			get_cached_release = function() return nil end,
			check_for_updates = function(_, callback)
				recorded.checks = recorded.checks + 1
				callback(false, nil, nil)
				return true
			end,
		}
		local mb = helpers.load_module("ui.menu.menu_builder")
		local hooks = {
			on_menu_changed = function() end,
			on_update_finished = function() end,
			on_open_today_log = function() return true end,
			on_update_checked = function() recorded.notified = true end,
		}
		-- An installed build's rows: the checkout the suite runs from greys them.
		local Installation = require("infra.installation")
		local real_is_source_run = Installation.is_source_run
		Installation.is_source_run = function() return false end
		local built, rows = pcall(mb._about_update_rows, {
			updater = fake, on_menu_changed = hooks.on_menu_changed, on_update_finished = hooks.on_update_finished,
			on_open_today_log = hooks.on_open_today_log, on_update_checked = hooks.on_update_checked,
		})
		Installation.is_source_run = real_is_source_run
		if not built then error(rows, 0) end
		for _, row in ipairs(rows) do
			if row.label == "check" then row.action() end
		end
		package.loaded["ui.update_check.bridge"] = saved
		recorded.fake, recorded.hooks = fake, hooks
		return recorded
	end

	helpers.it("opens the window over the updater and the menu's hooks", function()
		local recorded = check_row(true)
		helpers.assert_eq(#recorded.opens, 1, "the click opens the update-check window")
		local ctx = recorded.opens[1]
		helpers.assert_true(ctx.updater == recorded.fake, "the window checks through the updater")
		helpers.assert_true(ctx.on_menu_changed == recorded.hooks.on_menu_changed)
		helpers.assert_true(ctx.on_update_finished == recorded.hooks.on_update_finished,
			"an install restarts the daemon through the menu's hook")
		helpers.assert_true(ctx.on_open_today_log == recorded.hooks.on_open_today_log)
		helpers.assert_eq(recorded.checks, 0, "the window runs the check, not the row")
		helpers.assert_nil(recorded.notified, "no notification when the window answers")
	end)

	helpers.it("notifies the answer only when the window cannot open", function()
		local recorded = check_row(false)
		helpers.assert_eq(recorded.checks, 1, "the check still runs")
		helpers.assert_true(recorded.notified == true, "the answer is notified instead")
	end)
end)
