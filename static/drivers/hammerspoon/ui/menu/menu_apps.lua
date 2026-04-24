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
--- 3. Launch: Each entry opens the app via hs.application.launchOrFocus so the
---    OS handles focus correctly.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")

local LOG = "menu_apps"




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

--- Scans the apps/ directory and returns a list of discovered bundles.
--- @return table List of {name, path, bundleID, icon} entries.
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
			local bid     = type(info) == "table" and info.CFBundleIdentifier or nil
			local display = (type(info) == "table" and info.CFBundleDisplayName) or
			                (type(info) == "table" and info.CFBundleName) or raw_name

			local icon = nil
			-- Prefer bundle icon; fall back to SVG embedded in Resources/
			-- setSize alone does not reliably constrain high-res images in menus;
			-- draw into a fixed canvas to guarantee the rendered size
			local function resize_to_menu_icon(img)
				local c = hs.canvas.new({ x = 0, y = 0, w = 16, h = 16 })
				c:appendElements({
					type  = "image",
					image = img,
					frame = { x = 0, y = 0, w = 16, h = 16 },
					imageScaling = "scaleToFit",
				})
				local out = c:imageFromCanvas()
				c:delete()
				return out
			end

			if bid then
				local ok_img, img = pcall(hs.image.imageFromAppBundle, bid)
				if ok_img and img then
					local ok_r, resized = pcall(resize_to_menu_icon, img)
					icon = ok_r and resized or img
				end
			end
			if not icon then
				local svg_path = app_path .. "/Contents/Resources/AppIcon.svg"
				local ok_svg, img_svg = pcall(hs.image.imageFromPath, svg_path)
				if ok_svg and img_svg then
					local ok_r, resized = pcall(resize_to_menu_icon, img_svg)
					icon = ok_r and resized or img_svg
				end
			end

			table.insert(entries, {
				name     = display,
				path     = app_path,
				bundleID = bid,
				icon     = icon,
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

	local apps   = discover_bundled_apps()
	local rows   = {}

	for _, app in ipairs(apps) do
		local styled = hs.styledtext.new(
			app.name,
			{ paragraphStyle = { tabStops = {{ location = 260, alignment = "left" }} } }
		)

		local app_path = app.path
		local app_name = app.name
		table.insert(rows, {
			title    = styled,
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
