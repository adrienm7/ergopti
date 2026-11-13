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

local Logger = require("core.logger.engine.shim")
local Shell = require("core.process.adapters.shell_runner")

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

-- How long a notification stays up, in milliseconds (the shared registry).
local TIMEOUT_MS = require("infra.timings").ms("ui", "notification_ttl_ms")

-- How long notify-send may take to hand the notice over (the shared registry).
local SEND_TIMEOUT_MS = require("infra.timings").ms("ui", "notification_send_timeout_ms")

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
--- @return boolean Whether notify-send was started; its failure is logged when it exits.
local function send(message, opts, caption, native_admit)
	if type(message) ~= "string" or message == "" then
		Logger.error(LOG, "send(): a message is required — nothing was shown.")
		return false
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

	local title
	if caption then
		title = caption(options.title, PREFIX_FOR_LEVEL[level])
	else
		title = (PREFIX_FOR_LEVEL[level] or "")
			.. (type(options.title) == "string" and options.title ~= "" and options.title or DEFAULT_TITLE)
	end

	--- Leaves the notice in the log when the desktop cannot show it.
	--- @param detail string Why it was not shown.
	local function keep_in_log(detail)
		-- Private notices may contain user paths or process output; only a
		-- generic diagnostic may reach the fallback log.
		if options.private == true then Logger.info(LOG, "[notification] Private notification unavailable (%s).", detail)
		else Logger.info(LOG, "[notification] %s: %s", caption and title or tostring(options.title or DEFAULT_TITLE), message) end
	end

	if not available() then
		keep_in_log("notify-send is not installed")
		return false
	end

	-- Owned native notices can be invalidated by the capability probe or quoting.
	-- Admission is checked at the actual effect boundary, never supplied by JS.
	if native_admit then
		local admitted, current = pcall(native_admit)
		if not admitted or current ~= true then return false end
	end
	-- An argv, never a shell line: the "--" boundary keeps option-looking caller
	-- text literal. Run without blocking (reachable from the keystroke path) and
	-- watched to its exit, so a notify-send that runs and fails (no notification
	-- daemon, no session bus in the unit) is logged and its text kept in the log
	-- instead of counted as shown (NUI-003). Ownership stays with the process
	-- operation as before: a notice never delays shutdown, and its deadline stops
	-- the child's group, so an exit leaves at most one bounded notify-send behind.
	local argv = { "--app-name=" .. DEFAULT_TITLE, "--urgency=" .. urgency,
		"--expire-time=" .. string.format("%d", TIMEOUT_MS), "--", title, message }
	local handle, refusal = Shell.run_async("notify-send", argv, { timeout_ms = SEND_TIMEOUT_MS }, function(result)
		if result.ok == true then return end
		local detail = tostring(result.error or ("exit code " .. tostring(result.code)))
		Logger.error(LOG, "send(): notify-send failed (%s) — the notice stays in the log.", detail)
		keep_in_log(detail)
	end)
	if not handle then
		Logger.error(LOG, "send(): notify-send could not start (%s) — the notice stays in the log.", tostring(refusal))
		keep_in_log(tostring(refusal))
		return false
	end
	return true
end

--- Sends a generic notice with the port's original literal-title contract.
--- @param message string Original notification body.
--- @param opts table|nil Native title, level and click options.
--- @return boolean admitted Exact native command admission result.
function M.send(message, opts)
	return send(message, opts)
end

--- Native owned notice. true admits notify-send; it is not a delivery receipt.
function M.send_owned(message, opts, native_admit)
	if type(native_admit) ~= "function" then return false end
	return send(message, opts, nil, native_admit)
end

--- Dispatches an application notice through its injected shared caption policy.
--- This private adapter helper does not extend the generic Notifier port.
--- @param caption function Shared application-caption callback.
--- @param message string Original notification body.
--- @param opts table|nil Native title, level and click options.
--- @return boolean admitted Exact native command admission result.
function M._send_application(caption, message, opts)
	assert(type(caption) == "function", "application caption callback is required")
	return send(message, opts, caption)
end

--- Dispatches an owned application notice through the shared caption policy.
--- @param caption function Shared application-caption callback.
--- @param message string Original notification body.
--- @param opts table|nil Native title, level and click options.
--- @param native_admit function Current native owner admission at the effect boundary.
--- @return boolean admitted Exact native command admission result.
function M._send_application_owned(caption, message, opts, native_admit)
	assert(type(caption) == "function", "application caption callback is required")
	if type(native_admit) ~= "function" then return false end
	return send(message, opts, caption, native_admit)
end

return M
