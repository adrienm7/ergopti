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
--- The channel and the check interval are config.toml [updater] channel and
--- check_interval_seconds, like on the other drivers; the check record (last
--- check, failures, seed, last notified tag) is runtime state in the Storage
--- port under the shared key.
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
--- 5. Background schedule: _shared/lua/updater/schedule.lua decides from the
---    wall clock and the persisted record, so a restart mid-interval does not
---    check at boot and a machine off past its due time catches up after the
---    boot delay. luv timers are monotonic and stop during a suspend, so every
---    timer is bounded by reevaluate_sec and each evaluation re-reads the wall
---    clock; a gap longer than the timer is a wake, which restarts the boot
---    delay. Paused: nothing is dispatched and the record is left as it is.
--- 6. Self-replace: downloads the latest archive, extracts it, and replaces
---    the running binary. A .old backup is kept so the user can revert.
--- 7. A chosen release: the Versions window installs any release of the list it
---    shows through the same download, checksum and install path
---    (release_record, download_release, install_release_archive); only a
---    click there reaches them, never the schedule.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Paths     = require("infra.paths")
local NoReplaceMove = require("infra.no_replace_move")
local Version   = require("updater.version")
local Parser    = require("updater.release_parser")
local CheckResult = require("updater.check_result")
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

-- The config.toml section and keys of the subscribed channel and the check
-- interval, as on the other drivers.
local CONFIG_SECTION = "updater"
local CONFIG_CHANNEL_KEY = "channel"
local CONFIG_INTERVAL_KEY = "check_interval_seconds"

-- User-Agent header required by GitHub API.
local USER_AGENT = "ErgoptiPlus-Updater-Linux/1.0"
local REQUEST_OWNER = "updater"
local RELEASE_TIMEOUT_MS = 15000
local MAX_RELEASE_BODY_BYTES = 2 * 1024 * 1024
-- Transport pages fit the existing 2 MiB ceiling; the canonical URL still
-- determines the total candidate count (100), independently of page size.
local RELEASE_PAGE_SIZE = 20
local _release_fetch_cancel = nil
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

--- Resolves the Storage key of the check record. No fallback: two keys would
--- split the record and re-announce a release after every restart.
--- @param defs table Parsed updater defaults.
--- @return string key
local function require_state_key(defs)
	local section = type(defs) == "table" and defs.check_state or nil
	local key = type(section) == "table" and section.storage_key or nil
	if type(key) ~= "string" or key == "" then
		error("updater defaults do not declare check_state.storage_key", 0)
	end
	return key
end

local CHECK_STATE_KEY = require_state_key(_defs)
M.CHECK_STATE_KEY = CHECK_STATE_KEY

-- Wall clock in epoch seconds; a test seam.
M._now = os.time

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
local _bg_timer_handle = nil       -- the one armed schedule timer (timer_scheduler handle)
local _schedule_generation = 0    -- logical publication owner; independent of timer cleanup
local _schedule_active = false    -- stopped owners cannot publish a held automatic result
local _check_state     = nil       -- persisted check record (updater.schedule); loaded on first use
local _started_at      = nil       -- wall clock of the schedule start or of the last detected wake
local _armed_at        = nil       -- wall clock when the schedule timer was last armed
local _armed_for       = nil       -- its delay in seconds
local _is_paused       = nil       -- pause predicate injected by init()
local _on_available    = nil       -- "a new release was found" callback injected by init()
local _check_interval  = DEFAULT_INTERVAL_SEC
local _channel         = nil       -- registry channel id; resolved at the end of this file
local _config_path     = nil       -- config.toml holding [updater] channel; set by init()
local _channel_persisted = false   -- whether config.toml names the channel (else it is the default)
local _installed_launcher = nil  -- wrapper of the installation an update replaced
local _download_part   = nil
local _download_dest   = nil
local native_transfer, native_verified, native_install, native_channel_intent
local native_generation = 0
local _verified_archive = nil
local _verified_release = nil      -- the release record the verified archive belongs to

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
	local section = config[CONFIG_SECTION]
	if type(section) == "table" and section[CONFIG_INTERVAL_KEY] ~= nil then
		mark(CONFIG_SECTION, CONFIG_INTERVAL_KEY)
	end
end

--- Reads config.toml [updater] check_interval_seconds, snapped to the nearest
--- shared preset. An absent file or key yields the shared default; a value that
--- is not a whole number of seconds is logged and yields the default.
--- @param path string|nil config.toml path.
--- @return number seconds
local function _read_persisted_interval(path)
	if type(path) ~= "string" or path == "" then return DEFAULT_INTERVAL_SEC end
	local content = Fs.read(path)
	if content == nil then return DEFAULT_INTERVAL_SEC end
	local ok, config = pcall(TomlCodec.decode, content)
	if not ok or type(config) ~= "table" then return DEFAULT_INTERVAL_SEC end
	local section = config[CONFIG_SECTION]
	local raw = type(section) == "table" and section[CONFIG_INTERVAL_KEY] or nil
	if raw == nil then return DEFAULT_INTERVAL_SEC end
	if type(raw) ~= "number" or raw < 0 or raw ~= math.floor(raw) then
		Logger.warn(LOG, "config.toml check_interval_seconds '%s' is not a whole number of seconds; using %ds.",
			tostring(raw), DEFAULT_INTERVAL_SEC)
		return DEFAULT_INTERVAL_SEC
	end
	local seconds, code, snapped = Schedule.snap_interval(raw, TIMING)
	if snapped then
		Logger.warn(LOG, "config.toml check_interval_seconds %ds is not a frequency preset — using the nearest one, %ds (%s).",
			raw, seconds, code)
	end
	return seconds
end

--- Saves the check record. A refused write still advances this session's
--- copy, so a failing Storage port cannot turn every evaluation into a check.
--- @param state table Sanitized record.
--- @return boolean saved
local function _save_check_state(state)
	_check_state = state
	if _storage_set(CHECK_STATE_KEY, state) then return true end
	Logger.error(LOG, "The update-check record could not be saved; this session keeps its copy.")
	return false
end

--- Returns the check record, loading it once. Invalid fields are dropped with a
--- warning; a missing install seed (for the per-install jitter) is created.
--- @return table state
local function _load_check_state()
	if _check_state then return _check_state end
	local state, dropped = Schedule.sanitize_state(_storage_get(CHECK_STATE_KEY, nil))
	for _, field in ipairs(dropped) do
		Logger.warn(LOG, "Dropped the invalid '%s' of the stored update-check record.", field)
	end
	_check_state = state
	if state.seed == nil then
		-- Spread, not secrecy: installs first run at different times.
		state.seed = string.format("%08x%08x", M._now() % 4294967296, math.floor(os.clock() * 1000000) % 4294967296)
		_save_check_state(state)
	end
	Logger.debug(LOG, "Update-check record loaded (last check %s, failures %d).",
		tostring(state.last_check_at or "never"), state.failures or 0)
	return state
end

M._load_check_state = _load_check_state

local function _load_persisted()
	local persisted = _read_persisted_channel(_config_path)
	_channel_persisted = persisted ~= nil
	_channel = persisted or M.installed_channel()
	_check_interval = _read_persisted_interval(_config_path)
	_check_state = nil
	_load_check_state()
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
local function _build_fetch_request(channel, page)
	local cache_key = page and (channel .. "-page-" .. page .. "-size-" .. RELEASE_PAGE_SIZE) or channel
	local etag_file = etag_cache_path(cache_key)
	local parent = etag_file:match("^(.*)/[^/]+$")
	local options = {
		owner = REQUEST_OWNER,
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
		if _list_cache[cache_key] and Fs.exists(etag_file) then options.etag_compare = etag_file end
	end
	local url = M.release_api_url()
	if page then
		url = url:gsub("per_page=%d+", "per_page=" .. RELEASE_PAGE_SIZE) .. "&page=" .. page
	end
	return url, {
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
	local count = tonumber(M.release_api_url():match("[?&]per_page=(%d+)"))
	if not count or count < 1 or count % RELEASE_PAGE_SIZE ~= 0 then
		callback(nil, 0, "release candidate count must be a multiple of the transport page size", "unexpected")
		return false
	end
	local chunks, terminal, all_unchanged = {}, false, true
	local active_key
	local cancel
	-- reason: the updater.check_result reason a failure is shown with
	local function finish(body, status, err, reason)
		if terminal then return end
		terminal = true
		-- Native etag_save can advance its file before transport/JSON acceptance.
		-- A failed page must fetch fully next time, never pair that file with its
		-- older cached body. Successfully accepted pages retain their association.
		if body == nil and active_key then _list_cache[active_key] = nil end
		if _release_fetch_cancel == cancel then _release_fetch_cancel = nil end
		callback(body, status, err, reason)
	end
	cancel = function() finish(nil, 0, "cancelled", "unexpected") end
	_release_fetch_cancel = cancel
	local fetch_page
	fetch_page = function(page)
		local url, headers, options = M._build_fetch_request(channel, page)
		local key = channel .. "-page-" .. page .. "-size-" .. RELEASE_PAGE_SIZE
		active_key = key
		local answered = false
		local sent = M._http_client.get(url, headers, options, function(result)
			if terminal or answered then return end
			answered = true
			local status = tonumber(result and result.status) or 0
			local body = result and result.body
			if status == 304 then
				-- Curl retains 304 on a failed transfer; only a completed response
				-- carries error_body and can validate the cached page's ETag.
				if type(result.error_body) ~= "string" then
					finish(nil, status, "incomplete conditional response", "no_connection")
					return
				end
				body = _list_cache[key]
				if not body then
					Logger.warn(LOG, "GitHub answered 304 for channel %s page %d without a cached release page.", channel, page)
					finish(nil, status, "not modified, and no release page is cached", "unexpected")
					return
				end
				Logger.debug(LOG, "GitHub releases unchanged (304) for channel %s page %d; reusing the cached page.", channel, page)
			elseif not result or result.ok ~= true then
				if status == 403 then Logger.warn(LOG, "GitHub API rate limit (HTTP 403) for channel %s page %d.", channel, page) end
				finish(nil, status, result and result.error or "empty HTTP result", "no_connection")
				return
			else
				all_unchanged = false
			end
			local valid, decoded = pcall(Json.decode_lossless, body)
			if not valid or type(body) ~= "string" or not body:match("^%s*%[")
				or type(decoded) ~= "table" then
				finish(nil, status, "invalid release page JSON", "parse_failed")
				return
			end
			local entries = Parser.split_releases_array(body)
			if #entries ~= #decoded or #entries > RELEASE_PAGE_SIZE then
				finish(nil, status, "invalid release page entries", "parse_failed")
				return
			end
			_list_cache[key] = body
			for _, entry in ipairs(entries) do chunks[#chunks + 1] = entry end
			if #entries < RELEASE_PAGE_SIZE or #chunks == count then
				finish("[" .. table.concat(chunks, ",") .. "]", all_unchanged and 304 or 200, nil)
			else
				fetch_page(page + 1)
			end
		end)
		if sent ~= true and not answered then finish(nil, 0, "release page dispatch refused", "no_connection") end
		return sent == true
	end
	return fetch_page(1)
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

--- The installable record of one release object of the release list: its tag
--- and the canonical Linux bundle with its checksum, or nil when the release
--- lacks either (it cannot be installed on this system).
--- @param body string Raw release object JSON.
--- @return table|nil record { tag, notes, download_url, checksum_url, published_at, prerelease }
function M.release_record(body)
	if type(body) ~= "string" or body == "" then return nil end
	local tag = Parser.parse_tag(body)
	local asset_url = _select_update_asset(body)
	local checksum_url = _select_checksum_asset(body)
	if tag == "" or asset_url == "" or checksum_url == "" then return nil end
	return {
		tag          = tag,
		notes        = Parser.parse_notes(body),
		download_url = asset_url,
		checksum_url = checksum_url,
		published_at = Parser.parse_published_at(body),
		prerelease   = Parser.parse_prerelease_flag(body),
	}
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
--- @return string|nil refusal "no_asset" when the offered release lacks the
---   canonical Linux bundle or its checksum.
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
		return false, "no_asset"
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
--- @param result table The updater.check_result answer the update-check window shows.
local function publish_check(callback, available, release, err, result)
	if type(callback) ~= "function" then return end
	local ok, callback_error = pcall(callback, available, release, err, result)
	if not ok then Logger.error(LOG, "Update check callback raised: %s.", tostring(callback_error)) end
end

--- Checks the GitHub API for a newer release without blocking the event loop.
--- @param channel string|nil Registry channel id; defaults to the active channel.
--- @param callback function|nil Receives available, release, error and the
---   updater.check_result answer (state, latest, other channels, reason).
--- @return boolean Whether the asynchronous request was dispatched.
function M.check_for_updates(channel, callback)
	channel = channel or _channel
	local base = { channel = channel, current = M.current_version() }
	if native_channel_intent or _state == "checking" or _state == "downloading" or _state == "installing" then
		Logger.info(LOG, "Update check skipped: updater busy (%s).", _state)
		publish_check(callback, false, nil, "updater busy",
			CheckResult.failure(base, "unexpected", "the updater is busy (" .. _state .. ")"))
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
		function(body, status, fetch_error, reason)
			published = true
			if not body then
				_cached_release = known
				_state = known and "available" or "idle"
				Logger.warn(LOG, "Check failed (HTTP %d): %s.", status or 0,
					tostring(fetch_error or "empty body"))
				-- A failure the fetch did not classify is not claimed as a network one
				if reason == nil then
					Logger.error(LOG, "The release fetch failed without a reason; the check reports it as unexpected.")
				end
				publish_check(callback, known ~= nil, known, fetch_error or "empty body",
					CheckResult.failure(base, reason or "unexpected", fetch_error or "empty body"))
				return
			end
			_cached_release = nil
			local available, refusal = M._process_release_response(body, channel)
			local result = CheckResult.classify(body, {
				registry = CHANNELS, channel = channel,
				current = base.current, installed = M.installed_channel(),
			})
			if available then
				-- A source checkout is offered the channel's latest release too.
				result.state, result.latest = "available", _cached_release.tag
			elseif refusal == "no_asset" then
				result = CheckResult.failure({ channel = channel, current = base.current, latest = result.latest },
					"no_asset", "the release lacks the canonical Linux bundle or its checksum")
			end
			publish_check(callback, available, _cached_release, nil, result)
		end)
	if not ok then
		_state = known and "available" or "idle"
		Logger.error(LOG, "Update request dispatch raised: %s.", tostring(dispatched_or_error))
		publish_check(callback, false, nil, tostring(dispatched_or_error),
			CheckResult.failure(base, "unexpected", dispatched_or_error))
		return false
	end
	local dispatched = dispatched_or_error == true
	if not dispatched and not published then
		_state = known and "available" or "idle"
		publish_check(callback, false, nil, "update request was not dispatched",
			CheckResult.failure(base, "no_connection", "the update request was not dispatched"))
	end
	return dispatched
end

-- =========================================
-- =========================================
-- ======= 6/ Background Poller ============
-- =========================================
-- =========================================

--- Stops the schedule timer.
--- @return boolean stopped False when the timer could not be released.
function M.stop_background_checks()
	_schedule_active = false
	_schedule_generation = _schedule_generation + 1
	if _bg_timer_handle and Timer then
		if Timer.cancel(_bg_timer_handle) ~= true then return false end
		_bg_timer_handle = nil
	end
	return true
end

local function _schedule_current(generation)
	return _schedule_active == true and generation == _schedule_generation
end

--- Records one completed background check and announces a new release once.
--- @param ok boolean Whether GitHub answered with a usable release list.
--- @param available boolean
--- @param release table|nil
--- @param generation number Captured logical schedule owner.
local function _complete_background_check(ok, available, release, generation)
	if not _schedule_current(generation) then return end
	local state = Schedule.record_check(_load_check_state(), M._now(), ok)
	_save_check_state(state)
	Logger.info(LOG, "Background check recorded: %s (consecutive failures: %d).",
		ok and "success" or "failure", state.failures)
	if not available or not release then return end
	if Version.normalize_tag(release.tag) == Version.normalize_tag(state.last_notified_tag or "") then
		Logger.info(LOG, "Background check result: %s available, already notified.", release.tag)
		return
	end
	local notified = {}
	for field, value in pairs(state) do notified[field] = value end
	if not _schedule_current(generation) then return end
	Logger.info(LOG, "New release available: %s.", release.tag)
	if type(_on_available) ~= "function" then
		Logger.error(LOG, "Update notification has no registered handler.")
		return
	end
	local ok_notify, accepted = pcall(_on_available, release)
	if not ok_notify then
		Logger.error(LOG, "Update-available handler raised: %s.", tostring(accepted))
		return
	end
	if accepted ~= true then
		Logger.error(LOG, "Update notification was not accepted: %s.", tostring(accepted))
		return
	end
	if not _schedule_current(generation) then return end
	notified.last_notified_tag = release.tag
	_save_check_state(notified)
end

local _arm_schedule

--- One evaluation of the schedule: re-reads the wall clock, re-arms the one
--- timer, and dispatches a check only when one is due and the driver runs.
local function _evaluate_schedule()
	if _schedule_active ~= true then return end
	_bg_timer_handle = nil
	local now = M._now()
	-- A luv timer does not advance during a suspend: a wall-clock gap longer
	-- than the delay it was armed for is a wake, after which the network needs
	-- the boot delay before a catch-up check.
	if _armed_at and _armed_for and now - _armed_at > _armed_for + TIMING.reevaluate_sec then
		Logger.info(LOG, "Wake detected (%ds since the schedule timer was armed for %ds).",
			now - _armed_at, _armed_for)
		_started_at = now
	end
	local due_at, reason = Schedule.next_due({
		now = now, started_at = _started_at or now, interval = _check_interval,
		state = _load_check_state(), timing = TIMING,
	})
	if due_at == nil then
		Logger.debug(LOG, "Automatic update checks are off (%s).", reason)
		return
	end
	if due_at > now then
		_arm_schedule(Schedule.delay_until(due_at, now, TIMING))
		return
	end
	-- Re-evaluate after the bounded period whatever happens below: the check's
	-- completion records it, and the next due time follows from that record.
	_arm_schedule(TIMING.reevaluate_sec)
	if type(_is_paused) == "function" and _is_paused() == true then
		Logger.debug(LOG, "Update check due (%s) but the driver is paused; the record is left as it is.", reason)
		return
	end
	if native_channel_intent or _state == "checking" or _state == "downloading" or _state == "installing" then
		Logger.info(LOG, "Update check due (%s) but the updater is busy (%s).", reason, _state)
		return
	end
	Logger.info(LOG, "Background update check due (%s).", reason)
	local generation, completed = _schedule_generation, false
	M.check_for_updates(nil, function(available, release, err)
		if completed or not _schedule_current(generation) then return end
		completed = true
		_complete_background_check(err == nil, available, release, generation)
	end)
end

M._evaluate_schedule = _evaluate_schedule

--- Arms the one schedule timer.
--- @param delay_sec number
--- @return boolean armed
_arm_schedule = function(delay_sec)
	local generation = _schedule_generation
	local handle = Timer.after(delay_sec, function()
		if _schedule_current(generation) then _evaluate_schedule() end
	end)
	if type(handle) ~= "table" or handle.armed ~= true then
		Logger.error(LOG, "The update-check schedule timer could not be armed.")
		return false
	end
	_bg_timer_handle = handle
	_armed_at = M._now()
	_armed_for = delay_sec
	return true
end

--- Starts the automatic-check schedule from the persisted record: the boot
--- delay for a fresh install or an overdue check, the remaining wait otherwise.
--- @param channel string|nil Registry channel id; defaults to the persisted channel.
--- @param interval_sec number|nil Seconds between checks; defaults to persisted interval.
--- @param on_available function|nil Replaces the "new release" callback.
--- @return boolean started False when the timer capability is missing or refused.
function M.start_background_checks(channel, interval_sec, on_available)
	if not M.stop_background_checks() then
		Logger.error(LOG, "The previous update-check timer could not be released; the schedule is not restarted.")
		return false
	end
	if type(on_available) == "function" then _on_available = on_available end

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
		-- luv is optional: install.sh installs it where the distribution packages
		-- it for LuaJIT and degrades without it. A missing optional capability is a
		-- degraded feature, not a fault: as an ERROR it opened the error window at
		-- every start of such an install (hardening-a-startup-zero-error).
		Logger.warn(LOG, "Asynchronous timers are unavailable (luv is not installed) — background update checks disabled.")
		return false
	end

	local current_version = M.current_version()
	if current_version == "local" then
		Logger.debug(LOG, "Local source — background checks disabled.")
		return true
	end

	_schedule_active = true
	_started_at = _started_at or M._now()
	local now = M._now()
	local due_at, reason = Schedule.next_due({
		now = now, started_at = _started_at, interval = _check_interval,
		state = _load_check_state(), timing = TIMING,
	})
	local first_delay = due_at and Schedule.delay_until(due_at, now, TIMING) or TIMING.reevaluate_sec
	Logger.start(LOG, "Background checks every %ds on channel '%s' (next evaluation in %ds, %s).",
		_check_interval, _channel, first_delay, reason)
	if not _arm_schedule(first_delay) then
		_schedule_active = false
		Logger.error(LOG, "Background update checks could not start.")
		return false
	end
	Logger.success(LOG, "Background update checks scheduled.")
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
--- @param stage string|nil "download" or "verify": where a failure happened.
--- @param release table|nil The release the archive belongs to.
--- @param failure_state string The updater state a failure returns to.
--- @param failure_receipt table|nil Structured native evidence, never inferred from err.
local function publish_download(callback, path, err, stage, release, failure_state, failure_receipt)
	_state = path and "available" or failure_state
	_verified_archive = path
	_verified_release = path and release or nil
	_download_part = nil
	_download_dest = nil
	if err then Logger.error(LOG, "Update download failed (%s): %s.", tostring(stage), tostring(err)) end
	if type(callback) ~= "function" then return end
	local ok, callback_error = pcall(callback, path, err, path and nil or stage, failure_receipt)
	if not ok then Logger.error(LOG, "Update download callback raised: %s.", tostring(callback_error)) end
end

--- Removes the reserved partial file; the destination is not owned until publish.
local function remove_partial_download()
	if _download_part then Fs.delete(_download_part) end
end

--- Downloads one release's archive and its published checksum, and keeps the
--- archive only when its SHA-256 matches.
--- @param release table { tag, download_url, checksum_url }
--- @param download_url string
--- @param callback function|nil Receives verified path, error, failing stage, native failure receipt.
--- @param failure_state string The updater state a failure returns to.
--- @return boolean Whether the checksum request was dispatched.
-- Branded native artifacts retain physical owners; display paths are information.
local function release_snapshot(release)
 if type(release) ~= "table" then return nil end
 local copy = {}
 for _, name in ipairs({ "tag", "download_url", "checksum_url" }) do
  local value = rawget(release, name)
  if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then return nil end
  copy[name] = value
 end
 return copy
end
local function retire_verified_artifact()
 if not native_verified then return true end
 if native_install then return false end
 local owned = native_verified
 owned.cancelled = true
 local called, settled = pcall(owned.methods.retire_artifact, owned.brand)
 if not called or settled ~= true or native_verified ~= owned then return false end
 native_verified, _verified_archive, _verified_release = nil, nil, nil
 return true
end
local function native_source(record)
 if native_transfer ~= record or record.cancelled or record.done or record.generation ~= native_generation
  or M._http_client ~= record.http then return false end
 for _, key in ipairs({ "tag", "download_url", "checksum_url" }) do
  if rawget(record.release, key) ~= record.selected[key] then return false end
 end
 local inspected, current
 if record.execution then inspected, current = pcall(record.execution)
 elseif type(record.pause) == "function" then
  local called, paused = pcall(record.pause); inspected, current = called, paused == false
 else return false end
 if not inspected or current ~= true then return false end
 for _, key in ipairs({ "tag", "download_url", "checksum_url" }) do
  if rawget(record.release, key) ~= record.selected[key] then return false end
 end
 return native_transfer == record and not record.cancelled and not record.done
  and record.generation == native_generation and M._http_client == record.http
  and _channel == record.channel and (record.execution ~= nil or _is_paused == record.pause)
end
local function capture_operation(operation)
 if type(operation) ~= "table" then return nil end
 local methods = { is_settled = rawget(operation, "is_settled"),
  on_settled = rawget(operation, "on_settled"), cancel = rawget(operation, "request_cancel") or rawget(operation, "cancel") }
 if type(methods.is_settled) ~= "function" or type(methods.on_settled) ~= "function" or type(methods.cancel) ~= "function" then return nil end
 return methods
end
local function start_native_download(release, download_url, callback, failure_state, execution)
 if native_transfer or native_install or native_channel_intent then return false end
 local selected = release_snapshot(release)
 if not selected or selected.download_url ~= download_url or (execution ~= nil and type(execution) ~= "function") then return false end
 local previous_state, predecessor = _state, native_verified
 native_generation = native_generation + 1
 local record = { selected = selected, release = release, http = M._http_client, pause = _is_paused,
  generation = native_generation, channel = _channel, constructing = true, received = false, done = false, execution = execution }
 native_transfer = record -- Reserve admission before retiring any previous verified artifact.
 _state = "downloading"
 local function early_refusal(message)
  if native_transfer == record then
   record.done, native_transfer = true, nil
   _state = previous_state
  end
  -- Preserve predecessor metadata on source refusal. This is a known
  -- pre-acquisition failure, not a failed replacement of its verified archive.
  if type(callback) == "function" then pcall(callback, nil, message, "download") end
  return false
 end
 if not native_source(record) or native_verified ~= predecessor then return early_refusal("update transfer source refused") end
 if not retire_verified_artifact() or not native_source(record) or native_transfer ~= record then
  return early_refusal("previous native archive retirement refused")
 end
 local deliver
 local function terminal(path, err, stage, receipt, brand)
  if record.received then return end
  record.received = true
  record.result = { path = path, error = err, stage = stage, receipt = receipt, brand = brand }
  if deliver then deliver() end
 end
 deliver = function()
  if record.delivering or record.constructing or record.done or record.unknown or not record.operation then return end
  local operation, captured_result = record.operation, record.result
  local function intact()
   return native_transfer == record and not record.done and not record.unknown and not record.constructing
    and record.generation == native_generation and rawequal(record.operation, operation)
    and rawequal(record.result, captured_result)
  end
  record.delivering = true -- Includes physical source and namespace-cleanup probes.
  local guarded = pcall(function()
   if not intact() then return end
   local checked, physical = pcall(record.methods.is_settled, operation)
   if not checked or physical ~= true or not intact() then return end
   local result = captured_result or { error = "update transaction cancelled", stage = "download" }
   if result.path ~= nil and not record.cancelled then
    local inspected, current_source = pcall(native_source, record)
    if not intact() then return end
    if not inspected or current_source ~= true then
     record.cancelled = true
     result.error, result.stage = "update source revoked before archive publication", "download"
    end
   end
   if record.cancelled and result.brand ~= nil then
    -- Logical cancellation after physical transfer completion must still join
    -- the actual committed native namespace; transfer ACK alone is insufficient.
    local retired, closed = pcall(record.artifact_methods.retire_artifact, result.brand)
    if not intact() then return end
    if not retired or closed ~= true then
     if not record.artifact_observing then
      record.artifact_observing = true
      local watched, ack = pcall(record.artifact_methods.on_artifact_settled, result.brand, deliver)
      if not watched or ack ~= true then record.unknown = true end
     end
     return
    end
   end
   if not intact() then return end
   if record.cancelled then result.path, result.brand = nil, nil end
   local receiving_failure_state = failure_state
   if record.received and record.original_started == false and record.closed_allocation_refusal == true
    and result.path == nil and result.brand == nil and type(result.error) == "string" and result.stage == "download" then
    -- Preserve the pre-acquisition offer only for the fixed allocator fact.
    -- Error text and a missing target alone do not grant this receiving law.
    local checked, source_current = pcall(native_source, record)
    if not intact() then return end
    if checked and source_current == true and not record.cancelled then receiving_failure_state = previous_state end
   end
   record.done, native_transfer = true, nil -- Consume publication before logger/caller reentry.
   if type(result.path) == "string" and result.brand ~= nil then
    native_verified = { factory = record.artifact, methods = record.artifact_methods, brand = result.brand,
     transaction = record.transaction, selected = selected, path = result.path, cancelled = false }
   end
   publish_download(callback, result.path, result.error, result.stage, selected, receiving_failure_state, result.receipt)
  end)
  record.delivering = false
  if not guarded then
   record.unknown = true
   if not record.signalled then record.signalled = true; pcall(record.methods.cancel, operation) end
  elseif not record.done and not rawequal(record.result, captured_result) then
   deliver() -- Only a new authentic first terminal receipt warrants another admission.
  end
 end
 local initialized, flow = pcall(function()
  local Output = require("infra.archive_output")
  local Transfer = require("modules.updater.archive_transfer")
  local Clock = require("infra.monotonic")
  local native_artifact = rawget(Output, "native_artifact")
  local make_transfer = rawget(Transfer, "new")
  if type(native_artifact) ~= "function" or type(make_transfer) ~= "function"
   or type(rawget(Clock, "has_hires")) ~= "function" or Clock.has_hires() ~= true
   or type(rawget(Clock, "backend")) ~= "function" or Clock.backend() ~= "luv.hrtime" then return nil end
  local artifact = native_artifact(LINUX_ASSET_NAME)
  if type(artifact) ~= "table" then return nil end
  local methods = {}
  for _, name in ipairs({ "retire_artifact", "artifact_settled", "on_artifact_settled", "begin_install", "install_current", "install_feed", "finish_install" }) do
   methods[name] = rawget(artifact, name)
   if type(methods[name]) ~= "function" then return nil end
  end
  record.artifact, record.artifact_methods = artifact, methods
  local clock = rawget(Clock, "now_ms")
  if type(clock) ~= "function" then return nil end
  return make_transfer({ http = record.http, artifact = artifact, defaults = _defs, clock = clock,
   current = function(token)
    if record.transaction == nil then record.transaction = token end
    return rawequal(record.transaction, token) and native_source(record)
   end,
   parse_checksum = parse_checksum, owner = REQUEST_OWNER, headers = { ["User-Agent"] = USER_AGENT },
   max_download_bytes = MAX_DOWNLOAD_BYTES, max_checksum_bytes = MAX_CHECKSUM_BODY_BYTES })
 end)
 local started, operation
 if initialized and type(flow) == "table" and type(rawget(flow, "start")) == "function" then
  record.flow = flow
  started, operation = pcall(rawget(flow, "start"), flow, release, terminal)
 end
 if started and type(operation) == "table" then
  record.operation, record.methods = operation, capture_operation(operation)
  record.original_started = rawget(operation, "started") -- Snapshot before any physical observer/source probe.
  record.closed_allocation_refusal = rawget(operation, "closed_allocation_refusal") == true
  if record.methods then
   local observed, ack = pcall(record.methods.on_settled, operation, deliver)
   if not observed or ack ~= true then record.unknown = true end
  else record.unknown = true end
 elseif started == false then record.unknown = true end
 record.constructing = false
 if not record.operation and not record.unknown then
  record.done, native_transfer = true, nil
  publish_download(callback, nil, "native archive component unavailable", "download", selected, failure_state)
  return false -- No pathname reopen/legacy transport fallback.
 end
 if record.unknown or record.cancelled then
  if record.methods then pcall(record.methods.cancel, record.operation) end
 end
 deliver()
 -- A known terminal refusal with the exact original physical ACK did not
 -- dispatch transport. Pending/queued owners keep their existing admission.
 if record.received and record.done and record.original_started == false then return false end
 return record.operation ~= nil and not record.unknown -- Exact owned transaction admission, not HTTP success.
end

local function start_download(release, download_url, callback, failure_state, execution)
 return start_native_download(release, download_url, callback, failure_state, execution)
end

--- Downloads and verifies the canonical update archive asynchronously.
--- @param url string|nil Must match the cached release URL when provided.
--- @param callback function|nil Receives verified path, error, failing stage, native failure receipt.
--- @return boolean Whether the checksum request was dispatched.
function M.download_update(url, callback)
 if native_channel_intent then return false end
	local release = _cached_release
	local download_url = url or (release and release.download_url)
	if not release or type(download_url) ~= "string" or download_url == ""
		or download_url ~= release.download_url
		or type(release.checksum_url) ~= "string" or release.checksum_url == "" then
		Logger.error(LOG, "No authenticated canonical Linux download is available.")
		if type(callback) == "function" then callback(nil, "authenticated release unavailable", "download") end
		return false
	end
	if _state ~= "available" then
		if type(callback) == "function" then callback(nil, "updater is not ready to download", "download") end
		return false
	end
	return start_download(release, download_url, callback, "idle")
end

--- Downloads and verifies the archive of a release the user chose in the
--- Versions window, through the same checksum path as an update. The cached
--- update offer is left as it was, so a failure keeps the menu's update row.
--- @param release table M.release_record() result.
--- @param callback function|nil Receives verified path, error, failing stage.
--- @return boolean Whether the checksum request was dispatched.
function M.download_release(release, callback, native_execution)
 if native_channel_intent then return false end
	if type(release) ~= "table" or type(release.tag) ~= "string" or release.tag == ""
		or type(release.download_url) ~= "string" or release.download_url == ""
		or type(release.checksum_url) ~= "string" or release.checksum_url == "" then
		Logger.error(LOG, "Refused to download a release without its canonical Linux bundle and checksum.")
		if type(callback) == "function" then callback(nil, "authenticated release unavailable", "download") end
		return false
	end
	if native_channel_intent or _state == "checking" or _state == "downloading" or _state == "installing" then
		Logger.warn(LOG, "Refused to download %s while the updater is %s.", release.tag, _state)
		if type(callback) == "function" then callback(nil, "updater is busy", "download") end
		return false
	end
	Logger.info(LOG, "Downloading the chosen release %s.", release.tag)
	return start_download(release, release.download_url, callback, _state, native_execution)
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
 if native_install then return true end -- Accepted installation remains its own physical owner.
 if native_transfer then
  local record = native_transfer
  record.cancelled = true
  if record.methods and not record.signalled then
   record.signalled = true; pcall(record.methods.cancel, record.operation)
  end
  return true -- Logical cancellation; state stays busy through actual captured settlement.
 end
 if not retire_verified_artifact() then return false end
	local http_cancelled = M._http_client.cancel(REQUEST_OWNER)
	if http_cancelled and _release_fetch_cancel then _release_fetch_cancel() end
	local digest_cancelled = M._file_digest.cancel(REQUEST_OWNER)
	if not http_cancelled or not digest_cancelled then return false end
	if _state == "installing" then return true end
	remove_partial_download()
	_download_part = nil
	_download_dest = nil
 if not retire_verified_artifact() then return false end
	if _verified_archive then Fs.delete(_verified_archive); _verified_archive = nil end
	_verified_release = nil
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

--- Installs a verified archive into a standalone user installation. System
--- packages and immutable bundles retain ownership of their own update path.
--- @param archive_path string Path to the downloaded archive.
--- @param expected_version string|nil The version the archive must carry.
--- @return boolean true on success.
local function install_archive(archive_path, expected_version)
 if native_verified or native_install or native_transfer then return false end -- Native artifacts require the retained async owner.
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
	_verified_release = nil
	_installed_launcher = context.wrapper
	_state = "idle"
	return true
end

--- Installs the downloaded update into a standalone user installation.
--- @param archive_path string Path to the downloaded archive.
--- @return boolean true on success.
function M.install_update(archive_path)
	return install_archive(archive_path, _cached_release and _cached_release.tag or nil)
end

--- Installs the verified archive of a release the user chose in the Versions
--- window. The archive must be the one download_release verified for that
--- very tag, and the installer checks the version it carries.
--- @param archive_path string
--- @param tag string The chosen release's tag.
--- @return boolean true on success.
function M.install_release_archive(archive_path, tag)
	if type(tag) ~= "string" or not _verified_release or _verified_release.tag ~= tag then
		Logger.error(LOG, "Refusing to install %s: its archive was not verified for that release.", tostring(tag))
		return false
	end
	return install_archive(archive_path, tag)
end

--- Accepted installation owns its original script/release and one new deadline.
--- No display path is reopened; every tar reader comes from the private brand.
local function install_native_archive(path, tag, callback, admission)
 local verified = native_verified
 if native_channel_intent or native_transfer or native_install or not verified or verified.cancelled or path ~= verified.path
  or tag ~= verified.selected.tag or type(callback) ~= "function" or type(admission) ~= "function" then return false end
 local resolver, install = rawget(M, "_resolve_installation"), rawget(Installer, "install_owned")
 if type(resolver) ~= "function" or type(install) ~= "function" then return false end
 local work = { verified = verified, constructing = true, received = false, done = false }
 native_install = work -- Original private reservation precedes reentrant native admission.
 local function identity()
  return native_install == work and native_verified == verified and not verified.cancelled and not work.done
   and rawget(M, "_resolve_installation") == resolver and rawget(Installer, "install_owned") == install
 end
 local function initial_current()
  if not identity() then return false end
  local checked, current = pcall(admission)
  return checked and current == true and identity()
 end
 local function execution_current() return identity() end -- Accepted transaction ignores later page/pause retirement.
 local checked, context = pcall(resolver)
 if not checked or type(context) ~= "table" or rawget(context, "kind") ~= "standalone" or not initial_current() then
  native_install = nil; return false
 end
 local captured_context = {}
 for _, key in ipairs({ "kind", "reason", "install_root", "parent", "wrapper" }) do captured_context[key] = rawget(context, key) end
 _state = "installing"
 local reserved, token = pcall(verified.methods.begin_install, verified.brand, verified.transaction, _defs,
  initial_current, execution_current)
 if not reserved or token == nil then
  if native_install == work then native_install = nil; _state = "available" end
  return false -- begin_install refuses before any native reader acquisition.
 end
 work.token = token
 local function deliver()
  if work.constructing or work.done or work.unknown or not work.operation or not work.received then return end
  local probed, physical = pcall(work.methods.is_settled, work.operation)
  if not probed or physical ~= true or not identity() then return end
  work.done, native_install = true, nil
  local completed = work.result.installed == true
  if completed then
   native_verified, _verified_archive, _verified_release = nil, nil, nil
   _installed_launcher, _state = captured_context.wrapper, "idle"
  else _state = "available" end
  pcall(callback, completed, work.result.detail, work.result.receipt)
 end
 local started, operation = pcall(install, { factory = verified.factory, reservation = token,
  context = captured_context, expected_version = verified.selected.tag }, function(installed, detail, receipt)
  if work.received then return end
  work.received, work.result = true, { installed = installed, detail = detail, receipt = receipt }
  deliver()
 end)
 if started and type(operation) == "table" then
  work.operation, work.methods = operation, capture_operation(operation)
  if work.methods then
   local observed, ack = pcall(work.methods.on_settled, operation, deliver)
   if not observed or ack ~= true then work.unknown = true end
  else work.unknown = true end
 else work.unknown = true end -- A thrown/unknown installer construction may own native work.
 work.constructing = false
 if work.unknown and work.methods then pcall(work.methods.cancel, work.operation) end
 deliver()
 return work.operation ~= nil and not work.unknown
end
function M.install_update_async(path, callback, current)
 return install_native_archive(path, native_verified and native_verified.selected.tag or nil, callback, current)
end
function M.install_release_archive_async(path, tag, callback, current)
 return install_native_archive(path, tag, callback, current)
end

--- Whether this installation can replace itself (a standalone install), and
--- why not otherwise.
--- @return string kind "standalone", "package" or "unmanaged"
--- @return string|nil reason
function M.installation_kind()
	local ok, context = pcall(M._resolve_installation)
	if not ok or type(context) ~= "table" then return "unmanaged", tostring(context) end
	return context.kind, context.reason
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
 if native_install or native_channel_intent then return false end
 if type(new_channel) ~= "string" or CHANNELS.channel(new_channel) == nil then
  Logger.warn(LOG, "Unknown channel '%s' — keeping '%s'.", tostring(new_channel), _channel)
  return false
 end
 if new_channel == _channel and _channel_persisted then return true end
 local intent = { channel = _channel, persisted = _channel_persisted, cached = _cached_release,
  generation = native_generation }
 native_channel_intent = intent -- Reserve before cancellation/retirement/persistence probes.
 local function intact()
  return native_channel_intent == intent and native_install == nil and _channel == intent.channel
   and _channel_persisted == intent.persisted and _cached_release == intent.cached and native_generation == intent.generation
 end
 local guarded, changed = pcall(function()
  if (_state == "checking" or _state == "downloading") and (not M.cancel_update() or native_transfer ~= nil) then return false end
  if not intact() or not retire_verified_artifact() or not intact() then return false end
  -- Commit persistence/channel/cache only after exact predecessor namespace disposal.
  if not _persist_channel(new_channel) or not intact() then return false end
  _channel, _channel_persisted = new_channel, true
  if _verified_archive then Fs.delete(_verified_archive); _verified_archive = nil end
  _verified_release, _state, _cached_release = nil, "idle", nil
  return true
 end)
 if native_channel_intent == intent then native_channel_intent = nil end
 if not guarded or changed ~= true then return false end
 Logger.info(LOG, "Update channel set to '%s' (persisted).", _channel)
 return true
end

--- Returns the current check interval in seconds.
function M.get_check_interval()
	return _check_interval
end

--- Sets the check interval and persists it to config.toml [updater]
--- check_interval_seconds.
--- @param seconds number
--- @return boolean Whether the active interval matches the request.
function M.set_check_interval(seconds)
	local s = tonumber(seconds)
	if not s or s < 0 then return false end
	local wanted = math.floor(s)
	if wanted == _check_interval then return true end
	if type(_config_path) ~= "string" or _config_path == "" then
		Logger.error(LOG, "Check interval %ds cannot be saved: the updater has no config path (init not run).", wanted)
		return false
	end
	local call_ok, committed, err = pcall(TomlWriter.batch_write, _config_path, {
		{ section = CONFIG_SECTION, key = CONFIG_INTERVAL_KEY, value = wanted },
	})
	if not call_ok or committed ~= true then
		Logger.error(LOG, "Check interval %ds could not be written to config.toml — keeping %ds: %s.", wanted,
			_check_interval, tostring(call_ok and err or committed))
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
 if native_install or native_channel_intent then return false end
	if (_state == "checking" or _state == "downloading") and (not M.cancel_update() or native_transfer ~= nil) then
		Logger.error(LOG, "Cached release cannot clear while updater ownership is live.")
		return false
	end
 if not retire_verified_artifact() then return false end
	if _verified_archive then Fs.delete(_verified_archive); _verified_archive = nil end
	_verified_release = nil
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
--- @param opts table|nil { config_path, channel, interval_sec, on_available,
---   is_paused }: is_paused() returning true skips a due check (the pause).
function M.init(opts)
 if native_channel_intent or native_transfer or native_install then return false end
	opts = type(opts) == "table" and opts or {}
	if opts.is_paused ~= nil and type(opts.is_paused) ~= "function" then
		error("updater.init: is_paused must be a function", 2)
	end
	_is_paused = opts.is_paused
	_on_available = opts.on_available

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

	-- A local version run from source has no installation to update: it
	-- checks for nothing on its own, as on the other two drivers, and the
	-- tray greys its check and frequency rows.
	if require("infra.installation").is_source_run() then
		Logger.info(LOG, "Local version run from source: no automatic update check.")
		return
	end
	M.start_background_checks()
end

-- Until init() reads config.toml, the running build's channel is followed.
_channel = M.installed_channel()

return M
