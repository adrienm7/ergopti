--- modules/updater/init.lua
---
--- Cross-driver updater engine (version compare, GitHub fetch, background poller).
--- Canonical version algorithms: _shared/modules/updater/version.js
--- Shared pure version functions: _shared/lua/updater/version.lua

local M = {}

local hs           = hs
local Logger       = require("infra.logger")
local i18n       = require("infra.i18n")
local dialog     = require("infra.dialog_util")
local Paths      = require("infra.paths")
local FileSystem = require("adapters.file_system")
local JsonCodec  = require("adapters.json_codec")
local text_utils = require("infra.text_utils")
local NetworkInfo = require("adapters.network_info")
local Notifier    = require("adapters.notifier")
local TimerScheduler = require("adapters.timer_scheduler")
local Version    = require("updater.version")
local ReleaseParser = require("updater.release_parser")
local LOG        = "updater"

-- Hardcoded fallback — mirrors defaults.json committed alongside. Keeps the
-- engine functional when the shared tree is unreachable (packaged edge-case).
local _DEFAULTS_FALLBACK = {
	github = { owner = "adrienm7", repo = "ergopti" },
	timing = { default_check_interval_sec = 86400, boot_check_delay_sec = 30 },
}

--- Loads shared scalars from _shared/modules/updater/defaults.json. Falls back
--- to _DEFAULTS_FALLBACK so a missing/corrupt JSON is never silent.
--- @return table The parsed or fallback defaults table.
local function load_updater_defaults()
	local p = Paths.shared("modules/updater/defaults.json")
	if type(p) == "string" and p ~= "" then
		local raw = FileSystem.read(p)
		if raw then
			local ok, parsed = pcall(JsonCodec.decode, raw)
			if ok and type(parsed) == "table" then
				Logger.debug(LOG, "Loaded updater defaults from %s.", p)
				return parsed
			end
		end
	end
	Logger.warn(LOG, "defaults.json not found — using hardcoded updater fallback.")
	return _DEFAULTS_FALLBACK
end

local _defs = load_updater_defaults()
local GH_OWNER             = (_defs.github and _defs.github.owner) or _DEFAULTS_FALLBACK.github.owner
local GH_REPO              = (_defs.github and _defs.github.repo)  or _DEFAULTS_FALLBACK.github.repo
local DEFAULT_INTERVAL_SEC = (_defs.timing and _defs.timing.default_check_interval_sec) or _DEFAULTS_FALLBACK.timing.default_check_interval_sec
local BOOT_CHECK_DELAY_SEC = (_defs.timing and _defs.timing.boot_check_delay_sec)        or _DEFAULTS_FALLBACK.timing.boot_check_delay_sec

-- Exposed for testability — let unit tests assert the resolved values.
M.GH_OWNER             = GH_OWNER
M.GH_REPO              = GH_REPO
M.DEFAULT_INTERVAL_SEC = DEFAULT_INTERVAL_SEC
M.BOOT_CHECK_DELAY_SEC = BOOT_CHECK_DELAY_SEC

local ASSET_NAME = "ErgoptiPlus.app.zip"
local BUNDLED_ID = "com.ergopti.app"
local USER_AGENT = "ErgoptiPlus-Updater/1.0"
local DEV_PAGE_SIZE = 10
local SHA256_PREFIX = "sha256:"

-- Module state shared with menu_about.lua
local _update_state       = "idle"
local _cached_release     = nil
local _last_notified_tag  = ""
local _bg_timer           = nil
local _bg_timer_committed = false
local _boot_timer         = nil  -- one-shot boot-check; tracked so stop_background_checks() can cancel it
local _boot_timer_committed = false
local _check_interval_sec = DEFAULT_INTERVAL_SEC
-- Monotonic counter; bumped on start/stop. Async callbacks capture their own
-- generation before launching asyncGet and discard their response when the
-- global has moved on, preventing a stale in-flight response from clobbering
-- _cached_release / _update_state with data from the wrong channel.
local _poll_generation    = 0
-- Request and response order are distinct because timer-owned fetches overlap
local _poll_request_seq   = 0
local _poll_response_seq  = 0
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






-- ==================================
-- ==================================
-- ======= 1/ Version helpers =======
-- ==================================
-- ==================================

-- Version comparison functions are delegated to the shared pure-Lua module
-- _shared/lua/updater/version.lua, which mirrors the canonical JS algorithm
-- in _shared/modules/updater/version.js. The macOS driver no longer owns its
-- own copy of normalize_tag / parse_version / compare_versions / is_newer_version.

--- Delegates to the shared pure-Lua version module.
function M.normalize_tag(tag)
	return Version.normalize_tag(tag)
end

--- Delegates to the shared pure-Lua version module. The shared module is pure
--- (no Logger dependency) so non-semver diagnostic logging is restored here.
function M.compare_versions(a, b)
	local result = Version.compare_versions(a, b)
	if result == 0 then
		local na, nb = Version.normalize_tag(a), Version.normalize_tag(b)
		if na ~= nb then
			Logger.warn(LOG, "compare_versions: non-semver tags '%s'/'%s' — treating as equal.", na, nb)
		end
	end
	return result
end

--- Delegates to the shared pure-Lua version module.
function M.is_newer_version(latest, current)
	return Version.is_newer_version(latest, current)
end






-- =================================
-- =================================
-- ======= 2/ GitHub helpers =======
-- =================================
-- =================================

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

-- split_releases_array and parse_prerelease_flag are now delegated to the
-- shared release_parser module — see _shared/lua/updater/release_parser.lua

--- Picks the highest-semver prerelease from a releases array JSON string.
--- @param json string
--- @return string
function M.pick_latest_prerelease_json(json)
	return ReleaseParser.pick_latest_prerelease(json, M.compare_versions)
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
			return cached.body, nil
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
	return body, etag
end

function M.parse_tag(body)
	return ReleaseParser.parse_tag(body)
end

function M.parse_notes(body)
	return ReleaseParser.parse_notes(body)
end

function M.parse_asset_url(body)
	return ReleaseParser.parse_asset_url(body, ASSET_NAME)
end

--- Validates one self-update release record against the exact GitHub release
--- asset owned by this repository. The exact URL check rejects alternate
--- schemes, userinfo, query strings, fragments, repositories, tags, and names.
--- @param release table Candidate release record.
--- @return boolean valid Whether the record is safe for download.
--- @return string|nil reason Stable diagnostic on refusal.
function M.validate_install_asset(release)
	if type(release) ~= "table" then return false, "release metadata is not a table" end
	local tag = release.tag
	if type(tag) ~= "string" or not tag:match("^[%w][%w%.%+%-]*$") then
		return false, "release tag is invalid"
	end
	local expected_url = string.format(
		"https://github.com/%s/%s/releases/download/%s/%s",
		GH_OWNER,
		GH_REPO,
		tag,
		ASSET_NAME
	)
	if type(release.zip_url) ~= "string" or release.zip_url ~= expected_url then
		return false, "release asset URL does not match the selected repository and tag"
	end
	if type(release.sha256) ~= "string"
		or #release.sha256 ~= 64
		or not release.sha256:match("^[0-9a-f]+$") then
		return false, "release asset SHA-256 is invalid"
	end
	return true, nil
end

--- Parses and validates the exact installable asset from one GitHub release.
--- @param body string GitHub release JSON body.
--- @param expected_tag string Release tag selected by the version engine.
--- @return table|nil release Validated release record.
--- @return string|nil reason Stable diagnostic on refusal.
function M.parse_install_asset(body, expected_tag)
	if type(body) ~= "string" or body == "" then return nil, "release body is empty" end
	if type(expected_tag) ~= "string" or expected_tag == "" then
		return nil, "expected release tag is empty"
	end
	local decode_ok, decoded, decode_error = pcall(JsonCodec.decode, body)
	if not decode_ok or decode_error ~= nil or type(decoded) ~= "table" then
		return nil, "release JSON is invalid"
	end
	if decoded.tag_name ~= expected_tag then
		return nil, "release tag does not match the selected version"
	end
	if type(decoded.assets) ~= "table" then return nil, "release assets are missing" end

	local selected = nil
	for _, asset in ipairs(decoded.assets) do
		if type(asset) == "table" and asset.name == ASSET_NAME then
			if selected ~= nil then return nil, "release contains duplicate install assets" end
			selected = asset
		end
	end
	if not selected then return nil, "release install asset is missing" end

	local digest = selected.digest
	if type(digest) ~= "string" or digest:sub(1, #SHA256_PREFIX) ~= SHA256_PREFIX then
		return nil, "release asset SHA-256 is missing"
	end
	local release = {
		tag = expected_tag,
		zip_url = selected.browser_download_url,
		sha256 = digest:sub(#SHA256_PREFIX + 1):lower(),
	}
	local valid, reason = M.validate_install_asset(release)
	if valid ~= true then return nil, reason end
	return release, nil
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

--- Escapes a string so it is safe to use as the REPLACEMENT argument of gsub.
--- Lua treats "%" specially on that side: "%1".."%9" are capture references,
--- "%%" is a literal percent, and "%" followed by anything else RAISES
--- "invalid use of %". Release tags come from the GitHub API and are therefore
--- third-party-controlled, so they must never be interpolated into a template
--- verbatim — a tag such as "v1.2%3" would otherwise throw out of the label build.
--- @param s any The replacement text (coerced with tostring).
--- @return string The text with every "%" doubled.
-- Single source of truth: lib.text_utils (shared with the other Lua drivers).
local escape_replacement = text_utils.escape_gsub_replacement

function M.get_update_menu_label()
	if _update_state == "checking" then
		return i18n.get("menu.about.update_checking")
	end
	if _update_state == "installing" then
		return i18n.get("menu.about.update_installing")
	end
	if _update_state == "available" and _cached_release then
		return (i18n.get("menu.about.update_now"):gsub("{tag}", escape_replacement(_cached_release.tag)))
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
	local valid, reason = M.validate_install_asset(release)
	if valid ~= true then
		Logger.error(LOG, "Cached release refused — %s.", tostring(reason))
		return false, reason
	end
	_cached_release = release
	return true, nil
end




-- ================================
-- ======= 4/ Background poller ===
-- ================================

local function notify_new_version(tag, update_menu_fn)
	-- Availability and the menu refresh are recorded FIRST, unconditionally. The
	-- tag guard below suppresses a repeated NOTIFICATION, which is all it was ever
	-- meant to do — gating the state on it too meant that after a channel or
	-- interval change the "Update to vX" entry silently vanished while the release
	-- was still cached, because the second pass returned before setting either.
	_update_state = "available"
	if type(update_menu_fn) == "function" then pcall(update_menu_fn) end

	if M.normalize_tag(_last_notified_tag) == M.normalize_tag(tag) then return end
	_last_notified_tag = tag
	Logger.info(LOG, "New release available: %s (current: %s).", tag, M.current_version())
	-- The tag lands on the REPLACEMENT side of gsub, where "%" is special and a
	-- release such as "v2.1%-rc1" raises. The label builder above already escapes
	-- for exactly this reason; this notification body was the site it missed.
	local body = i18n.get("updater.tray_new_version_body"):gsub("{1}", escape_replacement(tag))
	local title = i18n.get("updater.tray_new_version_title")
	Notifier.send(title, { body = body, kind = "info" })
end

local function background_tick(channel, update_menu_fn, generation)
	if generation ~= _poll_generation then return end
	if M.is_local_source() or _check_interval_sec <= 0 then return end
	local reachable = NetworkInfo.isInternetReachable()
	if NetworkInfo.hasInternetProbeResult() and not reachable then
		Logger.debug(LOG, "Background check skipped: the current network probe reports no internet access.")
		return
	end
	local current = M.current_version()
	local url = M.release_api_url(channel)
	_poll_request_seq = _poll_request_seq + 1
	local request_seq = _poll_request_seq
	-- Lifecycle generation and request order are independent stale dimensions
	hs.http.asyncGet(url, fetch_headers(channel), function(status, body, response_headers)
		if generation ~= _poll_generation then
			Logger.debug(LOG,
				"Background check: stale response discarded (generation %d superseded by %d).",
				generation, _poll_generation)
			return
		end
		if request_seq < _poll_response_seq then
			Logger.debug(LOG,
				"Background check: stale response discarded (request %d superseded by response %d in generation %d).",
				request_seq, _poll_response_seq, generation)
			return
		end
		if request_seq == _poll_response_seq then
			Logger.debug(LOG,
				"Background check: duplicate response discarded (request %d in generation %d).",
				request_seq, generation)
			return
		end
		local response_etag
		body, response_etag = resolve_fetch_body(channel, status, body, response_headers)
		if not body then return end
		body = normalize_release_json(body, channel)
		local latest = M.parse_tag(body)
		if latest == "" then
			Logger.debug(LOG, "Background check: response has no usable release tag.")
			return
		end
		if _cached_release and _cached_release.tag
			and M.is_newer_version(_cached_release.tag, latest) then
			Logger.debug(LOG, "Background check: older release %s refused after %s.",
				latest, _cached_release.tag)
			return
		end
		local is_newer = M.is_newer_version(latest, current)
		local install_release = nil
		if is_newer then
			local asset_error
			install_release, asset_error = M.parse_install_asset(body, latest)
			if not install_release then
				Logger.warn(LOG, "Background check: release asset refused for %s — %s.",
					latest, tostring(asset_error))
				return
			end
		end
		-- Only a response that survived parsing, monotonicity, and install-asset
		-- validation may supersede an older request or its ETag.
		_poll_response_seq = request_seq
		if response_etag ~= nil then store_fetch_cache(channel, response_etag, body) end
		if not is_newer then
			Logger.debug(LOG, "Background check: up to date (%s).", current)
			return
		end
		install_release.notes = M.parse_notes(body)
		install_release.raw = body
		if M.set_cached_release(install_release) ~= true then return end
		notify_new_version(latest, update_menu_fn)
	end)
end

function M.stop_background_checks()
	Logger.start(LOG, "Stopping background update checks…")
	-- Invalidate both in-flight HTTP completions and callbacks from an exact
	-- recurring handle whose native stop refuses or raises
	_poll_generation = _poll_generation + 1
	local settled = true
	if _bg_timer then
		local ok_cancel, cancelled = pcall(TimerScheduler.cancel, _bg_timer)
		if ok_cancel and cancelled == true then
			_bg_timer = nil
			_bg_timer_committed = false
		else
			settled = false
			Logger.error(LOG, "Recurring update timer stop failed; retained for retry — %s.",
				tostring(ok_cancel and cancelled or cancelled))
		end
	end
	if _boot_timer then
		local ok_cancel, cancelled = pcall(TimerScheduler.cancel, _boot_timer)
		if ok_cancel and cancelled == true then
			_boot_timer = nil
			_boot_timer_committed = false
		else
			settled = false
			Logger.error(LOG, "Boot update timer stop failed; retained for retry — %s.",
				tostring(ok_cancel and cancelled or cancelled))
		end
	end
	if not settled then
		Logger.error(LOG, "Background update checks could not stop completely.")
		return false
	end
	Logger.success(LOG, "Background update checks stopped.")
	return true
end

function M.start_background_checks(channel, interval_sec, update_menu_fn)
	if M.stop_background_checks() ~= true then
		Logger.error(LOG, "Background update checks cannot start while prior timer cleanup is pending.")
		return false
	end
	-- Clear any cached release from a previous channel so stale update data from
	-- one channel does not bleed into another when the user switches channels.
	M.clear_cached_release()
	M.set_check_interval(interval_sec)
	if M.is_local_source() then
		Logger.debug(LOG, "Local source — background checks disabled.")
		return true
	end
	if _check_interval_sec <= 0 then
		Logger.debug(LOG, "Check interval 0 — background checks disabled.")
		return true
	end
	local first_delay = math.min(BOOT_CHECK_DELAY_SEC, _check_interval_sec)
	Logger.start(LOG, "Background update checks every %ds (first in %ds).", _check_interval_sec, first_delay)
	local generation = _poll_generation
	local recurring_candidate
	local ok_schedule, recurring_handle, recurring_committed = pcall(
		TimerScheduler.every, _check_interval_sec, function()
			if generation ~= _poll_generation
				or _bg_timer ~= recurring_candidate
				or not _bg_timer_committed then
				return
			end
			background_tick(channel, update_menu_fn, generation)
		end)
	recurring_candidate = recurring_handle
	if ok_schedule and type(recurring_handle) == "table" then
		_bg_timer = recurring_handle
		_bg_timer_committed = recurring_committed == true
	end
	if not ok_schedule or type(recurring_handle) ~= "table" or recurring_committed ~= true then
		M.stop_background_checks()
		Logger.error(LOG, "Recurring update timer could not be armed; background checks remain stopped — %s.",
			tostring(ok_schedule and recurring_committed or recurring_handle))
		return false
	end

	local boot_candidate
	local ok_boot, boot_handle, boot_committed = pcall(
		TimerScheduler.after, first_delay, function()
			if generation ~= _poll_generation
				or _boot_timer ~= boot_candidate
				or not _boot_timer_committed then
				return
			end
			_boot_timer = nil
			_boot_timer_committed = false
			background_tick(channel, update_menu_fn, generation)
		end)
	boot_candidate = boot_handle
	if ok_boot and type(boot_handle) == "table" then
		_boot_timer = boot_handle
		_boot_timer_committed = boot_committed == true
	end
	if not ok_boot or type(boot_handle) ~= "table" or boot_committed ~= true then
		M.stop_background_checks()
		Logger.error(LOG, "Boot update timer could not be armed; background checks remain stopped — %s.",
			tostring(ok_boot and boot_committed or boot_handle))
		return false
	end

	Logger.success(LOG, "Background update checks started.")
	return true
end

function M.restart_background_checks(channel, interval_sec, update_menu_fn)
	return M.start_background_checks(channel, interval_sec, update_menu_fn)
end

return M
