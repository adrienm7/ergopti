--- adapters/tray_menu.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TrayMenu port contract defined in
--- static/ergopti_plus/_shared/core/ports/TrayMenu.spec.js. A StatusNotifierItem
--- with a nested menu, hosted in-process for the life of the daemon.
---
--- WHAT THIS REPLACED, AND WHY NONE OF IT COULD HAVE WORKED:
--- The previous implementation assembled a tray out of one-shot `gdbus`
--- invocations. Every piece was individually plausible and the whole was
--- impossible:
---   - `gdbus call … RequestName` acquires the bus name in the GDBUS process,
---     which then exits and releases it. The name was gone before the next line.
---   - The dbusmenu XML was serialised into a temp file. Nothing read it: a
---     panel calls GetLayout over D-Bus, it does not open a file.
---   - No icon was ever set — resolve_tray_icon() returned "" because the assets
---     directory does not exist, and the result was assigned to an unused local.
---   - A monitor watched for an ItemActivated signal that nothing emitted.
---   - pump() blocked on a pipe read, from the daemon's idle callback, so the
---     keystroke path stalled until someone clicked an icon that was not there.
--- SNI is not a call you make. It is an object you HOST, and a command-line tool
--- cannot host one. The hosting now happens in platform/tray/appindicator.lua.
---
--- The yad fallback is gone with it. It was reachable only when gdbus was
--- absent, it crashed on first use (a `_yad_kill()` call thirty-four lines above
--- its own `local function` declaration, so a nil global), it drew a flat menu
--- where the tray needs nested ones, and it needs XEmbed — which no Wayland
--- panel provides. Two broken backends were not redundancy.
---
--- FEATURES & RATIONALE:
--- 1. One backend, hosted in-process. The icon exists for as long as the daemon
---    does, which is the actual requirement.
--- 2. Nested menus, because the hotstrings menu is a tree of categories and
---    sections and a flat list cannot express it.
--- 3. Non-blocking pump. It drains pending GTK events and returns.
--- 4. Callback isolation: a broken handler never takes the icon down.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Indicator = require("platform.tray.appindicator")
local Protocol = require("tray.protocol")

local LOG = "adapters.tray_menu"

-- The application id panels use to remember this icon's position between
-- sessions. Stable on purpose: a generated one makes the icon jump every start.
local INDICATOR_ID = "ergopti-plus"

-- Fallback icon name from the freedesktop theme. Used until an installed icon
-- exists — a themed name always resolves to something, where a missing file
-- resolves to a blank space the user cannot click.
local FALLBACK_ICON = "input-keyboard"




-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- The menu tree last handed to setMenu, kept so setIcon and setTooltip can be
-- called in any order without discarding it.
local _items = {}

-- Whether create() has succeeded. Distinct from Indicator.is_live() so a
-- caller's repeated setMenu() before any icon exists is a no-op rather than an
-- error.
local _started = false

-- Reported by getBackend(). One value now; kept because the daemon logs it and
-- a future second backend would need somewhere to say so.
local _backend = nil




-- =========================================
-- =========================================
-- ======= 2/ Lifecycle ====================
-- =========================================
-- =========================================

--- Resolves the icon to show: an installed file if there is one, else a themed
--- name. Never "" — an empty icon is an invisible, unclickable tray entry, which
--- is what the previous implementation produced on every machine.
--- @return string
local function resolve_icon()
	local ok_paths, Paths = pcall(require, "infra.paths")
	if ok_paths and type(Protocol.resolve_tray_icon) == "function" then
		local ok, icon = pcall(Protocol.resolve_tray_icon, Paths.driver_root and Paths.driver_root() or nil)
		if ok and type(icon) == "string" and icon ~= "" then return icon end
	end
	return FALLBACK_ICON
end

--- Creates the tray icon if it does not exist yet.
--- @return boolean True when an icon is live.
local function ensure_started()
	if _started then return true end
	if not Indicator.is_available() then
		_backend = nil
		return false
	end
	if not Indicator.create(INDICATOR_ID, resolve_icon(), "Ergopti+") then
		return false
	end
	_started = true
	_backend = "appindicator"
	return true
end

--- Sets the tray icon.
--- @param opts table|nil { title? = string, icon? = string }
function M.setIcon(opts)
	if not ensure_started() then return end
	local icon = type(opts) == "table" and opts.icon or nil
	if type(icon) == "string" and icon ~= "" then
		Indicator.set_icon(icon)
	end
end

--- Replaces the menu.
--- @param items table Array of { title, fn?, menu?, checked?, disabled?, separator? }.
function M.setMenu(items)
	_items = type(items) == "table" and items or {}
	if not ensure_started() then
		Logger.debug(LOG, "setMenu() before an icon exists — kept for when one does.")
		return
	end
	Indicator.set_menu(_items)
	Logger.debug(LOG, "Tray menu set (%d top-level row(s)).", #_items)
end

--- Sets the hover tooltip.
---
--- Not supported by libayatana's public API beyond the title, which is set at
--- creation; recorded rather than silently dropped so a caller can see why
--- nothing changed.
--- @param text string
function M.setTooltip(text)
	Logger.debug(LOG, "Tray tooltip requested (%s) — the indicator shows its title only.",
		tostring(text))
end

--- Removes the icon.
function M.destroy()
	if not _started then return end
	Indicator.destroy()
	_started = false
	_backend = nil
	_items = {}
end

--- Drains pending tray events. Never blocks.
function M.pump()
	if not _started then return end
	Indicator.pump()
end

--- The backend in use, or nil when there is none.
--- @return string|nil
function M.getBackend()
	return _backend
end

--- The menu tree currently installed. Test seam and diagnostic.
--- @return table
function M.getMenu()
	return _items
end

return M
