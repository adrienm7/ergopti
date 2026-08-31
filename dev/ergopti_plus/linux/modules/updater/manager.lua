--- modules/updater/manager.lua

--- ==============================================================================
--- MODULE: Updater Manager (Linux)
--- DESCRIPTION:
--- Self-update engine for the Linux driver. Checks the GitHub Releases API,
--- compares versions via the shared semver module, downloads the latest asset,
--- verifies integrity, and performs self-replacement. Supports channel switching
--- (stable → dev, dev → stable) and background polling at a configurable interval.
---
--- Persists user preferences (channel, interval, last notified tag) via the
--- storage adapter so settings survive daemon restarts.
---
--- FEATURES & RATIONALE:
--- 1. Event-loop-owned transport: the shared Linux HTTP adapter spawns curl
---    through libuv. Release checks therefore never block keyboard processing.
--- 2. ETag caching: stores the GitHub ETag header per channel in a temp file
---    so background checks that return 304 Not Modified do not count against
---    the API rate limit.
--- 3. Shared parser: delegates JSON parsing to _shared/lua/updater/release_parser.lua
---    which requires no full JSON decoder.
--- 4. Version compare: delegates to _shared/lua/updater/version.lua (semver).
--- 5. Background poller: uses the timer_scheduler adapter (luv-based when
---    available) with a graceful fallback message when luv is absent.
--- 6. Self-replace: downloads the latest archive, extracts it, and replaces
---    the running binary. A .old backup is kept so the user can revert.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Paths     = require("infra.paths")
local Version   = require("updater.version")
local Parser    = require("updater.release_parser")
local Installer = require("modules.updater.installer")
local Json      = require("json")
local Fs        = require("adapters.file_system")
local HttpClient = require("adapters.http_client")
local FileDigest = require("adapters.file_digest")
local ok_storage, Storage = pcall(require, "adapters.storage")
if not ok_storage then Storage = nil end
local ok_timer, Timer = pcall(require, "adapters.timer_scheduler")
if not ok_timer then Timer = nil end

local LOG = "modules.updater.manager"

M._http_client = HttpClient
M._file_digest = FileDigest

-- Single source of the driver version.
local DriverVersion = require("infra.version")

-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- Hardcoded fallback mirroring _shared/modules/updater/defaults.json — keeps
-- the engine functional when the shared tree is unreachable (packaged edge-case)
local _DEFAULTS_FALLBACK = {
	github = { owner = "adrienm7", repo = "ergopti" },
	timing = { default_check_interval_sec = 86400, boot_check_delay_sec = 30 },
}

--- Resolves the absolute path to _shared/modules/updater/defaults.json.
---
--- Through infra.paths, which knows both layouts that ship. Stripping four path
--- components off this file's own location described the checkout only: an
--- installed package stages the driver flat under /usr/lib/ergopti, so four up
--- leaves the install and the updater falls back to its hardcoded scalars.
--- @return string|nil Absolute path, or nil if it cannot be resolved.
local function resolve_defaults_path()
	return Paths.shared("modules/updater/defaults.json")
end

--- Loads the shared updater scalars from defaults.json. Falls back to
--- _DEFAULTS_FALLBACK (with a warn) so a missing or corrupt JSON is never silent.
--- @return table The parsed defaults, or the hardcoded fallback.
local function load_updater_defaults()
	local path = resolve_defaults_path()
	if path then
		local raw = Fs.read(path)
		if raw then
			local parsed = Json.decode(raw)
			if type(parsed) == "table" then
				Logger.debug(LOG, "Loaded updater defaults from %s.", path)
				return parsed
			end
		end
	end
	Logger.warn(LOG, "defaults.json not readable — using hardcoded updater fallback.")
	return _DEFAULTS_FALLBACK
end

local _defs = load_updater_defaults()

-- GitHub repo coordinates (single source: _shared/modules/updater/defaults.json)
local GH_OWNER = (_defs.github and _defs.github.owner) or _DEFAULTS_FALLBACK.github.owner
local GH_REPO  = (_defs.github and _defs.github.repo)  or _DEFAULTS_FALLBACK.github.repo

-- How many prerelease pages to fetch for the dev channel.
local DEV_PAGE_SIZE = 10

-- User-Agent header required by GitHub API.
local USER_AGENT = "ErgoptiPlus-Updater-Linux/1.0"
local HTTP_OWNER = "updater"
local RELEASE_TIMEOUT_MS = 15000
local MAX_RELEASE_BODY_BYTES = 2 * 1024 * 1024
local DOWNLOAD_TIMEOUT_MS = 5 * 60 * 1000
local MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024
local MAX_CHECKSUM_BODY_BYTES = 4096

-- Interval presets (same as macOS).
M.INTERVAL_PRESETS = {
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

--- Resolves the exact self-update asset emitted by release CI. Unlike timing
--- defaults, this value has no fallback: guessing an asset can install a .deb,
--- RPM, AppImage, or unrelated attachment as though it were the tar bundle.
--- @param defs table Parsed updater defaults.
--- @return string name Canonical release asset name.
local function require_linux_asset_name(defs)
	local assets = type(defs) == "table" and defs.release_assets or nil
	local name = type(assets) == "table" and assets.linux_bundle or nil
	if type(name) ~= "string"
		or not name:match("^[A-Za-z0-9._+-]+$")
		or not name:match("%.tar%.gz$") then
		error("updater defaults do not declare a safe release_assets.linux_bundle", 0)
	end
	return name
end

local LINUX_ASSET_NAME = require_linux_asset_name(_defs)
local LINUX_CHECKSUM_ASSET_NAME = LINUX_ASSET_NAME .. ".sha256"

-- Default check interval (single source: defaults.json timing)
local DEFAULT_INTERVAL_SEC = (_defs.timing and _defs.timing.default_check_interval_sec)
	or _DEFAULTS_FALLBACK.timing.default_check_interval_sec

-- Delay before the first boot check (single source: defaults.json timing)
local BOOT_CHECK_DELAY_SEC = (_defs.timing and _defs.timing.boot_check_delay_sec)
	or _DEFAULTS_FALLBACK.timing.boot_check_delay_sec

-- Exposed for testability — lets the drift/parity test assert the resolved
-- values against the shared defaults.json without reaching into locals
M.GH_OWNER             = GH_OWNER
M.GH_REPO              = GH_REPO
M.DEFAULT_INTERVAL_SEC = DEFAULT_INTERVAL_SEC
M.BOOT_CHECK_DELAY_SEC = BOOT_CHECK_DELAY_SEC
M.LINUX_ASSET_NAME     = LINUX_ASSET_NAME
M.LINUX_CHECKSUM_ASSET_NAME = LINUX_CHECKSUM_ASSET_NAME

-- Path for the ETag cache (one per channel).
local function etag_cache_path(channel)
	local home = require("infra.config_paths").home()
	return home .. "/.cache/ergopti_updater_etag_" .. (channel or "stable") .. ".txt"
end

-- =========================================
-- =========================================
-- ======= 2/ Internal State ===============
-- =========================================
-- =========================================

local _state           = "idle"    -- "idle" | "checking" | "available" | "downloading" | "installing"
local _cached_release  = nil       -- { tag, notes, download_url, published_at, prerelease }
local _last_notified   = ""        -- last tag we showed a tray notification for
local _session_notified = ""       -- throttles repeats when persistence is unavailable
local _bg_timer_handle = nil       -- timer_scheduler handle for background polling
local _boot_timer_handle = nil     -- one-shot boot-check handle
local _check_interval  = DEFAULT_INTERVAL_SEC
local _channel         = "stable" -- "stable" | "dev"
local _download_part   = nil
local _download_dest   = nil
local _verified_archive = nil

-- =========================================
-- =========================================
-- ======= 3/ Persistence ==================
-- =========================================
-- =========================================

local function _storage_get(key, default)
	if Storage then
		return Storage.get(key, default)
	end
	return default
end

local function _storage_set(key, value)
	if Storage then
		return Storage.set(key, value) == true
	end
	return false
end

local function _load_persisted()
	_channel = _storage_get("updater.channel", "stable")
	local interval = _storage_get("updater.interval_sec", nil)
	if type(interval) == "number" and interval >= 0 then
		_check_interval = interval
	end
	_last_notified = _storage_get("updater.last_notified", "")
end

-- =========================================
-- =========================================
-- ======= 4/ GitHub API Helpers ===========
-- =========================================
-- =========================================

--- Builds the GitHub Releases API URL for a given channel.
--- Stable → /releases/latest (single object)
--- Dev    → /releases?per_page=N (sorted array, newest first)
--- @param channel string "stable" | "dev"
--- @return string URL
function M.release_api_url(channel)
	local base = "https://api.github.com/repos/" .. GH_OWNER .. "/" .. GH_REPO .. "/releases"
	if channel == "dev" then
		return base .. "?per_page=" .. tostring(DEV_PAGE_SIZE)
	end
	return base .. "/latest"
end

--- Returns the public releases page URL shown to the user.
function M.releases_page_url()
	return "https://github.com/" .. GH_OWNER .. "/" .. GH_REPO .. "/releases"
end

--- Builds one shell-free conditional GitHub Releases request.
--- @param channel string "stable" | "dev".
--- @return string url
--- @return table headers
--- @return table options
local function _build_fetch_request(channel)
	local etag_file = etag_cache_path(channel)
	local parent = etag_file:match("^(.*)/[^/]+$")
	local options = {
		owner = HTTP_OWNER,
		timeout_ms = RELEASE_TIMEOUT_MS,
		max_body_bytes = MAX_RELEASE_BODY_BYTES,
		follow_redirects = true,
		https_only = true,
	}
	-- curl cannot create an ETag cache parent. Use conditional requests only
	-- when the standard cache directory already exists; never shell out to make
	-- it from the event-loop thread.
	if parent and Fs.exists(parent) then
		options.etag_save = etag_file
		if Fs.exists(etag_file) then options.etag_compare = etag_file end
	end
	return M.release_api_url(channel), {
		Accept = "application/vnd.github+json",
		["User-Agent"] = USER_AGENT,
	}, options
end

M._build_fetch_request = _build_fetch_request

--- Fetches a GitHub Releases response asynchronously.
--- @param channel string
--- @param callback function Receives body, status, error.
--- @return boolean Whether the asynchronous request was dispatched.
local function _fetch_releases(channel, callback)
	local url, headers, options = M._build_fetch_request(channel)
	return M._http_client.get(url, headers, options, function(result)
		local status = tonumber(result and result.status) or 0
		if status == 304 then
			Logger.debug(LOG, "GitHub releases unchanged (304) for channel %s.", channel)
			callback(nil, status, nil)
			return
		end
		if not result or result.ok ~= true then
			if status == 403 then
				Logger.warn(LOG, "GitHub API rate limit (HTTP 403) for channel %s.", channel)
			end
			callback(nil, status, result and result.error or "empty HTTP result")
			return
		end
		if type(result.body) ~= "string" or result.body == "" then
			callback(nil, status, "empty response body")
			return
		end
		callback(result.body, status, nil)
	end)
end

M._fetch_releases = _fetch_releases

--- Normalises the raw release JSON based on channel.
--- Stable: the response IS the release object.
--- Dev: the response is an array — picks the latest prerelease (or first item).
--- @param body string Raw JSON response.
--- @param channel string
--- @return string Normalised release object JSON.
local function _normalize_release_json(body, channel)
	if channel == "dev" and body:match("^%s*%[") then
		return Parser.pick_latest_prerelease(body, Version.compare_versions)
	end
	return body
end

--- Selects only the canonical Linux self-update archive from one release.
--- The shared parser binds name and URL from the same asset object and returns
--- an empty string when the exact attachment is absent.
--- @param body string Raw release JSON.
--- @return string url Exact asset URL, or an empty string.
local function _select_update_asset(body)
	return Parser.parse_asset_url(body, LINUX_ASSET_NAME)
end

M._select_update_asset = _select_update_asset

--- Selects only the checksum published beside the canonical Linux bundle.
--- @param body string Raw release JSON.
--- @return string url Exact checksum asset URL, or an empty string.
local function _select_checksum_asset(body)
	return Parser.parse_asset_url(body, LINUX_CHECKSUM_ASSET_NAME)
end

M._select_checksum_asset = _select_checksum_asset

-- =========================================
-- =========================================
-- ======= 5/ Check & Version Logic ========
-- =========================================
-- =========================================

--- Returns the current driver version.
function M.current_version()
	return DriverVersion.VERSION
end

--- Returns the GitHub repo coordinates (for tests/UI).
function M.repo_info()
	return { owner = GH_OWNER, repo = GH_REPO }
end

--- Applies one validated release response to updater state.
--- @param body string Raw GitHub response body.
--- @param channel string "stable" | "dev".
--- @return boolean Whether a newer canonical Linux release is available.
local function _process_release_response(body, channel)
	body = _normalize_release_json(body, channel)
	local latest_tag = Parser.parse_tag(body)

	if latest_tag == "" then
		Logger.warn(LOG, "Could not parse tag from GitHub response.")
		_state = "idle"
		return false
	end

	local current = M.current_version()

	if current == "local" then
		-- Running from source — always show the latest as available for dev.
		Logger.info(LOG, "Local source — latest release: %s.", latest_tag)
		_cached_release = {
			tag          = latest_tag,
			notes        = Parser.parse_notes(body),
			download_url = _select_update_asset(body),
			checksum_url = _select_checksum_asset(body),
			published_at = Parser.parse_published_at(body),
			prerelease   = Parser.parse_prerelease_flag(body),
		}
		_state = "available"
		return true
	end

	if not Version.is_newer_version(latest_tag, current) then
		Logger.debug(LOG, "Up to date: current %s, latest %s.", current, latest_tag)
		_state = "idle"
		return false
	end

	local asset_url = _select_update_asset(body)
	local checksum_url = _select_checksum_asset(body)
	if asset_url == "" or checksum_url == "" then
		Logger.error(LOG, "Release %s lacks the canonical Linux bundle or checksum (%s, %s).",
			latest_tag, LINUX_ASSET_NAME, LINUX_CHECKSUM_ASSET_NAME)
		_state = "idle"
		return false
	end

	_cached_release = {
		tag          = latest_tag,
		notes        = Parser.parse_notes(body),
		download_url = asset_url,
		checksum_url = checksum_url,
		published_at = Parser.parse_published_at(body),
		prerelease   = Parser.parse_prerelease_flag(body),
	}

	_state = "available"
	Logger.info(LOG, "New release available: %s (current: %s).", latest_tag, current)
	return true
end

M._process_release_response = _process_release_response

--- Calls one optional check completion without allowing UI code to unwind the
--- network callback.
--- @param callback function|nil
--- @param available boolean
--- @param release table|nil
--- @param err string|nil
local function publish_check(callback, available, release, err)
	if type(callback) ~= "function" then return end
	local ok, callback_error = pcall(callback, available, release, err)
	if not ok then Logger.error(LOG, "Update check callback raised: %s.", tostring(callback_error)) end
end

--- Checks the GitHub API for a newer release without blocking the event loop.
--- @param channel string|nil "stable" or "dev"; defaults to active channel.
--- @param callback function|nil Receives available, release, error.
--- @return boolean Whether the asynchronous request was dispatched.
function M.check_for_updates(channel, callback)
	channel = channel or _channel
	if _state == "checking" or _state == "downloading" or _state == "installing" then
		publish_check(callback, false, nil, "updater busy")
		return false
	end
	_state = "checking"
	_cached_release = nil
	local published = false
	local ok, dispatched_or_error = pcall(M._fetch_releases, channel,
		function(body, status, fetch_error)
			published = true
			if not body then
				_state = "idle"
				if status ~= 304 then
					Logger.warn(LOG, "Check failed (HTTP %d): %s.", status or 0,
						tostring(fetch_error or "empty body"))
				end
				publish_check(callback, false, nil, fetch_error)
				return
			end
			local available = M._process_release_response(body, channel)
			publish_check(callback, available, _cached_release, nil)
		end)
	if not ok then
		_state = "idle"
		Logger.error(LOG, "Update request dispatch raised: %s.", tostring(dispatched_or_error))
		publish_check(callback, false, nil, tostring(dispatched_or_error))
		return false
	end
	local dispatched = dispatched_or_error == true
	if not dispatched and not published then
		_state = "idle"
		publish_check(callback, false, nil, "update request was not dispatched")
	end
	return dispatched
end

-- =========================================
-- =========================================
-- ======= 6/ Background Poller ============
-- =========================================
-- =========================================

--- Stops any in-flight background polling timers.
function M.stop_background_checks()
	local stopped = true
	if _bg_timer_handle and Timer then
		if Timer.cancel(_bg_timer_handle) == true then
			_bg_timer_handle = nil
		else
			stopped = false
		end
	end
	if _boot_timer_handle and Timer then
		if Timer.cancel(_boot_timer_handle) == true then
			_boot_timer_handle = nil
		else
			stopped = false
		end
	end
	return stopped
end

--- Starts periodic update checks.
--- The first check fires after boot_check_delay_sec; subsequent checks run
--- every interval_sec seconds.
--- @param channel string|nil "stable" or "dev"; defaults to persisted channel.
--- @param interval_sec number|nil Seconds between checks; defaults to persisted interval.
--- @param on_available function|nil Callback invoked when a new version is found.
function M.start_background_checks(channel, interval_sec, on_available)
	M.stop_background_checks()

	if channel then
		M.set_channel(channel)
	end
	if type(interval_sec) == "number" and interval_sec >= 0 then
		M.set_check_interval(interval_sec)
	end

	if _check_interval <= 0 then
		Logger.debug(LOG, "Check interval 0 — background checks disabled.")
		return true
	end

	if not Timer or Timer.HAS_ASYNC ~= true then
		Logger.error(LOG, "Asynchronous timer capability unavailable — background checks disabled.")
		return false
	end

	local current_version = M.current_version()
	if current_version == "local" then
		Logger.debug(LOG, "Local source — background checks disabled.")
		return true
	end

	local function tick()
		if _state == "checking" or _state == "downloading" or _state == "installing" then return end
		M.check_for_updates(nil, function(available, release)
			if not available or not release then return end
			local tag = release.tag
			if Version.normalize_tag(tag) ~= Version.normalize_tag(_last_notified)
				and Version.normalize_tag(tag) ~= Version.normalize_tag(_session_notified) then
				_session_notified = tag
				if _storage_set("updater.last_notified", tag) then
					_last_notified = tag
				else
					Logger.error(LOG, "The notified release tag could not be persisted; this session is still throttled.")
				end
				Logger.info(LOG, "New release available: %s.", tag)
				if type(on_available) == "function" then
					pcall(on_available, release)
				end
			end
		end)
	end

	local first_delay = math.min(BOOT_CHECK_DELAY_SEC, _check_interval)
	Logger.start(LOG, "Background checks every %ds (first in %ds) on channel '%s'.",
		_check_interval, first_delay, _channel)

	_boot_timer_handle = Timer.after(first_delay, function()
		_boot_timer_handle = nil
		tick()
	end)

	_bg_timer_handle = Timer.every(_check_interval, tick)
	if type(_boot_timer_handle) ~= "table" or _boot_timer_handle.armed ~= true
		or type(_bg_timer_handle) ~= "table" or _bg_timer_handle.armed ~= true then
		if not M.stop_background_checks() then
			Logger.error(LOG, "Failed to roll back partially armed background update timers.")
		end
		Logger.error(LOG, "Background update timers could not be armed.")
		return false
	end
	return true
end

-- =========================================
-- =========================================
-- ======= 7/ Download & Install ===========
-- =========================================
-- =========================================

--- Parses the exact sha256sum record published for the Linux bundle.
--- @param body string
--- @return string|nil digest
--- @return string|nil error
local function parse_checksum(body)
	if type(body) ~= "string" then return nil, "checksum response is not text" end
	local digest, _, filename = body:match("^([0-9a-fA-F]+)%s+([*]?)([^%s]+)%s*$")
	if not digest or #digest ~= 64 or filename ~= LINUX_ASSET_NAME then
		return nil, "checksum record does not bind the canonical Linux bundle"
	end
	return digest:lower(), nil
end

M._parse_checksum = parse_checksum

--- Returns the byte length of a regular file without loading it into memory.
--- @param path string
--- @return number|nil
local function file_size(path)
	local ok, size = pcall(function()
		local handle = io.open(path, "rb")
		if not handle then return nil end
		local value = handle:seek("end")
		handle:close()
		return value
	end)
	return ok and tonumber(size) or nil
end

--- Publishes one download result while restoring updater ownership.
--- @param callback function|nil
--- @param path string|nil
--- @param err string|nil
local function publish_download(callback, path, err)
	_state = path and "available" or "idle"
	_verified_archive = path
	_download_part = nil
	_download_dest = nil
	if err then Logger.error(LOG, "Update download failed: %s.", tostring(err)) end
	if type(callback) ~= "function" then return end
	local ok, callback_error = pcall(callback, path, err)
	if not ok then Logger.error(LOG, "Update download callback raised: %s.", tostring(callback_error)) end
end

--- Removes both sides of a partially published download.
local function remove_partial_download()
	if _download_part then Fs.delete(_download_part) end
	if _download_dest then Fs.delete(_download_dest) end
end

--- Downloads and verifies the canonical update archive asynchronously.
--- @param url string|nil Must match the cached release URL when provided.
--- @param callback function|nil Receives verified path, error.
--- @return boolean Whether the checksum request was dispatched.
function M.download_update(url, callback)
	local release = _cached_release
	local download_url = url or (release and release.download_url)
	if not release or type(download_url) ~= "string" or download_url == ""
		or download_url ~= release.download_url
		or type(release.checksum_url) ~= "string" or release.checksum_url == "" then
		Logger.error(LOG, "No authenticated canonical Linux download is available.")
		if type(callback) == "function" then callback(nil, "authenticated release unavailable") end
		return false
	end
	if _state ~= "available" then
		if type(callback) == "function" then callback(nil, "updater is not ready to download") end
		return false
	end

	local temp_path = os.tmpname()
	if type(temp_path) ~= "string" or temp_path:sub(1, 1) ~= "/" then
		if type(callback) == "function" then callback(nil, "temporary path unavailable") end
		return false
	end
	Fs.delete(temp_path)
	if _verified_archive then Fs.delete(_verified_archive); _verified_archive = nil end
	_download_dest = temp_path .. ".tar.gz"
	_download_part = _download_dest .. ".part"
	remove_partial_download()
	_state = "downloading"

	local function fail(message)
		remove_partial_download()
		publish_download(callback, nil, message)
	end
	local checksum_dispatched = M._http_client.get(release.checksum_url, {
		["User-Agent"] = USER_AGENT,
	}, {
		owner = HTTP_OWNER,
		timeout_ms = RELEASE_TIMEOUT_MS,
		max_body_bytes = MAX_CHECKSUM_BODY_BYTES,
		follow_redirects = true,
		https_only = true,
	}, function(checksum_result)
		if not checksum_result or checksum_result.ok ~= true then
			fail(checksum_result and checksum_result.error or "checksum request failed")
			return
		end
		local expected, checksum_error = parse_checksum(checksum_result.body)
		if not expected then fail(checksum_error); return end

		Logger.info(LOG, "Downloading authenticated update to %s.", _download_part)
		M._http_client.download(download_url, { ["User-Agent"] = USER_AGENT }, _download_part, {
			owner = HTTP_OWNER,
			timeout_ms = DOWNLOAD_TIMEOUT_MS,
			max_download_bytes = MAX_DOWNLOAD_BYTES,
			https_only = true,
		}, function(download_result)
			if not download_result or download_result.ok ~= true then
				fail(download_result and download_result.error or "archive request failed")
				return
			end
			local size = file_size(_download_part)
			if not size or size <= 0 or size > MAX_DOWNLOAD_BYTES then
				fail("downloaded archive has an invalid size")
				return
			end
			M._file_digest.sha256(_download_part, { timeout_ms = RELEASE_TIMEOUT_MS },
				function(actual, digest_error)
					if not actual then fail(digest_error or "archive digest failed"); return end
					if actual ~= expected then fail("SHA-256 checksum mismatch"); return end
					local renamed, rename_error = os.rename(_download_part, _download_dest)
					if not renamed then
						fail("verified archive publication failed: " .. tostring(rename_error))
						return
					end
					local verified_path = _download_dest
					Logger.success(LOG, "Downloaded and verified %d bytes to %s.", size, verified_path)
					publish_download(callback, verified_path, nil)
				end)
		end)
	end)
	if not checksum_dispatched and _state == "downloading" then
		fail("checksum request was not dispatched")
	end
	return checksum_dispatched
end

--- Cancels any in-flight updater transport or digest and removes partial files.
--- @return boolean
function M.cancel_update()
	local http_cancelled = M._http_client.cancel(HTTP_OWNER)
	local digest_cancelled = M._file_digest.cancel()
	if not http_cancelled or not digest_cancelled then return false end
	remove_partial_download()
	_download_part = nil
	_download_dest = nil
	if _state == "checking" or _state == "downloading" then _state = "idle" end
	return true
end

local function module_source_path()
	local source_path = debug.getinfo(1, "S").source
	return source_path:match("^@(.+)$") or source_path
end

M._resolve_installation = function()
	return Installer.resolve(module_source_path())
end

--- Installs the downloaded update into a standalone user installation. System
--- packages and immutable bundles retain ownership of their own update path.
--- @param archive_path string Path to the downloaded archive.
--- @return boolean true on success.
function M.install_update(archive_path)
	if not archive_path or archive_path ~= _verified_archive or not Fs.exists(archive_path) then
		Logger.error(LOG, "Refusing an archive not authenticated by this updater: %s.",
			tostring(archive_path))
		return false
	end

	_state = "installing"
	local context = M._resolve_installation()
	if not context or context.kind ~= "standalone" then
		Logger.error(LOG, "Automatic replacement refused for %s installation: %s.",
			context and context.kind or "unknown",
			context and context.reason or "installation ownership is unknown")
		_state = "available"
		return false
	end

	local expected_version = _cached_release and _cached_release.tag or nil
	local installed, detail = Installer.install({
		archive_path = archive_path,
		expected_version = expected_version,
		context = context,
	})
	if not installed then
		Logger.error(LOG, "Update installation failed: %s.", tostring(detail))
		_state = "available"
		return false
	end
	if detail then Logger.warn(LOG, "%s.", detail) end
	Logger.success(LOG, "Update installed with a verified rollback backup. Restart the daemon to apply.")
	_verified_archive = nil
	_state = "idle"
	return true
end

-- =========================================
-- =========================================
-- ======= 8/ Channel Switching ============
-- =========================================
-- =========================================

--- Returns the active channel.
function M.get_channel()
	return _channel
end

--- Switches the update channel and persists the choice.
--- Clears cached release data when switching channels.
--- @param new_channel string "stable" | "dev"
--- @return boolean Whether the active channel matches the request.
function M.set_channel(new_channel)
	if new_channel ~= "stable" and new_channel ~= "dev" then
		Logger.warn(LOG, "Unknown channel '%s' — keeping '%s'.", tostring(new_channel), _channel)
		return false
	end
	if new_channel == _channel then return true end
	if (_state == "checking" or _state == "downloading") and not M.cancel_update() then
		Logger.error(LOG, "Update channel cannot change while updater ownership is live.")
		return false
	end

	if not _storage_set("updater.channel", new_channel) then
		Logger.error(LOG, "Update channel '%s' could not be persisted — keeping '%s'.", new_channel, _channel)
		return false
	end
	_channel = new_channel
	if _verified_archive then Fs.delete(_verified_archive); _verified_archive = nil end
	_state = "idle"
	_cached_release = nil
	Logger.info(LOG, "Update channel set to '%s' (persisted).", _channel)
	return true
end

--- Returns the current check interval in seconds.
function M.get_check_interval()
	return _check_interval
end

--- Sets the check interval and persists it.
--- @param seconds number
--- @return boolean Whether the active interval matches the request.
function M.set_check_interval(seconds)
	local s = tonumber(seconds)
	if not s or s < 0 then return false end
	local wanted = math.floor(s)
	if wanted == _check_interval then return true end
	if not _storage_set("updater.interval_sec", wanted) then
		Logger.error(LOG, "Check interval %ds could not be persisted — keeping %ds.", wanted, _check_interval)
		return false
	end
	_check_interval = wanted
	Logger.info(LOG, "Check interval set to %ds (persisted).", _check_interval)
	return true
end





-- =========================================
-- =========================================
-- ======= 9/ Public State Accessors =======
-- =========================================
-- =========================================

--- Returns the current update state.
--- @return string "idle" | "checking" | "available" | "downloading" | "installing"
function M.get_state()
	return _state
end

--- Returns the cached latest release, or nil.
--- @return table|nil { tag, notes, download_url, published_at, prerelease }
function M.get_cached_release()
	return _cached_release
end

--- Clears the cached release data.
function M.clear_cached_release()
	if (_state == "checking" or _state == "downloading") and not M.cancel_update() then
		Logger.error(LOG, "Cached release cannot clear while updater ownership is live.")
		return false
	end
	if _verified_archive then Fs.delete(_verified_archive); _verified_archive = nil end
	_cached_release = nil
	_state = "idle"
	return true
end

--- Test seam: places the module in the "an update is available" state without a
--- network round trip, so the label formatting can be exercised directly.
---
--- Reaching that state for real needs a GitHub response, and the one thing worth
--- asserting about it — that the release tag is carried into the localised
--- template intact — is pure formatting.
--- @param release table { tag = string, prerelease = boolean }.
function M._test_set_cached_release(release)
	_cached_release = release
	_state = "available"
end

--- Test seam: authenticates one local fixture as though verification completed.
--- @param path string
function M._test_set_verified_archive(path)
	_verified_archive = path
	_state = "available"
end

--- Returns a user-facing label for the update menu item.
--- @return string
function M.get_menu_label()
	local i18n = require("infra.i18n")
	if _state == "checking" then
		return i18n.get("menu.about.update_checking")
	end
	if _state == "downloading" then
		return i18n.get("menu.about.update_downloading")
	end
	if _state == "installing" then
		return i18n.get("menu.about.update_installing")
	end
	if _state == "available" and _cached_release then
		local tag = tostring(_cached_release.tag) ..
			(_cached_release.prerelease and " (dev)" or "")
		-- Plain-index substitution, not gsub: a tag is user-supplied data and a
		-- "%" in it would be read as a capture reference in gsub's REPLACEMENT
		-- string and raise "invalid use of '%'".
		local template = i18n.get("menu.about.update_now")
		local at = template:find("{tag}", 1, true)
		if not at then return template .. " " .. tag end
		return template:sub(1, at - 1) .. tag .. template:sub(at + 5)
	end
	-- "(dev)" is the channel's own name, the same token in every locale — see
	-- changelog_window.channel_dev, which is "Dev" in English and in French.
	if _channel == "dev" then
		return i18n.get("menu.about.check_for_updates") .. " (dev)"
	end
	return i18n.get("menu.about.check_for_updates")
end

-- =========================================
-- =========================================
-- ======= 10/ Init ========================
-- =========================================
-- =========================================

--- Initialises the updater: loads persisted settings, starts background checks.
--- @param opts table|nil { channel, interval_sec, on_available }
function M.init(opts)
	opts = type(opts) == "table" and opts or {}

	_load_persisted()

	if opts.channel then
		M.set_channel(opts.channel)
	end
	if type(opts.interval_sec) == "number" and opts.interval_sec >= 0 then
		M.set_check_interval(opts.interval_sec)
	end

	Logger.info(LOG, "Updater initialised (channel=%s, interval=%ds, version=%s).",
		_channel, _check_interval, M.current_version())

	local on_available = opts.on_available
	M.start_background_checks(nil, nil, on_available)
end

return M
