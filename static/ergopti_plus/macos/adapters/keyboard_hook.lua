--- adapters/keyboard_hook.lua

--- ==============================================================================
--- MODULE: KeyboardHook Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the KeyboardHook port contract defined in
--- static/ergopti_plus/_shared/core/ports/KeyboardHook.spec.js. Wraps hs.eventtap to
--- intercept (or passively observe) keyboard events and deliver them to domain
--- module callbacks (onChar, onKey) without exposing the hs.eventtap API.
---
--- FEATURES & RATIONALE:
--- 1. Dual mode: "observe" (intercept=false, default) lets events pass through
---    unchanged; "intercept" (intercept=true) allows the adapter to consume
---    events before the OS delivers them — required for tap-hold detection.
--- 2. Context tracking: refreshContext() reads the frontmost application via
---    hs.application; getContext() returns a {appId, windowTitle} table matching
---    the contract shape for both macOS (bundleID) and the Windows name field.
--- 3. Idempotent lifecycle: start() while already running is a silent no-op;
---    stop() while already stopped is safe.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local EventTapGuard = require("adapters.event_tap_guard")

local LOG = "adapters.keyboard_hook"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

local _tap       = nil   -- hs.eventtap instance (nil when stopped)
local _on_char   = nil   -- User callback for printable characters
local _on_key    = nil   -- User callback for non-printable keys
local _on_event  = nil   -- Optional raw event callback for advanced consumers
local _last_options = nil
local _context   = { appId = "", windowTitle = "" }


-- =======================================
-- =======================================
-- ======= 2/ Context Helpers ============
-- =======================================
-- =======================================

--- Queries the current foreground application and updates _context.
local function _read_context()
	local ok, app = pcall(hs.application.frontmostApplication)
	if ok and app then
		-- Capture the return value inside pcall so bundleID() is never called a
		-- second time outside protection (the app object may become invalid between
		-- the two calls — H-25 audit fix)
		local ok_bid, bid = pcall(function() return app:bundleID() end)
		_context.appId = (ok_bid and type(bid) == "string" and bid) or ""
		_context.windowTitle = ""
		local ok_w, win = pcall(function() return app:focusedWindow() end)
		if ok_w and win then
			local ok_t, title = pcall(function() return win:title() end)
			if ok_t then _context.windowTitle = title or "" end
		end
	end
end

--- Builds the event handler function based on the current callback bindings.
--- Called each time start() is invoked so callback changes take effect.
--- @return function hs.eventtap handler function.
local function _make_handler()
	return function(event)
		-- macOS reports a disabled tap THROUGH this callback; without this line
		-- the hook goes permanently deaf and nothing anywhere says so.
		if EventTapGuard.handle_disabled(event, _tap, "keyboard_hook") then return false end
		if _on_event then
			local ok, consume = pcall(_on_event, event)
			return ok and consume == true
		end
		local ok, char = pcall(function() return event:getCharacters() end)
		-- Use utf8.len() instead of # (byte count) so multi-byte characters like
		-- é, à, ñ are recognised as single printable codepoints (H3 audit fix).
		local char_codepoints = nil
		if ok and type(char) == "string" then
			local ok_len, n = pcall(utf8.len, char)
			if ok_len then char_codepoints = n end
		end
		if char_codepoints == 1 then
			-- Printable character path
			if _on_char then
				pcall(_on_char, {
					char      = char,
					timestamp = hs.timer.secondsSinceEpoch() * 1000,
					appId     = _context.appId,
				})
			end
		else
			-- Non-printable key path
			if _on_key then
				local ok_kc, kc = pcall(function() return event:getKeyCode() end)
				pcall(_on_key, {
					key       = ok_kc and tostring(kc) or "",
					timestamp = hs.timer.secondsSinceEpoch() * 1000,
					appId     = _context.appId,
				})
			end
		end
		-- Return false = pass event through (intercept mode not yet implemented)
		return false
	end
end


-- =========================================
-- =========================================
-- ======= 3/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Starts the keyboard hook. Always stops and nils any existing tap (enabled
--- or disabled) before creating a new one to prevent tap leaks (H5 audit fix).
--- @param opts table|nil { intercept?, onChar?, onKey?, onEvent?, eventTypes? }
function M.start(opts)
	-- Stop any existing tap (enabled or disabled) before creating a new one.
	-- The old guard `if _tap and _tap:isEnabled()` left a disabled-but-allocated
	-- tap dangling, leaking the event source to the OS event queue.
	if _tap then
		pcall(function() _tap:stop() end)
		_tap = nil
		Logger.debug(LOG, "start(): previous tap stopped before creating new one.")
	end
	-- Clear all callbacks before reading opts so no stale references from a
	-- previous lifecycle survive a restart where the new caller omits them (M-12 audit fix)
	_on_char = nil
	_on_key  = nil
	_on_event = nil
	local options = type(opts) == "table" and opts or _last_options or {}
	if type(opts) == "table" then _last_options = opts end
	if type(options.onChar) == "function" then _on_char = options.onChar end
	if type(options.onKey)  == "function" then _on_key  = options.onKey  end
	if type(options.onEvent) == "function" then _on_event = options.onEvent end

	_read_context()

	local event_types = type(options.eventTypes) == "table" and options.eventTypes or {
		hs.eventtap.event.types.keyDown,
	}
	local handler = _make_handler()
	local ok, tap_or_err = pcall(hs.eventtap.new, event_types, handler)
	if not ok then
		Logger.error(LOG, "start(): hs.eventtap.new failed — %s", tostring(tap_or_err))
		return
	end
	_tap = tap_or_err
	local ok_start, err = pcall(function() _tap:start() end)
	if not ok_start then
		Logger.error(LOG, "start(): eventtap:start() failed — %s", tostring(err))
		_tap = nil
	end
end

--- Stops the keyboard hook. Safe to call when not running.
function M.stop()
	if not _tap then return end
	pcall(function() _tap:stop() end)
	_tap = nil
end

--- Returns true if the keyboard hook is currently active.
--- @return boolean
function M.isRunning()
	return _tap ~= nil and _tap:isEnabled()
end

--- Re-reads the foreground application identity and caches it.
function M.refreshContext()
	_read_context()
end

--- Returns the last-known foreground application identity.
--- @return table { appId: string, windowTitle: string }
function M.getContext()
	return { appId = _context.appId, windowTitle = _context.windowTitle }
end

return M
