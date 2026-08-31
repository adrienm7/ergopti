--- ui/changelog/init.lua

--- ==============================================================================
--- MODULE: Changelog Window
--- DESCRIPTION:
--- Floating webview that fetches GitHub release notes and renders them as a
--- two-column UI: a sidebar listing available releases and a markdown content
--- pane. Uses the _shared/ui/changelog/ HTML/CSS/JS assets so Windows (AHK +
--- WebView2) and a future Linux driver can reuse the same frontend without
--- duplication.
---
--- FEATURES & RATIONALE:
--- 1. Native fetch proxy: hs.http.asyncGet is used instead of relying on the
---    WebKit fetch() API, which may be blocked by corporate proxies that only
---    whitelist browser user-agents. The Lua backend injects the result via
---    evaluateJavaScript("injectReleases(…)") so the JS never touches the network
---    directly.
--- 2. Singleton window: a second call to M.open() while the window is already
---    visible brings it to the front instead of opening a duplicate.
--- 3. Channel routing: the caller passes a default channel ("main" or "dev");
---    the user can switch channels interactively inside the UI.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local DeferredWork = require("infra.deferred_work")
local Paths      = require("infra.paths")
local ui_builder = require("ui.ui_builder")
local i18n       = require("infra.i18n")

local LOG = "changelog_window"

local GH_OWNER   = "adrienm7"
local GH_REPO    = "ergopti"
local GH_BASE    = string.format("https://api.github.com/repos/%s/%s/releases", GH_OWNER, GH_REPO)
local UA_HEADER  = { ["User-Agent"] = "ErgoptiPlus-Changelog/1.0" }

-- Window geometry is resolved at open time from the shared manifest
-- (ui_builder.get_app_geometry → _shared/ui/apps.manifest.json, SSoT). No local
-- width/height constant: hardcoding here is what caused the cross-driver drift.

local _wv       = nil
local _wv_committed = false
local _ucc      = nil
local _ready    = false
local _queued   = {}
local _fetch_generation = 0

-- The shared UI assets live in …/ergopti_plus/_shared/ui/changelog/. Resolved
-- through the single shared-tree resolver (Paths.shared); the trailing slash is
-- preserved because the consumer concatenates "index.html" onto this directory.
local ASSETS_DIR = (Paths.shared("ui/changelog") or "") .. "/"





-- ====================================
-- ====================================
-- ======= 1/ Javascript Bridge =======
-- ====================================
-- ====================================

--- Safely runs JS in the webview, queuing it when the page is not ready yet.
--- @param code string Raw JavaScript to evaluate.
--- @param generation number|nil Fetch generation that owns this publication.
local function eval(code, generation)
	if generation ~= nil and generation ~= _fetch_generation then return end
	if not _wv then return end
	if _ready and type(_wv.evaluateJavaScript) == "function" then
		pcall(function() _wv:evaluateJavaScript(code) end)
	else
		table.insert(_queued, {code = code, generation = generation})
		if #_queued > 300 then table.remove(_queued, 1) end
	end
end

--- Advances the fetch generation and invalidates every earlier publication.
--- @return number generation Newly active generation.
local function next_fetch_generation()
	_fetch_generation = _fetch_generation + 1
	return _fetch_generation
end

--- Escapes a Lua string for safe injection into a JS string literal.
--- @param s string
--- @return string
local function js_str(s)
	if s == nil then return "null" end
	return '"' .. tostring(s)
		:gsub("\\", "\\\\")
		:gsub('"',  '\\"')
		:gsub("\n", "\\n")
		:gsub("\r", "")
		.. '"'
end





-- ===========================================
-- ===========================================
-- ======= 2/ GitHub API Fetch Helpers =======
-- ===========================================
-- ===========================================

--- Fetches releases from the GitHub API and injects them into the webview.
--- When channel == "main" and the /latest endpoint returns 404, falls back
--- automatically to the dev endpoint so pre-releases are shown.
--- @param channel string "main" or "dev"
local function fetch_and_inject(channel)
	local request_generation = next_fetch_generation()
	local url = channel == "dev"
		and (GH_BASE .. "?per_page=20")
		or  (GH_BASE .. "?per_page=20")

	Logger.trace(LOG, "Fetching releases (channel=%s)…", channel)

	hs.http.asyncGet(url, UA_HEADER, function(status, body, _)
		if request_generation ~= _fetch_generation then return end
		Logger.debug(LOG, "GitHub API: HTTP %s, body_len=%s.", tostring(status), tostring(body and #body or "nil"))

		if status ~= 200 or not body or body == "" then
			Logger.warn(LOG, "GitHub API returned %s — injecting error.", tostring(status))
			eval(string.format("injectError(%s)", js_str(i18n.get("changelog_window.error_network"))),
				request_generation)
			return
		end

		-- Parse JSON via hs.json.
		local ok, data = pcall(hs.json.decode, body)
		if not ok or type(data) ~= "table" then
			Logger.warn(LOG, "GitHub API JSON parse failed.")
			eval(string.format("injectError(%s)", js_str(i18n.get("changelog_window.error_parse"))),
				request_generation)
			return
		end

		-- For the stable channel, filter out pre-releases.
		-- If none exist yet, inject an empty list so the JS shows the empty state
		-- rather than silently falling back to showing all pre-releases as "stable".
		local releases = data
		if channel == "main" then
			local stable = {}
			for _, r in ipairs(data) do
				if not r.prerelease then table.insert(stable, r) end
			end
			releases = stable
		end

		local ok_enc, json = pcall(hs.json.encode, releases)
		if not ok_enc or not json then
			Logger.warn(LOG, "Failed to re-encode releases as JSON.")
			eval(string.format("injectError(%s)", js_str(i18n.get("changelog_window.error_parse"))),
				request_generation)
			return
		end

		Logger.done(LOG, "Injecting %d release(s) into changelog UI.", #releases)
		eval(string.format("injectReleases(%s,%s)", json, js_str(channel)),
			request_generation)
	end)
end





-- ===========================================
-- ===========================================
-- ======= 3/ Window Lifecycle Helpers =======
-- ===========================================
-- ===========================================

--- Flushes the queued JS calls now that the page is ready.
local function flush_queue()
	_ready = true
	local q = _queued
	_queued = {}
	for _, pending in ipairs(q) do
		if pending.generation == nil or pending.generation == _fetch_generation then
			pcall(function() _wv:evaluateJavaScript(pending.code) end)
		end
	end
end

--- Creates the usercontent controller if not already done.
local function ensure_ucc()
	if _ucc then return end
	_ucc = hs.webview.usercontent.new("changelog_bridge")
	_ucc:setCallback(function(msg)
		if type(msg) ~= "table" then return end
		local body = msg.body
		if type(body) == "string" and body == "ready" then
			flush_queue()
			return
		end

		-- host_bridge.js's makeHostBridge() posts non-string payloads RAW (no
		-- JSON.stringify) on WKWebView — WebKit itself converts the JS object into
		-- a native Lua table, so `body` already IS that table here. Passing it
		-- through hs.json.decode (which expects a JSON *string*) always throws,
		-- and a bare pcall around it swallowed the error with zero logging —
		-- matching the convention already used by action_picker / hotstring_editor
		-- / hotstrings_config_window / metrics_apps, read the table directly.
		if type(body) ~= "table" then return end

		if body.action == "fetch" then
			fetch_and_inject(body.channel or "main")
		elseif body.action == "open_url" and type(body.url) == "string" then
			if ui_builder.open_http_url(body.url) then
				Logger.info(LOG, "Opened changelog release URL.")
			end
		end
	end)
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Opens (or brings to front) the changelog window.
--- @param opts table|nil { channel?: string } — "main" or "dev" (default "main").
function M.open(opts)
	local channel = (type(opts) == "table" and opts.channel == "dev") and "dev" or "main"

	-- Singleton: reuse existing window.
	if _wv then
		if _wv_committed ~= true then
			if M.close() ~= true then return false end
		else
			Logger.info(LOG, "Changelog window already open — bringing to front.")
			ui_builder.force_focus(_wv, false)
			-- Reload releases for the requested channel.
			fetch_and_inject(channel)
			return true
		end
	end

	next_fetch_generation()
	Logger.start(LOG, "Opening changelog window (channel=%s)…", channel)

	ensure_ucc()
	_ready  = false
	_queued = {}

	-- Inject repo config and default channel before i18n boot so script.js
	-- reads the correct values during its init() IIFE.
	local config_script = string.format(
		'<script>window.__changelog_gh_owner=%s;window.__changelog_gh_repo=%s;window.__changelog_channel=%s;</script>',
		js_str(GH_OWNER), js_str(GH_REPO), js_str(channel)
	)

	-- Build HTML with repo config injected before script.js IIFE runs.
	-- ui_builder.build_injected_html inlines CSS/JS; we then patch the result
	-- to prepend the config block right after <head> so window.__changelog_*
	-- are set before script.js's init() fires.
	local raw_html = ui_builder.build_injected_html(ASSETS_DIR)
	local final_html = raw_html:gsub("(<head[^>]*>)", function(tag)
		return tag .. config_script
	end, 1)

	local geo = ui_builder.get_app_geometry("changelog")
	if not geo then return false end
	local candidate = nil
	local closed = false
	local function candidate_is_owned()
		return closed ~= true and candidate ~= nil and _wv == candidate
	end
	local webview = ui_builder.show_webview({
		frame             = ui_builder.get_centered_frame(geo.width, geo.height),
		title             = i18n.get("changelog_window.window_title"),
		style_masks       = { "titled", "closable", "miniaturizable", "resizable" },
		level             = hs.drawing.windowLevels.floating,
		allow_text_entry  = false,
		allow_new_windows = false,
		usercontent       = _ucc,
		-- Pass pre-built HTML directly; skip assets_dir so show_webview does
		-- not call build_injected_html a second time.
		html_string       = final_html,
		on_navigation     = function(action)
			if action == "didFinishNavigation" then
				-- Safety flush after navigation — belt-and-suspenders alongside
				-- the "ready" message from script.js.
				DeferredWork.after(0.15, function()
					if not _ready then flush_queue() end
					-- Kick off the first fetch from the Lua side so the JS
					-- fallback timeout is beaten and we get the native proxy path.
					fetch_and_inject(channel)
				end, "changelog.navigation")
			end
			return true
		end,
		on_close          = function()
			closed = true
			if _wv ~= candidate then return end
			next_fetch_generation()
			_wv = nil
			_wv_committed = false
			_ready = false
			_queued = {}
		end,
		on_webview_created = function(owned)
			if _wv ~= nil then return false end
			candidate = owned
			_wv = owned
			_wv_committed = false
			return true
		end,
		is_current = function()
			return candidate_is_owned()
		end,
	})
	if webview == nil or webview ~= candidate or closed then
		if candidate ~= nil and _wv == candidate and M.close() ~= true then
			Logger.error(LOG, "Changelog construction rollback remains pending.")
		end
		Logger.error(LOG, "Changelog WebView creation failed.")
		return false
	end
	_wv_committed = true

	-- Safety: if didFinishNavigation fires very fast and queues pile up,
	-- flush after 1.5 s regardless.
	DeferredWork.after(1.5, function()
		if _wv and not _ready then flush_queue() end
	end, "changelog.ready_fallback")

	Logger.success(LOG, "Changelog window created.")
	return true
end

--- Closes the changelog window if open.
--- @return boolean committed
function M.close()
	if not _wv then return true end
	local owned = _wv
	local previous_ready = _ready
	local previous_queued = _queued
	local previous_generation = _fetch_generation
	local previous_committed = _wv_committed
	local ok, err = xpcall(function() owned:delete() end, debug.traceback)
	if not ok then
		-- A synchronous on_close may already have cleared the logical owner before
		-- the native deletion raised. Restore the complete exact session so open()
		-- cannot create a second changelog beside an ambiguously live first one.
		_wv = owned
		_wv_committed = previous_committed
		_ready = previous_ready
		_queued = previous_queued
		_fetch_generation = previous_generation
		Logger.error(LOG, "Changelog window close did not commit; exact WebView retained: %s.", tostring(err))
		return false
	end
	if _wv == owned then
		next_fetch_generation()
		_wv = nil
		_wv_committed = false
		_ready = false
		_queued = {}
	end
	Logger.info(LOG, "Changelog window closed.")
	return true
end

return M
