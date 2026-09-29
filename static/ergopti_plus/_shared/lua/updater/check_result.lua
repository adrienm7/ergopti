--- _shared/lua/updater/check_result.lua

--- ==============================================================================
--- MODULE: Manual Update Check Result (Shared Lua)
--- DESCRIPTION:
--- Turns one release list into the answer the update-check window shows for a
--- manual check on macOS and Linux: the checked channel has a release to offer,
--- is up to date, or has no release yet; plus every other channel whose latest
--- release was published after the installed build. A failed check becomes the
--- same table with a localized reason.
---
--- FEATURES & RATIONALE:
--- 1. One classification for both Lua drivers: the offer rule, the channel's
---    latest release and the other-channel notices all come from the shared
---    registry interpreter (updater.channels), whose vectors every port replays.
--- 2. PURE Lua (LuaJIT and 5.4): no driver imports, no io, no OS calls. The
---    driver passes the list body, its registry and its versions.
--- 3. The result carries ids, versions and locale keys only; the page composes
---    the sentences in the menu language.
--- ==============================================================================

local Parser = require("updater.release_parser")

local M = {}

-- The phases a result may carry, as the page (_shared/ui/update_check) knows them
M.STATES = { up_to_date = true, available = true, no_release = true, error = true }

-- The reasons a failed check may give, as locale keys the page translates
M.REASONS = {
	no_connection = "updater.no_connection",
	parse_failed  = "updater.parse_failed",
	unexpected    = "update_check.error_unexpected",
	no_asset      = "update_check.error_no_asset",
}

--- Classifies one release list for a manual check of one channel.
--- @param body string Raw GitHub releases array JSON.
--- @param opts table { registry, channel, current, installed }: the channel
---   interpreter, the checked channel, the installed version and its channel.
--- @return table result { state, channel, current, latest?, release?, others }
---   where release is the JSON object of the offered or latest release.
function M.classify(body, opts)
	local registry = opts.registry
	local chunks = Parser.split_releases_array(body)
	local tags, releases = {}, {}
	for index, chunk in ipairs(chunks) do
		tags[index] = Parser.parse_tag(chunk)
		releases[index] = { tag = tags[index], published_at = Parser.parse_published_at(chunk) }
	end
	local result = {
		channel = opts.channel,
		current = opts.current,
		others  = registry.newer_elsewhere(releases, opts.channel, opts.current),
	}
	local best = registry.pick_latest(tags, opts.channel)
	if not best then
		result.state = "no_release"
		return result
	end
	result.latest = tags[best]
	result.release = chunks[best]
	if registry.should_offer(tags[best], opts.current, opts.channel, opts.installed) then
		result.state = "available"
	else
		result.state = "up_to_date"
	end
	return result
end

--- Builds the result of a check that failed.
--- @param opts table { channel, current, latest? }: latest names the release
---   a reason is about (no_asset).
--- @param reason string One of the M.REASONS names.
--- @param detail any The English cause, for the log and the report.
--- @return table result { state = "error", channel, current, latest?, others, reason_key, detail }
function M.failure(opts, reason, detail)
	local key = M.REASONS[reason]
	if not key then error("unknown update-check failure reason: " .. tostring(reason), 2) end
	return {
		state      = "error",
		channel    = opts.channel,
		current    = opts.current,
		latest     = opts.latest,
		others     = {},
		reason_key = key,
		detail     = tostring(detail),
	}
end

return M
