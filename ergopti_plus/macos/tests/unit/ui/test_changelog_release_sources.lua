--- tests/unit/ui/test_changelog_release_sources.lua

--- ==============================================================================
--- MODULE: Changelog Bounded Release Sources
--- DESCRIPTION:
--- On a corporate network api.github.com can be blocked or held open by a proxy
--- while github.com works. Each request must be bounded by a deadline, a failed
--- API must fall back to the public releases Atom feed, and an exhausted fetch
--- must publish a translated error instead of leaving the window spinning.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

local FIXTURE_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]") or ".")
local FEED_PATH = FIXTURE_DIR .. "/../../../../_shared/tests/corpus/updater/releases_feed.atom"
local API_URL = "https://api.github.com/repos/adrienm7/ergopti/releases?per_page=20"
local FEED_URL = "https://github.com/adrienm7/ergopti/releases.atom"

--- Reads the shared fixture feed.
--- @return string
local function feed()
	local handle = assert(io.open(FEED_PATH, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Opens a ready changelog and requests one channel.
local function start(window, post, channel)
	hs.json.decode = json.decode
	helpers.assert_true(window.open({ channel = channel }))
	post("ready")
	post({ action = "fetch", channel = channel })
end

helpers.describe("changelog: bounded release sources", function()
	helpers.it("requests the shared API URL with a deadline from the shared defaults", function()
		with_changelog(function(window, state, post)
			start(window, post, "main")
			helpers.assert_eq(#state.urls_requested, 1)
			helpers.assert_eq(state.urls_requested[1].url, API_URL)
			helpers.assert_eq(state.urls_requested[1].headers["User-Agent"], "ErgoptiPlus-Changelog/1.0")
			helpers.assert_eq(#state.deadlines, 1, "every request must arm a deadline")
			helpers.assert_eq(state.deadlines[1].seconds, 15)
		end)
	end)

	helpers.it("falls back to the Atom feed when the API never answers", function()
		with_changelog(function(window, state, post)
			start(window, post, "dev")
			state.deadlines[1].callback()
			helpers.assert_eq(#state.urls_requested, 2, "a timed-out API must try the feed")
			helpers.assert_eq(state.urls_requested[2].url, FEED_URL)
			helpers.assert_eq(#state.deadlines, 2, "the feed request must be bounded too")
			state.callbacks[1](200, "[]", {})
			helpers.assert_eq(#state.evaluations, 0, "a late API answer must be ignored after its deadline")
			local text = feed()
			state.callbacks[2](200, text, {})
			helpers.assert_eq(#state.evaluations, 1)
			local script = state.evaluations[1]
			helpers.assert_true(script:find("^injectReleasesFeed%(\"<%?xml") ~= nil,
				"the feed must reach the page reader as a string")
			helpers.assert_true(script:find(',"dev")', 1, true) ~= nil)
			helpers.assert_true(script:find("releases/tag/v0.0.0-dev.130", 1, true) ~= nil)
			helpers.assert_eq(script:find("\n", 1, true), nil, "the feed text must be escaped into one JS literal")
		end)
	end)

	helpers.it("treats a negative hs.http status as a network failure", function()
		with_changelog(function(window, state, post)
			start(window, post, "main")
			state.callbacks[1](-1, "The Internet connection appears to be offline.", {})
			helpers.assert_eq(#state.urls_requested, 2)
			state.callbacks[2](-1, "offline", {})
			helpers.assert_eq(#state.evaluations, 1)
			helpers.assert_true(state.evaluations[1]:find('injectError("changelog_window.error_network")', 1, true) ~= nil)
		end)
	end)

	helpers.it("reports a GitHub rate limit when the feed cannot replace it", function()
		with_changelog(function(window, state, post)
			start(window, post, "main")
			state.callbacks[1](403, "", {})
			state.deadlines[2].callback()
			helpers.assert_eq(#state.evaluations, 1)
			helpers.assert_true(state.evaluations[1]:find("changelog_window.error_rate_limited", 1, true) ~= nil)
		end)
	end)

	helpers.it("never publishes a superseded feed result", function()
		with_changelog(function(window, state, post)
			start(window, post, "dev")
			state.callbacks[1](500, "", {})
			post({ action = "fetch", channel = "main" })
			state.callbacks[2](200, feed(), {})
			helpers.assert_eq(#state.evaluations, 0, "the dev feed must not overwrite the newer stable request")
			state.callbacks[3](200, "[]", {})
			helpers.assert_eq(#state.evaluations, 1)
			helpers.assert_true(state.evaluations[1]:find('"main"', 1, true) ~= nil)
		end)
	end)
end)
