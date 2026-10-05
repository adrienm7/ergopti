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
---
--- A release's « Install this version » button posts install_release: the
--- shared sequence (_shared/lua/updater/release_install.lua) backs the
--- configuration up (modules/updater/config_backup.lua), finds the release in
--- the list this bridge last fetched from the GitHub API, then downloads,
--- verifies and installs it through the updater manager's update path and
--- restarts the daemon on it. Each phase is pushed as install_progress. The
--- restore banner posts restore_backup; the daemon restarts on the restored
--- configuration.
--- ==============================================================================

local M = {}
M.bridge_name = "changelog_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.changelog"

-- Read canonical version from the single-source module (SSoT).
local Version = require("infra.version")
local Installation = require("infra.installation")
local Shell = require("adapters.shell_runner")
local Json = require("json")
local Base64 = require("compat.base64")
local ReleaseSources = require("updater.release_sources")
local Parser = require("updater.release_parser")
local ReleaseInstall = require("updater.release_install")
local VersionOrder = require("updater.version")
local NetworkFailure = require("network.failure")
local Paths = require("infra.paths")
local FileSystem = require("adapters.file_system")

-- The owner and the repository come from the shared updater defaults, their
-- single source (tools/test/test-repo-url-single-source.cjs). The loader is
-- defined with the native fetch below.
local load_sources
local APP_NAME = "changelog"
local HTTP_OWNER = "changelog"
-- Feeds carry the rendered notes of ten releases (about 0.5 MB today).
local MAX_SOURCE_BYTES = 4 * 1024 * 1024

local _fetch_generation = 0
local _sources = nil
-- The release list the last fetch published: { kind = "json"|"feed", body }.
-- An install finds its release here, so the page and the host act on one list.
local _last_list = nil
-- The one install session of this window (created on the first request).
local _install_session = nil
local _failure_contract = nil
local _daemon_state = nil
local _page_epoch, _page_document = nil, nil

--- The repository's web root, from the shared updater defaults.
--- @return string|nil url
--- @return string|nil error Why the defaults are unusable.
local function repository_url()
	local sources, err = load_sources()
	if not sources then return nil, err end
	return "https://github.com/" .. sources.owner .. "/" .. sources.repo, nil
end

--- Returns whether a URL belongs to the repository's HTTPS surface: the root
--- itself, or a path, query or fragment below it, never a longer name.
--- @param value any
--- @return boolean
local function is_allowed_repository_url(value)
	local root, err = repository_url()
	if not root then
		Logger.error(LOG, "Repository unknown, no URL is allowed: %s.", tostring(err))
		return false
	end
	if type(value) ~= "string" or value:sub(1, #root) ~= root then return false end
	local rest = value:sub(#root + 1)
	return rest == "" or rest:match("^[/%?#][A-Za-z0-9._~/%?=&+#-]*$") ~= nil
end

--- Converts the updater's cached record to the page's release schema.
--- @param cached table
--- @param releases_url string The repository's releases page.
--- @return table
local function page_release(cached, releases_url)
	local tag = type(cached.tag) == "string" and cached.tag or ""
	local release_url = releases_url
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
	local sources, sources_err = load_sources()
	if not sources then
		Logger.error(LOG, "Release sources unavailable, no cached release is shown: %s.", tostring(sources_err))
	end

	-- The updater's cached release belongs to the channel it checked, which is
	-- the subscribed one: it is a valid first entry only on that channel's view.
	local manager = updater()
	local subscribed = nil
	if sources and manager then
		local ok_subscribed, id = pcall(manager.get_channel)
		subscribed = ok_subscribed and registry_channel(id) or nil
		local ok_cached, cached = pcall(function()
			return type(manager.get_cached_release) == "function" and manager.get_cached_release() or nil
		end)
		local ok_channel, cached_channel = pcall(function()
			return type(manager.get_channel) == "function" and manager.get_channel() or nil
		end)
		if ok_cached and cached and ok_channel and cached_channel == channel then
			releases[#releases + 1] = page_release(cached, sources.page_url)
		end
	end

	return {
		action = "releases",
		releases = releases,
		channel = channel,
		-- The channel the user receives updates from, for the page's banner.
		subscribed_channel = subscribed,
		cache_miss = #releases == 0,
		repo_url = sources and sources.page_url or nil,
		version = state._version or Version.VERSION,
		-- What this build can install and restore, for the install buttons.
		install = M._install_context(),
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
load_sources = function()
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
local function default_push(payload, document_owner)
	local ok_manager, Manager = pcall(require, "ui.webview_manager")
	if not ok_manager or type(Manager.eval_js) ~= "function" then
		Logger.error(LOG, "Cannot push releases: webview_manager.eval_js is unavailable.")
		return false
	end
	local encoded = Base64.encode(Json.encode(payload))
	local script = string.format("if(window.__hostBridgeResponse)window.__hostBridgeResponse('%s',true,'%s')", M.bridge_name, encoded)
	if document_owner ~= nil then
		return type(Manager.eval_owned_js) == "function" and Manager.eval_owned_js(APP_NAME, document_owner, script) == true
	end
	return Manager.eval_js(APP_NAME, script) == true
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
	local loaded, host = pcall(require, "ui.webview_manager")
	local document, epoch = _page_document, _page_epoch
	_fetch_generation = _fetch_generation + 1
	local generation = _fetch_generation
	local function fetch_current()
		if not loaded or not host or document == nil or epoch == nil
			or type(host.document_owner_current) ~= "function"
			or type(host.document_owner_retained) ~= "function" then return false end
		local function identity()
			return generation == _fetch_generation and document == _page_document and epoch == _page_epoch
				and package.loaded["ui.webview_manager"] == host
		end
		if not identity() then return false end
		local ok, current = pcall(host.document_owner_current, document)
		return ok and current == true and identity() and host.document_owner_retained(document) == true and identity()
	end
	local function push(payload)
		if not fetch_current() then return false end
		return M._push(payload, document)
	end
	if not fetch_current() then return generation end
	if not registry_channel(channel) then
		Logger.error(LOG, "Refused a release fetch for a channel outside the registry.")
		push({ action = "releases_error", error_key = "changelog_window.error_network" })
		return generation
	end
	local sources, err = load_sources()
	if not fetch_current() then return generation end
	if not sources then
		Logger.error(LOG, "Release sources unavailable: %s.", tostring(err))
		push({ action = "releases_error", channel = channel, error_key = "changelog_window.error_network" })
		return generation
	end
	Logger.start(LOG, "Fetching releases (channel=%s)…", channel)
	if not fetch_current() then return generation end
	local transport = M._http_get
	local function owned_get(url, headers, timeout_ms, callback)
		if not fetch_current() then return false end
		return transport(url, headers, timeout_ms, function(...)
			-- Shared source policy may log and admit a feed fallback before its
			-- final publication. Refuse stale completions before that policy runs.
			if not fetch_current() then return end
			callback(...)
		end)
	end
	ReleaseSources.fetch(sources, owned_get, Logger, LOG, function(result)
		if not fetch_current() then
			Logger.debug(LOG, "Discarded a superseded release fetch (generation %d).", generation)
			return
		end
		if result.error then
			Logger.done(LOG, "Release fetch ended with an error (channel=%s).", channel)
			if not fetch_current() then return end
			_last_list = nil
			push({ action = "releases_error", channel = channel, error_key = result.error_key })
			return
		end
		Logger.success(LOG, "Releases fetched from %s (channel=%s).", result.source, channel)
		if not fetch_current() then return end
		_last_list = { kind = result.kind, body = result.body }
		local payload = { action = "releases", channel = channel }
		if result.kind == "feed" then payload.feed = result.body else payload.json = result.body end
		push(payload)
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

-- =========================================
-- =========================================
-- ======= 2/ Release Install ==============
-- =========================================
-- =========================================

-- Test seam: the configuration backup module (modules/updater/config_backup.lua).
M._config_backup = nil

--- The configuration backup owner, built for the folder in force now.
--- @return table|nil owner
local function backup_owner()
	local module = M._config_backup or require("modules.updater.config_backup")
	return module.owner()
end

--- Why this build cannot install a release, or nil when it can.
--- @param manager table|nil
--- @return string|nil key Locale key the page shows.
local function install_blocked(manager)
	if Installation.is_source_run() then return "changelog_window.install_blocked_source" end
	if manager and type(manager.installation_kind) == "function" and manager.installation_kind() == "package" then
		return "changelog_window.install_blocked_package"
	end
	return nil
end

--- The newest restorable pre-install backup as the page describes it, or nil.
--- @return table|nil
local function restorable_backup()
	local owner = backup_owner()
	local latest = owner and owner.latest("pre_install") or nil
	if not latest then return nil end
	return { id = latest.id, created_at = latest.created_at, tag = latest.tag }
end

--- What this build can install, for the page's buttons and restore banner.
--- @return table context { installed, blocked_key, backup }
function M._install_context()
	local manager = updater()
	local blocked = install_blocked(manager)
	return {
		installed = Version.VERSION,
		blocked_key = blocked or "",
		backup = restorable_backup(),
	}
end

--- Finds a release in the list the page shows.
--- @param tag string
--- @return string|nil chunk Raw release object JSON.
--- @return string|nil reason Locale key when it is not there.
local function find_release(tag)
	local manager = updater()
	if not _last_list then return nil, ReleaseInstall.REASON.unknown_release end
	if _last_list.kind ~= "json" then
		-- The Atom feed carries no asset list and no checksum.
		return nil, ReleaseInstall.REASON.no_details
	end
	if not manager or not manager.CHANNELS.channel_for_tag(tag) then
		return nil, ReleaseInstall.REASON.unknown_release
	end
	local wanted = VersionOrder.normalize_tag(tag)
	for _, chunk in ipairs(Parser.split_releases_array(_last_list.body)) do
		if VersionOrder.normalize_tag(Parser.parse_tag(chunk)) == wanted then return chunk, nil end
	end
	return nil, ReleaseInstall.REASON.unknown_release
end

--- The install session of this window, over the updater manager's update path.
--- @return table session
local function trusted_page_epoch(context)
	if type(context) ~= "table" or context.app_name ~= APP_NAME or type(context.epoch) ~= "number" then return nil end
	local ok, host = pcall(require, "ui.webview_manager")
	if not ok or type(host.current_epoch) ~= "function" or type(host.is_visible) ~= "function" then return nil end
	if context.document_owner == nil or type(host.document_owner_current) ~= "function"
		or host.document_owner_current(context.document_owner) ~= true then return nil end
	return host.current_epoch(APP_NAME) == context.epoch and host.is_visible(APP_NAME) == true and context.epoch or nil
end

local function failure_contract()
	if _failure_contract then return _failure_contract end
	local path = Paths.shared("modules/network/managed_network.json")
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	assert(type(raw) == "string", "the canonical managed network policy is unreadable")
	_failure_contract = NetworkFailure.new(Json.decode(raw))
	return _failure_contract
end

--- Captures actual admitted document and pause owners, privately.
local function failure_owner()
	local ok, host = pcall(require, "ui.webview_manager")
	local state, epoch, document = _daemon_state, _page_epoch, _page_document
	if not ok or type(state) ~= "table" then return nil end
	return { list = _last_list, generation = _fetch_generation, state = state, epoch = epoch,
		host = host, document = document, pause = state.is_paused }
end

local function failure_current(owner)
	if type(owner) ~= "table" or type(owner.state) ~= "table" or type(owner.pause) ~= "function"
		or owner.document == nil or not owner.host or owner.epoch == nil then return false end
	local host = owner.host
	for _, name in ipairs({ "get_daemon_state", "document_owner_current", "document_owner_retained", "current_epoch", "is_visible" }) do
		if type(host[name]) ~= "function" then return false end
	end
	local function identity()
		local state, epoch = host.get_daemon_state(), host.current_epoch(APP_NAME)
		local visible = host.is_visible(APP_NAME)
		return state == owner.state and epoch == owner.epoch and visible == true
			and package.loaded["ui.webview_manager"] == host and owner.document == _page_document
			and owner.list ~= nil and owner.list == _last_list and owner.generation == _fetch_generation
			and owner.state == _daemon_state and owner.state.is_paused == owner.pause
	end
	if not identity() then return false end
	local ok, paused = pcall(owner.pause)
	if not ok or paused ~= false or not identity() or host.document_owner_current(owner.document) ~= true
		or not identity() then return false end
	ok, paused = pcall(owner.pause)
	return ok and paused == false and identity() and host.document_owner_retained(owner.document) == true and identity()
end

local function install_session()
	if _install_session then return _install_session end
	_install_session = ReleaseInstall.new({
		logger = Logger,
		log = LOG,
		failure_contract = failure_contract,
		acceptance_owner = failure_owner,
		acceptance_current = failure_current,
		failure_owner = failure_owner,
		failure_current = failure_current,
		blocked = function() return install_blocked(updater()) end,
		find_release = function(tag) return find_release(tag) end,
		backup = function(chunk)
			local owner, err = backup_owner()
			if not owner then return nil, err end
			return owner.create("pre_install", { tag = Parser.parse_tag(chunk), from_version = Version.VERSION })
		end,
		resolve_asset = function(chunk)
			local manager = updater()
			return manager and manager.release_record(chunk) or nil
		end,
		download = function(record, _, done)
			local manager = updater()
			if not manager then return false end
			return manager.download_release(record, function(path, err, stage, failure_receipt)
				done(path, stage == "verify" and ReleaseInstall.REASON.verify or ReleaseInstall.REASON.download, err,
					failure_receipt)
			end) == true
		end,
		install = function(path, _, record)
			local manager = updater()
			if manager and manager.install_release_archive(path, record.tag) == true then return true end
			return false, ReleaseInstall.REASON.install, "the installer refused the archive"
		end,
		restart = function(chunk)
			local restart = type(_daemon_state) == "table" and _daemon_state.restart_after_update or nil
			if type(restart) ~= "function" then
				Logger.error(LOG, "No daemon restart hook: the installed release starts at the next launch.")
				return false
			end
			return restart(Parser.parse_tag(chunk)) == true
		end,
		report = function(message, retained_owner)
			local payload = { action = "install_progress" }
			for key, value in pairs(message) do payload[key] = value end
			-- Keep the original operation's document private. Missing/stale leases
			-- cannot select a successor document through the default push channel.
			if retained_owner ~= nil then
				if type(retained_owner) ~= "table" or retained_owner.document == nil then return false end
				return M._push(payload, retained_owner.document)
			end
			return M._push(payload)
		end,
	})
	return _install_session
end

--- Restores a pre-install backup and restarts the daemon on it.
--- @param id any Backup id posted by the page.
--- @return table answer restore_progress
local function restore(id)
	local owner = backup_owner()
	if not owner then
		return { action = "restore_progress", phase = "failed", reason_key = "changelog_window.restore_error_backup" }
	end
	M._push({ action = "restore_progress", phase = "restoring" })
	local restored, reason, pre = owner.restore(id)
	if not restored then
		local key = reason == "missing" and "changelog_window.restore_error_missing"
			or reason == "backup" and "changelog_window.restore_error_backup"
			or "changelog_window.restore_error_unexpected"
		return { action = "restore_progress", phase = "failed", reason_key = key,
			backup_path = pre and pre.path or nil }
	end
	local restart = type(_daemon_state) == "table" and _daemon_state.restart or nil
	if type(restart) ~= "function" or restart("configuration restored") ~= true then
		Logger.error(LOG, "The configuration is restored but the daemon could not restart on it.")
	end
	return { action = "restore_progress", phase = "restored", backup_path = pre and pre.path or nil }
end

--- Clears cached state; used by tests.
function M._reset()
	_fetch_generation = 0
	_sources = nil
	_last_list = nil
	_install_session = nil
	_daemon_state = nil
	_page_epoch, _page_document = nil, nil
	M._config_backup = nil
	M._http_get = default_http_get
	M._push = default_push
end





-- =========================================
-- =========================================
-- ======= 3/ Message Handler ==============
-- =========================================
-- =========================================

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state, context)
	local page_epoch = trusted_page_epoch(context)
	if page_epoch == nil then return nil end
	if page_epoch ~= nil then _page_epoch, _page_document = page_epoch, context.document_owner end
	if type(state) == "table" then _daemon_state = state end
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
			if _install_session then _install_session.retire() end
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

	-- Only this click installs a chosen release: nothing else calls the session.
	if action == "install_release" then
		install_session().install(payload.tag, payload.channel)
		return nil
	end

	if action == "install_failure_action" then
		if page_epoch ~= nil and _install_session then
			_install_session.failure_action(payload.operation, payload.epoch, payload.id)
		end
		return nil
	end

	if action == "restore_backup" then
		if install_session().busy() then
			return { action = "restore_progress", phase = "failed",
				reason_key = "changelog_window.restore_error_unexpected" }
		end
		return restore(payload.id)
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
