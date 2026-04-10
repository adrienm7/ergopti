--- lib/app_picker.lua

--- ==============================================================================
--- MODULE: Application Picker
--- DESCRIPTION:
--- Provides shared logic for discovering installed applications and building
--- a standardized exclusion menu.
---
--- FEATURES & RATIONALE:
--- 1. App Discovery: Scans the system for installed applications.
--- 2. Menu Building: Creates a standardized exclusion list submenu.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("lib.logger")

local LOG = "app_picker"





-- ========================================
-- ========================================
-- ======= 1/ Application Discovery =======
-- ========================================
-- ========================================

--- Scans the system for installed applications.
--- @return table A list of choices for hs.chooser.
function M.discover_apps()
	Logger.debug(LOG, "Discovering installed applications…")
	local cmd = "find /Applications \"$HOME/Applications\" -maxdepth 2 -name \"*.app\" -not -name \".*\" 2>/dev/null | sort"
	local ok, raw = pcall(hs.execute, cmd)
	if not ok or type(raw) ~= "string" then
		Logger.warn(LOG, "Failed to execute application discovery command.")
		return {}
	end
	
	local choices, seen = {}, {}
	for app_path in raw:gmatch("[^\n]+") do
		local name = app_path:match("([^/]+)%.app$")
		if name and not seen[app_path] then
			seen[app_path] = true
			local info = hs.application.infoForBundlePath(app_path)
			local bid  = type(info) == "table" and info.CFBundleIdentifier or nil
			local icon = nil
			
			if bid then
				local ok_img, img = pcall(hs.image.imageFromAppBundle, bid)
				if ok_img and img then
					pcall(function() img:setSize({w=18, h=18}) end)
					icon = img
				end
			end
			
			table.insert(choices, {
				text     = name, 
				subText  = app_path, 
				image    = icon,
				bundleID = bid, 
				appPath  = app_path,
			})
		end
	end
	
	table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
	Logger.info(LOG, "Application discovery completed.")
	return choices
end





-- ================================
-- ================================
-- ======= 2/ Menu Building =======
-- ================================
-- ================================

--- Builds a standardized exclusion list submenu.
--- @param current_apps table The current list of disabled apps.
--- @param on_change function Callback triggered when the list changes.
--- @param placeholder_text string Text to display in the chooser.
--- @return table The menu structure.
function M.build_menu(current_apps, on_change, placeholder_text)
	Logger.debug(LOG, "Building application exclusion menu…")
	local apps = type(current_apps) == "table" and current_apps or {}
	local menu = {}
	
	for i, app in ipairs(apps) do
		if type(app) == "table" then
			local icon = nil
			if app.bundleID then
				local ok, img = pcall(hs.image.imageFromAppBundle, app.bundleID)
				if ok and img then 
					pcall(function() img:setSize({w=16, h=16}) end)
					icon = img 
				end
			end
			
			local idx = i
			local styled = hs.styledtext.new(
				(app.name or "?") .. "\t✗",
				{ paragraphStyle = { tabStops = {{location = 260, alignment = "right"}} } }
			)
			
			table.insert(menu, {
				title = styled, 
				image = icon,
				fn    = function()
					local new_apps = {}
					for j, a in ipairs(apps) do
						if j ~= idx then table.insert(new_apps, a) end
					end
					on_change(new_apps)
				end,
			})
		end
	end
	
	if #menu > 0 then table.insert(menu, {title = "-"}) end

	-- One-click exclusion of the currently focused application
	local frontApp = hs.application.frontmostApplication()
	if frontApp then
		local bundleID = type(frontApp.bundleID) == "function" and frontApp:bundleID() or nil
		local appPath  = type(frontApp.path) == "function" and frontApp:path() or nil
		local appName  = type(frontApp.name) == "function" and frontApp:name() or nil

		local already_excluded = false
		for _, a in ipairs(apps) do
			if type(a) == "table" and ((a.appPath and a.appPath == appPath) or (a.bundleID and a.bundleID == bundleID)) then
				already_excluded = true
				break
			end
		end

		if not already_excluded and appName and appName ~= "Hammerspoon" then
			local icon = nil
			if bundleID then
				local ok, img = pcall(hs.image.imageFromAppBundle, bundleID)
				if ok and img then
					pcall(function() img:setSize({w=16, h=16}) end)
					icon = img
				end
			end
			table.insert(menu, {
				title = "Exclure " .. appName .. " (actuelle)",
				image = icon,
				fn    = function()
					local new_apps = {}
					for _, a in ipairs(apps) do table.insert(new_apps, a) end
					table.insert(new_apps, {
						name = appName, appPath = appPath, bundleID = bundleID,
					})
					on_change(new_apps)
				end,
			})
		end
	end
	
	table.insert(menu, {
		title = "+ Ajouter une autre application…",
		fn    = function()
			hs.timer.doAfter(0.1, function()
				local choices = M.discover_apps()
				local chooser = hs.chooser.new(function(choice)
					if not choice then return end
					
					local already_excluded = false
					for _, a in ipairs(apps) do
						if type(a) == "table" and a.appPath == choice.appPath then 
							already_excluded = true
							break 
						end
					end
					
					if not already_excluded then
						local new_apps = {}
						for _, a in ipairs(apps) do table.insert(new_apps, a) end
						table.insert(new_apps, {
							name = choice.text, appPath = choice.appPath, bundleID = choice.bundleID,
						})
						on_change(new_apps)
					end
				end)
				
				chooser:placeholderText(placeholder_text or "Rechercher une application…")
				chooser:choices(choices)
				chooser:bgDark(false)
				chooser:show()
			end)
		end,
	})
	
	Logger.info(LOG, "Application exclusion menu built successfully.")
	return menu
end

return M
