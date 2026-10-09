--- modules/gestures/action_confirm.lua

--- ==============================================================================
--- MODULE: Destructive Action Confirmation (macOS)
--- DESCRIPTION:
--- Asks the user before a catalogue action declared `confirm = true` runs
--- (empty_trash, remove_quarantine_selection, force_quit_frontmost), whichever
--- binding fired it.
---
--- FEATURES & RATIONALE:
--- 1. Non-blocking: the question is the NSAlert of dialog_util.alert, whose
---    runloop keeps turning, so the keyboard tap is never parked while the user
---    reads it. The action runs from the alert's callback, or not at all.
--- 2. Cancel is the first (default) button: Return on a question the user did
---    not expect must not destroy anything.
--- 3. One question at a time: a second press while one is shown is refused and
---    logged instead of stacking alerts whose answers could run twice.
--- 4. The alert brings the driver to the front, so the application the user
---    acted from is read before it and handed to the action:
---    force_quit_frontmost kills that one, never the driver in front once the
---    alert is gone. It is read from NSWorkspace, not the accessibility API, so
---    a hung application or one with no window is still the one killed.
--- 5. That application gets its focus back before the action runs, as best
---    effort: no action depends on it any more, so a failure is only logged.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local i18n = require("infra.i18n")
local Dialog = require("infra.dialog_util")
local MouseControl = require("adapters.mouse_control")
local WindowInfo = require("adapters.window_info")
local WindowManager = require("adapters.window_manager")

local LOG = "gestures.action_confirm"

-- Where the alert is anchored on the screen under the pointer: centered
-- horizontally, a third of the way down, where a system alert usually sits.
local ALERT_VERTICAL_FRACTION = 1 / 3

-- The question currently shown, or nil. Declared above every reader.
local _pending = nil

--- Whether a confirmation is waiting for its answer.
--- @return boolean
function M.is_pending()
	return _pending ~= nil
end

--- Asks whether an action may run, and runs it only on the explicit answer.
--- @param action_label string The action's localized label, quoted in the question.
--- @param on_confirmed function fn(acted_from) runs the action; called at most
--- once. acted_from is the frontmost application when the question was asked,
--- { pid, bundle_id }, or nil when it could not be read.
--- @return boolean asked True when the question is shown.
function M.ask(action_label, on_confirmed)
	if type(on_confirmed) ~= "function" then
		error("action_confirm.ask: on_confirmed must be a function", 2)
	end
	if _pending ~= nil then
		Logger.warn(LOG, "A confirmation is already shown — '%s' was not asked again.", tostring(action_label))
		return false
	end
	local frame = MouseControl.screen_frame_under_cursor()
	if type(frame) ~= "table" then
		Logger.error(LOG, "No screen holds the pointer — '%s' cannot be confirmed and does not run.",
			tostring(action_label))
		return false
	end
	-- Read before the alert brings the driver to the front.
	local acted_from = WindowInfo.frontmost_application()
	local confirm_label = i18n.get("dialog.confirm_action.confirm")
	local cancel_label = i18n.get("button.cancel")
	local question = {}
	_pending = question
	local shown, err = xpcall(Dialog.alert, debug.traceback,
		frame.x + frame.w / 2, frame.y + frame.h * ALERT_VERTICAL_FRACTION,
		function(button)
			if _pending ~= question then return end
			_pending = nil
			if button ~= confirm_label then
				Logger.info(LOG, "'%s' was cancelled at its confirmation.", tostring(action_label))
				return
			end
			Logger.info(LOG, "'%s' was confirmed.", tostring(action_label))
			if acted_from ~= nil and not WindowManager.activate(acted_from.bundle_id) then
				Logger.info(LOG, "'%s': %s could not get its focus back.", tostring(action_label),
					acted_from.bundle_id)
			end
			on_confirmed(acted_from)
		end,
		i18n.get("dialog.confirm_action.title"),
		i18n.format("dialog.confirm_action.message", action_label),
		cancel_label, confirm_label, "warning")
	if not shown then
		_pending = nil
		Logger.error(LOG, "The confirmation for '%s' could not be shown: %s.", tostring(action_label), tostring(err))
		return false
	end
	return true
end

return M
