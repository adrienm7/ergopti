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

-- ============================================================================
-- 1. Bridge handler registry (mirrors host_bridge.js contract)
-- ============================================================================

--- The canonical list of bridge handler names from _shared/ui/host_bridge.js.
--- Every Linux webview MUST register these before loading HTML.
M.BRIDGE_NAMES = {
	"action_picker_bridge",
	"changelog_bridge",
	"dl_bridge",
	"hsEditor",
	"hotstrings_config_bridge",
	"hsOnboarding",
	"hsPaths",
	"hsPersonalInfo",
	"metrics_apps_bridge",
	"metrics_typing_bridge",
	"model_browser_bridge",
	"prompt_bridge",
	"token_bridge",
	"healthcheck",
	"personal_toml_editor",
}

--- Returns the full bridge name registry.
--- @return table Array of bridge handler names.
function M.get_bridge_names()
	return M.BRIDGE_NAMES
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
			return p:gsub("\\", "/")
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
			return p:gsub("\\", "/")
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
--- <link rel="stylesheet"> tags. External URLs (http/https) are kept as-is.
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

	-- Inline local <link rel="stylesheet" href="...">; leave CDN URLs intact
	html = html:gsub('<link%s+rel="stylesheet"%s+href="([^"]+)"%s*/>', function(href)
		if href:match("^https?://") then
			return '<link rel="stylesheet" href="' .. href .. '" />'
		end
		local css = read_file(assets_dir .. "/" .. href)
		return css ~= "" and ("<style>" .. css .. "</style>") or ""
	end)

	-- Inline local <script src="..."></script>; leave CDN URLs intact
	html = html:gsub('<script%s+src="([^"]+)"%s*></script>', function(src)
		if src:match("^https?://") then
			return '<script src="' .. src .. '"></script>'
		end
		local js = read_file(assets_dir .. "/" .. src)
		return js ~= "" and ("<script>" .. js .. "</script>") or ""
	end)

	return html
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

	return html
end

return M
