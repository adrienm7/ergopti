--- _shared/lua/updater/release_sources.lua

--- ==============================================================================
--- MODULE: Release Sources (Shared)
--- DESCRIPTION:
--- Resolves the changelog's release sources from the shared updater defaults
--- and orders them: the GitHub REST API first, then the public releases Atom
--- feed on github.com. Corporate proxies commonly block or throttle
--- api.github.com while github.com stays reachable, so the feed is an explicit,
--- logged alternate source rather than a silent fallback.
---
--- The transport is injected: each driver passes a bounded asynchronous GET
--- that honours its system proxy. This module is PURE Lua — no driver imports,
--- no io/network, no OS calls — so macOS and Linux share one decision table.
--- ==============================================================================

local M = {}

M.SOURCE_API = "api"
M.SOURCE_FEED = "atom_feed"

local USER_AGENT = "ErgoptiPlus-Changelog/1.0"
local NAME_PATTERN = "^[A-Za-z0-9._-]+$"





-- ==========================================
-- ==========================================
-- ======= 1/ Defaults Resolution ===========
-- ==========================================
-- ==========================================

--- Expands one https URL template for the repository.
--- @param template any
--- @param owner string
--- @param repo string
--- @return string|nil url
local function expand(template, owner, repo)
	if type(template) ~= "string" or not template:find("{owner}/{repo}", 1, true) then return nil end
	local url = template:gsub("{owner}", owner):gsub("{repo}", repo)
	if not url:match("^https://[%w.-]+/") then return nil end
	return url
end

--- Reads one strictly positive integer budget in seconds.
--- @param value any
--- @return number|nil
local function positive_seconds(value)
	if type(value) ~= "number" or value <= 0 or value % 1 ~= 0 then return nil end
	return value
end

--- Validates the shared defaults and expands the source table.
--- @param defaults table Decoded _shared/modules/updater/defaults.json.
--- @return table|nil sources { owner, repo, api_url, feed_url, page_url, source_timeout_ms, proxy_timeout_ms, watchdog_ms }
--- @return string|nil error Exact reason when the defaults are unusable.
function M.resolve(defaults)
	if type(defaults) ~= "table" then return nil, "updater defaults are not a table" end
	local github = defaults.github
	local owner = type(github) == "table" and github.owner or nil
	local repo = type(github) == "table" and github.repo or nil
	if type(owner) ~= "string" or not owner:match(NAME_PATTERN)
		or type(repo) ~= "string" or not repo:match(NAME_PATTERN) then
		return nil, "updater defaults declare no valid github.owner/github.repo"
	end
	local spec = defaults.release_sources
	if type(spec) ~= "table" then return nil, "updater defaults declare no release_sources" end
	local sources = {
		owner = owner,
		repo = repo,
		api_url = expand(spec.api_releases_url, owner, repo),
		feed_url = expand(spec.atom_feed_url, owner, repo),
		page_url = expand(spec.releases_page_url, owner, repo),
	}
	for _, key in ipairs({ "api_url", "feed_url", "page_url" }) do
		if not sources[key] then return nil, "release_sources has an invalid " .. key .. " template" end
	end
	local source_sec = positive_seconds(spec.source_timeout_sec)
	local proxy_sec = positive_seconds(spec.proxy_resolve_timeout_sec)
	local watchdog_sec = positive_seconds(spec.ui_watchdog_sec)
	if not source_sec or not proxy_sec or not watchdog_sec then
		return nil, "release_sources has an invalid timeout budget"
	end
	if watchdog_sec <= proxy_sec + 2 * source_sec then
		return nil, "release_sources.ui_watchdog_sec does not outlast both sources"
	end
	sources.source_timeout_ms = source_sec * 1000
	sources.proxy_timeout_ms = proxy_sec * 1000
	sources.watchdog_ms = watchdog_sec * 1000
	return sources, nil
end





-- ==========================================
-- ==========================================
-- ======= 2/ Response Classification =======
-- ==========================================
-- ==========================================

--- Describes a failed attempt without echoing response content.
--- @param status any
--- @param err any
--- @return string
local function failure_reason(status, err)
	status = tonumber(status) or 0
	if status ~= 0 and status ~= 200 then return "HTTP " .. tostring(status) end
	if type(err) == "string" and err ~= "" then return err end
	return "no response"
end

--- Accepts an API response only when it is a JSON release array.
--- A proxy block page served with HTTP 200 is therefore a failure.
--- @param status any
--- @param body any
--- @param err any
--- @return boolean ok
--- @return string|nil reason
function M.classify_api(status, body, err)
	if tonumber(status) ~= 200 or type(body) ~= "string" then return false, failure_reason(status, err) end
	local text = body:gsub("^\239\187\191", "", 1)
	if not text:match("^%s*%[") or not text:match("%]%s*$") then
		return false, "HTTP 200 without a JSON release array"
	end
	return true, nil
end

--- Accepts a feed response only when it is an Atom document.
--- @param status any
--- @param body any
--- @param err any
--- @return boolean ok
--- @return string|nil reason
function M.classify_feed(status, body, err)
	if tonumber(status) ~= 200 or type(body) ~= "string" then return false, failure_reason(status, err) end
	if not body:find("<feed[%s>]") then return false, "HTTP 200 without an Atom feed" end
	return true, nil
end

--- Reports whether a failed API attempt was GitHub throttling the client.
--- @param status any
--- @return boolean
local function is_rate_limit(status)
	status = tonumber(status) or 0
	return status == 403 or status == 429
end





-- ==========================================
-- ==========================================
-- ======= 3/ Ordered Fetch =================
-- ==========================================
-- ==========================================

--- Fetches the release list from the first source that answers usefully.
--- get(url, headers, timeout_ms, callback) must call callback(status, body, err)
--- exactly once and bound the request by timeout_ms; a second call is ignored.
--- on_done receives { source, kind = "json"|"feed", body, api_failure? } or
--- { error = reason, error_key = locale key }.
--- @param sources table Result of M.resolve().
--- @param get function Driver transport.
--- @param logger table Logger with warn/info(tag, fmt, ...).
--- @param tag string Logger tag of the calling driver module.
--- @param on_done function Terminal callback, invoked exactly once.
function M.fetch(sources, get, logger, tag, on_done)
	local finished = false
	local function finish(result)
		if finished then return end
		finished = true
		on_done(result)
	end

	local function once(handler)
		local called = false
		return function(status, body, err)
			if called then return end
			called = true
			handler(status, body, err)
		end
	end

	local function try_feed(api_failure, api_status)
		get(sources.feed_url, { Accept = "application/atom+xml", ["User-Agent"] = USER_AGENT },
			sources.source_timeout_ms, once(function(status, body, err)
				local ok, reason = M.classify_feed(status, body, err)
				if ok then
					logger.info(tag, "Release list served by the Atom feed (API failed: %s).", api_failure)
					finish({ source = M.SOURCE_FEED, kind = "feed", body = body, api_failure = api_failure })
					return
				end
				logger.warn(tag, "Release sources exhausted: API failed (%s), Atom feed failed (%s).",
					api_failure, reason)
				finish({
					error = "API: " .. api_failure .. "; Atom feed: " .. reason,
					error_key = is_rate_limit(api_status) and "changelog_window.error_rate_limited"
						or "changelog_window.error_network",
				})
			end))
	end

	get(sources.api_url, { Accept = "application/vnd.github+json", ["User-Agent"] = USER_AGENT },
		sources.source_timeout_ms, once(function(status, body, err)
			local ok, reason = M.classify_api(status, body, err)
			if ok then
				logger.info(tag, "Release list served by the GitHub API.")
				finish({ source = M.SOURCE_API, kind = "json", body = body })
				return
			end
			logger.warn(tag, "GitHub API release list failed (%s); trying the Atom feed.", reason)
			try_feed(reason, status)
		end))
end

return M
