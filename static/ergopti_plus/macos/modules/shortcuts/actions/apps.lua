--- modules/shortcuts/actions/apps.lua

--- ==============================================================================
--- MODULE: Shortcuts — App Navigation Actions
--- DESCRIPTION:
--- Implements shortcuts that launch or focus applications and perform file-system
--- or web navigation: Finder / Downloads, ChatGPT, System Settings, and the
--- "copy path or search the web" smart action.
---
--- FEATURES & RATIONALE:
--- 1. File-Manager Agnosticism: Tries popular third-party managers (QSpace,
---    ForkLift, etc.) before falling back to stock Finder, so the shortcuts work
---    regardless of the user's setup.
--- 2. Smart Copy/Search: Detects whether the frontmost app is a file manager to
---    decide between copying the current path vs. opening the selection in a
---    browser or running a Google search.
--- ==============================================================================

local M = {}

local hs            = hs
local timer         = hs.timer
local eventtap      = hs.eventtap
local pasteboard    = hs.pasteboard
local urlevent      = hs.urlevent
local http          = hs.http
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")
local text_utils = require("lib.text_utils")
local i18n          = require("lib.i18n")
local AppLauncher   = require("adapters.app_launcher")
local WindowInfo    = require("adapters.window_info")
local WindowManager = require("adapters.window_manager")

local LOG = "shortcuts.actions.apps"

-- Explicit inter-key delay for simulated keystrokes. hs.eventtap.keyStroke()
-- defaults this argument to 200 000 us and implements it as a BLOCKING usleep on
-- the main run loop, so an omitted delay stalls the loop that services the typing
-- event tap — long enough for macOS to disable it (kCGEventTapDisabledByTimeout).
local KEYSTROKE_NO_DELAY_US = 0





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Priority-ordered list of file managers to try before falling back to stock Finder
local FILE_MANAGERS = {
	"qspace", "path finder", "forklift", "commander one",
	"totalfinder", "xtrafinder", "finder",
}

-- Google search base URL used when the selection is not a URL
local GOOGLE_SEARCH_URL = "https://www.google.com/search?q="

-- Wait after Cmd+Opt+C for Finder to populate the clipboard with the path
local FINDER_PATH_SETTLE_SEC = 0.15

-- Wait after Cmd+C for a text selection to reach the clipboard
local COPY_SETTLE_SEC        = 0.2

-- Delay before centering newly opened windows (give them time to appear)
local CENTER_DELAY_SEC       = 0.3

-- Additional delay for navigating to a sub-folder after the app focuses
local FOLDER_OPEN_DELAY_SEC  = 0.12





-- ==================================
-- ===================================
-- ======= 2/ Internal Helpers =======
-- ===================================
-- ==================================

--- Trims leading and trailing whitespace from a string.
--- @param s string The input string.
--- @return string The trimmed string.
local function trim(s)
	if type(s) ~= "string" then return "" end
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Heuristically checks whether a string looks like a URL and normalises it.
--- @param s string The candidate string.
--- @return string|nil Normalised URL, or nil if not a URL.
local function is_probable_url(s)
	local x = trim(s)
	if x:match("^https?://") then return x end
	if x:match("^www%.") or (x:match("%.%a%a") and not x:match("%s")) then
		return "http://" .. x
	end
	return nil
end

--- Returns true when the given app name matches a known file manager.
--- @param appname string Application name to test.
--- @return boolean True if it is a file manager.
local function is_finder_like(appname)
	if type(appname) ~= "string" then return false end
	local ln = appname:lower()
	for _, v in ipairs(FILE_MANAGERS) do
		if ln:find(v, 1, true) then return true end
	end
	return false
end

--- Tries to focus or launch the first matching application from a priority list.
--- @param apps table Ordered list of application names.
--- @return boolean True if one was successfully activated.
local function launch_first_available(apps)
	if type(apps) ~= "table" then return false end

	local ok_run, running = pcall(hs.application.runningApplications)
	running = ok_run and running or {}

	for _, name in ipairs(apps) do
		local lname = name:lower()

		-- Prefer an already-running instance to avoid a slow cold launch
		for _, a in ipairs(running) do
			local ok_n, an = pcall(function() return a:name() end)
			if ok_n and an and an:lower():find(lname, 1, true) then
				pcall(function() a:activate() end)
				return true
			end
		end

		if WindowManager.activate(name) or AppLauncher.launch(name) then return true end
	end

	return false
end

--- Centers all visible standard windows of an application on their respective screens.
--- @param app userdata The hs.application object.
local function center_windows_of_app(app)
	if not app or type(app.allWindows) ~= "function" then return end
	local ok, wins = pcall(function() return app:allWindows() end)
	if not ok or not wins then return end

	for _, w in ipairs(wins) do
		if w:isStandard() and w:isVisible() then
			local screen = w:screen()
			if screen then
				local sf = screen:frame()
				local wf = w:frame()
				pcall(function()
					w:setFrame({
						x = sf.x + math.floor((sf.w - wf.w) / 2),
						y = sf.y + math.floor((sf.h - wf.h) / 2),
						w = wf.w,
						h = wf.h,
					})
				end)
			end
		end
	end
end

--- Centers the frontmost application's windows after a short delay.
--- @param delay number Seconds to wait before centering.
local function center_frontmost_after(delay)
	timer.doAfter(tonumber(delay) or 0.2, function()
		local ok, f = pcall(hs.application.frontmostApplication)
		if ok and f then center_windows_of_app(f) end
	end)
end

--- Opens a URL directly, or falls back to a Google search for plain text.
--- @param text string The selected text or path to act on.
local function open_or_search(text)
	local trimmed = trim(text)
	local url     = is_probable_url(trimmed)
	if url then
		pcall(urlevent.openURL, url)
	else
		local q = http.encodeForQuery(trimmed)
		pcall(urlevent.openURL, GOOGLE_SEARCH_URL .. q)
	end
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Focuses an existing Finder window already showing the given folder path.
--- Compares each Finder window's target via AppleScript (handles localised
--- titles like "Téléchargements" vs "Downloads" reliably).
--- @param folder_path string POSIX path of the folder to look for.
--- @return boolean True if an existing window was found and focused.
local function focus_existing_finder_window(folder_path)
	local script = string.format([[
		tell application "Finder"
			set targetPath to POSIX file %q as alias
			repeat with w in windows
				try
					if (target of w as alias) is targetPath then
						set index of w to 1
						activate
						return "ok"
					end if
				end try
			end repeat
		end tell
		return "none"
	]], folder_path)

	local ok, result = hs.osascript.applescript(script)
	return ok and result == "ok"
end

--- Opens the Downloads folder via the best available file manager.
--- Reuses an existing window if one is already showing Downloads.
function M.open_downloads()
	local home = os.getenv("HOME") or "~"
	local downloads = home .. "/Downloads"

	-- First, try to focus an existing Finder window already on Downloads
	if focus_existing_finder_window(downloads) then
		Logger.info(LOG, "Focused existing Finder window for Downloads.")
		center_frontmost_after(CENTER_DELAY_SEC)
		return
	end

	if not launch_first_available(FILE_MANAGERS) then
		pcall(hs.execute, "open " .. text_utils.shell_quote(downloads))
	else
		timer.doAfter(FOLDER_OPEN_DELAY_SEC, function()
			pcall(hs.execute, "open " .. text_utils.shell_quote(downloads))
		end)
	end
	center_frontmost_after(CENTER_DELAY_SEC)
end

--- Opens the home directory via the best available file manager.
function M.open_finder()
	local home = os.getenv("HOME") or "~"
	if not launch_first_available(FILE_MANAGERS) then
		pcall(hs.execute, "open " .. text_utils.shell_quote(home))
	else
		timer.doAfter(FOLDER_OPEN_DELAY_SEC, function()
			pcall(hs.execute, "open " .. text_utils.shell_quote(home))
		end)
	end
	center_frontmost_after(CENTER_DELAY_SEC)
end

--- Opens the given ChatGPT URL in the default browser. The caller resolves the
--- URL (live-configured value or the manifest default) — this function is a
--- thin, side-effect-only opener so there is a single source of truth for URL
--- resolution (modules.shortcuts.bindings) instead of a second config reader here.
--- @param url string The ChatGPT URL to open.
function M.open_chatgpt(url)
	Logger.debug(LOG, "Opening ChatGPT URL: %s.", url)
	pcall(urlevent.openURL, url)
end

--- Opens macOS System Settings (falls back to System Preferences on older macOS).
function M.open_settings()
	if not AppLauncher.launch("System Settings") then
		AppLauncher.launch("System Preferences")
	end
	center_frontmost_after(CENTER_DELAY_SEC)
end

--- In a file manager: copies the current path (Cmd+Opt+C).
--- Elsewhere: copies the text selection and opens it as a URL or Google search.
function M.copy_or_open_path()
	local name = WindowInfo.getFocused().appId
	if name == "" then
		local ok, front = pcall(hs.application.frontmostApplication)
		name = (ok and front) and front:name() or ""
	end

	if is_finder_like(name) then
		-- Snapshot and CLEAR before asking Finder for the path. A non-empty clipboard
		-- afterwards only proves Finder wrote something if it was empty beforehand —
		-- without this, whatever the user had copied earlier was read back as "the
		-- path", reported in the success notification, and the selection fallback
		-- below became unreachable. The sibling branch already clears for exactly
		-- this reason; this one did not.
		local prior = nil
		pcall(function() prior = pasteboard.getContents(); pasteboard.clearContents() end)
		eventtap.keyStroke({"cmd", "alt"}, "c", KEYSTROKE_NO_DELAY_US)

		timer.doAfter(FINDER_PATH_SETTLE_SEC, function()
			local ok_p, p = pcall(pasteboard.getContents)
			if ok_p and p and p ~= "" then
				notifications.notify(string.format(i18n.get("shortcuts.copy_path_notif"), p), nil, "success")
				return
			end

			-- Finder did not populate the clipboard — copy the selection instead
			Logger.debug(LOG, "Finder did not write a path — falling back to copying the selection.")
			eventtap.keyStroke({"cmd"}, "c", KEYSTROKE_NO_DELAY_US)

			timer.doAfter(COPY_SETTLE_SEC, function()
				local sel = nil
				pcall(function() sel = pasteboard.getContents() end)
				pcall(function()
					if prior then pasteboard.setContents(prior) else pasteboard.clearContents() end
				end)
				if sel and sel ~= "" then open_or_search(sel) end
			end)
		end)
		return
	end

	-- Outside a file manager: copy selection and open or search
	local prior = nil
	pcall(function() prior = pasteboard.getContents(); pasteboard.clearContents() end)
	eventtap.keyStroke({"cmd"}, "c", KEYSTROKE_NO_DELAY_US)

	timer.doAfter(COPY_SETTLE_SEC, function()
		local sel = nil
		pcall(function() sel = pasteboard.getContents() end)
		pcall(function()
			if prior then pasteboard.setContents(prior) else pasteboard.clearContents() end
		end)
		if sel and sel ~= "" then open_or_search(sel) end
	end)
end

return M
