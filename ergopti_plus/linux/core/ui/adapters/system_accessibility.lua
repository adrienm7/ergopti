--- core/ui/adapters/system_accessibility.lua

--- ==============================================================================
--- MODULE: System Accessibility Settings (Linux)
--- DESCRIPTION:
--- Reads the desktop's accessibility settings the GNOME schemas expose, which
--- most GTK desktops honour: whether a screen reader is enabled, high contrast,
--- animations and the text scale.
---
--- FEATURES & RATIONALE:
--- 1. Never on the keystroke path: a preview is drawn on a keystroke, and a
---    gsettings child costs milliseconds. The values are answered from a cache
---    refreshed in the background (libuv children), at most every few seconds;
---    the first answer is « all off » until the first refresh lands.
--- 2. No libuv, no gsettings, or a desktop without the schemas: every setting
---    reads as off, reported once. The previews still draw.
--- 3. The screen-reader setting gates the previews' announcement (decided
---    2026-11-17, no setting of its own): with it on, the preview window is an
---    AT-SPI notification Orca speaks when it appears; off, it stays a tooltip.
---    The other drawn windows (the WPM widget, the spotlight overlay) are
---    named for AT-SPI through name_window under the same setting.
--- 4. The text scale (« Large text », org.gnome.desktop.interface
---    text-scaling-factor) is what GTK applies to its own widgets, the dialogs
---    included; a cairo-drawn preview sets its font sizes itself, so it reads
---    the factor here and multiplies them, as Windows does with « Make text
---    bigger ».
--- ==============================================================================

local M = {}

local Logger      = require("core.logger.engine.shim")
local ShellRunner = require("core.process.adapters.shell_runner")
local Timings     = require("core.timing.engine.timings")

local LOG = "core.ui.adapters.system_accessibility"

-- How long an answer stays fresh, and how long a gsettings read may take
-- before it is abandoned (the previous answer stays).
local REFRESH_SECONDS = Timings.sec("tooltip", "accessibility_settings_refresh_ms")
local READ_TIMEOUT_MS = Timings.ms("tooltip", "accessibility_settings_read_timeout_ms")

--- The settings read, each { schema, key, field, on = the value meaning true },
--- or { schema, key, field, scale = true } for the text scale.
M.KEYS = {
	{ schema = "org.gnome.desktop.a11y.applications", key = "screen-reader-enabled", field = "screen_reader", on = "true" },
	{ schema = "org.gnome.desktop.a11y.interface", key = "high-contrast", field = "high_contrast", on = "true" },
	{ schema = "org.gnome.desktop.interface", key = "enable-animations", field = "reduce_motion", on = "false" },
	{ schema = "org.gnome.desktop.interface", key = "text-scaling-factor", field = "text_scale", scale = true },
}

-- The range the text-scaling-factor schema accepts (an OS fact).
local TEXT_SCALE_MIN, TEXT_SCALE_MAX = 0.5, 3.0

local _settings = { screen_reader = false, high_contrast = false, reduce_motion = false, text_scale = 1 }
local _refreshed_at = nil
local _pending = 0
local _refusal_reported = false
local _started = false
local _available = true




-- ==================================
-- ==================================
-- ======= 1/ Reading ===============
-- ==================================
-- ==================================

--- Reads one gsettings answer: "true", "false" or nil when it says neither.
--- @param stdout string|nil
--- @return string|nil
function M.parse_boolean(stdout)
	if type(stdout) ~= "string" then return nil end
	local value = stdout:match("^%s*(%a+)%s*$")
	if value == "true" or value == "false" then return value end
	return nil
end

--- Reads a gsettings text-scaling-factor answer: a number GNOME accepts, or
--- nil when it says anything else.
--- @param stdout string|nil
--- @return number|nil
function M.parse_scale(stdout)
	if type(stdout) ~= "string" then return nil end
	local value = tonumber(stdout:match("^%s*([%d%.]+)%s*$"))
	if not value or value < TEXT_SCALE_MIN or value > TEXT_SCALE_MAX then return nil end
	return value
end

--- Reports a refused read once.
--- @param why string
local function report_refusal(why)
	if _refusal_reported then return end
	_refusal_reported = true
	Logger.info(LOG, "A desktop accessibility setting is unread (%s) — it reads as off.", tostring(why))
end

--- Starts a background refresh of every setting.
local function refresh()
	if _pending > 0 then return end
	for _, entry in ipairs(M.KEYS) do
		local handle, refusal = ShellRunner.run_async("gsettings", { "get", entry.schema, entry.key },
			{ timeout_ms = READ_TIMEOUT_MS }, function(result)
				_pending = _pending - 1
				local parse = entry.scale and M.parse_scale or M.parse_boolean
				local value = result and result.ok and parse(result.stdout) or nil
				if value == nil then
					report_refusal("gsettings get " .. entry.schema .. " " .. entry.key)
					return
				end
				if not entry.scale then value = value == entry.on end
				if _settings[entry.field] ~= value then
					_settings[entry.field] = value
					Logger.debug(LOG, "Desktop setting %s is now %s.", entry.field, tostring(value))
				end
			end)
		if handle then
			_pending = _pending + 1
		else
			report_refusal(refusal or "gsettings could not start")
		end
	end
end

--- Starts reading the desktop's settings. Before it, and in a process that
--- never calls it (a test), every setting reads as off and no child is
--- started. The drawn surfaces go through ensure_started.
--- @param now number|nil Test seam, see settings.
--- @return boolean started False when already started.
function M.start(now)
	if _started then
		Logger.warn(LOG, "Desktop accessibility settings already read — second start ignored.")
		return false
	end
	_started = true
	-- gsettings ships with GLib's tools, which a minimal image may lack: then
	-- every setting reads as off, said once, and no child is ever started.
	if ShellRunner.has_command("gsettings", true) ~= true then
		_available = false
		report_refusal("gsettings is not installed")
		return true
	end
	Logger.debug(LOG, "Desktop accessibility settings: reading in the background.")
	M.settings(now)
	return true
end

--- Starts the reading unless it already runs: the preview, the WPM widget and
--- the spotlight overlay each call it once they have bound GTK, and the first
--- of them starts it.
--- @param now number|nil Test seam, see settings.
--- @return boolean started True when this call started it.
function M.ensure_started(now)
	if _started then return false end
	return M.start(now)
end

--- The desktop's accessibility settings, from the cache; a stale cache starts
--- a background refresh and is answered meanwhile.
--- @param now number|nil Current time in seconds (test seam), os.time() by default.
--- @return table { screen_reader, high_contrast, reduce_motion } booleans and
---   text_scale, the text-scaling-factor (1 until read).
function M.settings(now)
	now = now or os.time()
	if not _started or not _available then return _settings end
	if _refreshed_at == nil or now - _refreshed_at >= REFRESH_SECONDS then
		_refreshed_at = now
		refresh()
	end
	return _settings
end




-- ==================================
-- ==================================
-- ======= 2/ Naming ================
-- ==================================
-- ==================================

--- Gives a drawn window an AT-SPI role and name: a cairo surface has no text
--- a screen reader can read. Orca speaks a NOTIFICATION when it is mapped and
--- reads a named window when the user reaches it.
--- @param window userdata|table The GTK window.
--- @param atk table|nil The Atk namespace; nil leaves the window unnamed.
--- @param role string|nil An Atk.Role member, such as "NOTIFICATION"; nil keeps the window's.
--- @param name string
--- @return boolean named
function M.name_window(window, atk, role, name)
	if type(atk) ~= "table" and type(atk) ~= "userdata" then return false end
	local ok, err = pcall(function()
		local accessible = window:get_accessible()
		if role then accessible:set_role(atk.Role[role]) end
		accessible:set_name(name)
	end)
	if not ok then
		Logger.debug(LOG, "A drawn window could not be named for AT-SPI: %s.", tostring(err))
		return false
	end
	return true
end

return M
