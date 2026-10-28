--- _shared/lua/feature_notice.lua

--- ==============================================================================
--- MODULE: Feature And Refusal Notices
--- DESCRIPTION:
--- The one behaviour of the menu's « feature switched on/off » notices and of the
--- « cannot quit right now » refusal, shared by the macOS and Linux menus. The
--- Windows `NotifyFeature` has the same contract (see the TODO item PAR-45).
---
--- FEATURES & RATIONALE:
--- 1. One Log Line: every menu feature toggle funnels through here. The toast
---    was its only trace, so a user log could never say what had been switched
---    and when; the line is written before the notice is sent.
--- 2. One Level Mapping: enabled is "success", disabled is "error". The level is
---    the severity the desktop renders, so the three drivers colour the same
---    toggle identically.
--- 3. Never Fatal: a notification that raises or is refused is logged as a
---    warning and forgotten. A toggle that was committed must not look failed
---    because the desktop notification service is absent.
--- 4. Injected Ports: the driver supplies its logger lines and its notifier, so
---    this module owns the behaviour and none of the native effects.
--- ==============================================================================

local M = {}

--- The notification levels the two outcomes of a toggle map to.
M.LEVEL_ENABLED = "success"
M.LEVEL_DISABLED = "error"
--- The level of the quit refusal.
M.LEVEL_REFUSAL = "error"
--- The locale key of the quit refusal text.
M.QUIT_REFUSED_KEY = "notify.quit_refused"

--- Checks the injected ports once.
--- @param ports table { send = function(text, level), info = function(fmt, ...), warn = function(fmt, ...) }
local function check(ports)
	assert(type(ports) == "table", "feature notices need their ports")
	assert(type(ports.send) == "function", "feature notices need a send port")
	assert(type(ports.info) == "function", "feature notices need an info log port")
	assert(type(ports.warn) == "function", "feature notices need a warn log port")
end

--- Sends one notice, converting a raised error or a refusal into a warning.
--- @param ports table Validated ports.
--- @param text string Notice body.
--- @param level string Notification level.
--- @param what string Short noun used in the warning line.
local function deliver(ports, text, level, what)
	local called, result = pcall(ports.send, text, level)
	if not called then
		ports.warn("%s notification failed: %s.", what, tostring(result))
	elseif result == false then
		ports.warn("%s notification was not shown.", what)
	end
end

--- Announces that a menu feature was switched on or off.
--- @param ports table { send, info, warn } injected by the driver.
--- @param label any Display name of the feature; converted with tostring.
--- @param enabled boolean The new state.
function M.feature(ports, label, enabled)
	check(ports)
	local on = enabled == true
	ports.info("Feature toggled from the menu: '%s' → %s.", tostring(label), on and "enabled" or "disabled")
	deliver(ports, tostring(label), on and M.LEVEL_ENABLED or M.LEVEL_DISABLED, "Feature toggle")
end

--- Tells the user that Quit was refused because another operation is running.
--- A refusal used to reach only the log, so the user saw Quit do nothing.
--- @param ports table { send, info, warn } injected by the driver.
--- @param translate function Locale lookup: key -> localized text.
function M.quit_refused(ports, translate)
	check(ports)
	assert(type(translate) == "function", "the quit refusal needs the locale lookup")
	ports.warn("Quit was refused; the user is notified.")
	deliver(ports, translate(M.QUIT_REFUSED_KEY), M.LEVEL_REFUSAL, "Quit refusal")
end

return M
