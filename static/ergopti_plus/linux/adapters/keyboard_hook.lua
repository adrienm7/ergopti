--- static/ergopti_plus/linux/adapters/keyboard_hook.lua

--- ==============================================================================
--- MODULE: KeyboardHook Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the KeyboardHook port contract defined in
--- static/ergopti_plus/shared/ports/KeyboardHook.spec.js. Wraps the libinput
--- event device interface (via a background read loop on /dev/input/eventN)
--- to intercept or passively observe keyboard events without coupling domain
--- modules to any X11, Wayland, or kernel API.
---
--- FEATURES & RATIONALE:
--- 1. Dual mode: "observe" (intercept=false, default) reads from the libinput
---    event stream without consuming events; "intercept" (intercept=true)
---    grabs the device exclusively via ioctl EVIOCGRAB, suppressing delivery
---    to the desktop environment — required for tap-hold detection.
--- 2. uinput re-injection: in intercept mode, consumed events are re-injected
---    via a uinput virtual device so the grab is transparent to the user.
--- 3. Context tracking: refreshContext() calls getFocused() on the WindowInfo
---    adapter to update the cached {appId, windowTitle} context.
--- 4. Idempotent lifecycle: start() while already running is a silent no-op;
---    stop() while already stopped is safe.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.keyboard_hook"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- luv coroutine / file handle for the /dev/input reader (nil when stopped).
-- TODO(linux): replace with a luv-based async fd reader once the libinput
-- binding is in place.
local _reader    = nil
local _on_char   = nil   -- User callback for printable characters
local _on_key    = nil   -- User callback for non-printable keys
local _context   = { appId = "", windowTitle = "" }
local _running   = false


-- =======================================
-- =======================================
-- ======= 2/ Context Helpers ============
-- =======================================
-- =======================================

--- Queries the active window via the WindowInfo adapter and caches the result.
local function _read_context()
	-- TODO(linux): require the window_info adapter lazily to avoid circular deps.
	local ok, window_info = pcall(require, "adapters.window_info")
	if not ok then return end
	local ok2, info = pcall(window_info.getFocused)
	if ok2 and type(info) == "table" then
		_context.appId       = info.appId or ""
		_context.windowTitle = info.windowTitle or ""
	end
end


-- =========================================
-- =========================================
-- ======= 3/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Starts the keyboard hook. Idempotent — safe to call while already running.
--- @param opts table|nil { intercept?, onChar?, onKey? }
function M.start(opts)
	if _running then
		Logger.debug(LOG, "start() called while already running — no-op.")
		return
	end

	local options = type(opts) == "table" and opts or {}
	if type(options.onChar) == "function" then _on_char = options.onChar end
	if type(options.onKey)  == "function" then _on_key  = options.onKey  end

	_read_context()

	-- TODO(linux): open /dev/input/eventN via lfs or luv async fd,
	-- set EVIOCGRAB when intercept=true, then dispatch EV_KEY events
	-- through _on_char / _on_key callbacks in a luv idle/poll loop.
	Logger.warn(LOG, "start(): libinput event reader not yet implemented — hook inactive.")
	_running = true
end

--- Stops the keyboard hook. Safe to call when not running.
function M.stop()
	if not _running then return end
	-- TODO(linux): close the /dev/input fd, release EVIOCGRAB, close the uinput re-injection device.
	_running = false
	_reader  = nil
	Logger.debug(LOG, "stop(): hook stopped.")
end

--- Returns true if the keyboard hook is currently active.
--- @return boolean
function M.isRunning()
	return _running
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
