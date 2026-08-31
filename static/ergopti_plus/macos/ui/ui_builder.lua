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
local DeferredWork = require("infra.deferred_work")
local LOG = "ui_builder"

-- Per-process cache of assembled HTML strings.  Avoids re-reading the local
-- CSS/JS files (and re-running the gsub inlining pass) on every UI open —
-- assets only change when the user edits source so a single assembly per
-- HS session is enough.
local _html_cache = {}

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
	local cache_key = assets_dir .. "|" .. html_name
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

	-- Inject window.__i18n_base and window._i18n_locale right after <head> so
	-- that i18n.js fetch() resolves locale JSON files correctly even when HTML
	-- is loaded inline (no file:// base URL).  The locale is read at build time
	-- from lib.i18n so the page renders in the user's active language.
	local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
	local active_locale = (ok_i18n and i18n_mod and i18n_mod.get_locale()) or "fr"
	local i18n_boot = string.format(
		'<script>window.__i18n_base="%s";window._i18n_locale="%s";</script>',
		_locales_base_url, active_locale
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
	Logger.start(LOG, "Warming up WebKit framework…")
	local ok, err = pcall(function()
		local wv = hs.webview.new({ x = -10, y = -10, w = 1, h = 1 }, { developerExtrasEnabled = false })
		if not wv then return end
		pcall(function() wv:html("<html><body></body></html>") end)
		pcall(function() wv:hide() end)
		-- Hold the warmup webview for 5 s so WebKit fully initialises, then release.
		if DeferredWork.after(5,
			function() pcall(function() wv:delete() end) end,
			"ui_builder.webkit_warmup") ~= true
		then
			pcall(function() wv:delete() end)
			error("WebKit warmup cleanup could not be scheduled")
		end
	end)
	if ok then
		Logger.success(LOG, "WebKit warmup scheduled.")
	else
		Logger.warn(LOG, "WebKit warmup failed: %s.", tostring(err))
	end
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
	local ok_j, data = pcall(hs.json.decode, content)
	if not ok_j or type(data) ~= "table" or type(data.apps) ~= "table" then
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

--- Forces a webview window to the front, teleports it to the current space natively, and gives it focus cleanly.
--- @param wv userdata The hs.webview object.
--- @param is_new boolean When true the window is being shown for the first time — skip hide/show to avoid a
---   flicker where the window appears briefly hidden before the HTML finishes loading.
--- @param lifecycle table|nil Optional exact owner `{ schedule_after, is_current }`.
function M.force_focus(wv, is_new, lifecycle)
	if not wv then return end
	lifecycle = type(lifecycle) == "table" and lifecycle or {}
	local function current()
		if type(lifecycle.is_current) ~= "function" then return true end
		local ok, result = xpcall(lifecycle.is_current, debug.traceback)
		return ok == true and result == true
	end
	local function schedule(delay, callback, label)
		if not current() then return false end
		if type(lifecycle.schedule_after) == "function" then
			local ok, result = xpcall(function()
				return lifecycle.schedule_after(delay, callback, label)
			end, debug.traceback)
			return ok == true and result == true
		end
		return DeferredWork.after(delay, callback, label or "ui_builder.force_focus")
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
			if ok_win and win then
				local ok_active, active_space = pcall(function()
					return hs_spaces.activeSpaceOnScreen(hs.screen.mainScreen())
				end)
				if not current() then return false end
				if ok_active and active_space then
					local ok_move = pcall(function() hs_spaces.moveWindowToSpace(win, active_space) end)
					if not current() then return false end
					if ok_move then
						Logger.debug(LOG, "Window teleported via hs.spaces.")
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
		if not wv or not current() then return end
		local ok, win = pcall(function() return wv:hswindow() end)
		
		if ok and win and type(win.focus) == "function" then
			-- Best case: we have a window handle.
			pcall(function() win:moveToScreen(hs.screen.mainScreen()) end)
			if not current() then return end
			pcall(function() win:raise() end) -- Ensure top of Z-order
			if not current() then return end
			pcall(function() win:focus() end) -- Capture keyboard focus
			if not current() then return end
			pcall(function() hs.focus(true) end) -- Force Hammerspoon app to foreground
			if not current() then return end
			Logger.info(LOG, "Window focus applied successfully (attempt %d).", attempts + 1)
		elseif attempts < max_attempts then
			-- Handle not ready yet: retry shortly.
			attempts = attempts + 1
			schedule(0.05, try_focus, "webview focus retry")
		else
			-- Final fallback: if no window handle after 1s, use the webview-level bringToFront.
			pcall(function() wv:bringToFront(true) end)
			if not current() then return end
			pcall(function() hs.focus(true) end)
			if not current() then return end
			Logger.warn(LOG, "Window focus applied via bringToFront fallback after %d attempts.", max_attempts)
		end
	end

	try_focus()
	return true
end

--- Centralized factory to create a webview window with consistent properties.
--- @param opts table The configuration options for the webview.
--- @return userdata|nil The configured webview instance.
function M.show_webview(opts)
	if type(opts) ~= "table" then return nil end
	Logger.debug(LOG, "Creating new webview window…")

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
	local caller_owns_webview = false
	if type(opts.on_webview_created) == "function" then
		local acquired_ok, acquired = xpcall(function()
			return opts.on_webview_created(wv)
		end, debug.traceback)
		if acquired_ok ~= true then
			pcall(function() wv:delete() end)
			return nil
		end
		caller_owns_webview = true
		-- A literal refusal after a successful ownership callback means the
		-- caller already owns the exact candidate and will settle it. Deleting it
		-- here would create an unobservable second cleanup attempt before the
		-- caller has installed its close contract.
		if acquired ~= true then return nil end
	end
	local function webview_current()
		if type(opts.is_current) ~= "function" then return true end
		local ok, result = xpcall(opts.is_current, debug.traceback)
		return ok == true and result == true
	end
	local strict_lifecycle = type(opts.is_current) == "function"
	local function abandon_required_mutation()
		if caller_owns_webview ~= true then
			pcall(function() wv:delete() end)
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

	local prefix = "ErgoptiPlus"
	local win_title = (opts.title and opts.title ~= "") and (prefix .. " — " .. opts.title) or prefix
	if not apply_webview_mutation(function() wv:windowTitle(win_title) end) then return nil end
	
	if opts.style_masks then 
		if not apply_webview_mutation(function() wv:windowStyle(opts.style_masks) end) then return nil end
	else
		local masks = hs.webview.windowMasks
		if not apply_webview_mutation(function()
			wv:windowStyle((masks["titled"] or 1) + (masks["closable"] or 2)
				+ (masks["utility"] or 16))
		end) then return nil end
	end
	
	-- DEFAULT TO FLOATING: Ensures Ergopti UIs appear on top of other apps.
	if not apply_webview_mutation(function()
		wv:level(opts.level or hs.drawing.windowLevels.floating)
	end) then return nil end
	if not apply_webview_mutation(function()
		wv:allowTextEntry(opts.allow_text_entry ~= false)
	end) then return nil end
	
	if not apply_webview_mutation(function()
		wv:allowGestures(opts.allow_gestures == true)
	end) then return nil end
	if opts.allow_new_windows ~= nil and not apply_webview_mutation(function()
		wv:allowNewWindows(opts.allow_new_windows)
	end) then return nil end

	-- Bind closing cleanup callback
	if type(opts.on_close) == "function" then
		if not apply_webview_mutation(function()
			wv:windowCallback(function(action)
				if action == "closing" or action == "closed" then opts.on_close() end
			end)
		end) then return nil end
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
			-- After the page finishes loading, inject locale strings so that
			-- data-i18n elements are populated even when fetch() fails (inline HTML,
			-- about:blank origin, no file:// CORS access).
			if action == "didFinishNavigation" and opts.inject_i18n ~= false then
				schedule_webview_timer(0.08, function()
					if not wv or not wv2 or not webview_current() then return end
					local ok_mod, locale_mod = pcall(require, "infra.locale")
					if not ok_mod or not locale_mod then return end
					local all_strings = locale_mod.all()
					if type(all_strings) ~= "table" then return end
					local ok_enc, json = pcall(hs.json.encode, all_strings)
					if not ok_enc or not json then return end
					pcall(function()
						wv:evaluateJavaScript(
							"if(window.i18n_apply){window.i18n_apply(" .. json .. ");}"
						)
					end)
				end, "webview i18n injection")
			end
			return result
		end)
	end) then return nil end

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
		if not webview_current() then return nil end
		if not apply_required_webview_mutation(function() wv:html(final_html) end,
			"HTML load") then
			return abandon_required_mutation()
		end
	end

	-- wv:html() loads content but does not show the window — explicit show() required.
	-- force_focus is called with is_new=true so it skips the hide/show flicker path
	-- and goes straight to the 50 ms delayed bringToFront + focus. This means every
	-- UI opened through this factory automatically comes to the foreground and receives
	-- keyboard focus without each caller having to remember to call it.
	if not apply_required_webview_mutation(function() wv:show() end, "show") then
		return abandon_required_mutation()
	end
	local focused = M.force_focus(wv, true, {
		schedule_after = opts.schedule_after,
		is_current = opts.is_current,
	})
	if strict_lifecycle and focused ~= true then return nil end
	if not webview_current() then return nil end
	Logger.info(LOG, "Webview window created successfully.")
	return wv
end

return M
