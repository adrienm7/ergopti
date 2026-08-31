--- ui/webkit_host.lua
---
--- Pure logic for the WebKit2GTK host bridge — path resolution, HTML asset
--- inlining, i18n locale injection, and bridge handler registry.
---
--- The actual GTK/WebKit2 calls (gtk_init, webkit_web_view_new, etc.) are
--- NOT in this module — they live in the native entry point (ergopti.lua)
--- which calls these pure functions to resolve paths and build HTML.
---
--- This file was Item 23 of the Linux port (Palier 4).
---
--- BRIDGE HANDLER REGISTRY:
--- Each bridge name from host_bridge.js must be registered with
--- webkit_user_content_manager_register_script_message_handler() before
--- loading the webview. This module exports the canonical registry.

local M = {}

-- pcall, not a hard require: this module is read by tests and tooling that load
-- it before the driver's own package.path is set, and a missing logger must cost
-- a diagnostic rather than the whole webview layer.
local Logger
local ok_logger, logger_mod = pcall(require, "logger.shim")
if ok_logger and type(logger_mod) == "table" then
	Logger = logger_mod
else
	local function noop() end
	Logger = { error = noop, warn = noop, info = noop, debug = noop }
end

local LOG = "ui.webkit_host"

-- ============================================================================
-- 1. Bridge handler registry (mirrors host_bridge.js contract)
-- ============================================================================

--- The one native capability owned by each shared UI page.
---
--- WebKit exposes every registered script-message handler directly to page
--- JavaScript. Registering the global bridge catalogue on every window therefore
--- gave a metrics page the capabilities of the prompt editor, onboarding, and
--- every other privileged page. Keep ownership explicit and page-scoped.
M.APP_BRIDGES = {
	action_picker            = "action_picker_bridge",
	changelog                = "changelog_bridge",
	download_window          = "dl_bridge",
	healthcheck              = "healthcheck",
	hotstring_editor         = "hsEditor",
	hotstrings_config_window = "hotstrings_config_bridge",
	metrics_apps             = "metrics_apps_bridge",
	metrics_typing           = "metrics_typing_bridge",
	model_browser            = "model_browser_bridge",
	numeric_prompt           = "numeric_prompt_bridge",
	onboarding               = "hsOnboarding",
	paths_editor             = "hsPaths",
	personal_info_editor     = "hsPersonalInfo",
	prompt_editor            = "prompt_bridge",
	token_prompt             = "token_bridge",
}

--- The canonical bridge-name catalogue, derived from page ownership above.
M.BRIDGE_NAMES = {}
for _, bridge_name in pairs(M.APP_BRIDGES) do
	M.BRIDGE_NAMES[#M.BRIDGE_NAMES + 1] = bridge_name
end
table.sort(M.BRIDGE_NAMES)

--- Returns the full bridge name registry.
--- @return table Array of bridge handler names.
function M.get_bridge_names()
	return M.BRIDGE_NAMES
end

--- Returns the sole native bridge owned by a shared UI page.
--- @param app_name string Shared UI directory name.
--- @return string|nil
function M.bridge_for_app(app_name)
	return M.APP_BRIDGES[app_name]
end

--- Checks whether a bridge name is valid.
--- @param name string
--- @return boolean
function M.is_valid_bridge(name)
	for _, b in ipairs(M.BRIDGE_NAMES) do
		if b == name then return true end
	end
	return false
end

-- ============================================================================
-- 2. Path resolution
-- ============================================================================

--- Resolves the shared UI assets root directory relative to the driver root.
--- @param driver_root string Absolute path to the linux driver root.
--- @return string Absolute path to _shared/ui/, or empty string if not found.
function M.resolve_ui_root(driver_root)
	driver_root = driver_root or "."
	local candidates = {
		driver_root .. "/../_shared/ui",
		driver_root .. "/../../_shared/ui",
	}
	for _, p in ipairs(candidates) do
		local fh = io.open(p .. "/host_bridge.js", "r")
		if fh then
			fh:close()
			-- Normalize to forward slashes
			return (p:gsub("\\", "/"))
		end
	end
	return ""
end

--- Resolves the locale data directory for i18n.
--- @param driver_root string Absolute path to the linux driver root.
--- @return string Absolute path to _shared/data/locales/, or empty string.
function M.resolve_locales_dir(driver_root)
	driver_root = driver_root or "."
	local candidates = {
		driver_root .. "/../_shared/data/locales",
		driver_root .. "/../../_shared/data/locales",
	}
	for _, p in ipairs(candidates) do
		local fh = io.open(p .. "/fr.json", "r")
		if fh then
			fh:close()
			return (p:gsub("\\", "/"))
		end
	end
	return ""
end

--- Resolves the path to a specific UI app's assets directory.
--- @param ui_root string Path returned by resolve_ui_root().
--- @param app_name string App directory name (e.g. "action_picker", "metrics_apps").
--- @return string Absolute path to the app directory, or empty string.
function M.resolve_app_dir(ui_root, app_name)
	if type(ui_root) ~= "string" or ui_root == "" then return "" end
	if type(app_name) ~= "string" or app_name == "" then return "" end
	local path = ui_root .. "/" .. app_name
	local fh = io.open(path .. "/index.html", "r")
	if fh then
		fh:close()
		return path
	end
	return ""
end

-- ============================================================================
-- 3. HTML asset inlining (mirrors ui_builder.lua)
-- ============================================================================

--- Reads a file from disk and returns its raw content.
--- Drops the cache-busting query from an asset reference.
---
--- `script.js?v=3` names the file `script.js`. The query means something to a
--- browser fetching over HTTP and nothing to `io.open`, so it has to come off
--- before the path is built — otherwise the read misses, the tag is replaced with
--- nothing, and the page loads with that asset silently absent.
--- @param reference string As written in the HTML.
--- @return string
local function strip_asset_query(reference)
	return (tostring(reference):gsub("[?#].*$", ""))
end

--- @param path string Full path to the file.
--- @return string The file content, or empty string if unreadable.
local function read_file(path)
	if type(path) ~= "string" or path == "" then return "" end
	local ok, fh = pcall(io.open, path, "r")
	if not ok or not fh then return "" end
	local content = fh:read("*a")
	fh:close()
	return content or ""
end

--- Builds a self-contained HTML string by inlining local <script src> and
--- <link rel="stylesheet"> tags. Remote executable assets fail the build.
--- @param assets_dir string Directory containing index.html and local assets.
--- @param html_name string|nil Name of the HTML file (default: "index.html").
--- @return string Self-contained HTML, or an error page on failure.
function M.build_injected_html(assets_dir, html_name)
	html_name = html_name or "index.html"
	if type(assets_dir) ~= "string" or assets_dir == "" then
		return "<html><body><h1>Build error: assets_dir empty</h1></body></html>"
	end

	local html_path = assets_dir .. "/" .. html_name
	local html = read_file(html_path)
	if html == "" then
		return "<html><body><h1>Build error: " .. html_name .. " not found</h1></body></html>"
	end

	local asset_error = nil
	local function reject_asset(kind, reference)
		asset_error = string.format("%s '%s' is remote or unreadable", kind, reference)
		Logger.error(LOG, "%s", asset_error)
		return ""
	end

	local function is_remote(reference)
		return reference:match("^%s*https?://") ~= nil
			or reference:match("^%s*//") ~= nil
	end

	-- Inline local stylesheets. Privileged webviews must not execute mutable
	-- network content, so remote references fail the complete page build.
	html = html:gsub('<link%s+rel="stylesheet"%s+href="([^"]+)"%s*/>', function(href)
		if is_remote(href) then return reject_asset("Stylesheet", href) end
		local css = read_file(assets_dir .. "/" .. strip_asset_query(href))
		if css == "" then return reject_asset("Stylesheet", href) end
		return "<style>" .. css .. "</style>"
	end)

	-- Attribute-bearing tags (notably `defer`) are accepted because inlining
	-- preserves their source order in the self-contained document.
	html = html:gsub('<script([^>]*)%s+src="([^"]+)"([^>]*)></script>', function(_before, src, _after)
		if is_remote(src) then return reject_asset("Script", src) end
		local js = read_file(assets_dir .. "/" .. strip_asset_query(src))
		if js == "" then return reject_asset("Script", src) end
		return "<script>" .. js .. "</script>"
	end)

	if asset_error then
		return "<html><body><h1>Build error: required local asset unavailable</h1></body></html>"
	end
	return html
end

--- Injects the Linux webview's no-network content security policy.
---
--- Inline script/style remain temporarily necessary because the host builds one
--- self-contained document. Remote execution and connections are denied. The
--- separate CSP hardening finding owns migration away from unsafe-inline.
--- @param html string
--- @param app_name string|nil Shared UI application name.
--- @return string
function M.inject_no_remote_csp(html, app_name)
	if type(html) ~= "string" then return html or "" end
	-- The source page can carry a browser-host CSP for external same-origin
	-- assets. Linux has already inlined those assets, so retaining both policies
	-- makes their intersection reject every script. Publish exactly one policy
	-- for the generated document instead.
	html = html:gsub(
		'<meta%s+[^>]-http%-equiv%s*=%s*["\']Content%-Security%-Policy["\'][^>]*>%s*', "")
	local connect_sources = "'self' file:"
	if app_name == "changelog" then
		connect_sources = connect_sources .. " https://api.github.com"
	end
	local script_sources = "'unsafe-inline'"
	if app_name == "changelog" then
		local handle = io.open("/dev/urandom", "rb")
		local random = handle and handle:read(18) or nil
		if handle then handle:close() end
		local ok_base64, Base64 = pcall(require, "compat.base64")
		local nonce = ok_base64 and type(random) == "string" and #random == 18
			and Base64.encode(random) or nil
		if type(nonce) ~= "string" or nonce == "" then
			Logger.error(LOG, "Cannot build changelog: CSP nonce generation failed.")
			return "<html><body><h1>Build error: CSP nonce unavailable</h1></body></html>"
		end
		html = html:gsub("<script([^>]*)>", function(attributes)
			return '<script nonce="' .. nonce .. '"' .. attributes .. ">"
		end)
		script_sources = "'nonce-" .. nonce .. "'"
	end
	local policy = "default-src 'none'; base-uri 'none'; connect-src " .. connect_sources .. "; "
		.. "font-src 'self' data:; form-action 'none'; frame-src 'none'; "
		.. "img-src 'self' data: blob: file:; media-src 'none'; object-src 'none'; "
		.. "script-src " .. script_sources .. "; style-src 'unsafe-inline'; worker-src 'none'"
	local meta = '<meta http-equiv="Content-Security-Policy" content="' .. policy .. '" />'
	return html:gsub("(<head[^>]*>)", function(tag)
		return tag .. meta
	end, 1)
end

-- ============================================================================
-- 4. i18n injection (mirrors ui_builder.lua i18n_boot)
-- ============================================================================

--- Builds the i18n bootstrap <script> tag to inject before the closing </head>.
--- Injects window.__i18n_base and window._i18n_locale so the browser-side
--- i18n.js fetch() resolves locale JSON files correctly even when the HTML
--- is loaded inline (no file:// base URL).
--- @param locales_dir string Path returned by resolve_locales_dir().
--- @param active_locale string Locale code (e.g. "fr", "en").
--- @return string Script tag to inject into <head>.
function M.build_i18n_boot_script(locales_dir, active_locale)
	locales_dir = locales_dir or ""
	active_locale = active_locale or "fr"

	-- Build a file:// URL for the locales directory
	local base = locales_dir:gsub("\\", "/")
	if base ~= "" then
		if not base:match("^/") then base = "/" .. base end
		if not base:match("/$") then base = base .. "/" end
		base = "file://" .. base
	end

	return string.format(
		'<script>window.__i18n_base="%s";window._i18n_locale="%s";</script>',
		base, active_locale
	)
end

--- Injects the i18n boot script into the HTML <head> tag.
--- @param html string Full HTML string.
--- @param i18n_script string Script tag from build_i18n_boot_script().
--- @return string HTML with the script injected after <head>.
function M.inject_i18n_boot(html, i18n_script)
	if type(html) ~= "string" or type(i18n_script) ~= "string" then
		return html or ""
	end
	return html:gsub("(<head[^>]*>)", function(tag)
		return tag .. i18n_script
	end, 1)
end

-- ============================================================================
-- 5. Full build pipeline (convenience)
-- ============================================================================

--- Builds a complete, self-contained HTML string for a webview app.
--- This is the main entry point: resolves paths, inlines assets, injects i18n.
--- @param driver_root string Absolute path to the linux driver root.
--- @param app_name string App directory name under _shared/ui/.
--- @param active_locale string|nil Locale code (default: "fr").
--- @return string Complete HTML string ready for webkit_web_view_load_html().
function M.build_app_html(driver_root, app_name, active_locale)
	active_locale = active_locale or "fr"

	local ui_root    = M.resolve_ui_root(driver_root)
	if ui_root == "" then
		return "<html><body><h1>Error: _shared/ui/ not found</h1></body></html>"
	end

	local app_dir = M.resolve_app_dir(ui_root, app_name)
	if app_dir == "" then
		return "<html><body><h1>Error: app '" .. app_name .. "' not found</h1></body></html>"
	end

	local html = M.build_injected_html(app_dir, "index.html")

	local locales_dir = M.resolve_locales_dir(driver_root)
	local i18n_script = M.build_i18n_boot_script(locales_dir, active_locale)
	html = M.inject_i18n_boot(html, i18n_script)
	html = html:gsub("(<head[^>]*>)", function(tag)
		return tag .. '<script>window.__ergopti_host="linux";</script>'
	end, 1)
	html = M.inject_no_remote_csp(html, app_name)

	return html
end

return M
