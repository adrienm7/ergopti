--- ui/gesture_conflict_notice.lua

--- ==============================================================================
--- MODULE: System Gesture Notices
--- DESCRIPTION:
--- Owns deferred warnings and durable per-group dismissal. Status remains visible
--- after dismissal, so acknowledging a warning never pretends the conflict ended.
--- ==============================================================================

local M = {}
local Dialog = require("infra.dialog_util")
local I18n = require("infra.i18n")
local Storage = require("adapters.storage")
local Deferred = require("infra.deferred_work")
local Shell = require("adapters.shell_runner")
local Logger = require("infra.logger")
local LOG = "gesture_conflict_notice"

--- Shows one conflict outside the caller's stack unless that group was dismissed.
--- @param warning table Host-owned { key, msg, url }.
--- @return boolean accepted
function M.show(warning)
	local key = "gesture_conflict_dismissed." .. warning.key
	if Storage.get(key, false) == true then return true end
	return Deferred.after(0, function()
		if Storage.get(key, false) == true then return end
		local settings = I18n.get("menu.gestures.open_settings")
		local dismiss = I18n.get("gestures.system.dismiss")
		local clicked = Dialog.block_alert(I18n.get("menu.gestures.conflict_title"),
			warning.msg, settings, dismiss, "warning")
		if clicked == settings then
			if not Shell.open(warning.url) then Logger.error(LOG, "System gesture settings could not open.") end
		elseif clicked == dismiss then
			if Storage.set(key, true) ~= true then Logger.error(LOG, "Gesture conflict dismissal could not be saved.") end
		end
	end, "gesture_conflict_notice.show")
end

return M
