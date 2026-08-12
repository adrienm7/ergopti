--- ui/menu/keymap_lifecycle.lua

--- ==============================================================================
--- MODULE: Menu Keymap Lifecycle Gate
--- DESCRIPTION:
--- Centralizes the strict start contract used by every menu action that can
--- publish keymap-backed features as enabled. The public state is updated only
--- after modules.keymap.start() returns the exact success value `true`.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local I18n          = require("infra.i18n")
local Notifications = require("infra.notifications")
local LOG = "menu.keymap_lifecycle"


--- Reports an activation refusal to the user as well as the file logger.
--- A menu click that simply does nothing is indistinguishable from a dead
--- driver, so every failed commitment must be visible without opening Console.
local function notify_start_failure()
	local ok, err = pcall(Notifications.notify,
		I18n.get("dialog.fatal_error.cannot_start"), nil, "error")
	if not ok then
		Logger.error(LOG, "Keymap start failure notification failed: %s.", tostring(err))
	end
end

--- Ensures key capture is live before callers mutate user-visible feature state.
--- Calling start on an already-started keymap is intentionally supported and
--- cheap; it verifies reality instead of trusting a potentially stale menu bit.
--- @param ctx table Context containing `state` and `keymap`.
--- @param reason string|nil Diagnostic action label.
--- @return boolean committed True only after keymap.start() returned true.
function M.ensure_started(ctx, reason)
	if type(ctx) ~= "table" or type(ctx.state) ~= "table" then
		Logger.error(LOG, "Keymap start refused (%s): menu state is unavailable.",
			tostring(reason or "menu action"))
		notify_start_failure()
		return false
	end
	local keymap = ctx.keymap
	if type(keymap) ~= "table" or type(keymap.start) ~= "function" then
		ctx.state.keymap = false
		Logger.error(LOG, "Keymap start refused (%s): keymap.start is unavailable.",
			tostring(reason or "menu action"))
		notify_start_failure()
		return false
	end

	local ok, result = xpcall(keymap.start, debug.traceback)
	if not ok or result ~= true then
		ctx.state.keymap = false
		Logger.error(LOG, "Keymap start refused (%s): start did not commit (%s).",
			tostring(reason or "menu action"), tostring(result))
		notify_start_failure()
		return false
	end

	ctx.state.keymap = true
	return true
end

return M
