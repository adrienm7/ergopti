--- tests/unit/modules/updater/test_updater_same_generation_responses.lua

--- ==============================================================================
--- MODULE: Updater Same-Generation Response Ordering Regression Tests
--- DESCRIPTION:
--- Exercises concurrent background responses within one poll generation and
--- prevents a later current request from downgrading an accepted release.
---
--- ROOT CAUSE ENCODED:
--- Generation fencing distinguishes channels and lifecycle epochs, but two
--- overlapping timer ticks share one generation. Without request ordering, an
--- older request that completes last can overwrite the newer request. Request
--- ordering alone is insufficient because a later valid request can still
--- return an older release, so accepted release versions must also be monotonic.
--- ==============================================================================

local helpers = require("tests.helpers")

local CHECK_INTERVAL_SEC = 60


--- Builds a logger spy that records rendered debug messages.
--- @param messages string[] Mutable message sink.
--- @return table logger Logger-compatible test double.
local function make_logger_spy(messages)
	local logger = helpers.make_logger_stub()
	logger.debug = function(_, format_string, ...)
		messages[#messages + 1] = string.format(format_string, ...)
	end
	return logger
end


--- Builds one minimal GitHub release response with the expected macOS asset.
--- @param tag string Semantic version tag.
--- @return string body JSON response body.
local function release_body(tag)
	return string.format(
		[[{"tag_name":"%s","body":"notes","assets":[{"name":"ErgoptiPlus.app.zip","browser_download_url":"https://example.test/%s.zip"}]}]],
		tag,
		tag
	)
end


--- Returns whether one rendered log message contains the literal needle.
--- @param messages string[] Rendered log messages.
--- @param needle string Literal substring.
--- @return boolean found Whether the substring was observed.
local function has_message(messages, needle)
	for _, message in ipairs(messages) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end


--- Loads a packaged updater with controllable timers and HTTP completions.
--- @return table updater Fresh updater module.
--- @return table requests Captured HTTP requests.
--- @return string[] messages Rendered debug messages.
--- @return table notifications Mutable notification count.
local function fresh_updater()
	local requests = {}
	local messages = {}
	local notifications = { count = 0 }
	package.loaded["infra.logger"] = make_logger_spy(messages)
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.network_info"] = {
		isInternetReachable = function() return true end,
		hasInternetProbeResult = function() return false end,
	}
	package.loaded["adapters.notifier"] = {
		send = function()
			notifications.count = notifications.count + 1
		end,
	}

	local updater = helpers.load_with_stubs("modules.updater", {
		processInfo = { bundleID = "com.ergopti.app", version = "1.0.0" },
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
	return updater, requests, messages, notifications
end


helpers.describe("updater: same-generation response ordering", function()

	helpers.it("same-generation updater responses keep the newest request and never downgrade cache", function()
		local updater, requests, messages, notifications = fresh_updater()
		local menu_updates = 0
		helpers.assert_eq(updater.start_background_checks("stable", CHECK_INTERVAL_SEC, function()
			menu_updates = menu_updates + 1
		end), true)

		local recurring_timer = nil
		local boot_timer = nil
		for _, timer in ipairs(_G.hs.timer.__timers) do
			if timer.delay == CHECK_INTERVAL_SEC then
				recurring_timer = timer
			elseif timer.delay == updater.BOOT_CHECK_DELAY_SEC then
				boot_timer = timer
			end
		end
		helpers.assert_true(recurring_timer ~= nil, "the recurring poll timer must be owned")
		helpers.assert_true(boot_timer ~= nil, "the boot poll timer must be owned")

		boot_timer:fire()
		recurring_timer:fire()
		helpers.assert_eq(#requests, 2, "two overlapping requests must be captured")

		requests[1].callback(200, release_body("v2.0.0"), { ETag = "etag-v2" })
		helpers.assert_eq(updater.get_cached_release().tag, "v2.0.0",
			"a valid response must not be lost only because a newer request is pending")
		requests[2].callback(200, release_body("v3.0.0"), { ETag = "etag-v3" })
		helpers.assert_eq(updater.get_cached_release().tag, "v3.0.0",
			"the newest request must publish its release")

		recurring_timer:fire()
		recurring_timer:fire()
		helpers.assert_eq(#requests, 4, "a second overlapping pair must be captured")
		requests[4].callback(200, release_body("v4.0.0"), { ETag = "etag-v4" })
		requests[4].callback(200, release_body("v4.0.0"), { ETag = "etag-v4-duplicate" })
		requests[3].callback(200, release_body("v5.0.0"), { ETag = "etag-v5" })
		helpers.assert_eq(updater.get_cached_release().tag, "v4.0.0",
			"an older same-generation request must not overwrite the newest request")

		recurring_timer:fire()
		helpers.assert_eq(#requests, 5, "a later current request must still run")
		helpers.assert_eq(requests[5].headers["If-None-Match"], "etag-v4",
			"a stale response must not overwrite the accepted ETag")
		requests[5].callback(200, release_body("v3.0.0"), { ETag = "etag-v3-later" })
		helpers.assert_eq(updater.get_cached_release().tag, "v4.0.0",
			"a current response must not downgrade the accepted release version")

		recurring_timer:fire()
		recurring_timer:fire()
		helpers.assert_eq(#requests, 7, "the failure-order control must capture another pair")
		helpers.assert_eq(requests[6].headers["If-None-Match"], "etag-v4",
			"a refused downgrade must not publish its ETag")
		requests[7].callback(500, "", {})
		requests[6].callback(200, release_body("v5.0.0"), { ETag = "etag-v5" })
		helpers.assert_eq(updater.get_cached_release().tag, "v5.0.0",
			"a newer HTTP failure must not discard an older valid in-flight response")
		recurring_timer:fire()
		helpers.assert_eq(requests[8].headers["If-None-Match"], "etag-v5",
			"only the valid monotonic response may publish the next conditional ETag")
		helpers.assert_eq(menu_updates, 4,
			"only the additional valid v5 response may rebuild the menu")
		helpers.assert_eq(notifications.count, 4,
			"only the additional valid v5 response may notify the user")
		helpers.assert_true(
			has_message(messages, "request 3 superseded by response 4 in generation 1"),
			"the stale log must report request ordering rather than a false generation mismatch")
		helpers.assert_true(
			has_message(messages, "duplicate response discarded (request 4 in generation 1)"),
			"a duplicate callback must be rejected with its real request identity")
		helpers.assert_true(
			has_message(messages, "older release v3.0.0 refused after v4.0.0"),
			"the downgrade guard must identify both release versions")

		helpers.assert_eq(updater.stop_background_checks(), true)
	end)

end)
