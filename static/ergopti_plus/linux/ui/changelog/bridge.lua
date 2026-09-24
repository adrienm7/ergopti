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
---
--- The page's subscription banner posts set_channel; the updater manager, the
--- one channel owner, persists it, and the answer (channel_changed) carries
--- the subscription that holds afterwards. A change made from the menu is
--- pushed to an open page the same way.
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

--- Returns the updater manager, the owner of the subscribed channel and of the
--- shared channel registry, or nil with the reason logged.
--- @return table|nil
local function updater()
	local ok, manager = pcall(require, "modules.updater.manager")
	if not ok or type(manager) ~= "table" then
		Logger.error(LOG, "The updater is unavailable: %s.", tostring(manager))
		return nil
	end
	return manager
end

--- Returns a channel id of the shared registry, or nil for anything else.
--- @param channel any
--- @return string|nil
local function registry_channel(channel)
	local manager = updater()
	if not manager or type(channel) ~= "string" then return nil end
	return manager.CHANNELS.channel(channel) and channel or nil
end

--- Builds the initial changelog data payload.
--- @param state table Daemon state.
--- @param channel string Registry channel the page shows.
--- @return table
local function _build_initial_payload(state, channel)
	state = type(state) == "table" and state or {}
	local releases = {}

	-- The updater's cached release belongs to the channel it checked, which is
	-- the subscribed one: it is a valid first entry only on that channel's view.
	local manager = updater()
	local subscribed = nil
	if manager then
		local ok_subscribed, id = pcall(manager.get_channel)
		subscribed = ok_subscribed and registry_channel(id) or nil
		local ok_cached, cached = pcall(function()
			return type(manager.get_cached_release) == "function" and manager.get_cached_release() or nil
		end)
		local ok_channel, cached_channel = pcall(function()
			return type(manager.get_channel) == "function" and manager.get_channel() or nil
		end)
		if ok_cached and cached and ok_channel and cached_channel == channel then
			releases[#releases + 1] = page_release(cached)
		end
	end

	return {
		action = "releases",
		releases = releases,
		channel = channel,
		-- The channel the user receives updates from, for the page's banner.
		subscribed_channel = subscribed,
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
--- The page filters the list for the channel it shows; the host fetches the
--- same list for every channel and only checks the id.
--- @param channel string Registry channel id.
--- @return number generation
function M.start_fetch(channel)
	_fetch_generation = _fetch_generation + 1
	local generation = _fetch_generation
	if not registry_channel(channel) then
		Logger.error(LOG, "Refused a release fetch for a channel outside the registry.")
		M._push({ action = "releases_error", error_key = "changelog_window.error_network" })
		return generation
	end
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

--- Subscribes to the channel the page asked for through the updater manager,
--- the one channel owner, and has the tray menu rebuilt so its tick follows.
--- @param channel any Channel id posted by the page.
--- @param state table|nil Daemon state (on_config_changed rebuilds the menu).
--- @return table answer { action = "channel_changed", channel, ok }
function M.subscribe(channel, state)
	local manager = updater()
	local id = registry_channel(channel)
	local committed = false
	if manager and not id then
		Logger.error(LOG, "Refused a subscription to a channel outside the registry.")
	elseif manager then
		local ok, result = pcall(manager.set_channel, id)
		if not ok then Logger.error(LOG, "The updater raised while changing the channel: %s.", tostring(result)) end
		committed = ok and result == true
		if committed and type(state) == "table" and type(state.on_config_changed) == "function" then
			local notified, err = pcall(state.on_config_changed)
			if not notified then Logger.error(LOG, "The menu could not follow the new channel: %s.", tostring(err)) end
		end
	end
	local held = nil
	if manager then
		local ok_held, current = pcall(manager.get_channel)
		held = ok_held and registry_channel(current) or nil
	end
	Logger.info(LOG, "Subscription to '%s' %s (subscribed=%s).", tostring(channel),
		committed and "committed" or "refused", tostring(held))
	return { action = "channel_changed", channel = held, ok = committed }
end

--- Tells an open Versions page which channel the user now receives updates
--- from; the menu calls it after its channel rows change the subscription.
--- @param channel string Registry channel id.
--- @return boolean pushed Whether a live page received it.
function M.push_subscribed_channel(channel)
	if not registry_channel(channel) then
		Logger.error(LOG, "Refused to push a subscription outside the registry.")
		return false
	end
	return M._push({ action = "channel_changed", channel = channel, ok = true }) == true
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
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" or payload == "refresh" then
			-- The window opens on the subscribed channel, as on the other drivers:
			-- this used to fetch "main" whatever the user followed.
			local manager = updater()
			local channel = manager and manager.get_channel() or nil
			if not registry_channel(channel) then
				M._push({ action = "releases_error", error_key = "changelog_window.error_network" })
				return nil
			end
			Logger.info(LOG, "Changelog UI %s (channel=%s).", payload, channel)
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
		if not registry_channel(payload.channel) then
			Logger.error(LOG, "Refused a release fetch for a channel outside the registry.")
			return { action = "releases_error", error_key = "changelog_window.error_network" }
		end
		M.start_fetch(payload.channel)
		return _build_initial_payload(state, payload.channel)
	end

	if action == "set_channel" then
		return M.subscribe(payload.channel, state)
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
