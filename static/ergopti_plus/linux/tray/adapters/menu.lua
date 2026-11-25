--- tray/adapters/menu.lua

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
--- cannot host one. The hosting now happens in tray/adapters/appindicator.lua.
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

local Logger = require("core.logger.engine.shim")
local I18n = require("core.i18n.engine.i18n")
local Indicator = require("tray.adapters.appindicator")
local Protocol = require("tray.protocol")
local Perf = require("core.logger.engine.perf_counters")

local LOG = "tray.adapters.menu"

-- The application id panels use to remember this icon's position between
-- sessions. Stable on purpose: a generated one makes the icon jump every start.
local INDICATOR_ID = "ergopti-plus"

-- The freedesktop themed icon drawn when a state's logo file is missing. A
-- themed name always resolves to something, where a missing file resolves to
-- a blank space the user cannot click; the warning sign, unlike the keyboard
-- glyph drawn before, says that something is wrong, and the description says
-- what (TRAY-05).
local MISSING_ICON = "dialog-warning"




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

-- Whether the paused logo is the one on screen, so a menu rebuild that does not
-- change the state does not re-send the icon over D-Bus.
local _paused = false

-- The accessible description last sent with the icon, so a menu rebuild after
-- a locale change relabels it without re-sending an unchanged one.
local _description = nil

-- Whether the logo file of the state last resolved is missing, so the
-- description says so, and the missing files already logged, each once.
local _icon_missing = false
local _missing_reported = {}




-- =========================================
-- =========================================
-- ======= 2/ Lifecycle ====================
-- =========================================
-- =========================================

--- Resolves the icon to show: the bundled logo of the state, else the themed
--- warning sign, logged once per missing file. Never "" — an empty icon is an
--- invisible, unclickable tray entry, which is what the previous implementation
--- produced on every machine — and never the other state's logo.
--- @param paused boolean|nil True for the greyed logo.
--- @return string
local function resolve_icon(paused)
	local Paths = require("core.fs.engine.paths")
	local icon, missing = Protocol.resolve_tray_icon(Paths.shared_root(), paused)
	_icon_missing = icon == ""
	if not _icon_missing then return icon end
	missing = missing or "(no shared tree)"
	if not _missing_reported[missing] then
		_missing_reported[missing] = true
		Logger.error(LOG, "Tray icon file %s is missing; the themed '%s' sign is drawn instead. Reinstall Ergopti+.",
			missing, MISSING_ICON)
	end
	return MISSING_ICON
end

--- The icon's accessible description: the only place the paused state is
--- said in words, since a screen reader cannot see the greyed logo, and the
--- place that says the logo file is missing. "" while the locale catalogue is
--- not loaded yet (get() would answer the key itself); the next menu build
--- fills it.
--- @param paused boolean
--- @return string
local function describe(paused)
	local key
	if _icon_missing then
		key = paused and "accessibility.tray_tip_paused_icon_missing" or "accessibility.tray_tip_icon_missing"
	else
		key = paused and "accessibility.tray_tip_paused" or "accessibility.tray_tip"
	end
	if I18n.has(key) ~= true then return "" end
	return I18n.get(key)
end

--- Sends the icon with its description.
--- @param icon string|nil An explicit icon, else the state's logo.
local function send_icon(icon)
	local shown = icon or resolve_icon(_paused)
	_description = describe(_paused)
	Indicator.set_icon(shown, _description)
end

--- Creates the tray icon if it does not exist yet.
--- @return boolean True when an icon is live.
local function ensure_started()
	if _started then return true end
	if not Indicator.is_available() then
		_backend = nil
		return false
	end
	local icon = resolve_icon(_paused)
	local description = describe(_paused)
	if not Indicator.create(INDICATOR_ID, icon, "Ergopti+", description) then
		return false
	end
	_description = description
	_started = true
	_backend = "appindicator"
	return true
end

--- Creates the tray icon with the logo of the current state. Linux-only and
--- outside the port contract: the daemon brings its icon up here once the
--- start check has passed, before the first menu exists.
--- @return boolean live Whether an icon is live.
function M.start()
	return ensure_started()
end

--- Draws an image file as the tray icon (port setIcon, TrayMenu.spec.js 2.0.0).
--- A missing file is refused with one logged error and the previous icon stays:
--- the adapter never draws another image in its place (TRAY-05).
--- @param opts table { image = string } Absolute path to an existing image file.
--- @return boolean drawn
function M.setIcon(opts)
	if type(opts) ~= "table" or type(opts.image) ~= "string" or opts.image == "" then
		Logger.error(LOG, "setIcon() refused: it takes an option map whose image names a file, not %s.",
			tostring(opts))
		return false
	end
	local handle = io.open(opts.image, "r")
	if handle == nil then
		Logger.error(LOG, "setIcon() refused: the tray icon file '%s' is missing.", opts.image)
		return false
	end
	handle:close()
	if not ensure_started() then return false end
	_description = describe(_paused)
	return Indicator.set_icon(opts.image, _description) == true
end

--- The native menu replacement behind setMenu, which counts and times it.
--- @param items table Array of rows.
--- @return boolean accepted
local function replace_menu(items)
	_items = type(items) == "table" and items or {}
	if not ensure_started() then
		Logger.debug(LOG, "setMenu() before an icon exists — kept for when one does.")
		return false
	end
	-- A reported problem (core/ui/engine/component_status.lua) leads the menu
	-- as a red row until the daemon exits: a notification alone vanished on
	-- KDE Plasma 6 without reaching its history.
	local rows = require("core.ui.engine.component_status").tray_rows(function(title, body)
		if not M.showStatusWindow(title, body) then
			Logger.error(LOG, "Status window for '%s' could not open; the explanation is in the log.", title)
		end
	end)
	for _, item in ipairs(_items) do rows[#rows + 1] = item end
	if Indicator.set_menu(rows) ~= true then return false end
	if describe(_paused) ~= _description then send_icon(nil) end
	Logger.debug(LOG, "Tray menu set (%d top-level row(s)).", #rows)
	return true
end

--- Replaces the menu.
--- @param items table Array of { title, fn?, menu?, checked?, disabled?, separator? }.
--- @return boolean accepted Native menu accepted; GTK events may remain queued.
function M.setMenu(items)
	local started = Perf.clock()
	Perf.count("tray.builds")
	local accepted = replace_menu(items)
	Perf.span("tray.build", started)
	return accepted
end

--- Installs a fallback menu: a name, optional action groups and a way out.
---
--- The only rows this driver draws outside the shared renderer, and on
--- purpose: they serve when the menu subsystem failed to load, and when the
--- daemon cannot reach the keyboard and holds its icon to say so, so they must
--- not depend on what they survive without. One builder serves both.
--- @param title string The first, inert row.
--- @param quit_label string The translated Quit row.
--- @param on_quit function Runs when Quit is clicked.
--- @param groups table|nil Ordered lists of { label, fn } actions; a separator
---   parts each group after the first from the previous one, and from Quit.
function M.setFallbackMenu(title, quit_label, on_quit, groups)
	local rows = { { title = title, disabled = true } }
	for index, group in ipairs(groups or {}) do
		if index > 1 then rows[#rows + 1] = { separator = true } end
		for _, action in ipairs(group) do
			rows[#rows + 1] = { title = action.label, fn = action.fn }
		end
	end
	if groups and #groups > 0 then rows[#rows + 1] = { separator = true } end
	rows[#rows + 1] = { title = quit_label, fn = on_quit }
	M.setMenu(rows)
end

--- Shows (or brings back) the status window beside the icon.
---
--- Linux-only and outside the port contract: it serves the degraded state the
--- daemon holds when it cannot reach the keyboard, the one case where the tray
--- alone does not say enough.
--- @param title string Window title.
--- @param text string The explanation.
--- @return boolean shown
function M.showStatusWindow(title, text)
	if not ensure_started() then return false end
	return Indicator.show_window(title, text) == true
end

--- Shows the greyed logo while the daemon is paused, as the macOS menu bar and
--- the Windows tray do; the normal one otherwise.
--- @param paused boolean
function M.setPaused(paused)
	paused = paused == true
	if paused == _paused then return end
	_paused = paused
	if not _started then return end
	send_icon(nil)
	Logger.debug(LOG, "Tray icon shows the %s logo.", paused and "paused" or "active")
end

--- The icon the tray shows (or would show) right now. Diagnostic and test seam.
--- @return string
function M.getIcon()
	return resolve_icon(_paused)
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
	_paused = false
	_description = nil
end

--- Drains pending tray events. Never blocks.
function M.pump()
	if not _started then return end
	Indicator.pump()
end

--- The tray's half of the daemon's idle wait while an icon is live, or nil: a
--- panel's request then wakes the wait at once instead of waiting out its
--- timeout (each dbusmenu call cost up to 8 ms before, 26 ms per submenu).
--- @return table|nil { begin, finish } for keyboard_hook.idle_wait.
function M.wait_companion()
	if not _started then return nil end
	return Indicator.wait_companion()
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
