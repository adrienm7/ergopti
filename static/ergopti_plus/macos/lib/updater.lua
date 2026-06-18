--- lib/updater.lua
---
--- Cross-driver updater engine (version compare, GitHub fetch, background poller).
--- Canonical algorithms: shared/updater/version.js

local M = {}

local hs           = hs
local Logger       = require("lib.logger")
local i18n       = require("lib.i18n")
local dialog     = require("lib.dialog_util")
local LOG        = "updater"

local GH_OWNER   = "adrienm7"
local GH_REPO    = "ergopti"
local ASSET_NAME = "ErgoptiPlus.app.zip"
local BUNDLED_ID = "com.ergopti.app"
local USER_AGENT = "ErgoptiPlus-Updater/1.0"
local DEFAULT_INTERVAL_SEC = 86400
local BOOT_CHECK_DELAY_SEC = 30
local DEV_PAGE_SIZE = 10

-- Module state shared with menu_about.lua
local _update_state       = "idle"
local _cached_release     = nil
local _last_notified_tag  = ""
local _bg_timer           = nil
local _boot_timer         = nil  -- one-shot boot-check; tracked so stop_background_checks() can cancel it
local _check_interval_sec = DEFAULT_INTERVAL_SEC
-- Monotonic counter; bumped on start/stop. Async callbacks capture their own
-- generation before launching asyncGet and discard their response when the
-- global has moved on, preventing a stale in-flight response from clobbering
-- _cached_release / _update_state with data from the wrong channel.
local _poll_generation    = 0
-- Per-channel ETag cache for conditional GET (304 does not count vs rate limit).
local _fetch_cache        = {}

local INTERVAL_PRESETS = {
	{ code = "1m",    seconds = 60 },
	{ code = "5m",    seconds = 300 },
	{ code = "10m",   seconds = 600 },
	{ code = "1h",    seconds = 3600 },
	{ code = "2h",    seconds = 7200 },
	{ code = "3h",    seconds = 10800 },
	{ code = "6h",    seconds = 21600 },
	{ code = "12h",   seconds = 43200 },
	{ code = "24h",   seconds = 86400 },
	{ code = "2d",    seconds = 172800 },
	{ code = "7d",    seconds = 604800 },
	{ code = "never", seconds = 0 },
}

M.INTERVAL_PRESETS = INTERVAL_PRESETS




--- ==================================
-- ======= 1/ Version helpers =======
--- ==================================

function M.normalize_tag(tag)
	if type(tag) ~= "string" then return "" end
	local t = tag:match("^%s*(.-)%s*$") or tag
	if t:sub(1, 1):lower() == "v" then t = t:sub(2) end
	return t
end

local function parse_version(tag)
	local norm = M.normalize_tag(tag)
	local maj, min, pat, pre = norm:match("^(%d+)%.(%d+)%.(%d+)%-?(.*)$")
	if not maj then return nil end
	if pre == "" then pre = nil end
	return {
		major = tonumber(maj),
		minor = tonumber(min),
		patch = tonumber(pat),
		prerelease = pre and (function()
			local parts = {}
			for part in pre:gmatch("[^%.]+") do table.insert(parts, part) end
			return parts
		end)() or nil,
	}
end

local function compare_prerelease_id(a, b)
	local a_num = a:match("^%d+$") ~= nil
	local b_num = b:match("^%d+$") ~= nil
	if a_num and b_num then
		local ai, bi = tonumber(a), tonumber(b)
		if ai > bi then return 1 end
		if ai < bi then return -1 end
		return 0
	end
	if a > b then return 1 end
	if a < b then return -1 end
	return 0
end

local function compare_prerelease(a, b)
	if not a and not b then return 0 end
	if not a and b then return 1 end
	if a and not b then return -1 end
	local len = math.max(#a, #b)
	for i = 1, len do
		local ai, bi = a[i], b[i]
		if not ai then return -1 end
		if not bi then return 1 end
		local cmp = compare_prerelease_id(ai, bi)
		if cmp ~= 0 then return cmp end
	end
	return 0
end

--- @param a string
--- @param b string
--- @return integer 1 | -1 | 0
function M.compare_versions(a, b)
	local pa, pb = parse_version(a), parse_version(b)
	if not pa or not pb then
		local na, nb = M.normalize_tag(a), M.normalize_tag(b)
		if na == nb then return 0 end
		-- Non-semver fallback: lexicographic comparison is wrong for tags like
		-- "10" vs "9". Treat ambiguous ordering as non-newer (fail-closed) and
		-- warn so the issue is visible.
		Logger.warn(LOG, "compare_versions: non-semver tags '%s'/'%s' — treating as equal.", na, nb)
		return 0
	end
	if pa.major ~= pb.major then return pa.major > pb.major and 1 or -1 end
	if pa.minor ~= pb.minor then return pa.minor > pb.minor and 1 or -1 end
	if pa.patch ~= pb.patch then return pa.patch > pb.patch and 1 or -1 end
	return compare_prerelease(pa.prerelease, pb.prerelease)
end

--- @param latest string
--- @param current string
--- @return boolean
function M.is_newer_version(latest, current)
	return M.compare_versions(latest, current) > 0
end




--- =================================
-- ======= 2/ GitHub helpers =======
--- =================================

function M.is_local_source()
	local info = hs.processInfo
	if not info then return true end
	return (info.bundleID or "") ~= BUNDLED_ID
end

function M.current_version()
	if M.is_local_source() then return "local" end
	local info = hs.processInfo
	if info and info.version and info.version ~= "" then
		return info.version
	end
	return "local"
end

function M.release_api_url(channel)
	local base = string.format("https://api.github.com/repos/%s/%s/releases", GH_OWNER, GH_REPO)
	if channel == "dev" then
		return base .. "?per_page=" .. tostring(DEV_PAGE_SIZE)
	end
	return base .. "/latest"
end

function M.releases_page_url()
	return string.format("https://github.com/%s/%s/releases", GH_OWNER, GH_REPO)
end

local function split_releases_array(json)
	local out = {}
	if type(json) ~= "string" or json == "" then return out end
	local trimmed = json:match("^%s*(.*)$") or json
	if trimmed:sub(1, 1) ~= "[" then return out end
	local pos, depth, start = 2, 0, 0
	local in_str, esc = false, false
	while pos <= #trimmed do
		local c = trimmed:sub(pos, pos)
		if in_str then
			if esc then esc = false
			elseif c == "\\" then esc = true
			elseif c == '"' then in_str = false end
		elseif c == '"' then in_str = true
		elseif c == "{" then
			if depth == 0 then start = pos end
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 and start > 0 then
				table.insert(out, trimmed:sub(start, pos))
				start = 0
			end
		end
		pos = pos + 1
	end
	return out
end

local function parse_prerelease_flag(json)
	return json:match('"prerelease"%s*:%s*true') ~= nil
end

--- Picks the highest-semver prerelease from a releases array JSON string.
--- @param json string
--- @return string
function M.pick_latest_prerelease_json(json)
	local chunks = split_releases_array(json)
	local best_chunk, best_tag = "", ""
	for _, chunk in ipairs(chunks) do
		if parse_prerelease_flag(chunk) then
			local tag = M.parse_tag(chunk)
			if tag ~= "" and (best_tag == "" or M.compare_versions(tag, best_tag) > 0) then
				best_tag = tag
				best_chunk = chunk
			end
		end
	end
	if best_chunk ~= "" then return best_chunk end
	return chunks[1] or json
end

function M.unwrap_first_prerelease_json(json)
	return M.pick_latest_prerelease_json(json)
end

local function fetch_headers(channel)
	local headers = {
		["User-Agent"] = USER_AGENT,
		["Accept"] = "application/vnd.github+json",
	}
	local cached = _fetch_cache[channel]
	if cached and cached.etag and cached.etag ~= "" then
		headers["If-None-Match"] = cached.etag
	end
	return headers
end

local function store_fetch_cache(channel, etag, body)
	if type(etag) == "string" and etag ~= "" and type(body) == "string" and body ~= "" then
		_fetch_cache[channel] = { etag = etag, body = body }
	end
end

local function resolve_fetch_body(channel, status, body, response_headers)
	if status == 304 then
		local cached = _fetch_cache[channel]
		if cached and cached.body then
			Logger.debug(LOG, "GitHub releases unchanged (304) for channel %s.", channel)
			return cached.body
		end
		return nil
	end
	if status == 403 then
		Logger.warn(LOG, "GitHub API rate limit (HTTP 403) for channel %s.", channel)
		return nil
	end
	if status ~= 200 or not body or body == "" then
		Logger.debug(LOG, "Background check: HTTP %s.", tostring(status))
		return nil
	end
	local etag = ""
	if type(response_headers) == "table" then
		etag = response_headers["ETag"] or response_headers["etag"] or ""
	end
	store_fetch_cache(channel, etag, body)
	return body
end

function M.parse_tag(body)
	if not body or body == "" then return "" end
	return body:match('"tag_name"%s*:%s*"([^"]+)"') or ""
end

function M.parse_notes(body)
	if not body or body == "" then return "" end
	local raw = body:match('"body"%s*:%s*"(.-[^\\])"')
	if not raw then return "" end
	return raw:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
end

function M.parse_asset_url(body)
	if not body or body == "" then return "" end
	for obj in body:gmatch("%b{}") do
		local name = obj:match('"name"%s*:%s*"([^"]+)"')
		if name == ASSET_NAME then
			return obj:match('"browser_download_url"%s*:%s*"([^"]+)"') or ""
		end
	end
	return ""
end

local function normalize_release_json(body, channel)
	if channel == "dev" and body:match("^%s*%[") then
		return M.pick_latest_prerelease_json(body)
	end
	return body
end




-- ================================
-- ======= 3/ Public state =========
-- ================================

function M.get_update_state()
	return _update_state
end

function M.get_cached_release()
	return _cached_release
end

function M.set_check_interval(seconds)
	local s = tonumber(seconds)
	if not s or s < 0 then return end
	_check_interval_sec = math.floor(s)
end

function M.get_check_interval()
	return _check_interval_sec
end

function M.get_update_menu_label()
	if _update_state == "checking" then
		return i18n.get("menu.about.update_checking")
	end
	if _update_state == "installing" then
		return i18n.get("menu.about.update_installing")
	end
	if _update_state == "available" and _cached_release then
		return i18n.get("menu.about.update_now"):gsub("{tag}", _cached_release.tag)
	end
	return i18n.get("menu.about.check_for_updates")
end

function M.clear_cached_release()
	_cached_release = nil
	_update_state = "idle"
end

function M.set_update_state(state)
	if type(state) == "string" then _update_state = state end
end

function M.set_cached_release(release)
	_cached_release = release
end




-- ================================
-- ======= 4/ Background poller ===
-- ================================

local function notify_new_version(tag, update_menu_fn)
	if M.normalize_tag(_last_notified_tag) == M.normalize_tag(tag) then return end
	_last_notified_tag = tag
	Logger.info(LOG, "New release available: %s (current: %s).", tag, M.current_version())
	_update_state = "available"
	if type(update_menu_fn) == "function" then pcall(update_menu_fn) end
	local body = i18n.get("updater.tray_new_version_body"):gsub("{1}", tag)
	local title = i18n.get("updater.tray_new_version_title")
	pcall(function()
		hs.notify.new({
			title = title,
			informativeText = body,
			hasActionButton = false,
		}):send()
	end)
end

local function background_tick(channel, update_menu_fn)
	if M.is_local_source() or _check_interval_sec <= 0 then return end
	local current = M.current_version()
	local url = M.release_api_url(channel)
	-- Capture generation before the async call so a channel switch mid-flight
	-- can be detected and the stale response discarded.
	local gen = _poll_generation
	hs.http.asyncGet(url, fetch_headers(channel), function(status, body, response_headers)
		if gen ~= _poll_generation then
			Logger.debug(LOG, "Background check: stale response discarded (gen %d != %d).", gen, _poll_generation)
			return
		end
		body = resolve_fetch_body(channel, status, body, response_headers)
		if not body then return end
		body = normalize_release_json(body, channel)
		local latest = M.parse_tag(body)
		if latest == "" or not M.is_newer_version(latest, current) then
			Logger.debug(LOG, "Background check: up to date (%s).", current)
			return
		end
		local zip_url = M.parse_asset_url(body)
		if zip_url == "" then
			Logger.warn(LOG, "Background check: asset missing in %s.", latest)
			return
		end
		_cached_release = {
			tag     = latest,
			notes   = M.parse_notes(body),
			zip_url = zip_url,
			raw     = body,
		}
		notify_new_version(latest, update_menu_fn)
	end)
end

function M.stop_background_checks()
	-- Bump generation to invalidate any in-flight asyncGet callbacks.
	_poll_generation = _poll_generation + 1
	if _bg_timer then
		pcall(function() _bg_timer:stop() end)
		_bg_timer = nil
	end
	if _boot_timer then
		pcall(function() _boot_timer:stop() end)
		_boot_timer = nil
	end
end

function M.start_background_checks(channel, interval_sec, update_menu_fn)
	M.stop_background_checks()
	M.set_check_interval(interval_sec)
	if M.is_local_source() then
		Logger.debug(LOG, "Local source — background checks disabled.")
		return
	end
	if _check_interval_sec <= 0 then
		Logger.debug(LOG, "Check interval 0 — background checks disabled.")
		return
	end
	local first_delay = math.min(BOOT_CHECK_DELAY_SEC, _check_interval_sec)
	Logger.start(LOG, "Background update checks every %ds (first in %ds).", _check_interval_sec, first_delay)
	_bg_timer = hs.timer.doEvery(_check_interval_sec, function()
		background_tick(channel, update_menu_fn)
	end)
	_boot_timer = hs.timer.doAfter(first_delay, function()
		_boot_timer = nil
		background_tick(channel, update_menu_fn)
	end)
end

function M.restart_background_checks(channel, interval_sec, update_menu_fn)
	M.start_background_checks(channel, interval_sec, update_menu_fn)
end

return M