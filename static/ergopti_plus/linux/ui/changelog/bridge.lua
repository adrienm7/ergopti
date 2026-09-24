--- ui/changelog/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Changelog / Release Notes Viewer
--- Handles JS->Lua messages from _shared/ui/changelog/.
--- Bridge name: "changelog_bridge"
---
--- The page never reaches the network on Linux: this handler fetches the
--- release list through the shared curl adapter (bounded, proxy variables
--- honoured by curl), trying the GitHub API first and the public Atom feed
--- second (_shared/lua/updater/release_sources.lua), then pushes the result or
--- a translated error key back through window.__hostBridgeResponse.
--- ==============================================================================

local M = {}
M.bridge_name = "changelog_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.changelog"

-- Read canonical version from the single-source module (SSoT).
local Version = require("infra.version")
local Shell = require("adapters.shell_runner")
local Json = require("json")
local Base64 = require("compat.base64")
local ReleaseSources = require("updater.release_sources")

local REPOSITORY_URL = "https://github.com/adrienm7/ergopti"
local APP_NAME = "changelog"
local HTTP_OWNER = "changelog"
-- Feeds carry the rendered notes of ten releases (about 0.5 MB today).
local MAX_SOURCE_BYTES = 4 * 1024 * 1024

local _fetch_generation = 0
local _sources = nil

--- Returns whether a URL belongs to the repository's HTTPS surface.
--- @param value any
--- @return boolean
local function is_allowed_repository_url(value)
	return type(value) == "string"
		and value:match("^https://github%.com/adrienm7/ergopti/?[A-Za-z0-9._~/%?=&+#-]*$") ~= nil
end

--- Converts the updater's cached record to the page's release schema.
--- @param cached table
--- @return table
local function page_release(cached)
	local tag = type(cached.tag) == "string" and cached.tag or ""
	local release_url = REPOSITORY_URL .. "/releases"
	if tag:match("^[A-Za-z0-9._+-]+$") then release_url = release_url .. "/tag/" .. tag end
	return {
		tag_name = tag,
		body = type(cached.notes) == "string" and cached.notes or "",
		html_url = release_url,
		published_at = type(cached.published_at) == "string" and cached.published_at or "",
		prerelease = cached.prerelease == true,
	}
end

--- Builds the initial changelog data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state, channel)
	state = type(state) == "table" and state or {}
	channel = channel == "dev" and "dev" or "main"
	local releases = {}

	-- Try to get releases from the updater if loaded.
	local ok_up, updater = pcall(require, "modules.updater.manager")
	if ok_up and updater then
		-- The updater may have cached release data.
		local ok_cached, cached = pcall(function()
			return type(updater.get_cached_release) == "function" and updater.get_cached_release() or nil
		end)
		local ok_channel, cached_channel = pcall(function()
			return type(updater.get_channel) == "function" and updater.get_channel() or nil
		end)
		local expected_channel = channel == "dev" and "dev" or "stable"
		if ok_cached and cached and ok_channel and cached_channel == expected_channel then
			releases[#releases + 1] = page_release(cached)
		end
	end

	return {
		action = "releases",
		releases = releases,
		channel = channel,
		cache_miss = #releases == 0,
		repo_url = REPOSITORY_URL .. "/releases",
		version = state._version or Version.VERSION,
	}
end





-- =========================================
-- =========================================
-- ======= 1/ Native Release Fetch =========
-- =========================================
-- =========================================

--- Loads and validates the release sources once from the shared defaults.
--- @return table|nil sources
--- @return string|nil error
local function load_sources()
	if _sources then return _sources, nil end
	local ok_paths, Paths = pcall(require, "infra.paths")
	local path = ok_paths and Paths.shared("modules/updater/defaults.json") or nil
	if not path then return nil, "shared updater defaults path is unavailable" end
	local handle = io.open(path, "rb")
	if not handle then return nil, "shared updater defaults are unreadable" end
	local raw = handle:read("*a")
	handle:close()
	local ok_json, decoded = pcall(Json.decode, raw)
	if not ok_json then return nil, "shared updater defaults are not valid JSON" end
	local sources, err = ReleaseSources.resolve(decoded)
	if not sources then return nil, err end
	_sources = sources
	return sources, nil
end

--- Default transport: the shared asynchronous curl adapter. curl itself honours
--- https_proxy/all_proxy/no_proxy from the daemon environment.
--- @param url string
--- @param headers table
--- @param timeout_ms number
--- @param callback function Receives status, body, err.
local function default_http_get(url, headers, timeout_ms, callback)
	local HttpClient = require("adapters.http_client")
	HttpClient.get(url, headers, {
		owner = HTTP_OWNER,
		timeout_ms = timeout_ms,
		max_body_bytes = MAX_SOURCE_BYTES,
		follow_redirects = true,
		https_only = true,
	}, function(result)
		result = type(result) == "table" and result or {}
		callback(result.status, result.body, result.ok == true and nil or result.error)
	end)
end

--- Default page channel: the host->page response hook of the shared UI.
--- @param payload table
--- @return boolean pushed
local function default_push(payload)
	local ok_manager, Manager = pcall(require, "ui.webview_manager")
	if not ok_manager or type(Manager.eval_js) ~= "function" then
		Logger.error(LOG, "Cannot push releases: webview_manager.eval_js is unavailable.")
		return false
	end
	local encoded = Base64.encode(Json.encode(payload))
	return Manager.eval_js(APP_NAME, string.format(
		"if(window.__hostBridgeResponse)window.__hostBridgeResponse('%s',true,'%s')",
		M.bridge_name, encoded)) == true
end

-- Injectable seams for tests; production uses the curl adapter and WebKit.
M._http_get = default_http_get
M._push = default_push

--- Starts one native fetch; a newer request supersedes every older result.
--- @param channel string "main" or "dev".
--- @return number generation
function M.start_fetch(channel)
	channel = channel == "dev" and "dev" or "main"
	_fetch_generation = _fetch_generation + 1
	local generation = _fetch_generation
	local sources, err = load_sources()
	if not sources then
		Logger.error(LOG, "Release sources unavailable: %s.", tostring(err))
		M._push({ action = "releases_error", channel = channel, error_key = "changelog_window.error_network" })
		return generation
	end
	Logger.start(LOG, "Fetching releases (channel=%s)…", channel)
	ReleaseSources.fetch(sources, M._http_get, Logger, LOG, function(result)
		if generation ~= _fetch_generation then
			Logger.debug(LOG, "Discarded a superseded release fetch (generation %d).", generation)
			return
		end
		if result.error then
			Logger.done(LOG, "Release fetch ended with an error (channel=%s).", channel)
			M._push({ action = "releases_error", channel = channel, error_key = result.error_key })
			return
		end
		Logger.success(LOG, "Releases fetched from %s (channel=%s).", result.source, channel)
		local payload = { action = "releases", channel = channel }
		if result.kind == "feed" then payload.feed = result.body else payload.json = result.body end
		M._push(payload)
	end)
	return generation
end

--- Clears cached state; used by tests.
function M._reset()
	_fetch_generation = 0
	_sources = nil
	M._http_get = default_http_get
	M._push = default_push
end





-- =========================================
-- =========================================
-- ======= 2/ Message Handler ==============
-- =========================================
-- =========================================

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
--- The page channel of the release feed the installation follows: "dev" for
--- prereleases, "main" for stable. It opened on "main" always, which hides
--- prereleases, and every release is one: the window opened on an empty list.
--- @return string "main" | "dev"
local function followed_channel()
	local ok, updater = pcall(require, "modules.updater.manager")
	if ok and type(updater) == "table" and type(updater.get_channel) == "function"
		and updater.get_channel() == "dev" then
		return "dev"
	end
	return "main"
end

function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" or payload == "refresh" then
			if payload == "ready" then Logger.info(LOG, "Changelog UI ready.") end
			local channel = followed_channel()
			M.start_fetch(channel)
			return _build_initial_payload(state, channel)
		end
		if payload == "close" then
			Logger.info(LOG, "Changelog close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "fetch" then
		M.start_fetch(payload.channel)
		return _build_initial_payload(state, payload.channel)
	end

	if action == "open_url" then
		if not is_allowed_repository_url(payload.url) then
			Logger.error(LOG, "Changelog rejected a non-repository URL.")
			return { action = "open_url", opened = false, error = "Release URL refused." }
		end
		if not Shell.has_command("xdg-open") then
			Logger.error(LOG, "xdg-open is unavailable — the release URL cannot be opened.")
			return { action = "open_url", opened = false, error = "xdg-open is unavailable." }
		end
		local opened = Shell.run("xdg-open " .. Shell.quote(payload.url) .. " >/dev/null 2>&1 &")
		if opened then
			Logger.info(LOG, "Opened changelog release URL.")
		else
			Logger.error(LOG, "The changelog release URL could not be opened.")
		end
		return {
			action = "open_url",
			opened = opened,
			error = opened and nil or "Release URL could not be opened.",
		}
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
