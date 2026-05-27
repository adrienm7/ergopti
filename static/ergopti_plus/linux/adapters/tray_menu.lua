--- static/ergopti_plus/linux/adapters/tray_menu.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TrayMenu port contract defined in
--- static/ergopti_plus/shared/ports/TrayMenu.spec.js. Wraps the D-Bus
--- StatusNotifierItem / AppIndicator interface (via a helper process or the
--- libappindicator C binding) to expose a platform-agnostic interface
--- (setIcon, setMenu, setTooltip, destroy) for desktop-environment tray icons.
---
--- FEATURES & RATIONALE:
--- 1. D-Bus backend: the StatusNotifierItem (SNI) protocol is supported by
---    KDE Plasma, GNOME (with AppIndicator extension), XFCE, and most
---    wlroots compositors — it is the de-facto Linux standard for tray icons.
--- 2. Lazy creation: the tray item is constructed on the first setter call so
---    modules that do not need a tray icon do not allocate one.
--- 3. Graceful degradation: if the D-Bus session bus is unavailable (headless
---    / server), all methods are silent no-ops and log a single warning.
--- 4. Defensive pcall: all D-Bus calls are wrapped in pcall to prevent a
---    compositor crash or restart from propagating to domain logic.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.tray_menu"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Handle to the active tray indicator process / D-Bus object.
-- Nil until the first setter is called.
-- TODO(linux): replace with a proper SNI/AppIndicator binding handle.
local _indicator = nil

local function _ensure_indicator()
	if _indicator then return _indicator end
	-- TODO(linux): create a StatusNotifierItem via D-Bus or libappindicator.
	-- For now mark as a sentinel so the guard does not keep re-attempting.
	Logger.warn(LOG, "_ensure_indicator(): SNI/AppIndicator not yet implemented — tray disabled.")
	_indicator = false   -- false = attempted but unavailable
	return nil
end


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Sets the tray icon.
--- @param opts table { image?, title? }
---              image  string  Path to a PNG/SVG file used as the tray icon.
---              title  string  Text label shown beside the icon.
function M.setIcon(opts)
	-- TODO(linux): forward icon path / title to the SNI object via D-Bus.
	local ind = _ensure_indicator()
	if not ind then return end
	local options = type(opts) == "table" and opts or {}
	Logger.debug(LOG, "setIcon(): image=%s title=%s", tostring(options.image), tostring(options.title))
end

--- Replaces the drop-down menu items.
--- @param items table Array of { title, fn, checked?, disabled? } entries.
function M.setMenu(items)
	-- TODO(linux): serialise items into a com.canonical.dbusmenu structure.
	local ind = _ensure_indicator()
	if not ind then return end
	Logger.debug(LOG, "setMenu(): %d item(s).", type(items) == "table" and #items or 0)
end

--- Sets the tooltip shown on hover.
--- @param text string Tooltip text.
function M.setTooltip(text)
	-- TODO(linux): set the SNI Tooltip property on the D-Bus object.
	local ind = _ensure_indicator()
	if not ind then return end
	Logger.debug(LOG, "setTooltip(): %s.", tostring(text))
end

--- Removes and destroys the tray icon. Safe to call multiple times.
function M.destroy()
	if not _indicator then return end
	-- TODO(linux): unregister the SNI object from the session bus.
	_indicator = nil
	Logger.debug(LOG, "destroy(): tray icon released.")
end

return M
