--- ui/menu/menu_apps.lua

--- ==============================================================================
--- MODULE: Menu Applications
--- DESCRIPTION:
--- Builds the "Applications" submenu listing the bundled utility apps located
--- in the apps/ directory alongside the Hammerspoon driver.
---
--- FEATURES & RATIONALE:
--- 1. Discovery: Scans the apps/ directory at build time so new bundles appear
---    automatically without touching this file.
--- 2. Style Parity: Mirrors the icon + styled-text row format used in
---    lib/app_picker.lua for visual consistency across the menu.
--- 3. Icon Loading: Loads icons directly from the .icns file in Resources/ to
---    avoid relying on bundle ID registration (which may not be done on first
---    install). Falls back to AppIcon.svg, then to no icon.
--- 4. Launch: Each entry opens the app via hs.application.launchOrFocus so the
---    OS handles focus correctly.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")

local LOG = "menu_apps"


-- Short descriptions shown next to each app name in the submenu
local APP_DESCRIPTIONS = {
	["App Cloner"] = "Cloner une app avec icône et identité propres",
	["Encryptor"]  = "Chiffrer des fichiers journaux",
}




-- ==========================================
-- ==========================================
-- ======= 1/ Application Discovery =========
-- ==========================================
-- ==========================================

--- Resolves the absolute path to the apps/ directory bundled with the driver.
--- @return string|nil The path, or nil if it cannot be determined.
local function apps_dir()
	-- hs.configdir points to the loaded Hammerspoon config root
	local base = hs.configdir
	if not base then return nil end
	-- The apps/ folder sits at the same level as init.lua
	return base .. "/apps"
end

--- Draws an image into a 16×16 canvas to guarantee pixel-accurate menu sizing.
--- setSize() alone does not constrain high-res images when macOS renders menus.
--- @param img userdata An hs.image object.
--- @return userdata A new 16×16 hs.image.
local function resize_to_menu_icon(img)
	local c = hs.canvas.new({ x = 0, y = 0, w = 16, h = 16 })
	c:appendElements({
		type         = "image",
		image        = img,
		frame        = { x = 0, y = 0, w = 16, h = 16 },
		imageScaling = "scaleToFit",
	})
	local out = c:imageFromCanvas()
	c:delete()
	return out
end

--- Loads the icon for a bundle, trying sources in priority order.
--- Priority: .icns declared in Info.plist → any .icns in Resources → AppIcon.svg.
--- Does NOT rely on bundle ID registration so it works before the first launch.
--- @param app_path string Absolute path to the .app bundle.
--- @param info table|nil Parsed Info.plist table (may be nil).
--- @return userdata|nil An hs.image sized to 16×16, or nil on failure.
local function load_icon(app_path, info)
	local resources = app_path .. "/Contents/Resources"

	-- Try the declared icon file first
	local icon_file = type(info) == "table" and info.CFBundleIconFile or nil
	if icon_file then
		-- macOS omits the extension in the plist value half the time
		local candidates = {
			resources .. "/" .. icon_file,
			resources .. "/" .. icon_file .. ".icns",
		}
		for _, p in ipairs(candidates) do
			local ok, img = pcall(hs.image.imageFromPath, p)
			if ok and img then
				local ok_r, r = pcall(resize_to_menu_icon, img)
				return ok_r and r or img
			end
		end
	end

	-- Scan for any .icns in Resources/
	local ok_ls, ls = pcall(hs.execute, string.format(
		"find %q -maxdepth 1 -name '*.icns' 2>/dev/null | head -1",
		resources
	))
	if ok_ls and type(ls) == "string" then
		local icns_path = ls:match("([^\n]+)")
		if icns_path then
			local ok, img = pcall(hs.image.imageFromPath, icns_path)
			if ok and img then
				local ok_r, r = pcall(resize_to_menu_icon, img)
				return ok_r and r or img
			end
		end
	end

	-- SVG fallback
	local svg_path = resources .. "/AppIcon.svg"
	local ok_svg, img_svg = pcall(hs.image.imageFromPath, svg_path)
	if ok_svg and img_svg then
		local ok_r, r = pcall(resize_to_menu_icon, img_svg)
		return ok_r and r or img_svg
	end

	return nil
end

--- Scans the apps/ directory and returns a list of discovered bundles.
--- @return table List of {name, description, path, icon} entries.
local function discover_bundled_apps()
	local dir = apps_dir()
	if not dir then
		Logger.warn(LOG, "Could not resolve apps/ directory path.")
		return {}
	end

	Logger.trace(LOG, "Scanning apps/ directory: %s…", dir)
	local ok, raw = pcall(hs.execute, string.format(
		"find %q -maxdepth 1 -name '*.app' 2>/dev/null | sort",
		dir
	))
	if not ok or type(raw) ~= "string" then
		Logger.warn(LOG, "App directory scan failed.")
		return {}
	end

	local entries = {}
	for app_path in raw:gmatch("[^\n]+") do
		local raw_name = app_path:match("([^/]+)%.app$")
		if raw_name then
			local info    = hs.application.infoForBundlePath(app_path)
			local display = (type(info) == "table" and info.CFBundleDisplayName ~= "" and info.CFBundleDisplayName)
			             or (type(info) == "table" and info.CFBundleName ~= "" and info.CFBundleName)
			             or raw_name

			table.insert(entries, {
				name        = display,
				description = APP_DESCRIPTIONS[display] or "",
				path        = app_path,
				icon        = load_icon(app_path, info),
			})
		end
	end

	Logger.done(LOG, "Found %d bundled app(s).", #entries)
	return entries
end




-- =====================================
-- =====================================
-- ======= 2/ Submenu Construction =======
-- =====================================
-- =====================================

--- Builds the Applications submenu for the Hammerspoon menubar.
--- @param ctx table The global UI context.
--- @return table The menu item representing the Applications submenu.
function M.build(ctx)
	Logger.trace(LOG, "Building applications submenu…")
	local paused = ctx and ctx.paused

	local apps = discover_bundled_apps()
	local rows = {}

	for _, app in ipairs(apps) do
		local label = app.name
		if app.description ~= "" then
			label = label .. " — " .. app.description
		end

		local app_path = app.path
		local app_name = app.name
		table.insert(rows, {
			title    = label,
			image    = app.icon,
			disabled = paused,
			fn       = function()
				Logger.info(LOG, "Opening bundled app '%s'…", app_name)
				local ok_open, err = pcall(hs.application.launchOrFocus, app_path)
				if not ok_open then
					Logger.error(LOG, "Failed to open '%s': %s.", app_name, tostring(err))
				end
			end,
		})
	end

	if #rows == 0 then
		table.insert(rows, { title = "Aucune application disponible", disabled = true })
	end

	Logger.done(LOG, "Applications submenu built (%d item(s)).", #rows)
	return {
		title    = "Applications 🛠️",
		disabled = paused,
		menu     = rows,
	}
end

return M
