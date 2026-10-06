--- adapters/update_launcher.lua

--- ==============================================================================
--- MODULE: Native Update Launcher
--- DESCRIPTION:
--- Sends the embedded Hammerspoon menu commands to the outer ErgoptiPlus app.
--- The launcher-owned Sparkle controller verifies, downloads and installs; it
--- schedules no check (the Lua driver owns the cadence, modules/updater/
--- auto_check.lua). These commands only tell it which channel's feed to read
--- and when to check.
---
--- FEATURES & RATIONALE:
--- 1. Exact commands: ergoptiplus://updater/check/<channel> (select the
---    channel, then check) and ergoptiplus://updater/channel/<channel> (select
---    it for the next check). The launcher accepts only channel ids of the
---    shared registry; this adapter refuses anything that is not an id.
--- 2. Visible failure: a refused check surfaces a dialog (or a notification
---    when the dialog itself fails), never silence.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local dialog = require("infra.dialog_util")
local i18n   = require("infra.i18n")
local Notifier = require("adapters.application_notifier")

local LOG = "update_launcher"
local COMMAND_ROOT = "ergoptiplus://updater/"
local CHANNEL_ID_PATTERN = "^[a-z][a-z0-9_]*$"

--- Builds one exact command URL, or nil for a value that is no channel id.
--- @param verb string "check" or "channel".
--- @param channel any Registry channel id.
--- @return string|nil url
local function command_url(verb, channel)
	if type(channel) ~= "string" or not channel:match(CHANNEL_ID_PATTERN) then return nil end
	return COMMAND_ROOT .. verb .. "/" .. channel
end

--- Opens one command URL through Launch Services.
--- @param url string
--- @return boolean accepted
--- @return string|nil reason
local function open_command(url)
	local ok, accepted_or_error = pcall(function()
		return hs.urlevent.openURL(url)
	end)
	if ok and accepted_or_error == true then return true, nil end
	return false, ok and "Launch Services refused the URL" or tostring(accepted_or_error)
end

--- Asks the running native launcher to check the channel's feed with Sparkle's UI.
--- @param channel string Registry channel id the check reads.
--- @return boolean sent True only when Launch Services accepted the command.
function M.request_check(channel)
	Logger.start(LOG, "Requesting a native Sparkle update check (channel=%s).", tostring(channel))
	local url = command_url("check", channel)
	local sent, reason = false, "the channel is not a registry id"
	if url then sent, reason = open_command(url) end
	if sent then
		Logger.success(LOG, "Native Sparkle update check requested.")
		return true
	end

	Logger.error(LOG, "Native Sparkle update command failed: %s.", tostring(reason))
	local title = i18n.get("common.error_title")
	-- Only the request failed: nothing was downloaded or installed yet.
	local message = i18n.get("updater.check_request_failed")
	local dialog_ok = pcall(dialog.block_alert, title, message, i18n.get("button.ok"))
	if not dialog_ok then
		Notifier.send(title, { body = message, kind = "error" })
	end
	return false
end

--- Tells the native launcher which channel Sparkle's next check reads.
--- @param channel string Registry channel id.
--- @return boolean sent True only when Launch Services accepted the command.
function M.select_channel(channel)
	local url = command_url("channel", channel)
	if not url then
		Logger.error(LOG, "Refused to send a channel that is not a registry id to the launcher.")
		return false
	end
	local sent, reason = open_command(url)
	if not sent then
		Logger.error(LOG, "The launcher did not receive the update channel '%s': %s.", channel, tostring(reason))
		return false
	end
	Logger.info(LOG, "Launcher update channel set to '%s'.", channel)
	return true
end

return M
