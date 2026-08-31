--- adapters/update_launcher.lua

--- ==============================================================================
--- MODULE: Native Update Launcher
--- DESCRIPTION:
--- Sends the embedded Hammerspoon menu command to the outer ErgoptiPlus app.
--- The launcher-owned Sparkle controller is the sole update authority.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local dialog = require("infra.dialog_util")
local i18n   = require("infra.i18n")
local Notifier = require("adapters.notifier")

local LOG = "update_launcher"
local CHECK_COMMAND_URL = "ergoptiplus://updater/check"

--- Asks the running native launcher to present Sparkle's update UI.
--- @return boolean sent True only when Launch Services accepted the command.
function M.request_check()
	Logger.start(LOG, "Requesting a native Sparkle update check.")
	local ok, accepted_or_error = pcall(function()
		return hs.urlevent.openURL(CHECK_COMMAND_URL)
	end)
	if ok and accepted_or_error == true then
		Logger.success(LOG, "Native Sparkle update check requested.")
		return true
	end

	Logger.error(LOG, "Native Sparkle update command failed: %s.",
		ok and "Launch Services refused the URL" or tostring(accepted_or_error))
	local title = i18n.get("common.error_title")
	local message = i18n.get("menu.about.update.install_error")
	local dialog_ok = pcall(dialog.block_alert, title, message, i18n.get("button.ok"))
	if not dialog_ok then
		Notifier.send(title, { body = message, kind = "error" })
	end
	return false
end

return M
