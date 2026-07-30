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
local hs     = hs
local ShellRunner = require("adapters.shell_runner")
local Logger = require("lib.logger")
local i18n   = require("lib.i18n")
local text_utils = require("lib.text_utils")

local LOG = "app_picker"





-- ========================================
-- ========================================
-- ======= 1/ Application Discovery =======
-- ========================================
-- ========================================

--- Scans the system for installed applications.

-- Discovered-application cache. Declared above the function that reads it: a
-- local placed below would bind the nil global instead.
local _apps_cache    = nil
local _apps_cache_at = 0

-- Forward declaration: discover_apps's completion callback calls build_choices,
-- which is defined below it. A local declared after the closure would bind the
-- nil global instead.
local build_choices

-- How long a discovery result stays warm. Long enough that reopening the picker
-- costs nothing, short enough that an app installed during the session shows up
-- without a reload.
local APPS_CACHE_TTL_SEC = 60

-- Absolute path: this process does not inherit the login shell's PATH.
local FIND_BIN = "/usr/bin/find"

--- Scans the system for installed applications, asynchronously.
---
--- The enumeration is a `find` across two application trees. It used to run
--- through the SYNCHRONOUS shell primitive on the main runloop, reached via a
--- short timer as if that moved it off the thread. It does not: a timer callback
--- runs on the same single runloop, so the picker froze the driver — and the
--- keyboard tap with it — for the whole scan. It goes through the async spawner
--- now, which also pins the task against the GC.
---
--- @param on_ready function Called as on_ready(choices) with the list. Invoked
---        synchronously when the cache is warm, and from the subprocess callback
---        otherwise, so callers must not depend on the return value.
function M.discover_apps(on_ready)
	if type(on_ready) ~= "function" then
		Logger.error(LOG, "discover_apps() requires a callback — nothing discovered.")
		return
	end
	-- Served from cache when it is still warm. The scan is a blocking `find`
	-- across two application trees plus one Info.plist read and one icon
	-- rasterisation PER INSTALLED APP, all on the main run loop — hs.timer.doAfter
	-- moves it off the click's stack frame but not off that thread. The set of
	-- installed applications does not change between two menu opens a few seconds
	-- apart, so re-paying it on every open buys nothing.
	local now = os.time()
	if _apps_cache and (now - _apps_cache_at) < APPS_CACHE_TTL_SEC then
		Logger.debug(LOG, "Serving %d application(s) from cache.", #_apps_cache)
		on_ready(_apps_cache)
		return
	end

	Logger.debug(LOG, "Discovering installed applications…")
	-- argv, not a shell string: the two roots are separate arguments, so a space or
	-- a quote in HOME can no longer be re-interpreted. The `| sort` is dropped
	-- because the choices are sorted in Lua further down anyway.
	local home = os.getenv("HOME") or ""
	local args = {
		"/Applications", home .. "/Applications",
		"-maxdepth", "2", "-name", "*.app", "-not", "-name", ".*",
	}
	local handle = ShellRunner.spawn(FIND_BIN, args, function(exit_code, stdout)
		if type(stdout) ~= "string" or stdout == "" then
			Logger.warn(LOG, "Application discovery returned nothing (exit %s).",
				tostring(exit_code))
			-- A failure is NOT cached: the next open should retry rather than serve
			-- an empty picker for the whole TTL.
			on_ready({})
			return
		end
		on_ready(build_choices(stdout))
	end)
	if not handle.start() then
		Logger.error(LOG, "Could not start the application discovery subprocess.")
		on_ready({})
	end
end


--- Turns the newline-separated `find` output into hs.chooser choices.
--- @param raw string Subprocess stdout.
--- @return table
build_choices = function(raw)
	
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
	Logger.info(LOG, "Application discovery completed (%d app(s)).", #choices)
	_apps_cache    = choices
	_apps_cache_at = os.time()
	return choices
end





-- ================================
-- ================================
-- ======= 2/ Menu Building =======
-- ================================
-- ================================

--- Escapes a string so it is safe to use as the REPLACEMENT argument of gsub.
--- Lua treats "%" specially on that side: "%1".."%9" are capture references,
--- "%%" is a literal percent, and "%" followed by anything else RAISES
--- "invalid use of %". Application names are third-party-controlled (an app may
--- legitimately be called "100% Orange Juice"), so every interpolation of one
--- into a template must go through here or the whole menu build throws.
--- @param s any The replacement text (coerced with tostring).
--- @return string The text with every "%" doubled.
-- Single source of truth: lib.text_utils (shared with the other Lua drivers).
local escape_replacement = text_utils.escape_gsub_replacement

--- Builds a standardized exclusion list submenu.
--- @param current_apps table The current list of disabled apps.
--- @param on_change function Callback triggered when the list changes.
--- @param placeholder_text string Text to display in the chooser.
--- @return table The menu structure.
function M.build_menu(current_apps, on_change, placeholder_text)
	Logger.debug(LOG, "Building application exclusion menu…")
	local _build_t0 = hs.timer.absoluteTime()
	local apps = type(current_apps) == "table" and current_apps or {}
	-- Sort a shallow copy by display name so the list is always alphabetical
	local sorted_apps = {}
	for _, a in ipairs(apps) do table.insert(sorted_apps, a) end
	table.sort(sorted_apps, function(a, b)
		return (a.name or ""):lower() < (b.name or ""):lower()
	end)
	local menu = {}

	for _, app in ipairs(sorted_apps) do
		if type(app) == "table" then
			local icon = nil
			if app.bundleID then
				local ok, img = pcall(hs.image.imageFromAppBundle, app.bundleID)
				if ok and img then
					pcall(function() img:setSize({w=16, h=16}) end)
					icon = img
				end
			end

			-- Capture identity by path so removal is order-independent after sort
			local app_path   = app.appPath
			local app_bundle = app.bundleID
			local styled = hs.styledtext.new(
				(app.name or "?") .. "\t✗",
				{ paragraphStyle = { tabStops = {{location = 260, alignment = "right"}} } }
			)

			table.insert(menu, {
				title = styled,
				image = icon,
				fn    = function()
					local new_apps = {}
					for _, a in ipairs(apps) do
						local same = (app_path   and a.appPath   == app_path)
						          or (app_bundle and a.bundleID  == app_bundle)
						if not same then table.insert(new_apps, a) end
					end
					on_change(new_apps)
				end,
			})
		end
	end

	if #menu > 0 then table.insert(menu, {title = "-"}) end

	table.insert(menu, {
		title = i18n.get("app_picker.add_another_app"),
		fn    = function()
			-- The chooser is built inside the discovery callback. The 0.1 s timer this
			-- used to rely on moved the scan off the click's stack frame but not off
			-- the runloop, so the whole driver froze for the duration of the `find`.
			M.discover_apps(function(choices)
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

				chooser:placeholderText(placeholder_text or i18n.get("app_picker.search_placeholder"))
				chooser:choices(choices)
				chooser:bgDark(false)
				chooser:show()
			end)
		end,
	})

	-- Static entry to exclude the current frontmost application (always up-to-date if build_menu is called before each display)
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
				title = i18n.get("app_picker.exclude_current"):gsub("{app}", escape_replacement(appName)),
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

	-- Timing surfaced so the boot log shows the cost of each exclusion-menu build
	-- (built once per picker per menu tree rebuild — keylogger + LLM = two per tree).
	Logger.info(LOG, "Application exclusion menu built successfully (%d excluded app(s), %.1f ms).",
		#sorted_apps, (hs.timer.absoluteTime() - _build_t0) / 1e6)
	if #menu == 0 then
		table.insert(menu, { title = i18n.get("app_picker.no_app_excluded"), disabled = true })
	end
	return type(menu) == "table" and menu or {}
end

return M
