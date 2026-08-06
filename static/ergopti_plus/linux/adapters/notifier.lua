--- adapters/notifier.lua

--- ==============================================================================
--- MODULE: Notifier Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Notifier port contract defined in
--- _shared/core/ports/Notifier.spec.js. Sends desktop notifications through the
--- freedesktop `notify-send` command.
---
--- WHY THIS DRIVER HAD NONE:
--- The port has existed since the driver did, macOS and Windows both implement
--- it, and the strings every caller would use are already translated into all
--- twenty-one locales. What was missing was the twenty lines that reach the
--- desktop — so every message the other two drivers show their users, this one
--- kept to its log file.
---
--- FEATURES & RATIONALE:
--- 1. `notify-send` rather than a D-Bus binding. It ships with the notification
---    daemon on every desktop that has one, needs no library, and works
---    identically under X11 and Wayland. A direct
---    org.freedesktop.Notifications call would need a D-Bus binding this driver
---    does not have and could not add without a C dependency.
--- 2. The four contract levels map to the two urgencies the freedesktop spec
---    actually defines, plus one that is deliberately not "critical": a
---    critical notification does not time out on most desktops, and nothing
---    this daemon reports is worth a message the user must dismiss by hand.
--- 3. Never fatal, and never blocking. A notification that fails is logged and
---    forgotten — the contract says so, and a keystroke path must not wait on a
---    desktop service that may not be running at all.
--- 4. Absence is detected once and reported once. On a headless machine or a
---    minimal install there is no notification daemon, and a warning per
---    notification would drown the log the message was trying to complement.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")

local LOG = "adapters.notifier"

-- The title shown when a caller supplies none. From the port contract, so the
-- three drivers name the application identically in the user's notification
-- centre.
local DEFAULT_TITLE = "Ergopti+"

-- The freedesktop urgency for each contract level.
--
-- "critical" is deliberately unused. On most desktops a critical notification
-- never times out and has to be dismissed by hand, and nothing this daemon
-- reports is worth interrupting someone that way — an unreadable keymap is a
-- log line and a degraded feature, not a modal.
local URGENCY_FOR_LEVEL = {
	info    = "low",
	success = "low",
	warning = "normal",
	error   = "normal",
}

-- What a level prefixes its title with, so severity survives a desktop that
-- renders every notification identically.
local PREFIX_FOR_LEVEL = {
	info    = "",
	success = "",
	warning = "⚠ ",
	error   = "✖ ",
}

-- How long a notification stays up, in milliseconds. Long enough to read a
-- sentence, short enough not to stack up during a burst of them.
local TIMEOUT_MS = 5000

-- Whether `notify-send` is present. nil until the first send probes for it.
local _available = nil

-- Whether the absence has already been reported. A warning per notification
-- would drown the log that the notification was meant to complement.
local _absence_logged = false




-- ===========================================
-- ===========================================
-- ======= 1/ Availability ===================
-- ===========================================
-- ===========================================

--- Whether this machine can show a desktop notification at all.
---
--- Probed once. A headless daemon, a container, or a minimal install has no
--- notification daemon, and asking every time costs a subprocess on a path that
--- can be reached from a keystroke.
--- @return boolean
local function available()
	if _available ~= nil then return _available end
	_available = Shell.has_command("notify-send")
	if not _available and not _absence_logged then
		_absence_logged = true
		Logger.warn(LOG,
			"notify-send is not installed — notifications stay in the log. "
				.. "Install libnotify-bin (Debian) or libnotify-tools (Fedora/Arch).")
	end
	return _available
end




-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Displays a system notification.
---
--- @param message string Body text.
--- @param opts table|nil { title?, level?, onClick? }
---        level is one of "info", "success", "warning", "error" (default "info").
---        onClick is accepted and ignored: `notify-send` returns as soon as the
---        notification is posted and cannot report a click without holding the
---        process open, which this daemon will not do on a keystroke path.
function M.send(message, opts)
	if type(message) ~= "string" or message == "" then
		Logger.error(LOG, "send(): a message is required — nothing was shown.")
		return
	end
	local options = type(opts) == "table" and opts or {}
	local level = type(options.level) == "string" and options.level or "info"
	local urgency = URGENCY_FOR_LEVEL[level]
	if not urgency then
		-- Named but unknown. Reported rather than silently treated as info: a
		-- caller passing "critical" or "fatal" believes it is asking for
		-- something, and quietly downgrading it hides the disagreement for ever.
		Logger.warn(LOG, "send(): unknown level '%s' — shown as info.", level)
		level, urgency = "info", URGENCY_FOR_LEVEL.info
	end

	if not available() then
		-- The log is the fallback surface, so the message is not simply dropped.
		Logger.info(LOG, "[notification] %s: %s", tostring(options.title or DEFAULT_TITLE), message)
		return
	end

	local title = (PREFIX_FOR_LEVEL[level] or "")
		.. (type(options.title) == "string" and options.title ~= "" and options.title or DEFAULT_TITLE)

	-- Backgrounded, and its output discarded. notify-send returns once the
	-- daemon acknowledges, which is fast but not instant, and this can be
	-- reached from the keystroke path.
	local command = string.format(
		"notify-send --app-name=%s --urgency=%s --expire-time=%d %s %s >/dev/null 2>&1 &",
		Shell.quote(DEFAULT_TITLE), urgency, TIMEOUT_MS,
		Shell.quote(title), Shell.quote(message))

	local ok = Shell.run(command)
	if not ok then
		Logger.error(LOG, "send(): notify-send failed — the message stays in the log: %s", message)
	end
end

return M
