--- adapters/auto_click_ports.lua

--- ==============================================================================
--- MODULE: Auto-Click Ports (macOS)
--- DESCRIPTION:
--- The Hammerspoon side of the anti-sleep auto-clicker's session ports
--- (_shared/shortcuts/engine/auto_click_session.lua): the frontmost window and
--- its bundle id, the lock, pause and secure-field state, the scan through the
--- screen vision service, the click, the clock and the user's languages.
--- modules/shortcuts/actions/auto_click.lua owns the session and calls only
--- these ports.
---
--- FEATURES & RATIONALE:
--- 1. Fail closed: a state that cannot be read counts as locked, paused or
---    secure, so an unanswered question never lets a click through.
--- 2. The click is two Ergopti-tagged mouse events through
---    platform/input/synthetic_input.lua, so the keep-awake watcher never takes
---    it for the user's input; the pointer then goes back where it was.
--- ==============================================================================

local M = {}

local hs = hs
local Logger = require("core.logger.engine.shim")
local SyntheticInput = require("platform.input.synthetic_input")

local LOG = "adapters.auto_click_ports"

--- The user's preferred languages for Vision; none known lets it detect them.
--- @return table languages BCP 47 tags.
function M.languages()
	local ok, languages = pcall(function() return hs.host.locale.preferredLanguages() end)
	return ok and type(languages) == "table" and languages or {}
end

--- Posts one tagged mouse event at a point.
local function post_mouse(event_type, point)
	local prepared, detail = SyntheticInput.prepare_mouse_event(
		-- The keep-awake session's own provenance: its watcher ignores it.
		"shortcuts.keep_awake", event_type, point)
	if not prepared then
		Logger.warn(LOG, "An automatic click could not be prepared: %s.", tostring(detail))
		return false
	end
	local posted, post_detail = SyntheticInput.post_mouse_event(prepared)
	if not posted then Logger.warn(LOG, "An automatic click could not be posted: %s.", tostring(post_detail)) end
	return posted == true
end

--- The session ports.
--- @param vision function Returns the started screen vision service.
--- @return table ports
function M.ports(vision)
	local Secure = require("platform.focus.secure_field_detector")
	return {
		foreground = function()
			local ok, window = pcall(hs.window.frontmostWindow)
			if not ok or not window then return nil end
			local ok_app, app = pcall(window.application, window)
			local bundle = ok_app and app and app:bundleID() or nil
			return { window = window:id(), app_id = bundle }
		end,
		state = function()
			local ok_lock, properties = pcall(hs.caffeinate.sessionProperties)
			local locked = not ok_lock or type(properties) ~= "table" or properties.CGSSessionScreenIsLocked == true
			local ok_pause, paused = pcall(function() return require("modules.shortcuts.script_control").is_paused() end)
			local ok_secure, secure = pcall(Secure.isSecureField)
			return { locked = locked, paused = not ok_pause or paused == true, secure_field = not ok_secure or secure == true }
		end,
		scan = function(window, request, callback) vision().scan_window(window, request, callback) end,
		click = function(x, y)
			local ok_pos, origin = pcall(hs.mouse.absolutePosition)
			local point = { x = x, y = y }
			local types = hs.eventtap.event.types
			local clicked = post_mouse(types.leftMouseDown, point) and post_mouse(types.leftMouseUp, point)
			if ok_pos and origin then pcall(hs.mouse.absolutePosition, origin) end
			return clicked
		end,
		now_ms = function() return math.floor(hs.timer.absoluteTime() / 1000000) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
		languages = M.languages,
	}
end

return M
