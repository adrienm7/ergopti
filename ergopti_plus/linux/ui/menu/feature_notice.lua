--- ui/menu/feature_notice.lua

--- ==============================================================================
--- MODULE: Feature And Refusal Notices (Linux)
--- DESCRIPTION:
--- Binds the shared feature_notice behaviour (the one the macOS menu uses) to the
--- freedesktop notifier and the central logger. The menu builder calls it after
--- every committed feature switch and when the daemon refuses Quit.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local SharedNotice = require("feature_notice")

local LOG = "ui.menu.feature_notice"

-- The ports the shared behaviour injects: the notifier is required at call time
-- so a daemon without notify-send only logs, and the logger lines carry this
-- module's tag.
local PORTS = {
	send = function(text, level) return require("adapters.notifier").send(text, { level = level }) end,
	info = function(fmt, ...) Logger.info(LOG, fmt, ...) end,
	warn = function(fmt, ...) Logger.warn(LOG, fmt, ...) end,
}

--- Announces that a menu feature was switched on or off.
--- @param label string Already-localised feature name.
--- @param enabled boolean New state.
function M.feature(label, enabled)
	SharedNotice.feature(PORTS, label, enabled)
end

--- Tells the user that Quit was refused because a shutdown already runs.
--- @param translate function Locale lookup: key -> localized text.
function M.quit_refused(translate)
	SharedNotice.quit_refused(PORTS, translate)
end

return M
