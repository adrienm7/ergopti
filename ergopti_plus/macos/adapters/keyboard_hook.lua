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
local Logger = require("infra.logger")

local LOG = "adapters.keyboard_hook"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

local _tap       = nil   -- hs.eventtap instance (nil when stopped)
local _tap_committed = false
local _on_char   = nil   -- User callback for printable characters
local _on_key    = nil   -- User callback for non-printable keys
local _on_event  = nil   -- Optional raw event callback for advanced consumers
local _last_options = nil
local _context   = { appId = "", windowTitle = "" }
local _handler_generation = 0

--- Makes any retained native tap callback-inert without discarding its handle.
local function clear_callbacks()
	_handler_generation = _handler_generation + 1
	_on_char = nil
	_on_key = nil
	_on_event = nil
end

--- Probes one exact native tap without letting a Hammerspoon error escape.
--- @param tap userdata|table Native eventtap handle.
--- @param operation string Operation label used in diagnostics.
--- @return boolean|nil enabled Exact state, or nil when it cannot be proven.
local function probe_enabled(tap, operation)
	if not tap or type(tap.isEnabled) ~= "function" then
		Logger.error(LOG, "%s: eventtap state query is unavailable.", operation)
		return nil
	end
	local ok, enabled_or_err = pcall(tap.isEnabled, tap)
	if not ok then
		Logger.error(LOG, "%s: eventtap state query failed — %s",
			operation, tostring(enabled_or_err))
		return nil
	end
	if enabled_or_err ~= true and enabled_or_err ~= false then
		Logger.error(LOG, "%s: eventtap state query returned %s.",
			operation, tostring(enabled_or_err))
		return nil
	end
	return enabled_or_err
end

--- Stops the retained tap and releases it only after disabled state is proven.
--- @param operation string Operation label used in diagnostics.
--- @return boolean stopped True only when no native cleanup debt remains.
local function stop_retained_tap(operation)
	if not _tap then
		_tap_committed = false
		return true
	end
	local tap = _tap
	_tap_committed = false
	clear_callbacks()
	if type(tap.stop) ~= "function" then
		Logger.error(LOG, "%s: eventtap stop is unavailable; retaining the exact handle.",
			operation)
		return false
	end
	local ok, stop_err = pcall(tap.stop, tap)
	if not ok then
		Logger.error(LOG, "%s: eventtap stop failed — %s; retaining the exact handle.",
			operation, tostring(stop_err))
		return false
	end
	if probe_enabled(tap, operation) ~= false then
		Logger.error(LOG, "%s: eventtap stop did not commit; retaining the exact handle.",
			operation)
		return false
	end
	if _tap == tap then _tap = nil end
	return true
end


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
local function _make_handler(generation)
	return function(event)
		if generation ~= _handler_generation then return false end
		if _on_event then
			local ok, consume, returned_events = Logger.pcall(LOG, _on_event, event)
			if not ok then return false end
			if returned_events ~= nil and type(returned_events) ~= "table" then
				Logger.error(LOG,
					"onEvent returned invalid ordered events (%s); propagating the original only.",
					type(returned_events))
				returned_events = nil
			end
			return consume == true, returned_events
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
				Logger.pcall(LOG, _on_char, {
					char      = char,
					timestamp = hs.timer.secondsSinceEpoch() * 1000,
					appId     = _context.appId,
				})
			end
		else
			-- Non-printable key path
			if _on_key then
				local ok_kc, kc = pcall(function() return event:getKeyCode() end)
				Logger.pcall(LOG, _on_key, {
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
--- @return boolean started True only after native enabled state is proven.
function M.start(opts)
	if type(opts) == "table" then _last_options = opts end
	-- Stop any existing tap (enabled or disabled) before creating a new one.
	-- The old guard `if _tap and _tap:isEnabled()` left a disabled-but-allocated
	-- tap dangling, leaking the event source to the OS event queue.
	local had_previous_tap = _tap ~= nil
	if had_previous_tap and not stop_retained_tap("start() preflight") then
		Logger.error(LOG, "start(): previous tap cleanup remains pending; replacement refused.")
		return false
	elseif had_previous_tap then
		Logger.debug(LOG, "start(): previous tap stopped before creating new one.")
	end
	-- Clear all callbacks before reading opts so no stale references from a
	-- previous lifecycle survive a restart where the new caller omits them (M-12 audit fix)
	clear_callbacks()
	local options = type(opts) == "table" and opts or _last_options or {}
	if type(options.onChar) == "function" then _on_char = options.onChar end
	if type(options.onKey)  == "function" then _on_key  = options.onKey  end
	if type(options.onEvent) == "function" then _on_event = options.onEvent end

	_read_context()

	local event_types = type(options.eventTypes) == "table" and options.eventTypes or {
		hs.eventtap.event.types.keyDown,
	}
	_handler_generation = _handler_generation + 1
	local handler = _make_handler(_handler_generation)
	local ok, tap_or_err = pcall(hs.eventtap.new, event_types, handler)
	if not ok or not tap_or_err then
		Logger.error(LOG, "start(): hs.eventtap.new failed — %s", tostring(tap_or_err))
		clear_callbacks()
		return false
	end
	_tap = tap_or_err
	local ok_start, err = pcall(function() _tap:start() end)
	if not ok_start then
		Logger.error(LOG, "start(): eventtap:start() failed — %s", tostring(err))
		stop_retained_tap("start() rollback")
		return false
	end
	if probe_enabled(_tap, "start() commit") ~= true then
		Logger.error(LOG, "start(): eventtap start did not commit.")
		stop_retained_tap("start() rollback")
		return false
	end
	_tap_committed = true
	return true
end

--- Stops the keyboard hook. Safe to call when not running.
--- @return boolean stopped True only after native disabled state is proven.
function M.stop()
	return stop_retained_tap("stop()")
end

--- Returns true if the keyboard hook is currently active.
--- @return boolean
function M.isRunning()
	if not _tap or not _tap_committed then return false end
	local enabled = probe_enabled(_tap, "isRunning()")
	if enabled == true then return true end
	_tap_committed = false
	clear_callbacks()
	return false
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
