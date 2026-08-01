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
		local css = read_file(assets_dir .. href)
		return css ~= "" and ("<style>" .. css .. "</style>") or ""
	end)

	-- Inline local <script src="..."></script> tags; leave CDN URLs intact
	html = html:gsub('<script%s+src="([^"]+)"%s*></script>', function(src)
		if src:match("^https?://") then
			return '<script src="' .. src .. '"></script>'
		end
		local js = read_file(assets_dir .. src)
		return js ~= "" and ("<script>" .. js .. "</script>") or ""
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
		hs.timer.doAfter(5, function() pcall(function() wv:delete() end) end)
	end)
	if ok then
		Logger.success(LOG, "WebKit warmup scheduled.")
	else
		Logger.warn(LOG, "WebKit warmup failed: %s.", tostring(err))
	end
end





-- ====================================
-- ====================================
-- ======= 2/ Window Management =======
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
function M.force_focus(wv, is_new)
	if not wv then return end

	Logger.debug(LOG, "Forcing window focus and teleporting to active space…")

	-- Teleport strategy for an already-visible window:
	-- 1. Try hs.spaces: move the window to the active space programmatically.
	-- 2. Fall back to hide+show: macOS moves a shown window to the active space.
	-- On a brand-new window skip both — the webview is not yet visible so hide()
	-- races with the async HTML load and causes a blank first open.
	if not is_new then
		local ok_sp, hs_spaces = pcall(require, "hs.spaces")
		if ok_sp and hs_spaces then
			local ok_win, win = pcall(function() return wv:hswindow() end)
			if ok_win and win then
				local ok_active, active_space = pcall(function()
					return hs_spaces.activeSpaceOnScreen(hs.screen.mainScreen())
				end)
				if ok_active and active_space then
					local ok_move = pcall(function() hs_spaces.moveWindowToSpace(win, active_space) end)
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
		if not wv then return end
		local ok, win = pcall(function() return wv:hswindow() end)
		
		if ok and win and type(win.focus) == "function" then
			-- Best case: we have a window handle.
			pcall(function() win:moveToScreen(hs.screen.mainScreen()) end)
			pcall(function() win:raise() end) -- Ensure top of Z-order
			pcall(function() win:focus() end) -- Capture keyboard focus
			pcall(function() hs.focus(true) end) -- Force Hammerspoon app to foreground
			Logger.info(LOG, "Window focus applied successfully (attempt %d).", attempts + 1)
		elseif attempts < max_attempts then
			-- Handle not ready yet: retry shortly.
			attempts = attempts + 1
			hs.timer.doAfter(0.05, try_focus)
		else
			-- Final fallback: if no window handle after 1s, use the webview-level bringToFront.
			pcall(function() wv:bringToFront(true) end)
			pcall(function() hs.focus(true) end)
			Logger.warn(LOG, "Window focus applied via bringToFront fallback after %d attempts.", max_attempts)
		end
	end

	try_focus()
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

	local prefix = "ErgoptiPlus"
	local win_title = (opts.title and opts.title ~= "") and (prefix .. " — " .. opts.title) or prefix
	pcall(function() wv:windowTitle(win_title) end)
	
	if opts.style_masks then 
		pcall(function() wv:windowStyle(opts.style_masks) end) 
	else
		local masks = hs.webview.windowMasks
		pcall(function() wv:windowStyle((masks["titled"] or 1) + (masks["closable"] or 2) + (masks["utility"] or 16)) end)
	end
	
	-- DEFAULT TO FLOATING: Ensures Ergopti UIs appear on top of other apps.
	pcall(function() wv:level(opts.level or hs.drawing.windowLevels.floating) end)
	pcall(function() wv:allowTextEntry(opts.allow_text_entry ~= false) end)
	
	pcall(function() wv:allowGestures(opts.allow_gestures == true) end)
	if opts.allow_new_windows ~= nil then pcall(function() wv:allowNewWindows(opts.allow_new_windows) end) end

	-- Bind closing cleanup callback
	if type(opts.on_close) == "function" then
		pcall(function()
			wv:windowCallback(function(action)
				if action == "closing" or action == "closed" then opts.on_close() end
			end)
		end)
	end

	-- Bind navigation callback; also inject i18n strings after every navigation
	-- as a fallback for webviews where i18n.js fetch() cannot reach file:// URLs.
	local caller_nav = opts.on_navigation
	pcall(function()
		wv:navigationCallback(function(action, wv2, nav)
			-- Forward to the caller's own handler first
			local result = true
			if type(caller_nav) == "function" then
				result = caller_nav(action, wv2, nav)
			end
			-- After the page finishes loading, inject locale strings so that
			-- data-i18n elements are populated even when fetch() fails (inline HTML,
			-- about:blank origin, no file:// CORS access).
			if action == "didFinishNavigation" and opts.inject_i18n ~= false then
				hs.timer.doAfter(0.08, function()
					if not wv or not wv2 then return end
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
				end)
			end
			return result
		end)
	end)

	-- Inject HTML assets — prefer a pre-built html_string when provided so
	-- callers that need to patch the HTML before loading (e.g. injecting a
	-- config <script> block) can do so without duplicating the inlining logic.
	if type(opts.html_string) == "string" and opts.html_string ~= "" then
		pcall(function() wv:html(opts.html_string) end)
	elseif type(opts.assets_dir) == "string" then
		local final_html = M.build_injected_html(opts.assets_dir)
		pcall(function() wv:html(final_html) end)
	end

	-- wv:html() loads content but does not show the window — explicit show() required.
	-- force_focus is called with is_new=true so it skips the hide/show flicker path
	-- and goes straight to the 50 ms delayed bringToFront + focus. This means every
	-- UI opened through this factory automatically comes to the foreground and receives
	-- keyboard focus without each caller having to remember to call it.
	pcall(function() wv:show() end)
	M.force_focus(wv, true)
	Logger.info(LOG, "Webview window created successfully.")
	return wv
end

return M
