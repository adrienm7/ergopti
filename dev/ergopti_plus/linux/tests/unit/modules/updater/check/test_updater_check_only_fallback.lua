--- tests/unit/modules/updater/check/test_updater_check_only_fallback.lua

--- ==============================================================================
--- MODULE: Check-Only Fallback When The GitHub API Is Blocked (Linux)
--- DESCRIPTION:
--- Corporate proxies commonly block or throttle api.github.com while github.com
--- stays reachable, and the anonymous quota is 60 requests an hour. The update
--- check used to fail in both cases (macOS already read the public Atom feed).
--- It now reads the feed and announces the newer release, flagged check-only:
--- the feed names no asset and no digest, so nothing is downloaded from it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local FEED_PATH = helpers.driver_root() .. "/../_shared/tests/corpus/updater/releases_feed.atom"

local function read_feed()
	local handle = assert(io.open(FEED_PATH, "rb"), "cannot open the feed fixture")
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Loads a fresh manager over a Storage fake, as the installed build of channel main.
local function boot(current)
	local previous_storage, previous_manager = package.loaded["adapters.storage"], package.loaded["modules.updater.manager"]
	package.loaded["adapters.storage"] = Fakes.storage({ initial = {} })
	package.loaded["modules.updater.manager"] = nil
	local ok, manager = pcall(require, "modules.updater.manager")
	package.loaded["adapters.storage"], package.loaded["modules.updater.manager"] = previous_storage, previous_manager
	helpers.assert_true(ok and type(manager) == "table", tostring(manager))
	manager.current_version = function() return current end
	manager.installed_channel = function() return "main" end
	return manager
end

--- Scripts the transport: the API answers api_result for every page, the feed feed_result.
--- Returns the list of requested URLs.
local function script(manager, api_result, feed_result)
	local urls = {}
	manager._http_client = require("tests.support.release_http_fixture").attach({
		get = function(url, _, _, callback)
			urls[#urls + 1] = url
			if url:find("api.github.com", 1, true) then callback(api_result) else callback(feed_result) end
			return true
		end,
		cancel = function() return true end,
	})
	return urls
end

local function check(manager)
	local answer = {}
	manager.check_for_updates("main", function(available, release, err, result)
		answer = { available = available, release = release, err = err, result = result }
	end)
	return answer
end

helpers.describe("updater (linux): the check falls back on the public feed", function()

	helpers.it("check-only: a blocked API still announces the newer release", function()
		local manager = boot("2.3.0")
		local urls = script(manager, { ok = false, status = 0, body = "", error = "proxy refused" },
			{ ok = true, status = 200, body = read_feed() })
		local answer = check(manager)
		helpers.assert_eq(answer.result.state, "available")
		helpers.assert_eq(answer.result.latest, "v2.4.0")
		helpers.assert_eq(answer.result.check_only, true, "the page must not offer an install")
		helpers.assert_eq(answer.available, true)
		helpers.assert_eq(answer.release.check_only, true)
		helpers.assert_eq(answer.release.download_url, "", "nothing installable was named")
		helpers.assert_eq(manager.get_state(), "available")
		helpers.assert_true(urls[#urls]:find("github.com/adrienm7/ergopti/releases.atom", 1, true) ~= nil
			or urls[#urls]:find("atom", 1, true) ~= nil, "the last request was the feed: " .. tostring(urls[#urls]))
	end)

	helpers.it("check-only: an exhausted quota (HTTP 403) falls back too", function()
		local manager = boot("2.3.0")
		script(manager, { ok = false, status = 403, body = "", error = "HTTP 403",
			rate_limit = { remaining = "0", reset = "1700000000" } }, { ok = true, status = 200, body = read_feed() })
		local answer = check(manager)
		helpers.assert_eq(answer.result.state, "available")
		helpers.assert_eq(answer.result.check_only, true)
	end)

	helpers.it("check-only: an up-to-date build is told so, not offered anything", function()
		local manager = boot("2.4.0")
		script(manager, { ok = false, status = 0, body = "", error = "proxy refused" },
			{ ok = true, status = 200, body = read_feed() })
		local answer = check(manager)
		helpers.assert_eq(answer.result.state, "up_to_date")
		helpers.assert_nil(answer.result.check_only)
		helpers.assert_nil(manager.get_cached_release())
	end)

	helpers.it("check-only: both sources failing is one network failure naming both", function()
		local manager = boot("2.3.0")
		script(manager, { ok = false, status = 0, body = "", error = "proxy refused" },
			{ ok = false, status = 0, body = "", error = "feed refused" })
		local answer = check(manager)
		helpers.assert_eq(answer.result.state, "error")
		helpers.assert_eq(answer.result.reason_key, "updater.no_connection")
		helpers.assert_true(answer.result.detail:find("proxy refused", 1, true) ~= nil
			and answer.result.detail:find("feed refused", 1, true) ~= nil, answer.result.detail)
		helpers.assert_eq(manager.get_state(), "idle")
	end)

	helpers.it("check-only: a proxy page served as the feed is refused", function()
		local manager = boot("2.3.0")
		script(manager, { ok = false, status = 0, body = "", error = "proxy refused" },
			{ ok = true, status = 200, body = "<html>blocked by policy</html>" })
		local answer = check(manager)
		helpers.assert_eq(answer.result.state, "error")
		helpers.assert_true(answer.result.detail:find("Atom", 1, true) ~= nil, answer.result.detail)
	end)

end)
