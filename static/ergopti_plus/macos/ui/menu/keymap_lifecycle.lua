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

--- Reports a rejected keymap-backed mutation without claiming it succeeded.
local function notify_mutation_failure()
	local ok, err = pcall(Notifications.notify,
		I18n.get("common.error_title"), I18n.get("dialog.bulk_toggle.save_failed"), "error")
	if not ok then
		Logger.error(LOG, "Keymap mutation failure notification failed: %s.", tostring(err))
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

--- Runs a registry mutation and publishes UI state only after exact true.
--- @param ctx table Menu context.
--- @param reason string|nil Diagnostic action label.
--- @param mutation function Must return exact true on commitment.
--- @param publish function|nil State/persistence/notification callback.
--- @return boolean committed
function M.commit_mutation(ctx, reason, mutation, publish)
	if type(ctx) ~= "table" or type(mutation) ~= "function" then
		Logger.error(LOG, "Keymap mutation refused (%s): callback is unavailable.",
			tostring(reason or "menu action"))
		notify_mutation_failure()
		return false
	end

	local ok, result = xpcall(mutation, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Keymap mutation refused (%s): mutation did not commit (%s).",
			tostring(reason or "menu action"), tostring(result))
		notify_mutation_failure()
		return false
	end

	if type(publish) == "function" then
		local publish_ok, publish_err = xpcall(publish, debug.traceback)
		if not publish_ok then
			Logger.error(LOG, "Keymap mutation publication failed (%s): %s.",
				tostring(reason or "menu action"), tostring(publish_err))
			notify_mutation_failure()
			return false
		end
	end
	return true
end

return M
