--- ui/ui_builder.lua

--- ==============================================================================
--- MODULE: UI Builder Factory
--- DESCRIPTION:
--- Centralized factory and manager for all Hammerspoon webview user interfaces.
--- It provides a unified way to construct windows, inject standalone HTML/JS/CSS
--- assets, and manage window lifecycles natively.
---
--- FEATURES & RATIONALE:
--- 1. Singleton Preservation: By combining this module with early returns in UI modules, pressing a shortcut multiple times will not destroy an already open window. It simply brings the existing window to the front, preserving any text the user has already started typing, or creates a new window only if none exists.
--- 2. Active Space Teleportation: If a user opens the UI in Space 1, moves to Space 2, and triggers the shortcut again, the script momentarily hides and shows the window. This natively teleports the existing window to the active space without erasing its DOM state.
--- 3. Smart Focus Management: Brings the window to the front and gives it system focus, but deliberately uses the "normal" window level. This ensures it appears on top when triggered, but clicking on another application gracefully pushes the UI to the background.
--- 4. DRY Architecture: Removes repetitive window creation and configuration boilerplate across all UI modules.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("infra.logger")
local Paths = require("infra.paths")
local I18nSeed = require("webview.i18n_seed")
local DeferredWork = require("infra.deferred_work")
local TimerScheduler = require("adapters.timer_scheduler")
local JsonCodec = require("adapters.json_codec")

--- Monotonic milliseconds for webview open, load and close durations.
--- @return number
local function now_ms()
	return TimerScheduler.now_ns() / 1e6
end
local LOG = "ui_builder"

-- The generated shared policy owns branding for every native host.
local WindowTitles = require("window_titles")
local WindowTitleKeyOwner = rawget(WindowTitles, "key_for_app")
local WindowTitleComposeOwner = rawget(WindowTitles, "compose")
local WindowPresentationOwner = rawget(WindowTitles, "presentation_for_app")
local Presentation = require("webview.presentation")
local PresentationPrepareOwner = rawget(Presentation, "prepare")
local PresentationI18n = require("infra.i18n")
local PresentationLocale = require("infra.locale")
local PresentationTranslateOwner = rawget(PresentationI18n, "get")
local PresentationLocaleGetOwner = rawget(PresentationLocale, "get")
local PresentationLocaleCurrentOwner = rawget(PresentationLocale, "current_locale")
local PresentationLocaleCore = require("locale.core")
local PresentationCoreGetOwner = rawget(PresentationLocaleCore, "get")
local PresentationCoreCurrentOwner = rawget(PresentationLocaleCore, "current_locale")
local _presentation_receipts = setmetatable({}, { __mode = "k" })
local PresentationPrepareApi, PresentationFieldsApi, PresentationCurrentApi, PresentationShowApi

-- Per-process cache of assembled HTML strings.  Avoids re-reading the local
-- CSS/JS files (and re-running the gsub inlining pass) on every UI open —
-- assets only change when the user edits source so a single assembly per
-- HS session is enough.
local _html_cache = {}
local _factory_build_owner = nil
local _factory_cleanup_owner = nil
local _factory_cleanup_closing = nil

--- Retries one exact factory-owned WebView cleanup debt.
--- @return boolean settled True only when no cleanup debt remains.
local function settle_factory_cleanup()
	if not _factory_cleanup_owner then return true end
	if _factory_cleanup_closing then
		Logger.warn(LOG, "WebView factory cleanup re-entry refused; exact owner retained.")
		return false
	end
	local webview = _factory_cleanup_owner
	if type(webview.delete) ~= "function" then
		Logger.error(LOG, "WebView factory cleanup refused; exact owner has no delete method.")
		return false
	end
	_factory_cleanup_closing = webview
	local ok, err = xpcall(function() webview:delete() end, debug.traceback)
	if _factory_cleanup_closing == webview then _factory_cleanup_closing = nil end
	if not ok then
		_factory_cleanup_owner = webview
		Logger.error(LOG, "WebView factory cleanup did not commit; exact owner retained: %s.",
			tostring(err))
		return false
	end
	if _factory_cleanup_owner == webview then _factory_cleanup_owner = nil end
	return true
end

--- Transfers one failed unowned candidate into the cleanup debt slot.
--- @param webview userdata|table Exact factory-owned candidate.
--- @param label string Failure boundary.
local function abandon_factory_candidate(webview, label)
	if _factory_build_owner == webview then _factory_build_owner = nil end
	_factory_cleanup_owner = webview
	if settle_factory_cleanup() ~= true then
		Logger.error(LOG, "WebView factory %s rollback remains pending.", tostring(label))
	end
end

local _webkit_warmup_session = nil
local _webkit_warmup_closing = nil

--- Closes one exact WebKit warmup session.
--- @param session table Exact warmup session.
--- @return boolean settled True only when native deletion committed.
local function close_webkit_warmup(session)
	if _webkit_warmup_session ~= session then return true end
	if _webkit_warmup_closing then
		Logger.warn(LOG, "WebKit warmup cleanup re-entry refused; exact owner retained.")
		return false
	end
	local webview = session.webview
	if type(webview) ~= "table" and type(webview) ~= "userdata" then
		Logger.error(LOG, "WebKit warmup cleanup refused; exact WebView is invalid.")
		return false
	end
	if type(webview.delete) ~= "function" then
		Logger.error(LOG, "WebKit warmup cleanup refused; exact WebView has no delete method.")
		return false
	end
	_webkit_warmup_closing = session
	local ok, err = xpcall(function() webview:delete() end, debug.traceback)
	if _webkit_warmup_closing == session then _webkit_warmup_closing = nil end
	if not ok then
		session.webview = webview
		_webkit_warmup_session = session
		Logger.error(LOG, "WebKit warmup cleanup did not commit; exact WebView retained: %s.",
			tostring(err))
		return false
	end
	if _webkit_warmup_session == session then _webkit_warmup_session = nil end
	session.webview = nil
	return true
end

-- Absolute file:// URL to the shared static/ergopti_plus/_shared/data/locales/ directory.
-- Computed once at module-load time from this file's own path.
-- Injected into every webview as window.__i18n_base so that the browser-side
-- i18n.js fetch() resolves locale JSON files correctly even when the HTML is
-- loaded inline (via wv:html()) with no base URL.
local _locales_base_url = (function()
	-- Resolved through the single shared-tree resolver (Paths.shared); the
	-- trailing slash is preserved because the browser-side fetch() concatenates
	-- the locale filename directly onto this base.
	local locales = (Paths.shared("data/locales") or "") .. "/"
	-- Normalise to forward slashes and prepend file:// so fetch() accepts it
	locales = locales:gsub("\\", "/")
	if not locales:match("^/") then locales = "/" .. locales end
	return "file://" .. locales
end)()





-- ===================================
-- ===================================
-- ======= 1/ Asset Operations =======
-- ===================================
-- ===================================

--- Builds the boot-script statement that hands a page its strings: the whole
--- catalogue, active locale over English over French, so a key the active
--- locale lacks shows English rather than its name.
--- @param html_path string Page being built, named in the error log.
--- @return string The statement, or "" when the strings are unavailable.
local function strings_seed(html_path)
	local ok_cat, catalogue = pcall(function() return require("infra.locale").catalogue() end)
	local statement, seed_err = nil, catalogue
	if ok_cat then statement, seed_err = I18nSeed.statement(catalogue) end
	if not statement then
		Logger.error(LOG, "Page '%s' is built without its strings: %s.", html_path, tostring(seed_err))
		return ""
	end
	return statement
end

--- Reads a file from disk and returns its raw content.
--- Drops a cache-busting query or fragment from an asset reference.
---
--- `script.js?v=3` is an ordinary thing for a page author to write — it means
--- something to a browser fetching over HTTP — and it is not part of the
--- FILENAME. Concatenated raw onto the assets directory it makes the open miss,
--- and the tag is then replaced with nothing. The Linux driver carries the same
--- helper for the same reason.
--- @param reference string An href or src attribute value.
--- @return string The reference with everything from "?" or "#" removed.
local function strip_asset_query(reference)
	return (tostring(reference):gsub("[?#].*$", ""))
end

--- @param path string Full path to the file.
--- @return string The file content, or empty string if unreadable.
local function read_file(path)
	local ok, fh = pcall(io.open, path, "r")
	if not ok or not fh then return "" end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Builds a self-contained HTML string by inlining all local <script src> and
--- <link rel="stylesheet"> tags found in the HTML file. External URLs (http/https)
--- are kept as-is so CDN libraries still load from the network. Using function
--- replacements in gsub avoids any % escaping issues with JS/CSS content.
--- @param assets_dir string The directory containing the HTML and local assets.
--- @param html_name string Optional name of the HTML file (default: "index.html").
--- @return string The complete self-contained HTML string.
function M.build_injected_html(assets_dir, html_name)
	html_name = html_name or "index.html"
	-- The locale is part of the key: the page carries its strings, so a page
	-- built before a language switch must not be served after it.
	local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
	local active_locale = (ok_i18n and i18n_mod and i18n_mod.get_locale()) or "fr"
	local cache_key = assets_dir .. "|" .. html_name .. "|" .. active_locale
	if _html_cache[cache_key] then
		Logger.debug(LOG, "Injected HTML cache hit for '%s'.", html_name)
		return _html_cache[cache_key]
	end

	Logger.debug(LOG, "Building injected HTML assets…")

	local html_path = assets_dir .. html_name
	local ok, fh = pcall(io.open, html_path, "r")
	if not ok or not fh then
		Logger.error(LOG, "Failed to find HTML template: %s.", html_name)
		return "<html><body><h1>Build error: " .. html_name .. " not found</h1></body></html>"
	end
	local html = fh:read("*a")
	fh:close()

	-- Inject window.__i18n_base, window._i18n_locale and the page's strings
	-- right after <head>, before any page script runs. The page is inline, so
	-- its own fetch of a file:// locale is refused: the seeded strings are what
	-- it shows, from its first render, whatever state the boot is in.
	local i18n_boot = string.format(
		'<script>window.__i18n_base="%s";window._i18n_locale="%s";%s</script>',
		_locales_base_url, active_locale, strings_seed(html_path)
	)
	-- Use a function replacement to avoid gsub interpreting % in the boot script
	html = html:gsub("(<head[^>]*>)", function(tag) return tag .. i18n_boot end, 1)

	-- Inline local <link rel="stylesheet" href="..."> tags; leave CDN URLs intact
	html = html:gsub('<link%s+rel="stylesheet"%s+href="([^"]+)"%s*/>', function(href)
		if href:match("^https?://") then
			return '<link rel="stylesheet" href="' .. href .. '" />'
		end
		local css = read_file(assets_dir .. strip_asset_query(href))
		if css == "" then
			Logger.error(LOG, "Stylesheet '%s' could not be read — the page loads unstyled.", href)
			return ""
		end
		return "<style>" .. css .. "</style>"
	end)

	-- Inline local scripts even when the tag carries loading attributes such as
	-- `defer`. The metrics dashboards vendor their chart libraries locally; a
	-- src-only pattern left those tags unresolved inside an inline webview.
	html = html:gsub('<script([^>]*)%s+src="([^"]+)"([^>]*)></script>', function(_before, src, _after)
		if src:match("^https?://") then
			return '<script src="' .. src .. '"></script>'
		end
		local js = read_file(assets_dir .. strip_asset_query(src))
		if js == "" then
			-- Said out loud rather than silently deleted. The tag used to be
			-- replaced with nothing, so a page whose script could not be read
			-- loaded LOOKING fine and did nothing: every function the host later
			-- called was undefined, and every push it made was discarded by the
			-- page's own `if (window.x)` guard. The Linux driver spent five CI
			-- cycles on exactly that shape of silence.
			Logger.error(LOG, "Script '%s' could not be read — the page loads without it, "
				.. "so every function it defines will be undefined.", src)
			return ""
		end
		return "<script>" .. js .. "</script>"
	end)

	_html_cache[cache_key] = html
	Logger.info(LOG, "Injected HTML assets built and memoised (%d bytes).", #html)
	return html
end

--- Drops every memoised HTML so the next open re-reads sources from disk.
--- Call this from a /reload-style command if you edit assets and want the
--- change to take effect without a full Hammerspoon reload.
function M.clear_html_cache()
	_html_cache = {}
	Logger.info(LOG, "Injected HTML cache cleared.")
end

--- Pre-warms macOS WebKit by creating a tiny invisible webview.  The very
--- first webview created in a Hammerspoon session pays a 1-2 s framework-
--- load cost; subsequent webviews open in a single frame.  Calling this
--- once at HS startup moves that cost off the user's critical path so
--- dashboards open instantly when the menu shortcut is pressed.
function M.warmup_webkit()
	if _webkit_warmup_session then
		if _webkit_warmup_session.pending then
			Logger.debug(LOG, "WebKit warmup already pending; reusing exact session.")
			return true
		end
		return close_webkit_warmup(_webkit_warmup_session)
	end

	Logger.start(LOG, "Warming up WebKit framework…")
	local session = nil
	local ok, result = xpcall(function()
		local wv = hs.webview.new({ x = -10, y = -10, w = 1, h = 1 }, { developerExtrasEnabled = false })
		if not wv then return false end
		session = {pending = true, webview = wv}
		_webkit_warmup_session = session
		pcall(function() wv:html("<html><body></body></html>") end)
		pcall(function() wv:hide() end)
		-- Hold the warmup webview for 5 s so WebKit fully initialises, then release.
		if DeferredWork.after(5,
			function()
				if _webkit_warmup_session ~= session then return false end
				session.pending = false
				return close_webkit_warmup(session)
			end,
			"ui_builder.webkit_warmup") ~= true
		then
			session.pending = false
			close_webkit_warmup(session)
			return false
		end
		return true
	end, debug.traceback)
	if not ok and session and _webkit_warmup_session == session then
		session.pending = false
		close_webkit_warmup(session)
	end
	if ok and result == true then
		Logger.success(LOG, "WebKit warmup scheduled.")
		return true
	end
	Logger.warn(LOG, "WebKit warmup failed: %s.", tostring(result))
	return false
end





-- ==========================================
-- ==========================================
-- ======= 2/ External URL Operations =======
-- ==========================================
-- ==========================================

--- Opens an absolute HTTP(S) URL through the system handler.
--- Untrusted webview messages reach this boundary, so the native side owns the
--- scheme allowlist and basic syntax validation even when the frontend already
--- constrains its links.
--- @param url any Candidate URL from a webview bridge.
--- @return boolean True when the native open request was accepted.
function M.open_http_url(url)
	if type(url) ~= "string" then
		Logger.warn(LOG, "Refusing external URL: only absolute HTTP and HTTPS URLs are allowed.")
		return false
	end
	local scheme, authority_and_path = url:match("^([%a][%w+%.%-]*)://(.+)$")
	if not scheme
		or (scheme:lower() ~= "http" and scheme:lower() ~= "https")
		or authority_and_path:find("[%s%c]")
		or authority_and_path:match("^[/?#]")
	then
		Logger.warn(LOG, "Refusing external URL: only absolute HTTP and HTTPS URLs are allowed.")
		return false
	end

	local ok, accepted = pcall(hs.urlevent.openURL, url)
	if not ok or accepted == false then
		Logger.error(LOG, "Failed to open a validated external HTTP URL.")
		return false
	end
	return true
end





-- ====================================
-- ====================================
-- ======= 3/ Window Management =======
-- ====================================
-- ====================================

-- Per-process cache of the parsed shared apps manifest (`apps` table keyed by
-- app id). Read once from the shared tree; geometry never changes during a
-- session, so a single decode per HS session is enough.
local _apps_manifest_cache = nil

--- Loads and caches the shared per-app geometry manifest.
--- @return table|nil The `apps` table keyed by app id, or nil on failure.
local function load_apps_manifest()
	if _apps_manifest_cache ~= nil then
		return _apps_manifest_cache
	end
	local path = Paths.shared("ui/apps.manifest.json") or ""
	local ok_r, fh = pcall(io.open, path, "r")
	if not ok_r or not fh then
		Logger.error(LOG, "Cannot open apps.manifest.json at '%s'.", path)
		return nil
	end
	local content = fh:read("*a")
	fh:close()
	local data, decode_err = JsonCodec.decode(content)
	if decode_err ~= nil or type(data) ~= "table" or type(data.apps) ~= "table" then
		Logger.error(LOG, "Failed to parse apps.manifest.json.")
		return nil
	end
	_apps_manifest_cache = data.apps
	return _apps_manifest_cache
end

--- Resolves the canonical geometry for a webview app from the shared manifest.
--- Window geometry is defined exactly once in `_shared/ui/apps.manifest.json` so
--- all three drivers open every window at the same size (SSoT). Callers MUST use
--- this instead of hardcoding width/height. Fails loud (logs ERROR, returns nil)
--- on an unknown id so a typo surfaces immediately rather than silently opening a
--- mis-sized window; callers return early on nil (no hardcoded fallback, §5.4).
--- @param app_id string The manifest key (e.g. "hotstring_editor").
--- @return table|nil { width, height, min_width, min_height } or nil on miss.
function M.get_app_geometry(app_id)
	local apps = load_apps_manifest()
	if type(apps) ~= "table" then return nil end
	local entry = apps[app_id]
	if type(entry) ~= "table" or type(entry.width) ~= "number" or type(entry.height) ~= "number" then
		Logger.error(LOG, "No geometry for app id '%s' in apps.manifest.json.", tostring(app_id))
		return nil
	end
	Logger.debug(LOG, "Geometry for '%s': %dx%d.", app_id, entry.width, entry.height)
	return {
		width      = entry.width,
		height     = entry.height,
		min_width  = entry.min_width or entry.width,
		min_height = entry.min_height or entry.height,
	}
end

--- Calculates a perfectly centered frame for a given width and height on the main screen.
--- @param w number The desired width of the window.
--- @param h number The desired height of the window.
--- @return table The dictionary containing x, y, w, h coordinates.
function M.get_centered_frame(w, h)
	local screen = hs.screen.mainScreen()
	local sf = screen and type(screen.frame) == "function" and screen:frame() or {x = 0, y = 0, w = 1920, h = 1080}
	return {
		x = math.floor(sf.x + (sf.w - w) / 2),
		y = math.floor(sf.y + (sf.h - h) / 2),
		w = w,
		h = h
	}
end

--- Presents a webview window: teleports it to the current space, raises it and
--- gives it focus. This is the driver's one "present window" helper, used when a
--- window opens and when an open window is requested again. It never changes the
--- window level: an Ergopti window is focused, never kept above other apps.
--- @param wv userdata The hs.webview object.
--- @param is_new boolean When true the window is being shown for the first time — skip hide/show to avoid a
---   flicker where the window appears briefly hidden before the HTML finishes loading.
--- @param lifecycle table|nil Optional exact owner `{ schedule_after, is_current }`.
--- @return boolean|nil committed True after focus dispatch or an owned retry; false on failure or retirement.
function M.force_focus(wv, is_new, lifecycle)
	if not wv then return end
	lifecycle = type(lifecycle) == "table" and lifecycle or {}
	local failed = false
	local function fail(category)
		if not failed then
			failed = true
			Logger.error(LOG, "WebView focus failed at %s; further attempts suppressed.", category)
		end
		return false
	end
	local function current()
		if failed then return false end
		if type(lifecycle.is_current) ~= "function" then return true end
		local ok, result = xpcall(lifecycle.is_current, debug.traceback)
		if not ok then return fail("owner validation") end
		return ok == true and result == true
	end
	local function schedule(delay, callback, label)
		if not current() then return false end
		local ok, result = pcall(function()
			if type(lifecycle.schedule_after) == "function" then
				return lifecycle.schedule_after(delay, callback, label)
			end
			return DeferredWork.after(delay, callback, label or "ui_builder.force_focus")
		end)
		if not current() then return false end
		if not ok or result ~= true then return fail("retry scheduling") end
		return true
	end
	if not current() then return false end

	Logger.debug(LOG, "Forcing window focus and teleporting to active space…")

	-- Teleport strategy for an already-visible window:
	-- 1. Try hs.spaces: move the window to the active space programmatically.
	-- 2. Fall back to hide+show: macOS moves a shown window to the active space.
	-- On a brand-new window skip both — the webview is not yet visible so hide()
	-- races with the async HTML load and causes a blank first open.
	if not is_new then
		local ok_sp, hs_spaces = pcall(require, "hs.spaces")
		if not current() then return false end
		if ok_sp and hs_spaces then
			local ok_win, win = pcall(function() return wv:hswindow() end)
			if not current() then return false end
			if not ok_win then return fail("window lookup") end
			if ok_win and win then
				local ok_active, active_space = pcall(function()
					return hs_spaces.activeSpaceOnScreen(hs.screen.mainScreen())
				end)
				if not current() then return false end
				if not ok_active or active_space == nil then return fail("active space lookup") end
				if ok_active and active_space then
					local ok_move, moved = pcall(function() return hs_spaces.moveWindowToSpace(win, active_space) end)
					if not current() then return false end
					if not ok_move then return fail("space move") end
					if moved == true then
						Logger.debug(LOG, "Window teleported via hs.spaces.")
					else
						-- A documented refusal, e.g. the active Space belongs to a
						-- full-screen app. Presenting still has to happen: raising and
						-- focusing below switch the user to the window's own Space.
						Logger.warn(LOG, "The Space refused the window; presenting it on its own Space.")
					end
				end
			end
		end
		-- Intentionally no hide+show here: hide() resets the macOS compositor z-order
		-- and breaks Mission Control click-to-focus.  hs.spaces teleport is sufficient.
	end

	-- Bring to front and request system focus.
	-- We use a retry mechanism because hswindow() might return nil while the
	-- window is still being composited by the OS.
	local attempts = 0
	local max_attempts = 20
	local function try_focus()
		if not wv or not current() then return false end
		local ok, win = pcall(function() return wv:hswindow() end)
		if not current() then return false end
		if not ok then return fail("window lookup") end
		
		if ok and win and type(win.focus) == "function" then
			-- Best case: we have a window handle.
			local moved = pcall(function()
				local screen = hs.screen.mainScreen()
				if current() then win:moveToScreen(screen) end
			end)
			if not current() then return false end
			if not moved then return fail("screen move") end
			local activated = pcall(function() hs.focus(true) end)
			if not current() then return false end
			if not activated then return fail("application focus") end
			local restored, restore_result = pcall(function() return win:unminimize() end)
			if not current() then return false end
			if not restored or restore_result == nil or restore_result == false then
				return fail("window restore")
			end
			local raised = pcall(function() win:raise() end)
			if not current() then return false end
			if not raised then return fail("window raise") end
			local focused = pcall(function() win:focus() end)
			if not current() then return false end
			if not focused then return fail("window focus") end
			Logger.info(LOG, "Window presentation requested (attempt %d).", attempts + 1)
			return current()
		elseif attempts < max_attempts then
			-- Handle not ready yet: retry shortly.
			attempts = attempts + 1
			return schedule(0.05, try_focus, "webview focus retry")
		else
			-- Final fallback when no window handle appeared within 1 s: order the
			-- webview front again (show() makes it key) and activate Hammerspoon.
			-- Never bringToFront(): it sets a floating or screen-saver LEVEL instead
			-- of raising the window, which then stays above every other app.
			local activated = pcall(function() hs.focus(true) end)
			if not current() then return false end
			if not activated then return fail("fallback application focus") end
			local shown = pcall(function() wv:show() end)
			if not current() then return false end
			if not shown then return fail("fallback window focus") end
			Logger.warn(LOG, "Window presentation requested via show fallback after %d attempts.", max_attempts)
			return current()
		end
	end

	return try_focus()
end

--- True when the webview's window is the focused window. A shortcut or menu
--- entry that toggles a window closes it only when the user is looking at it;
--- a covered window is presented instead, since no window floats any more. A
--- failed lookup reads as not focused, so the toggle presents rather than
--- closing a window the user may not see.
--- @param wv userdata|nil The hs.webview object.
--- @return boolean
function M.is_window_focused(wv)
	if not wv then return false end
	local ok_win, win = pcall(function() return wv:hswindow() end)
	if not ok_win or not win then return false end
	local ok_focused, focused = pcall(function() return hs.window.focusedWindow() end)
	if not ok_focused or not focused then return false end
	local ok_same, same = pcall(function() return win:id() == focused:id() end)
	return ok_same and same == true
end

--- Composes a native window title. The product name is added here and only
--- here, so callers pass a brand-less *.window_title string: passing a string
--- that already carried the brand produced "ErgoptiPlus — ErgoptiPlus — Setup".
--- @param title string|nil Brand-less, already-translated title.
--- @return string
function M.window_title(title)
	return WindowTitles.compose(title)
end

--- Retitles an open webview, e.g. after a live language switch.
--- @param view userdata|table The native webview.
--- @param title string|nil Brand-less, already-translated title.
--- @return boolean applied
function M.set_window_title(view, title)
	if view == nil or type(view.windowTitle) ~= "function" then return false end
	local ok, err = pcall(function() view:windowTitle(M.window_title(title)) end)
	if not ok then
		Logger.error(LOG, "Webview retitle failed: %s.", tostring(err))
		return false
	end
	return true
end

--- The one window kept above other apps: the Accessibility steps of the macOS
--- permission dialog (ui/permission_dialog; its other kinds are focused like
--- any window). It is shown only while ErgoptiPlus is not trusted for
--- Accessibility, where force_focus cannot find it (hswindow() is an
--- Accessibility lookup), and its steps are followed in System Settings, the
--- active app, whose first click would bury a window at the normal level. It
--- floats, never activates the app (it requires focus = false) and its owner
--- closes it as soon as the grant arrives. No other window may name this chrome.
M.PERMISSION_DIALOG_CHROME = "permission_dialog"

--- Reports native constructor availability without allocating or changing a window.
--- @return boolean available The factory has its actual native creation port.
function M.can_create_webview()
	return type(hs) == "table" and type(hs.webview) == "table"
		and type(hs.webview.new) == "function"
end

--- Authenticates the actual contextual declaration and translation dependencies.
--- @return boolean current
local function presentation_owners_current()
	return getmetatable(WindowTitles) == nil and getmetatable(Presentation) == nil
		and getmetatable(PresentationI18n) == nil and getmetatable(PresentationLocale) == nil
		and getmetatable(PresentationLocaleCore) == nil
		and rawget(package.loaded, "ui.ui_builder") == M
		and rawget(package.loaded, "window_titles") == WindowTitles
		and rawget(package.loaded, "webview.presentation") == Presentation
		and rawget(package.loaded, "infra.i18n") == PresentationI18n
		and rawget(package.loaded, "infra.locale") == PresentationLocale
		and rawget(package.loaded, "locale.core") == PresentationLocaleCore
		and rawget(PresentationLocaleCore, "get") == PresentationCoreGetOwner
		and rawget(PresentationLocaleCore, "current_locale") == PresentationCoreCurrentOwner
		and rawget(WindowTitles, "presentation_for_app") == WindowPresentationOwner
		and rawget(WindowTitles, "compose") == WindowTitleComposeOwner
		and rawget(Presentation, "prepare") == PresentationPrepareOwner
		and rawget(PresentationI18n, "get") == PresentationTranslateOwner
		and rawget(PresentationLocale, "get") == PresentationLocaleGetOwner
		and rawget(PresentationLocale, "current_locale") == PresentationLocaleCurrentOwner
		and rawget(M, "prepare_app_presentation") == PresentationPrepareApi
		and rawget(M, "presentation_fields") == PresentationFieldsApi
		and rawget(M, "presentation_current") == PresentationCurrentApi
		and rawget(M, "show_webview") == PresentationShowApi
end

--- Prepares one genuine context before its caller replaces an existing window.
--- @param app_id string Canonical app identity.
--- @param presentation_id string Canonical context identity.
--- @return table|nil Opaque factory-owned receiving receipt.
function M.prepare_app_presentation(app_id, presentation_id)
	if type(WindowPresentationOwner) ~= "function" or type(PresentationPrepareOwner) ~= "function"
		or not presentation_owners_current() then return nil end
	local ok, prepared = pcall(PresentationPrepareOwner, WindowTitles, PresentationI18n,
		PresentationLocale, app_id, presentation_id, "hs", presentation_owners_current)
	if not ok or type(prepared) ~= "table" or getmetatable(prepared) ~= nil
		or type(rawget(prepared, "current")) ~= "function" or not presentation_owners_current()
		or prepared.current() ~= true then return nil end
	local receipt = {}
	_presentation_receipts[receipt] = {
		app_id = app_id, presentation_id = presentation_id,
		title = prepared.title, label = prepared.label, caption = prepared.caption,
		current = prepared.current,
	}
	return receipt
end

--- Checks only this factory's exact receipt and its retained Source cohort.
--- @param receipt table Opaque context receipt.
--- @return boolean current
function M.presentation_current(receipt)
	if type(receipt) ~= "table" or getmetatable(receipt) ~= nil or next(receipt) ~= nil
		or not presentation_owners_current() then return false end
	local retained = _presentation_receipts[receipt]
	if retained == nil then return false end
	local ok, current = pcall(retained.current)
	return ok and current == true and presentation_owners_current()
end

--- Reads the two immutable page strings from the actual factory-owned context.
--- @param receipt table Opaque context receipt.
--- @return string|nil title
--- @return string|nil label
function M.presentation_fields(receipt)
	if not PresentationCurrentApi(receipt) then return nil end
	local retained = _presentation_receipts[receipt]
	return retained.title, retained.label
end

PresentationPrepareApi = M.prepare_app_presentation
PresentationFieldsApi = M.presentation_fields
PresentationCurrentApi = M.presentation_current

--- Resolves an explicit app identity through the actual shared title policy.
--- Caller text remains supported only when no declared app identity is supplied.
--- @param opts table Native factory request.
--- @return string|nil label
--- @return string|nil caption
--- @return function|nil live
local function declared_window_title(opts)
	if getmetatable(opts) ~= nil then return nil end
	local app_id = rawget(opts, "app_id")
	local presentation_id, receipt = rawget(opts, "presentation_id"), rawget(opts, "presentation_receipt")
	if presentation_id ~= nil or receipt ~= nil then
		if rawget(opts, "title") ~= nil or rawget(opts, "label") ~= nil
			or not PresentationCurrentApi(receipt) then return nil end
		local retained = _presentation_receipts[receipt]
		if app_id ~= retained.app_id or presentation_id ~= retained.presentation_id then return nil end
		local function live()
			return getmetatable(opts) == nil and rawget(opts, "app_id") == app_id
				and rawget(opts, "presentation_id") == presentation_id
				and rawget(opts, "presentation_receipt") == receipt
				and rawget(opts, "title") == nil and rawget(opts, "label") == nil
				and PresentationCurrentApi(receipt)
		end
		if not live() then return nil end
		return retained.title, retained.caption, live
	end
	if type(app_id) ~= "string" or not app_id:match("^[a-z][a-z0-9_]*$")
		or rawget(opts, "title") ~= nil then return nil end
	local ok_i18n, i18n = pcall(require, "infra.i18n")
	if not ok_i18n or type(i18n) ~= "table" then return nil end
	local translate = rawget(i18n, "get")
	local function live()
		return getmetatable(opts) == nil and rawget(opts, "app_id") == app_id
			and rawget(opts, "title") == nil
			and getmetatable(WindowTitles) == nil and getmetatable(i18n) == nil
			and rawget(package.loaded, "window_titles") == WindowTitles
			and rawget(package.loaded, "infra.i18n") == i18n
			and rawget(WindowTitles, "key_for_app") == WindowTitleKeyOwner
			and rawget(WindowTitles, "compose") == WindowTitleComposeOwner
			and rawget(i18n, "get") == translate
			and type(WindowTitleKeyOwner) == "function"
			and type(WindowTitleComposeOwner) == "function" and type(translate) == "function"
	end
	if not live() then return nil end
	local ok, label, caption = pcall(function()
		local key = WindowTitleKeyOwner(app_id)
		if not live() or type(key) ~= "string" or key == "" then return nil end
		local text = translate(key)
		if not live() or type(text) ~= "string" or text == "" or text == key then return nil end
		local composed = WindowTitleComposeOwner(text)
		if not live() or type(composed) ~= "string" or composed == "" then return nil end
		return text, composed
	end)
	if not ok or label == nil or not live() then return nil end
	return label, caption, live
end

--- Centralized factory to create a webview window with consistent properties.
--- An explicit app_id receives its canonical shared title; title is caller text
--- only when no app identity is supplied. Unknown app identities refuse.
--- @param opts table The configuration options for the webview; focus = false
---        shows the window without activating the app or changing its level;
---        chrome = M.PERMISSION_DIALOG_CHROME is the one floating exception.
--- @return userdata|nil The configured webview instance.
function M.show_webview(opts)
	if type(opts) ~= "table" then return nil end
	local title_label, declared_caption, title_live
	if rawget(opts, "presentation_id") ~= nil or rawget(opts, "presentation_receipt") ~= nil
		or opts.app_id ~= nil then
		title_label, declared_caption, title_live = declared_window_title(opts)
		if title_label == nil then
			Logger.error(LOG, "WebView factory refused its declared app title.")
			return nil
		end
	end
	if M.can_create_webview() ~= true then return nil end
	if opts.level ~= nil then
		-- Refused before the native window exists, so nothing is left to clean up.
		Logger.error(LOG, "WebView factory refused a window level: windows are focused, never kept on top.")
		return nil
	end
	if opts.allow_text_entry ~= nil then
		Logger.error(LOG, "WebView factory refused allow_text_entry: every window must become key when clicked.")
		return nil
	end
	if opts.chrome ~= nil and (opts.chrome ~= M.PERMISSION_DIALOG_CHROME or opts.focus ~= false) then
		Logger.error(LOG, "WebView factory refused chrome '%s': only the permission dialog floats, unfocused.",
			tostring(opts.chrome))
		return nil
	end
	if _factory_build_owner then
		Logger.warn(LOG, "WebView factory construction re-entry refused; candidate still in progress.")
		return nil
	end
	if settle_factory_cleanup() ~= true then return nil end
	-- Open, first load and close are timed: a blank or slow window is otherwise
	-- indistinguishable in the log from a window that was never requested.
	local view_label = title_live and title_label
		or ((type(opts.title) == "string" and opts.title ~= "") and opts.title or "untitled")
	local opened_ms = now_ms()
	local load_logged = false
	Logger.debug(LOG, "Creating webview window '%s'…", view_label)

	if title_live and not title_live() then return nil end

	-- Prevent LuaSkin crash by not passing explicit nil for the third argument
	local wv
	if opts.usercontent then
		wv = hs.webview.new(opts.frame, { developerExtrasEnabled = false }, opts.usercontent)
	else
		wv = hs.webview.new(opts.frame, { developerExtrasEnabled = false })
	end
	
	if not wv then 
		Logger.error(LOG, "Failed to instantiate webview object.")
		return nil 
	end
	_factory_build_owner = wv
	local caller_owns_webview = false
	if type(opts.on_webview_created) == "function" then
		local acquired_ok, acquired = xpcall(function()
			return opts.on_webview_created(wv)
		end, debug.traceback)
		if acquired_ok ~= true then
			abandon_factory_candidate(wv, "ownership callback")
			return nil
		end
		caller_owns_webview = true
		if _factory_build_owner == wv then _factory_build_owner = nil end
		-- A literal refusal after a successful ownership callback means the
		-- caller already owns the exact candidate and will settle it. Deleting it
		-- here would create an unobservable second cleanup attempt before the
		-- caller has installed its close contract.
		if acquired ~= true then return nil end
	end
	local contextual_title = rawget(opts, "presentation_id") ~= nil or rawget(opts, "presentation_receipt") ~= nil
	local function webview_current()
		if contextual_title and (not title_live or not title_live()) then return false end
		if type(opts.is_current) ~= "function" then return true end
		local ok, result = xpcall(opts.is_current, debug.traceback)
		return ok == true and result == true
	end
	local strict_lifecycle = type(opts.is_current) == "function" or contextual_title
	local function abandon_required_mutation()
		if caller_owns_webview ~= true then
			abandon_factory_candidate(wv, "required mutation")
		end
		return nil
	end
	local function apply_webview_mutation(callback)
		if not webview_current() then return false end
		local ok = xpcall(callback, debug.traceback)
		if strict_lifecycle then
			return ok == true and webview_current()
		end
		-- Preserve the legacy best-effort factory for callers that do not opt in
		-- to exact ownership. Strict callers fail closed on any native exception.
		return true
	end
	local function apply_required_webview_mutation(callback, label)
		if not webview_current() then return false end
		local ok, result = xpcall(callback, debug.traceback)
		if ok ~= true then
			Logger.error(LOG, "Required webview %s failed: %s.", label, tostring(result))
			return false
		end
		if not webview_current() then
			Logger.error(LOG, "Required webview %s lost its lifecycle owner.", label)
			return false
		end
		return true
	end
	local function schedule_webview_timer(delay, callback, label)
		if type(opts.schedule_after) == "function" then
			local ok, result = xpcall(function()
				return opts.schedule_after(delay, callback, label)
			end, debug.traceback)
			return ok == true and result == true
		end
		return DeferredWork.after(delay, callback, label or "ui_builder.webview")
	end

	if title_live and not title_live() then return abandon_required_mutation() end
	local win_title = declared_caption or M.window_title(opts.title)
	local title_received = false
	if not apply_webview_mutation(function()
		-- Lifecycle observation may yield after the outer title admission.
		if title_live and not title_live() then return end
		wv:windowTitle(win_title)
		title_received = true
	end) then
		return abandon_required_mutation()
	end
	if title_live and (not title_received or not title_live()) then return abandon_required_mutation() end
	
	-- The chrome every Ergopti window shares comes from one function, so no
	-- window can be built with only part of it.
	for _, step in ipairs(M.window_chrome_steps(wv, opts)) do
		if not apply_webview_mutation(step.apply) then return abandon_required_mutation() end
	end
	-- Hammerspoon's webview window becomes key only while it allows text entry
	-- (libwebview.m canBecomeKeyWindow): without it a click never brings the
	-- window of the inactive app in front, and the window stays buried.
	if not apply_webview_mutation(function()
		wv:allowTextEntry(true)
	end) then return abandon_required_mutation() end
	
	if not apply_webview_mutation(function()
		wv:allowGestures(opts.allow_gestures == true)
	end) then return abandon_required_mutation() end
	if opts.allow_new_windows ~= nil and not apply_webview_mutation(function()
		wv:allowNewWindows(opts.allow_new_windows)
	end) then return abandon_required_mutation() end

	-- Bind closing cleanup callback
	if type(opts.on_close) == "function" then
		if not apply_webview_mutation(function()
			wv:windowCallback(function(action)
				if action == "closing" or action == "closed" then
					if action == "closing" then
						Logger.info(LOG, "Webview '%s' closed after %.1f s open.", view_label,
							(now_ms() - opened_ms) / 1000)
					end
					opts.on_close()
				end
			end)
		end) then return abandon_required_mutation() end
	end

	-- Bind navigation callback; also inject i18n strings after every navigation
	-- as a fallback for webviews where i18n.js fetch() cannot reach file:// URLs.
	local caller_nav = opts.on_navigation
	if not apply_webview_mutation(function()
		wv:navigationCallback(function(action, wv2, nav)
			if not webview_current() then return false end
			-- Forward to the caller's own handler first
			local result = true
			if type(caller_nav) == "function" then
				result = caller_nav(action, wv2, nav)
			end
			if action == "didFinishNavigation" and not load_logged then
				load_logged = true
				Logger.info(LOG, "Webview '%s' page loaded in %.0f ms.", view_label,
					now_ms() - opened_ms)
			elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
				Logger.warn(LOG, "Webview '%s' navigation failed (%s).", view_label, tostring(action))
			end
			-- After the page finishes loading, inject locale strings so that
			-- data-i18n elements are populated even when fetch() fails (inline HTML,
			-- about:blank origin, no file:// CORS access).
			if action == "didFinishNavigation" and opts.inject_i18n ~= false then
				schedule_webview_timer(0.08, function()
					if not wv or not wv2 or not webview_current() then return end
					local ok_mod, locale_mod = pcall(require, "infra.locale")
					if not ok_mod or not locale_mod then return end
					local all_strings = locale_mod.catalogue()
					if type(all_strings) ~= "table" then return end
					local ok_enc, json = pcall(hs.json.encode, all_strings)
					if not ok_enc or not json then
						Logger.warn(LOG, "Webview '%s' i18n strings could not be encoded: %s.",
							view_label, tostring(json))
						return
					end
					local injected, inject_err = pcall(function()
						wv:evaluateJavaScript(
							"if(window.i18n_apply){window.i18n_apply(" .. json .. ");}"
						)
					end)
					if not injected then
						Logger.warn(LOG, "Webview '%s' i18n injection failed: %s.",
							view_label, tostring(inject_err))
					end
				end, "webview i18n injection")
			end
			return result
		end)
	end) then return abandon_required_mutation() end

	-- Inject HTML assets — prefer a pre-built html_string when provided so
	-- callers that need to patch the HTML before loading (e.g. injecting a
	-- config <script> block) can do so without duplicating the inlining logic.
	if type(opts.html_string) == "string" and opts.html_string ~= "" then
		if not apply_required_webview_mutation(function() wv:html(opts.html_string) end,
			"HTML load") then
			return abandon_required_mutation()
		end
	elseif type(opts.assets_dir) == "string" then
		local final_html = M.build_injected_html(opts.assets_dir)
		if not webview_current() then return abandon_required_mutation() end
		if not apply_required_webview_mutation(function() wv:html(final_html) end,
			"HTML load") then
			return abandon_required_mutation()
		end
	end

	-- wv:html() loads content but does not show the window — explicit show() required.
	-- force_focus is called with is_new=true so it skips the space teleport and
	-- goes straight to raise + focus. This means every UI opened through this
	-- factory automatically comes to the foreground and receives keyboard focus
	-- without each caller having to remember to call it.
	-- A window opened with focus = false is shown and left where it is, without
	-- activating Hammerspoon. The forced focus finds the window through
	-- Accessibility, so it always fails in an untrusted process: a window meant
	-- to sit beside another app (System Settings) must not be focused.
	if not apply_required_webview_mutation(function() wv:show() end, "show") then
		return abandon_required_mutation()
	end
	local focused = true
	if opts.focus ~= false then
		focused = M.force_focus(wv, true, {
			schedule_after = opts.schedule_after,
			is_current = opts.is_current,
		})
	end
	if strict_lifecycle and focused ~= true then return abandon_required_mutation() end
	if not webview_current() then return abandon_required_mutation() end
	if _factory_build_owner == wv then _factory_build_owner = nil end
	Logger.info(LOG, "Webview '%s' opened in %.0f ms.", view_label,
		now_ms() - opened_ms)
	return wv
end

--- The window chrome every Ergopti webview window gets: a native title bar and
--- close button, the drop shadow that gives it a visible edge over a white page
--- (Hammerspoon webviews have none by default), and the normal window level.
--- An Ergopti window is raised and focused when it opens (force_focus), never
--- kept above other apps: at the floating level the diagnostics window stayed
--- over every window the user opened afterwards. The level step runs after the
--- style because a utility panel mask can make an NSPanel float on its own.
--- Every window applies these steps, in this order, and a window that skips this
--- function is caught by test_window_chrome_everywhere.
--- @param wv table The hs.webview window.
--- @param opts table|nil { style_masks?, chrome? } override for the mask; a level
---        is refused, and chrome = M.PERMISSION_DIALOG_CHROME floats (see there).
--- @return table Array of { name = string, apply = function } mutation steps.
function M.window_chrome_steps(wv, opts)
	opts = opts or {}
	if opts.level ~= nil then
		error("window_chrome_steps: windows take no level; they are focused, never kept on top", 2)
	end
	if opts.chrome ~= nil and opts.chrome ~= M.PERMISSION_DIALOG_CHROME then
		error("window_chrome_steps: unknown chrome '" .. tostring(opts.chrome) .. "'", 2)
	end
	local level = hs.drawing.windowLevels.normal
	if opts.chrome == M.PERMISSION_DIALOG_CHROME then
		level = hs.drawing.windowLevels.floating
	end
	if type(level) ~= "number" then
		error("window_chrome_steps: the window level is unavailable", 2)
	end
	local masks = hs.webview.windowMasks
	local style = opts.style_masks
		or ((masks["titled"] or 1) + (masks["closable"] or 2) + (masks["utility"] or 16))
	return {
		{ name = "windowStyle", apply = function() wv:windowStyle(style) end },
		{ name = "shadow",      apply = function() wv:shadow(true) end },
		{ name = "level",       apply = function() wv:level(level) end },
	}
end

PresentationShowApi = M.show_webview

return M
