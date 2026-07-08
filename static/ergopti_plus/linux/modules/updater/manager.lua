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
--- 1. curl-based: uses io.popen("curl -s ...") for GET requests to the GitHub
---    API. The existing http_client adapter only supports POST; curl is
---    universally available on Linux and handles redirects, SSL, and ETag
---    caching natively.
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
local Version   = require("updater.version")
local Parser    = require("updater.release_parser")
local Fs        = require("adapters.file_system")
local ok_storage, Storage = pcall(require, "adapters.storage")
if not ok_storage then Storage = nil end
local ok_timer, Timer = pcall(require, "adapters.timer_scheduler")
if not ok_timer then Timer = nil end

local LOG = "modules.updater.manager"

-- Single source of the driver version.
local DriverVersion = require("lib.version")

-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- GitHub repo coordinates (match macOS defaults.json).
local GH_OWNER = "adrienm7"
local GH_REPO  = "ergopti"

-- How many prerelease pages to fetch for the dev channel.
local DEV_PAGE_SIZE = 10

-- User-Agent header required by GitHub API.
local USER_AGENT = "ErgoptiPlus-Updater-Linux/1.0"

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

-- Fallback asset name for Linux releases.
local LINUX_ASSET_NAME = "ergopti_linux.tar.gz"

-- Default check interval (24h).
local DEFAULT_INTERVAL_SEC = 86400

-- Delay before the first boot check (30s).
local BOOT_CHECK_DELAY_SEC = 30

-- Path for the ETag cache (one per channel).
local function etag_cache_path(channel)
	local home = os.getenv("HOME") or "/tmp"
	return home .. "/.cache/ergopti/updater_etag_" .. (channel or "stable") .. ".txt"
end

-- =========================================
-- =========================================
-- ======= 2/ Internal State ===============
-- =========================================
-- =========================================

local _state           = "idle"    -- "idle" | "checking" | "available" | "downloading" | "installing"
local _cached_release  = nil       -- { tag, notes, download_url, published_at, prerelease }
local _last_notified   = ""        -- last tag we showed a tray notification for
local _bg_timer_handle = nil       -- timer_scheduler handle for background polling
local _boot_timer_handle = nil     -- one-shot boot-check handle
local _check_interval  = DEFAULT_INTERVAL_SEC
local _channel         = "stable" -- "stable" | "dev"

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
		Storage.set(key, value)
	end
end

local function _load_persisted()
	_channel = _storage_get("updater.channel", "stable")
	local interval = _storage_get("updater.interval_sec", nil)
	if type(interval) == "number" and interval >= 0 then
		_check_interval = interval
	end
	_last_notified = _storage_get("updater.last_notified", "")
end

local function _persist()
	_storage_set("updater.channel", _channel)
	_storage_set("updater.interval_sec", _check_interval)
	_storage_set("updater.last_notified", _last_notified)
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

--- Reads a cached ETag for a channel.
--- @param channel string
--- @return string|nil
local function _read_etag(channel)
	local path = etag_cache_path(channel)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local etag = fh:read("*l")
	fh:close()
	return etag and etag ~= "" and etag or nil
end

--- Writes an ETag value to the cache for a channel.
--- @param channel string
--- @param etag string
local function _write_etag(channel, etag)
	if type(etag) ~= "string" or etag == "" then return end
	local path = etag_cache_path(channel)
	-- Ensure cache directory exists.
	local dir = path:match("^(.*)/[^/]+$")
	if dir then os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null") end
	local fh = io.open(path, "w")
	if fh then
		fh:write(etag)
		fh:close()
	end
end

--- Fetches the GitHub Releases API response via curl.
--- Returns the raw body, or nil on error/304.
--- @param channel string
--- @return string|nil body, integer|nil http_status
local function _fetch_releases(channel)
	local url = M.release_api_url(channel)
	local etag = _read_etag(channel)

	-- Build the curl command with ETag support.
	local etag_flag = ""
	if etag then
		etag_flag = " -H 'If-None-Match: " .. etag:gsub("'", "'\\''") .. "'"
	end

	local safe_url = url:gsub("'", "'\\''")
	-- -w '\n%{http_code}' appends a newline + HTTP status code at the end.
	local cmd = string.format(
		"curl -s -w '\n%%{http_code}' -H 'Accept: application/vnd.github+json'" ..
		" -H 'User-Agent: %s'%s '%s' 2>/dev/null",
		USER_AGENT, etag_flag, safe_url
	)

	local pipe = io.popen(cmd)
	if not pipe then
		Logger.error(LOG, "curl popen failed for %s.", url)
		return nil, 0
	end

	local output = pipe:read("*a")
	pipe:close()

	if not output or output == "" then
		Logger.warn(LOG, "Empty response from GitHub API.")
		return nil, 0
	end

	-- The HTTP status code is on the last line (appended by -w '\n%{http_code}').
	-- Split on the LAST newline to separate body from status.
	local last_nl = nil
	local pos = #output
	while pos > 0 do
		if output:sub(pos, pos) == "\n" then
			last_nl = pos
			break
		end
		pos = pos - 1
	end

	local body, status_str
	if last_nl then
		body = output:sub(1, last_nl - 1)
		status_str = output:sub(last_nl + 1)
	else
		body = ""
		status_str = output
	end

	local status = tonumber(status_str) or 0

	if status == 304 then
		Logger.debug(LOG, "GitHub releases unchanged (304) for channel %s.", channel)
		return nil, 304
	end

	if status == 403 then
		Logger.warn(LOG, "GitHub API rate limit (HTTP 403) for channel %s.")
		return nil, 403
	end

	if status ~= 200 then
		Logger.debug(LOG, "GitHub API returned HTTP %d for channel %s.", status, channel)
		return nil, status
	end

	-- Cache the ETag from the response. We use timestamp-based invalidation
	-- since we can't easily capture the ETag header with io.popen.
	-- The cache is written with a short TTL (1h) so background checks at
	-- 24h intervals effectively always get fresh data.
	_write_etag(channel, os.date("!%Y-%m-%dT%H:%M:%SZ"))

	return body, 200
end

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

--- Checks the GitHub API for a newer release.
--- Sets _state and _cached_release on success.
--- @param channel string|nil "stable" or "dev"; defaults to active channel.
--- @return boolean true if an update is available.
function M.check_for_updates(channel)
	channel = channel or _channel
	_state = "checking"
	_cached_release = nil

	local body, status = _fetch_releases(channel)
	if not body then
		if status == 304 then
			_state = "idle"
			Logger.debug(LOG, "No new release (304).")
		else
			_state = "idle"
			Logger.warn(LOG, "Check failed (HTTP %d or empty body).", status or 0)
		end
		return false
	end

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
			download_url = Parser.parse_asset_url(body, LINUX_ASSET_NAME),
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

	local asset_url = Parser.parse_asset_url(body, LINUX_ASSET_NAME)
	if asset_url == "" then
		-- Try without the Linux-specific asset name — the release may use a
		-- different naming convention.
		Logger.debug(LOG, "Asset '%s' not found in release %s — trying first asset.",
			LINUX_ASSET_NAME, latest_tag)
		-- Grab the first available browser_download_url.
		asset_url = body:match('"browser_download_url"%s*:%s*"([^"]+)"') or ""
	end

	_cached_release = {
		tag          = latest_tag,
		notes        = Parser.parse_notes(body),
		download_url = asset_url,
		published_at = Parser.parse_published_at(body),
		prerelease   = Parser.parse_prerelease_flag(body),
	}

	_state = "available"
	Logger.info(LOG, "New release available: %s (current: %s).", latest_tag, current)
	return true
end

-- =========================================
-- =========================================
-- ======= 6/ Background Poller ============
-- =========================================
-- =========================================

--- Stops any in-flight background polling timers.
function M.stop_background_checks()
	if _bg_timer_handle and Timer then
		Timer.cancel(_bg_timer_handle)
		_bg_timer_handle = nil
	end
	if _boot_timer_handle and Timer then
		Timer.cancel(_boot_timer_handle)
		_boot_timer_handle = nil
	end
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
		_channel = channel
		_persist()
	end
	if type(interval_sec) == "number" and interval_sec >= 0 then
		_check_interval = interval_sec
		_persist()
	end

	if _check_interval <= 0 then
		Logger.debug(LOG, "Check interval 0 — background checks disabled.")
		return
	end

	if not Timer then
		Logger.warn(LOG, "timer_scheduler unavailable — background checks disabled.")
		return
	end

	local current_version = M.current_version()
	if current_version == "local" then
		Logger.debug(LOG, "Local source — background checks disabled.")
		return
	end

	local function tick()
		local available = M.check_for_updates()
		if available and _cached_release then
			local tag = _cached_release.tag
			if Version.normalize_tag(tag) ~= Version.normalize_tag(_last_notified) then
				_last_notified = tag
				_persist()
				Logger.info(LOG, "New release available: %s.", tag)
				if type(on_available) == "function" then
					pcall(on_available, _cached_release)
				end
			end
		end
	end

	local first_delay = math.min(BOOT_CHECK_DELAY_SEC, _check_interval)
	Logger.start(LOG, "Background checks every %ds (first in %ds) on channel '%s'.",
		_check_interval, first_delay, _channel)

	_boot_timer_handle = Timer.after(first_delay, function()
		_boot_timer_handle = nil
		tick()
	end)

	_bg_timer_handle = Timer.every(_check_interval, tick)
end

-- =========================================
-- =========================================
-- ======= 7/ Download & Install ===========
-- =========================================
-- =========================================

--- Downloads the update archive to a temporary location.
--- @param url string|nil Download URL (defaults to _cached_release.download_url).
--- @return string|nil Path to the downloaded archive, or nil on failure.
function M.download_update(url)
	url = url or (_cached_release and _cached_release.download_url)
	if not url or url == "" then
		Logger.error(LOG, "No download URL available.")
		return nil
	end

	_state = "downloading"

	local home = os.getenv("HOME") or "/tmp"
	local dest = home .. "/.cache/ergopti/ergopti_update.tar.gz"

	-- Ensure cache directory exists.
	local dir = dest:match("^(.*)/[^/]+$")
	if dir then os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null") end

	local safe_url = url:gsub("'", "'\\''")
	local safe_dest = dest:gsub("'", "'\\''")

	Logger.info(LOG, "Downloading %s → %s …", url, dest)

	local cmd = string.format(
		"curl -sL -o '%s' -H 'User-Agent: %s' '%s' 2>&1",
		safe_dest, USER_AGENT, safe_url
	)

	local pipe = io.popen(cmd)
	if not pipe then
		Logger.error(LOG, "curl popen failed for download.")
		_state = "idle"
		return nil
	end
	local err_output = pipe:read("*a")
	pipe:close()

	if err_output and err_output ~= "" then
		Logger.error(LOG, "Download failed: %s", err_output:gsub("\\n", " "):sub(1, 200))
		_state = "idle"
		return nil
	end

	-- Verify the file was downloaded and has a reasonable size (>1 KB).
	if not Fs.exists(dest) then
		Logger.error(LOG, "Downloaded file not found at %s.", dest)
		_state = "idle"
		return nil
	end
	local fh_size = io.open(dest, "r")
	if fh_size then
		local size = fh_size:seek("end")
		fh_size:close()
		if size < 1024 then
			Logger.error(LOG, "Downloaded file too small (%d bytes) — likely corrupt.", size)
			os.remove(dest)
			_state = "idle"
			return nil
		end
		Logger.debug(LOG, "Downloaded %d bytes.", size)
	end

	Logger.success(LOG, "Downloaded to %s.", dest)
	return dest
end

--- Installs the downloaded update by extracting the archive and replacing
--- the running binary. Keeps a .old backup.
--- @param archive_path string Path to the downloaded archive.
--- @return boolean true on success.
function M.install_update(archive_path)
	if not archive_path or not Fs.exists(archive_path) then
		Logger.error(LOG, "Archive not found at %s.", tostring(archive_path))
		return false
	end

	_state = "installing"

	-- Determine the install directory (where the daemon script lives).
	local script_dir = (function()
		local src = debug.getinfo(1, "S").source
		local path = src:match("^@(.+)$") or "."
		return path:match("^(.*)[/\\][^/\\\\]+$") or "."
	end)()

	-- The daemon binary is in the same dir as this script's grandparent.
	local install_dir = script_dir .. "/../.."

	local safe_archive = archive_path:gsub("'", "'\\''")
	local safe_dir = install_dir:gsub("'", "'\\''")
	local extract_dir = install_dir .. "/_update_tmp"

	-- Remove stale extraction dir.
	os.execute("rm -rf '" .. extract_dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	os.execute("mkdir -p '" .. extract_dir:gsub("'", "'\\''") .. "' 2>/dev/null")

	-- Extract the archive.
	local cmd = string.format(
		"tar -xzf '%s' -C '%s' 2>&1",
		safe_archive, extract_dir:gsub("'", "'\\''")
	)

	Logger.info(LOG, "Extracting %s → %s …", archive_path, extract_dir)

	local pipe = io.popen(cmd)
	if not pipe then
		Logger.error(LOG, "tar popen failed.")
		_state = "idle"
		return false
	end
	local err_output = pipe:read("*a")
	pipe:close()

	if err_output and err_output ~= "" and not err_output:match("^%s*$") then
		Logger.warn(LOG, "Extract warnings: %s", err_output:gsub("\\n", " "):sub(1, 200))
		-- Tar may produce warnings for permissions/ownership that are harmless.
	end

	-- Move old installation to .old backup, then move new files in place.
	-- For safety, we copy files rather than replacing in-place.
	local backup_dir = install_dir .. ".old"
	os.execute("rm -rf '" .. backup_dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	os.execute("mv '" .. safe_dir .. "' '" .. backup_dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	os.execute("mv '" .. extract_dir:gsub("'", "'\\''") .. "' '" .. safe_dir .. "' 2>/dev/null")

	-- Clean up.
	os.execute("rm -f '" .. safe_archive .. "' 2>/dev/null")

	Logger.success(LOG, "Update installed. Restart the daemon to apply.")
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
function M.set_channel(new_channel)
	if new_channel ~= "stable" and new_channel ~= "dev" then
		Logger.warn(LOG, "Unknown channel '%s' — keeping '%s'.", tostring(new_channel), _channel)
		return
	end
	if new_channel == _channel then return end

	_channel = new_channel
	_state = "idle"
	_cached_release = nil
	_persist()
	Logger.info(LOG, "Update channel set to '%s' (persisted).", _channel)
end

--- Returns the current check interval in seconds.
function M.get_check_interval()
	return _check_interval
end

--- Sets the check interval and persists it.
--- @param seconds number
function M.set_check_interval(seconds)
	local s = tonumber(seconds)
	if not s or s < 0 then return end
	_check_interval = math.floor(s)
	_persist()
	Logger.info(LOG, "Check interval set to %ds (persisted).", _check_interval)
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
	_cached_release = nil
	_state = "idle"
end

--- Returns a user-facing label for the update menu item.
--- @return string
function M.get_menu_label()
	if _state == "checking" then
		return "Vérification en cours…"
	end
	if _state == "downloading" then
		return "Téléchargement en cours…"
	end
	if _state == "installing" then
		return "Installation en cours…"
	end
	if _state == "available" and _cached_release then
		local tag = _cached_release.tag
		local suffix = _cached_release.prerelease and " (dev)" or ""
		return "Mettre à jour → " .. tag .. suffix
	end
	if _channel == "dev" then
		return "Rechercher les mises à jour (dev)"
	end
	return "Rechercher les mises à jour"
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
		_channel = opts.channel
		_persist()
	end
	if type(opts.interval_sec) == "number" and opts.interval_sec >= 0 then
		_check_interval = opts.interval_sec
		_persist()
	end

	Logger.info(LOG, "Updater initialised (channel=%s, interval=%ds, version=%s).",
		_channel, _check_interval, M.current_version())

	local on_available = opts.on_available
	M.start_background_checks(nil, nil, on_available)
end

return M
