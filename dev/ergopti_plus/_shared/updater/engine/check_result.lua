--- _shared/updater/engine/check_result.lua

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
--- 4. A check that reached no list names its cause when the evidence proves
---    one (UPD-06): an exhausted GitHub rate limit, or a network cause the
---    shared managed-network contract classified from a native receipt (proxy,
---    offline, certificate, a blocked host). The Windows host applies the same
---    rule (ui/update_check/init.ahk UpdateCheck_FailureKey), both replaying
---    _shared/tests/corpus/updater/check_session_vectors.json failure_reasons.
--- ==============================================================================

local Parser = require("updater.engine.release_parser")

local M = {}

-- The phases a result may carry, as the page (_shared/ui/update_check) knows them
M.STATES = { up_to_date = true, available = true, no_release = true, error = true }

-- The reasons a failed check may give, as locale keys the page translates
M.REASONS = {
	no_connection = "updater.no_connection",
	parse_failed  = "updater.parse_failed",
	unexpected    = "update_check.error_unexpected",
	no_asset      = "update_check.error_no_asset",
	rate_limited  = "update_check.error_rate_limited",
}

-- The reason keys a failed answer may carry besides a classified network cause
local REASON_KEYS = {}
for _, key in pairs(M.REASONS) do REASON_KEYS[key] = true end

--- Whether a key is a network cause's message of the managed-network contract.
--- @param key any
--- @return boolean
local function network_message_key(key)
	return type(key) == "string" and key:match("^network%.failure%.[a-z][a-z_]*$") ~= nil
end

--- Whether a failed answer's reason key is one the page may show: a reason of
--- M.REASONS or a network cause's message.
--- @param key any
--- @return boolean
function M.admits_reason_key(key)
	return REASON_KEYS[key] == true or (network_message_key(key) and key ~= "network.failure.unknown")
end

--- The reason key of a failed check, from its reason and its evidence.
--- @param reason string One of the M.REASONS names.
--- @param evidence table|nil { rate_limited = boolean, report = { cause, message_key }|nil }:
---   the API's exhausted rate limit, and the managed-network report the driver
---   classified from the fetch's native receipt.
--- @return string key
function M.failure_key(reason, evidence)
	local key = M.REASONS[reason]
	if not key then error("unknown update-check failure reason: " .. tostring(reason), 2) end
	if reason ~= "no_connection" or type(evidence) ~= "table" then return key end
	if evidence.rate_limited == true then return M.REASONS.rate_limited end
	local report = evidence.report
	-- An unknown cause proves nothing: « Could not reach GitHub » stays
	if type(report) == "table" and type(report.cause) == "string" and report.cause ~= "unknown"
		and network_message_key(report.message_key) and report.message_key == "network.failure." .. report.cause then
		return report.message_key
	end
	return key
end

--- Classifies one release list for a manual check of one channel.
--- @param body string Raw GitHub releases array JSON.
--- @param opts table { registry, channel, current, installed, check_only? }: the
---   channel interpreter, the checked channel, the installed version and its
---   channel. check_only marks a list read from the public Atom feed: it names
---   tags only, so an available release is announced but cannot be installed
---   (the install needs the API's asset list and digests).
--- @return table result { state, channel, current, latest?, release?, others, check_only? }
---   where release is the JSON object of the offered or latest release.
function M.classify(body, opts)
	local registry = opts.registry
	-- One decode of the list gives every release's tag and date: the list is
	-- about 6 MB and each span used to be decoded twice more.
	local chunks, releases = Parser.index_releases(body)
	local tags = {}
	for index, release in ipairs(releases) do tags[index] = release.tag end
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
		if opts.check_only == true then result.check_only = true end
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
--- @param evidence table|nil What the failed fetch proved (M.failure_key).
--- @return table result { state = "error", channel, current, latest?, others, reason_key, detail }
function M.failure(opts, reason, detail, evidence)
	if not M.REASONS[reason] then error("unknown update-check failure reason: " .. tostring(reason), 2) end
	local key = M.failure_key(reason, evidence)
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
