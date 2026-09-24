--- modules/updater/manager.lua

--- ==============================================================================
--- MODULE: Updater Manager (Linux)
--- DESCRIPTION:
--- Self-update engine for the Linux driver. Checks the GitHub Releases API,
--- compares versions via the shared semver module, downloads the latest asset,
--- verifies integrity, and performs self-replacement. Owns the subscribed update
--- channel (any channel of the shared registry) and background polling at a
--- configurable interval.
---
--- The channel is config.toml [updater] channel, like on the other drivers;
--- the interval and the last notified tag stay in the storage adapter.
---
--- FEATURES & RATIONALE:
--- 1. Event-loop-owned transport: the shared Linux HTTP adapter spawns curl
---    through libuv. Release checks therefore never block keyboard processing.
--- 2. ETag caching: stores the GitHub ETag header per channel in a temp file
---    so background checks that return 304 Not Modified do not count against
---    the API rate limit. A 304 has no body: it reuses the list this process
---    read, and a request is conditional only while that list is held, so the
---    first request after a start is a full one.
--- 3. Shared parser: delegates JSON parsing to _shared/lua/updater/release_parser.lua
---    which requires no full JSON decoder.
--- 4. Shared channels: every channel reads the same release list and keeps its
---    latest release through _shared/lua/updater/channels.lua (the registry in
---    _shared/modules/updater/channels.json); version order comes from
---    _shared/lua/updater/version.lua.
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
local Channels  = require("updater.channels")
local Schedule  = require("updater.schedule")
local Installer = require("modules.updater.installer")
local Json      = require("json")
local TomlCodec = require("toml_codec")
local TomlWriter = require("toml_codec.writer")
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

--- Resolves the release list every channel reads. No fallback: /releases/latest
--- ignores prereleases and answers 404 while a channel has no release, which is
--- the failure this list replaced.
--- @param defs table Parsed updater defaults.
--- @return string url
local function require_check_releases_url(defs)
	local check = type(defs) == "table" and defs.update_check or nil
	local template = type(check) == "table" and check.releases_url or nil
	if type(template) ~= "string" or not template:find("{owner}/{repo}", 1, true)
		or not template:match("^https://api%.github%.com/") then
		error("updater defaults do not declare update_check.releases_url", 0)
	end
	return (template:gsub("{owner}", function() return GH_OWNER end)
		:gsub("{repo}", function() return GH_REPO end))
end

local CHECK_RELEASES_URL = require_check_releases_url(_defs)

--- Loads the shared update-channel registry. Unlike the timing defaults it has
--- no fallback: a guessed channel list could offer another channel's artifacts.
--- @return table registry updater.channels interpreter.
local function load_channel_registry()
	local path = Paths.shared("modules/updater/channels.json")
	local raw = path and Fs.read(path) or nil
	if type(raw) ~= "string" then error("the shared update channel registry is unreadable", 0) end
	local registry, err = Channels.load(Json.decode(raw))
	if not registry then error("the shared update channel registry is invalid: " .. tostring(err), 0) end
	return registry
end

local CHANNELS = load_channel_registry()
M.CHANNELS = CHANNELS

-- The config.toml section and key of the subscribed channel, as on the other drivers.
local CONFIG_SECTION = "updater"
local CONFIG_CHANNEL_KEY = "channel"

-- User-Agent header required by GitHub API.
local USER_AGENT = "ErgoptiPlus-Updater-Linux/1.0"
local HTTP_OWNER = "updater"
local RELEASE_TIMEOUT_MS = 15000
local MAX_RELEASE_BODY_BYTES = 2 * 1024 * 1024
local DOWNLOAD_TIMEOUT_MS = 5 * 60 * 1000
local MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024
local MAX_CHECKSUM_BODY_BYTES = 4096

--- Resolves the automatic-check timing (presets, backoff, jitter). No fallback:
--- a guessed preset list would tick a row that does not match the cadence.
--- @param defs table Parsed updater defaults.
--- @return table timing defaults.json timing, validated by updater.schedule.
local function require_timing(defs)
	local timing = type(defs) == "table" and defs.timing or nil
	local ok, err = Schedule.validate_timing(timing)
	if not ok then error("updater defaults declare an invalid timing: " .. tostring(err), 0) end
	return timing
end

local TIMING = require_timing(_defs)
M.TIMING = TIMING

-- The shared frequency presets in display order, never last (defaults.json).
M.INTERVAL_PRESETS = TIMING.check_interval_presets

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
	return home .. "/.cache/ergopti_updater_etag_" .. channel .. ".txt"
end

-- =========================================
-- =========================================
-- ======= 2/ Internal State ===============
-- =========================================
-- =========================================

local _state           = "idle"    -- "idle" | "checking" | "available" | "downloading" | "installing"
local _cached_release  = nil       -- { tag, notes, download_url, published_at, prerelease }
local _list_cache      = {}        -- channel -> the last release list a 200 returned
local _last_notified   = ""        -- last tag we showed a tray notification for
local _session_notified = ""       -- throttles repeats when persistence is unavailable
local _bg_timer_handle = nil       -- timer_scheduler handle for background polling
local _boot_timer_handle = nil     -- one-shot boot-check handle
local _check_interval  = DEFAULT_INTERVAL_SEC
local _channel         = nil       -- registry channel id; resolved at the end of this file
local _config_path     = nil       -- config.toml holding [updater] channel; set by init()
local _channel_persisted = false   -- whether config.toml names the channel (else it is the default)
local _installed_launcher = nil  -- wrapper of the installation an update replaced
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

--- Resolves the subscribed channel of a decoded config.toml through the
--- registry (a hand-written alias such as "stable" reads as its channel).
--- @param config table Decoded config.toml.
--- @param mark function|nil mark(...segments), called for the key it takes.
--- @return string|nil id Channel id, or nil when the key is absent or unknown.
--- @return any raw The persisted value, for the caller's log line.
local function _channel_from_config(config, mark)
	local section = config[CONFIG_SECTION]
	local raw = type(section) == "table" and section[CONFIG_CHANNEL_KEY] or nil
	if raw == nil then return nil, nil end
	local id = CHANNELS.resolve(raw)
	if id and mark then mark(CONFIG_SECTION, CONFIG_CHANNEL_KEY) end
	return id, raw
end

--- Reads the subscribed channel from config.toml [updater] channel. An absent
--- file or key yields nil; an unreadable file or an unknown value is logged and
--- yields nil, so the installed build's channel is followed.
--- @param path string|nil config.toml path.
--- @return string|nil id
local function _read_persisted_channel(path)
	if type(path) ~= "string" or path == "" then return nil end
	local content = Fs.read(path)
	if content == nil then return nil end
	local ok, config = pcall(TomlCodec.decode, content)
	if not ok or type(config) ~= "table" then
		Logger.error(LOG, "config.toml could not be parsed; the update channel follows the installed build.")
		return nil
	end
	local id, raw = _channel_from_config(config)
	if raw ~= nil and not id then
		Logger.warn(LOG, "config.toml names an unknown update channel '%s'; following the installed build.",
			tostring(raw))
	end
	return id
end

--- Marks the config.toml paths the updater takes, through the walk init() uses,
--- so the unused-key cleanup never offers the subscribed channel.
--- @param config table Decoded config.toml.
--- @param mark function mark(...segments) from config_unused_keys.
function M.mark_config_reads(config, mark)
	if type(mark) ~= "function" or type(config) ~= "table" then
		error("updater.mark_config_reads needs a decoded config and a mark function", 2)
	end
	_channel_from_config(config, mark)
end

local function _load_persisted()
	local persisted = _read_persisted_channel(_config_path)
	_channel_persisted = persisted ~= nil
	_channel = persisted or M.installed_channel()
	local interval = _storage_get("updater.interval_sec", nil)
	if type(interval) == "number" and interval >= 0 and interval == math.floor(interval) then
		local seconds, code, snapped = Schedule.snap_interval(interval, TIMING)
		if snapped then
			Logger.warn(LOG, "Saved check interval %ds is not a frequency preset — using the nearest one, %ds (%s).",
				interval, seconds, code)
		end
		_check_interval = seconds
	end
	_last_notified = _storage_get("updater.last_notified", "")
end

--- Writes the subscribed channel to config.toml through the shared TOML writer.
--- @param id string Registry channel id.
--- @return boolean committed
local function _persist_channel(id)
	if type(_config_path) ~= "string" or _config_path == "" then
		Logger.error(LOG, "Update channel '%s' cannot be saved: the updater has no config path (init not run).", id)
		return false
	end
	local call_ok, committed, err = pcall(TomlWriter.batch_write, _config_path, {
		{ section = CONFIG_SECTION, key = CONFIG_CHANNEL_KEY, value = id },
	})
	if not call_ok or committed ~= true then
		Logger.error(LOG, "Update channel '%s' could not be written to config.toml: %s.", id,
			tostring(call_ok and err or committed))
		return false
	end
	return true
end

-- =========================================
-- =========================================
-- ======= 4/ GitHub API Helpers ===========
-- =========================================
-- =========================================

--- Returns the GitHub Releases list every channel reads (defaults.json
--- update_check.releases_url). Each channel keeps its own latest release from
--- it through the shared registry.
--- @return string URL
function M.release_api_url()
	return CHECK_RELEASES_URL
end

--- Returns the public releases page URL shown to the user.
function M.releases_page_url()
	return "https://github.com/" .. GH_OWNER .. "/" .. GH_REPO .. "/releases"
end

--- Builds one shell-free conditional GitHub Releases request.
--- @param channel string Registry channel id (keys the ETag cache).
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
	-- it from the event-loop thread. A 304 carries no body, so the request is
	-- conditional only while this process holds the list the saved ETag names.
	if parent and Fs.exists(parent) then
		options.etag_save = etag_file
		if _list_cache[channel] and Fs.exists(etag_file) then options.etag_compare = etag_file end
	end
	return M.release_api_url(), {
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
			local cached = _list_cache[channel]
			if not cached then
				Logger.warn(LOG, "GitHub answered 304 for channel %s without a cached release list.", channel)
				callback(nil, status, "not modified, and no release list is cached")
				return
			end
			Logger.debug(LOG, "GitHub releases unchanged (304) for channel %s; reusing the cached list.", channel)
			callback(cached, status, nil)
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
		_list_cache[channel] = result.body
		callback(result.body, status, nil)
	end)
end

M._fetch_releases = _fetch_releases

--- Returns the JSON object of a channel's latest release in the release list,
--- chosen by the registry's tag rule and semver order (GitHub lists by publish
--- date, so a later stable must not hide a higher dev build or the reverse).
--- @param body string Raw releases array JSON.
--- @param channel string Registry channel id.
--- @return string|nil release Release object JSON, or nil when the list holds none.
local function _select_channel_release(body, channel)
	if not body:match("^%s*%[") then return nil end
	local chunks = Parser.split_releases_array(body)
	local tags = {}
	for index, chunk in ipairs(chunks) do tags[index] = Parser.parse_tag(chunk) end
	local best = CHANNELS.pick_latest(tags, channel)
	return best and chunks[best] or nil
end

M._select_channel_release = _select_channel_release

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

--- Returns the channel of the running build: the registry channel that owns its
--- version, or the unreleased-build channel for a source checkout.
--- @return string id
function M.installed_channel()
	return CHANNELS.channel_for_tag(M.current_version()) or CHANNELS.unreleased_build_channel
end

--- Applies one validated release list to updater state.
--- @param body string Raw GitHub response body (the release list).
--- @param channel string Registry channel id.
--- @return boolean Whether a newer canonical Linux release is available.
local function _process_release_response(body, channel)
	local release = _select_channel_release(body, channel)
	if not release then
		Logger.info(LOG, "Update check result: no release on channel '%s' yet.", channel)
		_cached_release = nil
		_state = "idle"
		return false
	end
	body = release
	local latest_tag = Parser.parse_tag(body)

	if latest_tag == "" then
		Logger.warn(LOG, "Could not parse tag from GitHub response.")
		_cached_release = nil
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

	-- A deliberate switch to another channel offers that channel's latest release
	-- even when semver orders it below the installed build (the same rule as the
	-- other drivers, pinned by channel_vectors.json).
	if not CHANNELS.should_offer(latest_tag, current, channel, M.installed_channel()) then
		-- Info, not debug: "the check ran and found nothing" is the answer a user
		-- asking "why did it not update" needs, and it happens a few times a day.
		Logger.info(LOG, "Update check result: up to date (current %s, latest %s).", current, latest_tag)
		_cached_release = nil
		_state = "idle"
		return false
	end

	local asset_url = _select_update_asset(body)
	local checksum_url = _select_checksum_asset(body)
	if asset_url == "" or checksum_url == "" then
		Logger.error(LOG, "Release %s lacks the canonical Linux bundle or checksum (%s, %s).",
			latest_tag, LINUX_ASSET_NAME, LINUX_CHECKSUM_ASSET_NAME)
		_cached_release = nil
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
--- @param channel string|nil Registry channel id; defaults to the active channel.
--- @param callback function|nil Receives available, release, error.
--- @return boolean Whether the asynchronous request was dispatched.
function M.check_for_updates(channel, callback)
	channel = channel or _channel
	if _state == "checking" or _state == "downloading" or _state == "installing" then
		Logger.info(LOG, "Update check skipped: updater busy (%s).", _state)
		publish_check(callback, false, nil, "updater busy")
		return false
	end
	Logger.info(LOG, "Update check requested on channel '%s'.", tostring(channel))
	-- The release already found stays known until a response replaces it: an
	-- unchanged answer (304, the ETag at work) or a failed request says nothing
	-- new, and used to forget an update the menu had just offered.
	local known = channel == _channel and _cached_release or nil
	_state = "checking"
	local published = false
	local ok, dispatched_or_error = pcall(M._fetch_releases, channel,
		function(body, status, fetch_error)
			published = true
			if not body then
				_cached_release = known
				_state = known and "available" or "idle"
				Logger.warn(LOG, "Check failed (HTTP %d): %s.", status or 0,
					tostring(fetch_error or "empty body"))
				publish_check(callback, known ~= nil, known, fetch_error or "empty body")
				return
			end
			_cached_release = nil
			local available = M._process_release_response(body, channel)
			publish_check(callback, available, _cached_release, nil)
		end)
	if not ok then
		_state = known and "available" or "idle"
		Logger.error(LOG, "Update request dispatch raised: %s.", tostring(dispatched_or_error))
		publish_check(callback, false, nil, tostring(dispatched_or_error))
		return false
	end
	local dispatched = dispatched_or_error == true
	if not dispatched and not published then
		_state = known and "available" or "idle"
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
--- @param channel string|nil Registry channel id; defaults to the persisted channel.
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
					local ok_notify, notify_error = pcall(on_available, release)
					if not ok_notify then
						Logger.error(LOG, "Update-available handler raised: %s.", tostring(notify_error))
					end
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
---
--- A verified archive is cancelled too: set_channel() and
--- clear_cached_release() both delete it, and a cancel that left it on disk
--- with state "available" would keep install_update() working after the user
--- — or the shutdown coordinator — asked for cancellation. An install already
--- in flight owns the archive and its own state, so cancelling transports
--- must not pull either out from under it.
--- @return boolean
function M.cancel_update()
	local http_cancelled = M._http_client.cancel(HTTP_OWNER)
	local digest_cancelled = M._file_digest.cancel()
	if not http_cancelled or not digest_cancelled then return false end
	if _state == "installing" then return true end
	remove_partial_download()
	_download_part = nil
	_download_dest = nil
	if _verified_archive then Fs.delete(_verified_archive); _verified_archive = nil end
	_state = "idle"
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
	Logger.success(LOG, "Update installed with a verified rollback backup.")
	_verified_archive = nil
	_installed_launcher = context.wrapper
	_state = "idle"
	return true
end

--- The launcher of the installation the last update replaced, which starts
--- the new version.
--- @return string|nil
function M.installed_launcher()
	return _installed_launcher
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

--- Switches the update channel and persists it to config.toml [updater] channel.
--- Clears cached release data when switching channels.
--- @param new_channel string Registry channel id (exact; aliases are resolved
---   only where config.toml is read).
--- @return boolean Whether the active channel matches the request.
function M.set_channel(new_channel)
	if type(new_channel) ~= "string" or CHANNELS.channel(new_channel) == nil then
		Logger.warn(LOG, "Unknown channel '%s' — keeping '%s'.", tostring(new_channel), _channel)
		return false
	end
	-- A choice equal to the default is still written: the user picked it, and
	-- a later build of another channel must not move them off it.
	if new_channel == _channel and _channel_persisted then return true end
	if (_state == "checking" or _state == "downloading") and not M.cancel_update() then
		Logger.error(LOG, "Update channel cannot change while updater ownership is live.")
		return false
	end

	if not _persist_channel(new_channel) then
		Logger.error(LOG, "Update channel '%s' could not be persisted — keeping '%s'.", new_channel, _channel)
		return false
	end
	_channel = new_channel
	_channel_persisted = true
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

--- Returns a user-facing label for the check row of the Updates submenu.
--- The row always runs a check, so a found release never renames it: the
--- separate "Download and install <tag>" row names and installs that release.
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
	-- The channel has its own row; checking never grants install consent.
	return i18n.get("menu.about.check_for_updates")
end

-- =========================================
-- =========================================
-- ======= 10/ Init ========================
-- =========================================
-- =========================================

--- Initialises the updater: loads persisted settings, starts background checks.
--- @param opts table|nil { config_path, channel, interval_sec, on_available }
function M.init(opts)
	opts = type(opts) == "table" and opts or {}

	_config_path = opts.config_path or require("infra.config_paths").config("config.toml")
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

-- Until init() reads config.toml, the running build's channel is followed.
_channel = M.installed_channel()

return M
