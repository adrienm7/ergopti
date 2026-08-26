--- tests/unit/modules/updater/test_updater_install_ownership.lua

--- ==============================================================================
--- MODULE: Updater Install Ownership Regression Tests
--- DESCRIPTION:
--- Proves that a background response cannot overwrite an active one-click
--- installation state and expose a second install action.
---
--- ROOT CAUSE ENCODED:
--- Background requests may start before the user begins an install and complete
--- while the bundle swap is in progress. The poll completion and the menu flow
--- must share one exact install owner; a poll generation only identifies the
--- background-check lifecycle and cannot authorize install-state transitions.
--- ==============================================================================

local helpers = require("tests.helpers")

local CHECK_INTERVAL_SEC = 60
local DIGEST = string.rep("a", 64)


--- Builds one valid GitHub release response for the macOS install asset.
--- @param tag string Release tag.
--- @return string body JSON response body.
local function release_body(tag)
	return string.format(
		[[{"tag_name":"%s","body":"notes","assets":[{"name":"ErgoptiPlus.app.zip","browser_download_url":"https://github.com/adrienm7/ergopti/releases/download/%s/ErgoptiPlus.app.zip","digest":"sha256:%s"}]}]],
		tag,
		tag,
		DIGEST
	)
end


--- Builds one validated release record without parsing JSON.
--- @param tag string Release tag.
--- @return table release Installable release metadata.
local function install_release(tag)
	return {
		tag = tag,
		zip_url = "https://github.com/adrienm7/ergopti/releases/download/"
			.. tag .. "/ErgoptiPlus.app.zip",
		sha256 = DIGEST,
	}
end


--- Loads the real updater with controllable background HTTP completions.
--- @return table updater Fresh updater module.
--- @return table requests Captured HTTP requests.
--- @return table notifications Mutable notification count.
local function fresh_updater()
	local requests = {}
	local notifications = { count = 0 }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.network_info"] = {
		isInternetReachable = function() return true end,
		hasInternetProbeResult = function() return false end,
	}
	package.loaded["adapters.notifier"] = {
		send = function() notifications.count = notifications.count + 1 end,
	}

	local updater = helpers.load_with_stubs("modules.updater", {
		processInfo = {
			bundleID = "com.ergopti.app",
			bundlePath = "/Applications/ErgoptiPlus.app",
			version = "1.0.0",
		},
		fs = { temporaryDirectory = function() return "/tmp/" end },
		http = {
			asyncGet = function(url, headers, callback)
				requests[#requests + 1] = {
					url = url,
					headers = headers,
					callback = callback,
				}
			end,
		},
	})
	return updater, requests, notifications
end


helpers.describe("updater: install ownership", function()

	helpers.it("keeps installing authoritative when an older background request completes (HS-040)", function()
		local updater, requests = fresh_updater()
		local menu_updates = 0
		helpers.assert_eq(updater.start_background_checks("main", CHECK_INTERVAL_SEC, function()
			menu_updates = menu_updates + 1
		end), true)

		local boot_timer = nil
		for _, timer in ipairs(_G.hs.timer.__timers) do
			if timer.delay == updater.BOOT_CHECK_DELAY_SEC then boot_timer = timer end
		end
		helpers.assert_true(boot_timer ~= nil, "the boot poll must be owned")
		boot_timer:fire()
		helpers.assert_eq(#requests, 1, "the pre-install background request must be captured")

		local install_token = updater.begin_install()
		helpers.assert_type(install_token, "table", "the menu flow must acquire an exact install owner")
		requests[1].callback(200, release_body("v2.0.0"), { ETag = "install-race" })

		helpers.assert_eq(updater.get_update_state(), "installing",
			"a background completion must not expose a second install while the first owns the bundle swap")
		helpers.assert_eq(menu_updates, 0,
			"an unchanged install label must not be rebuilt as an available action")
		helpers.assert_eq(updater.clear_cached_release(), false,
			"cache invalidation must not release an unrelated install owner")
		helpers.assert_eq(updater.get_update_state(), "installing")
		helpers.assert_eq(updater.set_update_state("idle"), false,
			"a non-owner must not clear installing while the bundle swap is active")
		local competing_token = updater.begin_install()
		helpers.assert_eq(competing_token, nil, "a second install owner must be refused")
		helpers.assert_eq(updater.finish_install(install_token, "available"), true,
			"the exact owner must commit its terminal state")
		helpers.assert_eq(updater.get_update_state(), "available")
		helpers.assert_eq(updater.stop_background_checks(), true)
	end)

	helpers.it("does not let a stale install token settle its successor (HS-040)", function()
		local updater = fresh_updater()
		local first = updater.begin_install()
		helpers.assert_type(first, "table")
		helpers.assert_eq(updater.finish_install(first, "idle"), true)

		local successor = updater.begin_install()
		helpers.assert_type(successor, "table")
		helpers.assert_true(successor ~= first, "each install must receive a unique identity")
		helpers.assert_eq(updater.finish_install(first, "available"), false,
			"a stale completion must not release the current install")
		helpers.assert_eq(updater.get_update_state(), "installing")
		helpers.assert_eq(updater.finish_install(successor, "idle"), true)
	end)

	helpers.it("lets the real menu dispatch only one install across a poll completion (HS-040)", function()
		local updater, requests = fresh_updater()
		helpers.assert_eq(updater.start_background_checks("main", CHECK_INTERVAL_SEC, function() end), true)

		local boot_timer = nil
		for _, timer in ipairs(_G.hs.timer.__timers) do
			if timer.delay == updater.BOOT_CHECK_DELAY_SEC then boot_timer = timer end
		end
		helpers.assert_true(boot_timer ~= nil)
		boot_timer:fire()
		helpers.assert_eq(#requests, 1, "the older poll request must remain in flight")

		helpers.assert_eq(updater.set_cached_release(install_release("v2.0.0")), true)
		helpers.assert_eq(updater.set_update_state("available"), true)
		package.loaded["infra.dialog_util"] = { block_alert = function() end }
		package.loaded["ui.changelog"] = { open = function() end }
		package.loaded["infra.manifest_menu"] = {
			build = function(_, _, _, _, _, providers) return providers.about_updates() end,
		}
		package.loaded["adapters.crypto"] = { sha256_bytes = function() return DIGEST end }
		package.loaded["adapters.task_lifecycle"] = {
			native = function() error("the pending download must not reach extraction", 0) end,
			start = function() return false end,
		}
		package.loaded["ui.menu.menu_about"] = nil
		local about = require("ui.menu.menu_about")
		local built = about.build({
			state = { update_channel = "main", update_check_interval_seconds = CHECK_INTERVAL_SEC },
			updateMenu = function() end,
		})
		local update_action = nil
		local expected_label = updater.get_update_menu_label()
		for _, row in ipairs(built.submenu) do
			if row.label == expected_label and type(row.action) == "function" then
				update_action = row.action
			end
		end
		helpers.assert_type(update_action, "function", "the real update action must be rendered")

		update_action()
		helpers.assert_eq(updater.get_update_state(), "installing")
		helpers.assert_eq(#requests, 2, "the first click must dispatch one archive download")

		requests[1].callback(200, release_body("v3.0.0"), { ETag = "during-install" })
		helpers.assert_eq(updater.get_update_state(), "installing",
			"the in-flight poll must not reopen the update action")
		update_action()
		helpers.assert_eq(#requests, 2,
			"re-entering the original menu closure must not dispatch a second archive download")

		requests[2].callback(500, nil, {})
		helpers.assert_eq(updater.get_update_state(), "available",
			"the exact download owner must remain able to settle after the race")
		helpers.assert_eq(updater.stop_background_checks(), true)
	end)

	helpers.it("restores availability before suppressing a repeated notification", function()
		local updater, requests, notifications = fresh_updater()
		local menu_updates = 0
		helpers.assert_eq(updater.start_background_checks("main", CHECK_INTERVAL_SEC, function()
			menu_updates = menu_updates + 1
		end), true)

		local boot_timer = nil
		local recurring_timer = nil
		for _, timer in ipairs(_G.hs.timer.__timers) do
			if timer.delay == updater.BOOT_CHECK_DELAY_SEC then
				boot_timer = timer
			elseif timer.delay == CHECK_INTERVAL_SEC then
				recurring_timer = timer
			end
		end
		helpers.assert_true(boot_timer ~= nil and recurring_timer ~= nil,
			"both background owners must be available to drive repeated responses")

		boot_timer:fire()
		requests[1].callback(200, release_body("v2.0.0"), { ETag = "first" })
		helpers.assert_eq(updater.get_update_state(), "available")
		helpers.assert_eq(menu_updates, 1)
		helpers.assert_eq(notifications.count, 1)

		helpers.assert_eq(updater.clear_cached_release(), true)
		recurring_timer:fire()
		helpers.assert_eq(#requests, 2)
		requests[2].callback(200, release_body("v2.0.0"), { ETag = "repeat" })
		helpers.assert_eq(updater.get_update_state(), "available",
			"the repeated-notification guard must not suppress availability")
		helpers.assert_eq(menu_updates, 2,
			"the repeated release must restore the update action")
		helpers.assert_eq(notifications.count, 1,
			"the repeated release must not duplicate the notification")
		helpers.assert_eq(updater.stop_background_checks(), true)
	end)

end)
