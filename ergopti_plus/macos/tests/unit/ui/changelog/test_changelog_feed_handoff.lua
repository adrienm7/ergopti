--- macos/tests/unit/ui/changelog/test_changelog_feed_handoff.lua

--- ==============================================================================
--- MODULE: Versions Window Feed-Only Hand-Off To Sparkle (macOS)
--- DESCRIPTION:
--- When the GitHub API gives no list, the Versions window lists the releases
--- Atom feed, which names no files and no digests: a direct install is refused
--- with the no-details warning. The page then offers the channel's newest
--- release through install_through_updater, and the real window controller
--- hands that channel to Sparkle (adapters/update_launcher.lua), which checks
--- the EdDSA signature of its appcast and asks the user. These cases drive the
--- real bridge callback and the real modules/updater/feed_handoff.lua over a
--- fetched feed (sparkle-handoff-2026-10-22).
---
--- ROOT CAUSE ENCODED:
--- Sparkle installs its channel's newest release only, so a hand-off of any
--- other tag would install something else than the row the user clicked. The
--- host must check the tag against the feed it read, and never reach Sparkle
--- for an API list (whose digests the direct install verifies) or a refusal.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

-- The feed of a stable release published after the newest dev build.
local FEED_TAGS = { "v1.4.0", "v0.0.0-dev.142", "v1.3.0", "v0.0.0-dev.141", "v0.0.0-dev.140" }

--- An Atom feed of FEED_TAGS on the repository the shared defaults name.
--- @return string
local function feed()
	local entries = {}
	for index, tag in ipairs(FEED_TAGS) do
		entries[#entries + 1] = string.format('<entry><updated>2026-10-%02dT10:00:00Z</updated>'
			.. '<link rel="alternate" type="text/html" href="https://github.com/adrienm7/ergopti/releases/tag/%s"/>'
			.. '<title>%s</title></entry>', 20 - index, tag, tag)
	end
	return '<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom">\n'
		.. table.concat(entries, "\n") .. "\n</feed>\n"
end

--- Stubbed owners around the real hand-off module; its launcher records every
--- Sparkle check it is asked for.
--- @param opts table { current, sent = false }
--- @return table deps, table checks
local function owners(opts)
	opts = opts or {}
	local checks = {}
	local previous = package.loaded["adapters.update_launcher"]
	package.loaded["adapters.update_launcher"] = {
		request_check = function(channel)
			checks[#checks + 1] = channel
			return opts.sent ~= false
		end,
	}
	package.loaded["modules.updater.feed_handoff"] = nil
	local handoff = require("modules.updater.feed_handoff")
	package.loaded["modules.updater.feed_handoff"] = nil
	package.loaded["adapters.update_launcher"] = previous
	return {
		updater = {
			is_local_source = function() return false end,
			current_version = function() return opts.current or "0.0.0-dev.140" end,
			installed_channel = function() return "dev" end,
		},
		backup = { owner = function() return { latest = function() return nil end } end },
		installer = {},
		coordinator = {},
		handoff = handoff,
	}, checks
end

--- Opens the window on dev and answers its fetch with the feed after the API failed.
local function open_on_feed(changelog, state, post, deps)
	changelog._deps = deps
	helpers.assert_true(changelog.open({ channel = "dev" }))
	post("ready")
	post({ action = "fetch", channel = "dev" })
	state.callbacks[#state.callbacks](403, "", {})
	state.callbacks[#state.callbacks](200, feed(), {})
	local fed = false
	for _, code in ipairs(state.evaluations) do
		if code:find("injectReleasesFeed(", 1, true) then fed = true end
	end
	helpers.assert_true(fed, "the API failure must fall back to the feed")
end

--- The last install message the page received, or "".
local function last_install_message(state)
	for index = #state.evaluations, 1, -1 do
		local code = state.evaluations[index]
		if code:find("setInstallProgress(", 1, true) then return code end
	end
	return ""
end

helpers.describe("Versions window feed-only hand-off to Sparkle (macOS)", function()
	helpers.it("seeds the page with the hand-off it can offer", function()
		with_changelog(function(changelog, state)
			changelog._deps = owners()
			helpers.assert_true(changelog.open({ channel = "dev" }))
			helpers.assert_true(state.view.options.html_string:find(
				"window.__feed_install_handoff=true;", 1, true) ~= nil)
		end)
	end)

	helpers.it("hands the channel's newest feed release to Sparkle on its channel", function()
		with_changelog(function(changelog, state, post)
			local deps, checks = owners()
			open_on_feed(changelog, state, post, deps)
			post({ action = "install_through_updater", tag = "v0.0.0-dev.142", channel = "dev" })
			helpers.assert_eq(table.concat(checks, ","), "dev", "Sparkle checks the dev appcast once")
			local message = last_install_message(state)
			helpers.assert_true(message:find('"phase":"handed_off"', 1, true) ~= nil, message)
			helpers.assert_true(message:find('"tag":"v0.0.0-dev.142"', 1, true) ~= nil, message)
		end)
	end)

	helpers.it("never hands an older release, nor another channel's tag, to Sparkle", function()
		with_changelog(function(changelog, state, post)
			local deps, checks = owners()
			open_on_feed(changelog, state, post, deps)
			for _, tag in ipairs({ "v0.0.0-dev.141", "v0.0.0-dev.140", "v1.4.0" }) do
				post({ action = "install_through_updater", tag = tag, channel = "dev" })
				local message = last_install_message(state)
				helpers.assert_true(message:find('"phase":"failed"', 1, true) ~= nil, tag .. ": " .. message)
				helpers.assert_true(message:find("changelog_window.install_error_no_details", 1, true) ~= nil,
					tag .. " keeps the existing warning: " .. message)
			end
			helpers.assert_eq(#checks, 0, "Sparkle installs its newest release only: it is never asked")
		end)
	end)

	helpers.it("offers a switch of channel that channel's newest release", function()
		with_changelog(function(changelog, state, post)
			local deps, checks = owners()
			open_on_feed(changelog, state, post, deps)
			post({ action = "install_through_updater", tag = "v1.3.0", channel = "main" })
			helpers.assert_eq(#checks, 0, "v1.3.0 is not the newest stable release")
			post({ action = "install_through_updater", tag = "v1.4.0", channel = "main" })
			helpers.assert_eq(table.concat(checks, ","), "main")
		end)
	end)

	helpers.it("refuses when the installed build is already the channel's newest", function()
		with_changelog(function(changelog, state, post)
			local deps, checks = owners({ current = "0.0.0-dev.142" })
			open_on_feed(changelog, state, post, deps)
			post({ action = "install_through_updater", tag = "v0.0.0-dev.142", channel = "dev" })
			helpers.assert_eq(#checks, 0)
			helpers.assert_true(last_install_message(state):find('"phase":"failed"', 1, true) ~= nil)
		end)
	end)

	helpers.it("reports a hand-off the launcher did not take", function()
		with_changelog(function(changelog, state, post)
			local deps, checks = owners({ sent = false })
			open_on_feed(changelog, state, post, deps)
			post({ action = "install_through_updater", tag = "v0.0.0-dev.142", channel = "dev" })
			helpers.assert_eq(#checks, 1)
			local message = last_install_message(state)
			helpers.assert_true(message:find('"phase":"failed"', 1, true) ~= nil, message)
			helpers.assert_true(message:find("changelog_window.install_error_handoff", 1, true) ~= nil, message)
		end)
	end)

	helpers.it("never reaches Sparkle for an API list, whose digests install directly", function()
		with_changelog(function(changelog, state, post)
			local deps, checks = owners()
			changelog._deps = deps
			helpers.assert_true(changelog.open({ channel = "dev" }))
			post("ready")
			post({ action = "fetch", channel = "dev" })
			state.callbacks[#state.callbacks](200, state.dev_body, {})
			post({ action = "install_through_updater", tag = "dev-release", channel = "dev" })
			helpers.assert_eq(#checks, 0)
			helpers.assert_true(last_install_message(state):find(
				"changelog_window.install_error_unknown_release", 1, true) ~= nil)
		end)
	end)
end)
