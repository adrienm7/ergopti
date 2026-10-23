--- modules/updater/feed_handoff.lua

--- ==============================================================================
--- MODULE: Feed-Only Release Hand-Off To Sparkle (macOS)
--- DESCRIPTION:
--- When the GitHub API gives the Versions window no list, the window reads the
--- releases Atom feed, which names no files and no digests: this driver cannot
--- verify a download from it. Sparkle can, against the EdDSA signature of the
--- channel's appcast, which carries that channel's newest release only. This
--- module is the window's one route to Sparkle for that release.
---
--- FEATURES & RATIONALE:
--- 1. Narrow owner: the only file the Versions window reaches the launcher
---    through, so every file that asks Sparkle for an update keeps owning no
---    install primitive (tests/unit/ui/menu/metrics_and_about/
---    test_menu_about_sparkle_ownership.lua) while the window keeps its own
---    verified install path.
--- 2. Newest only: newest_offered() names the one tag Sparkle would install
---    for a channel, by the shared registry's latest pick and offer rule; any
---    other row of a feed-only list stays refused.
--- 3. Sparkle asks the user: request() only selects the channel's appcast and
---    starts Sparkle's check, whose own dialog installs or not.
--- ==============================================================================

local M = {}

local UpdateLauncher = require("adapters.update_launcher")
local VersionOrder = require("updater.version")

--- The tag of a feed-only list that Sparkle would install for a channel: the
--- channel's newest tag, when the shared offer rule offers it.
--- @param registry table updater.channels interpreter.
--- @param tags table Feed tags, newest first.
--- @param channel string Registry channel id on screen.
--- @param current string Installed build version.
--- @param installed string Registry channel of the installed build.
--- @return string|nil tag
function M.newest_offered(registry, tags, channel, current, installed)
	if type(tags) ~= "table" then return nil end
	local best = registry.pick_latest(tags, channel)
	local newest = best and tags[best] or nil
	if not newest or not registry.should_offer(newest, current, channel, installed) then return nil end
	return newest
end

--- Whether a posted tag is the one newest_offered() names.
--- @param tag string Posted tag.
--- @param newest string|nil Result of newest_offered().
--- @return boolean
function M.is_newest(tag, newest)
	return type(tag) == "string" and newest ~= nil
		and VersionOrder.normalize_tag(tag) == VersionOrder.normalize_tag(newest)
end

--- Selects the channel's appcast and starts Sparkle's check, which verifies the
--- release's signature and asks the user before installing.
--- @param channel string Registry channel id.
--- @return boolean sent True when the launcher accepted the command.
function M.request(channel)
	return UpdateLauncher.request_check(channel) == true
end

return M
