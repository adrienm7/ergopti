--- infra/gui_stack.lua

--- ==============================================================================
--- MODULE: Desktop Toolkit Start Check (Linux)
--- DESCRIPTION:
--- GTK 3, libayatana-appindicator3, lgi and WebKitGTK 4.1 are system libraries
--- the package formats cannot carry: they must match the host's GLib, GL and C
--- library. The owned-runtimes registry decides them as SYS: checked at start,
--- refused in words. This module is that check and that refusal.
---
--- FEATURES & RATIONALE:
--- 1. The tray needs GTK 3 and libayatana-appindicator3. Without either there
---    is no icon and no menu, so the daemon refused nothing and ran invisibly:
---    the user saw an app that never started. With --tray it now refuses to
---    start, names the library, and exits EX_UNAVAILABLE so the unit does not
---    restart it every three seconds.
--- 2. The windows (settings, metrics, editors) need lgi and WebKitGTK 4.1.
---    Hotstrings and the tray work without them, so a missing one is told once
---    at start and the daemon continues; the windows stay closed.
--- 3. WebKitGTK 4.1 is required by version, not by namespace: lgi.WebKit2
---    resolves whatever version is installed, and 4.0 links libsoup 2, which
---    the windows were never built for.
--- 4. The words come from the shared catalogue in the user's language; the
---    component names are product names and stay as they are.
--- ==============================================================================

local M = {}

local LOG = "infra.gui_stack"

--- sysexits.h EX_UNAVAILABLE, as the AppImage C library preflight uses.
M.EXIT_UNAVAILABLE = 69

--- The WebKitGTK namespace and version every window is built for.
M.WEBKIT_NAMESPACE = "WebKit2"
M.WEBKIT_VERSION = "4.1"

--- The component names a refusal shows.
M.LGI_COMPONENT = "lgi (Lua GObject Introspection)"
M.WEBKIT_COMPONENT = "WebKitGTK " .. M.WEBKIT_VERSION

M.TITLE_KEY = "startup.linux_gui_stack_title"
M.TRAY_BODY_KEY = "startup.linux_gui_stack_tray_body"
M.WINDOWS_BODY_KEY = "startup.linux_gui_stack_windows_body"




-- =====================================
-- =====================================
-- ======= 1/ Checks ===================
-- =====================================
-- =====================================

--- The library the tray cannot load.
--- @param indicator table platform.tray.appindicator or a test double.
--- @return string|nil The component name, nil when the tray can bind or the
---   only problem is a session without a display.
function M.tray_missing(indicator)
	if indicator.is_available() then return nil end
	return indicator.missing_component()
end

--- The library the windows cannot load.
--- @param load_lgi function|nil Returns ok, lgi like pcall(require, "lgi"); a test seam.
--- @return string|nil The component name, nil when WebKitGTK 4.1 loads.
function M.windows_missing(load_lgi)
	local ok, lgi = (load_lgi or function() return pcall(require, "lgi") end)()
	if not ok or type(lgi) ~= "table" or type(lgi.require) ~= "function" then return M.LGI_COMPONENT end
	local loaded, namespace = pcall(lgi.require, M.WEBKIT_NAMESPACE, M.WEBKIT_VERSION)
	if not loaded or namespace == nil then return M.WEBKIT_COMPONENT end
	return nil
end




-- =====================================
-- =====================================
-- ======= 2/ Refusal ==================
-- =====================================
-- =====================================

--- A translated text with {1} filled, or the key when the catalogue cannot answer.
--- @param i18n table|nil
--- @param key string
--- @param component string|nil
--- @return string
local function text(i18n, key, component)
	local value = key
	if i18n then
		local ok, translated = pcall(i18n.get, key)
		if ok and type(translated) == "string" then value = translated end
	end
	if component then value = value:gsub("{1}", function() return component end) end
	return value
end

--- Tells the user, in their language, what is missing and what follows.
--- @param deps table { i18n, notifier, print, logger }; each optional but logger.
--- @param body_key string M.TRAY_BODY_KEY or M.WINDOWS_BODY_KEY.
--- @param component string The missing component.
--- @param level string "error" or "warning", for the notification.
local function tell(deps, body_key, component, level)
	local title = text(deps.i18n, M.TITLE_KEY)
	local body = text(deps.i18n, body_key, component)
	local out = deps.print or print
	out(title)
	out(body)
	if deps.notifier and type(deps.notifier.send) == "function" then
		pcall(deps.notifier.send, body, { title = title, level = level })
	end
end

--- Runs the start check of a --tray launch.
--- @param deps table { i18n, notifier, print, load_lgi, logger, indicator }; indicator
---   is platform.tray.appindicator unless a test supplies a double.
--- @return integer|nil The exit status when the daemon must not start, nil to continue.
function M.check_at_start(deps)
	local Logger = deps.logger or require("core.logger.engine.shim")
	local tray = M.tray_missing(deps.indicator or require("platform.tray.appindicator"))
	if tray then
		Logger.error(LOG, "Start refused: the tray needs %s, which this system does not provide.", tray)
		tell(deps, M.TRAY_BODY_KEY, tray, "error")
		return M.EXIT_UNAVAILABLE
	end
	local windows = M.windows_missing(deps.load_lgi)
	if windows then
		Logger.warn(LOG, "Windows unavailable: they need %s, which this system does not provide.", windows)
		tell(deps, M.WINDOWS_BODY_KEY, windows, "warning")
		return nil
	end
	Logger.debug(LOG, "Desktop toolkit present: GTK 3, libayatana-appindicator3, lgi and %s.", M.WEBKIT_COMPONENT)
	return nil
end

return M
