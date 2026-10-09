--- ui/permission_dialog/login_items_guide.lua

--- ==============================================================================
--- MODULE: Login Items Approval Guide
--- DESCRIPTION:
--- Shows the permission dialog's Login Items steps while the remap guardian
--- waits for "Allow in the Background", and closes them once it no longer does.
---
--- FEATURES & RATIONALE:
--- 1. Proactive: tap-holds stay off until macOS lets the guardian run, and
---    nothing told the user where to allow it. A banner can go unseen (a fresh
---    install may lack the notification permission), so the steps open in the
---    same native dialog as the Accessibility ones, as an ordinary focused
---    window.
--- 2. Once per launch: the remap bridge's approval notice offers the steps on
---    its first requires_approval answer. A later episode, or an offer after
---    the user closed them, gets the notice's banner instead; the Tap-Holds
---    menu row reopens the steps on request.
--- 3. After Accessibility: the dialog has one owner and those steps come
---    first, so an offer made while they are open waits until they close.
--- 4. Closes itself: a bounded poll reads the in-memory guardian state, which
---    the remap bridge's own readiness wait refreshes; that wait also deploys
---    the retained rules once the guardian is ready, so this guide deploys
---    nothing. The poll stops when the dialog closes, at its deadline, and at
---    reload or quit through the scheduler's teardown (cancelAll).
--- 5. Not an error: an approval not given yet is the state this guide exists
---    for, logged as a start/success pair with warnings for the other ends.
--- ==============================================================================

local M = {}

local Logger           = require("infra.logger")
local i18n             = require("infra.i18n")
local PermissionDialog = require("ui.permission_dialog")
local TimerScheduler   = require("adapters.timer_scheduler")

local LOG = "login_items_guide"

-- The dialog kinds this guide shows, and the one it must wait behind.
local KIND = "login_items"
local ACCESSIBILITY = "accessibility"

-- Guardian states read from platform.remap.guardian_state(): the one the steps
-- are for, and the one a failed or superseded probe leaves while it lasts.
local REQUIRES_APPROVAL = "requires_approval"
local READY = "ready"
local UNKNOWN = "unknown"

-- The state is an in-memory read, so a short period costs nothing. Ten
-- minutes leave time to follow the steps without keeping a forgotten dialog
-- up for good; the Tap-Holds menu row remains after it.
M.POLL_SECONDS = 1
M.DEADLINE_SECONDS = 600

-- True once the automatic offer showed (or queued) the steps in this launch.
local _offered = false

-- The running guide: { remap, timer, elapsed, shown, queued }, or nil.
local _guide = nil




-- =====================================
-- ======= 1/ Internal helpers =========
-- =====================================

--- Checks the remap facade before any side effect.
--- @param remap table Remap facade.
local function validate(remap)
	if type(remap) ~= "table" or type(remap.guardian_state) ~= "function"
		or type(remap.open_login_items) ~= "function"
		or type(remap.get_tap_holds_enabled) ~= "function" then
		error("login_items_guide: remap must provide guardian_state, open_login_items and get_tap_holds_enabled", 3)
	end
end

--- Reads the guardian state without letting a raise stop the caller.
--- @param remap table Remap facade.
--- @return string state A guardian state; `unknown` when unreadable.
local function read_state(remap)
	local ok, state = pcall(remap.guardian_state)
	if not ok or type(state) ~= "string" then
		Logger.warn(LOG, "The remap guardian state is unreadable: %s.", tostring(state))
		return UNKNOWN
	end
	return state
end

--- Returns the dialog's "Open Settings" action: the remap bridge's Login Items
--- opener, which a refused launch reports through a localized notice.
--- @param remap table Remap facade.
--- @return function open_settings fn() -> boolean accepted.
local function settings_opener(remap)
	return function()
		return remap.open_login_items(function(opened, detail)
			if opened == true then return end
			Logger.warn(LOG, "Login Items settings did not open from the steps: %s.", tostring(detail))
			local ok, sent_or_err = pcall(require("infra.notifications").notify,
				i18n.get("karabiner.guardian_settings_open_failed"), nil, "error")
			if not ok or sent_or_err ~= true then
				Logger.error(LOG, "Login Items failure notice was not delivered: %s.", tostring(sent_or_err))
			end
		end) == true
	end
end

--- Ends a guide: stops its poll, then closes the steps when asked. The guide
--- is released first, so the dialog's close report finds nothing to end.
--- @param guide table The running guide.
--- @param close_dialog boolean Whether the steps must close as well.
--- @return boolean settled True when the poll stopped and the steps closed.
local function finish(guide, close_dialog)
	if _guide ~= guide then return true end
	_guide = nil
	local settled = TimerScheduler.cancel(guide.timer) == true
	if not settled then
		Logger.warn(LOG, "The Login Items approval poll did not settle on cancel.")
	end
	if close_dialog and PermissionDialog.close(KIND) ~= true then settled = false end
	return settled
end

--- Hears that the steps closed without this guide asking: Later, the close
--- button, or another permission taking the dialog.
--- @param guide table The guide that showed them.
local function on_steps_closed(guide)
	if _guide ~= guide then return end
	Logger.warn(LOG,
		"The Login Items steps closed after %d s before the guardian was approved; the Tap-Holds menu keeps them.",
		guide.elapsed)
	finish(guide, false)
end

--- Shows the steps, or keeps them waiting while the Accessibility ones are open.
--- @param guide table The running guide.
--- @return boolean offered True when the steps are open or waiting to open.
local function present(guide)
	if PermissionDialog.is_open(ACCESSIBILITY) then
		if not guide.queued then
			guide.queued = true
			Logger.info(LOG, "The Accessibility steps are open; the Login Items steps follow once they close.")
		end
		return true
	end
	guide.queued = false
	local shown = PermissionDialog.show({
		kind          = KIND,
		open_settings = settings_opener(guide.remap),
		on_closed     = function() on_steps_closed(guide) end,
	})
	if shown ~= true then
		Logger.warn(LOG, "The Login Items steps could not be shown; the Tap-Holds menu keeps them.")
		return false
	end
	guide.shown = true
	return true
end

--- Runs one poll: closes the steps once the guardian no longer needs them,
--- shows steps that waited behind Accessibility, and stops at the deadline.
--- @param guide table The running guide.
local function tick(guide)
	if _guide ~= guide then return end
	guide.elapsed = guide.elapsed + M.POLL_SECONDS
	local state = read_state(guide.remap)
	if state == READY then
		Logger.success(LOG,
			"Remap guardian allowed in the background after %d s; the Login Items steps closed.", guide.elapsed)
		finish(guide, true)
		return
	end
	if state ~= REQUIRES_APPROVAL and state ~= UNKNOWN then
		Logger.warn(LOG, "The remap guardian is now '%s'; the Login Items steps closed.", state)
		finish(guide, true)
		return
	end
	if guide.elapsed >= M.DEADLINE_SECONDS then
		Logger.warn(LOG,
			"Remap guardian still awaits Login Items approval after %d s; the steps closed, the Tap-Holds menu keeps them.",
			guide.elapsed)
		finish(guide, true)
		return
	end
	if state == REQUIRES_APPROVAL and not guide.shown and present(guide) ~= true then
		finish(guide, false)
	end
end

--- Starts guiding, or presents the steps of the guide already running.
--- @param remap table Remap facade.
--- @param trigger string Why the steps are shown, for the log.
--- @return boolean offered True when the steps are open or waiting to open.
local function start(remap, trigger)
	local state = read_state(remap)
	if state ~= REQUIRES_APPROVAL then
		Logger.info(LOG, "No Login Items steps to show (%s): the remap guardian is '%s'.", trigger, state)
		return false
	end
	if _guide ~= nil then return present(_guide) end

	Logger.start(LOG, "Waiting for the remap guardian's Login Items approval (%s, up to %d s)…",
		trigger, M.DEADLINE_SECONDS)
	local guide = { remap = remap, elapsed = 0, shown = false, queued = false }
	local timer, committed = TimerScheduler.every(M.POLL_SECONDS, function() tick(guide) end)
	if committed ~= true then
		Logger.error(LOG, "The Login Items approval poll could not start; the steps are not shown.")
		return false
	end
	guide.timer = timer
	_guide = guide
	if present(guide) ~= true then
		finish(guide, false)
		return false
	end
	return true
end




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Offers the steps once per launch, when the guardian first awaits approval.
--- The remap bridge's approval notice calls it and sends its banner instead
--- when it answers false.
--- @param remap table Remap facade { guardian_state(), open_login_items(on_done) }.
--- @return boolean offered True when the steps are open or waiting to open.
function M.offer(remap)
	validate(remap)
	-- The steps promise that the Tap-Holds menu keeps them after « Later »,
	-- and that menu only lists the guardian while Tap-Holds are on: with them
	-- off, the notice keeps its banner, which stays reachable.
	if remap.get_tap_holds_enabled() ~= true then
		Logger.info(LOG, "No automatic Login Items steps: Tap-Holds are off, the approval banner stays.")
		return false
	end
	if _offered then
		Logger.debug(LOG, "The Login Items steps were already offered in this launch.")
		return false
	end
	local offered = start(remap, "automatic")
	if offered then _offered = true end
	return offered
end

--- Shows the steps again on the user's request, whatever was offered before.
--- @param remap table Remap facade { guardian_state(), open_login_items(on_done) }.
--- @return boolean offered True when the steps are open or waiting to open.
function M.reopen(remap)
	validate(remap)
	return start(remap, "requested")
end

--- Reports whether the steps are being guided (open or waiting to open).
--- @return boolean
function M.is_active()
	return _guide ~= nil
end

return M
