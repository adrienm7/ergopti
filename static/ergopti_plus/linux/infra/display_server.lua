--- infra/display_server.lua

--- ==============================================================================
--- MODULE: Display Server Detection (Linux)
--- DESCRIPTION:
--- Answers "X11 or Wayland?", once, for the handful of concerns that genuinely
--- depend on it: the focused window, the clipboard, and the keyboard layout.
---
--- WHY THERE IS ONE OF THESE, AND WHY IT IS SMALL:
--- The keystroke path deliberately does NOT consult it. Capture and injection go
--- through evdev and uinput, which sit UNDER the display server: neither X11 nor
--- any compositor can tell that our virtual keyboard is not physical, so there is
--- nothing there to branch on. That is the whole reason this driver is one
--- binary rather than the two mutually exclusive builds espanso ships.
---
--- What genuinely differs is the periphery — asking which window has focus,
--- reading and setting the clipboard, and dumping the active keymap. Those three
--- had no shared answer at all: window_info and process_lifecycle each carried
--- their own X11-only implementation, and a docstring promised a Wayland
--- fallback that its body did not contain.
---
--- FEATURES & RATIONALE:
--- 1. WAYLAND_DISPLAY wins over XDG_SESSION_TYPE. A Wayland socket in the
---    environment is a positive fact; XDG_SESSION_TYPE is a label a login
---    manager sets and routinely gets wrong (it is "tty" on more than one
---    display manager running a perfectly good Wayland session).
--- 2. DISPLAY is checked last, because XWayland sets it too. Ordering it earlier
---    would classify every Wayland session as X11, which is the single mistake
---    that would make all three consumers pick the wrong tool.
--- 3. Cached, with an explicit refresh. Probing the environment per keystroke is
---    waste; probing it once and never again breaks the requirement that a user
---    can log out of X11 and back into Wayland untouched. The unit restarts on
---    that transition, but refresh() exists so nothing depends on that being the
---    only way the answer can change.
--- 4. The compositor identity comes back too. "Wayland" is not enough to know
---    how to ask for the focused window: sway answers swaymsg, Hyprland answers
---    hyprctl, and GNOME answers neither. Consumers get the fact, not a guess.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.display_server"




-- =============================================
-- =============================================
-- ======= 1/ Answers ==========================
-- =============================================
-- =============================================

--- A Wayland compositor is running this session.
M.WAYLAND = "wayland"

--- An X server is running this session (including a session that only has
--- XWayland, which is indistinguishable from real X11 to an X client).
M.X11 = "x11"

--- Neither could be established: a TTY, a headless service, or an environment
--- the session manager did not populate. Consumers must degrade rather than
--- guess, because guessing X11 here is how a Wayland user gets silence.
M.UNKNOWN = "unknown"

-- Cached probe result; nil until the first ask.
local _kind = nil
local _desktop = nil




-- =============================================
-- =============================================
-- ======= 2/ Probing ==========================
-- =============================================
-- =============================================

--- Reads an environment variable, treating empty as absent.
--- @param name string
--- @return string|nil
local function env(name)
	local value = os.getenv(name)
	if type(value) ~= "string" or value == "" then return nil end
	return value
end

--- Performs the probe. Separated from kind() so the result can be logged exactly
--- once per transition rather than on every call.
--- @return string kind, string desktop
local function probe()
	local session = (env("XDG_SESSION_TYPE") or ""):lower()
	local desktop = env("XDG_CURRENT_DESKTOP") or env("DESKTOP_SESSION") or ""

	if env("WAYLAND_DISPLAY") then
		return M.WAYLAND, desktop
	end
	if session == "wayland" then
		return M.WAYLAND, desktop
	end
	if env("DISPLAY") or session == "x11" then
		return M.X11, desktop
	end
	return M.UNKNOWN, desktop
end

--- The display server running this session.
--- @return string One of WAYLAND, X11, UNKNOWN.
function M.kind()
	if _kind then return _kind end
	_kind, _desktop = probe()
	Logger.info(LOG, "Display server: %s (desktop=%s).", _kind,
		_desktop ~= "" and _desktop or "unknown")
	return _kind
end

--- Re-probes the environment, discarding the cached answer.
---
--- Exists for the logout-and-log-back-in-under-the-other-server case. The user
--- unit is restarted on that transition today, so this is belt and braces — but
--- the requirement is that the driver adapts without reconfiguration, and a
--- value that can only be established at process start makes that a property of
--- the service manager rather than of the driver.
--- @return string The freshly probed kind.
function M.refresh()
	local previous = _kind
	_kind, _desktop = probe()
	if previous and previous ~= _kind then
		Logger.info(LOG, "Display server changed: %s → %s.", previous, _kind)
	end
	return _kind
end

--- @return boolean True on a Wayland session.
function M.is_wayland()
	return M.kind() == M.WAYLAND
end

--- @return boolean True on an X11 session (including XWayland-only).
function M.is_x11()
	return M.kind() == M.X11
end

--- The desktop environment or compositor name, lowercased, or "" when unset.
---
--- Wayland alone does not say how to ask a question: sway answers swaymsg,
--- Hyprland answers hyprctl, GNOME answers neither and needs a portal. Consumers
--- get the fact rather than re-deriving it from an environment variable each.
--- @return string
function M.desktop()
	M.kind()
	return (_desktop or ""):lower()
end

--- True when the desktop identity contains the given token.
--- @param token string Lowercased needle, e.g. "sway", "gnome", "kde".
--- @return boolean
function M.desktop_is(token)
	if type(token) ~= "string" or token == "" then return false end
	return M.desktop():find(token, 1, true) ~= nil
end

--- Test seam: forces a probe result without touching the environment.
--- @param kind string|nil One of the constants, or nil to clear the cache.
--- @param desktop string|nil
function M._set_for_test(kind, desktop)
	_kind = kind
	_desktop = desktop
end

return M
