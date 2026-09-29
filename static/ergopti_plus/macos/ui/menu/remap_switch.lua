--- ui/menu/remap_switch.lua

--- ==============================================================================
--- MODULE: Remap Switch Menu Commands
--- DESCRIPTION:
--- The two Configuration rows that own « Ergopti uses Karabiner »: the
--- checkbox that turns the integration on or off, and « Remove Ergopti from
--- Karabiner », which turns it off or, when it already is, only cleans
--- karabiner.json. Both delegate to the remap owner's transactions.
---
--- FEATURES & RATIONALE:
--- 1. One owner: the remap module persists the switch, fences the exact lease
---    and removes the marked rules; this module only asks and reports.
--- 2. Honest feedback: a removal is confirmed by a notification only after
---    the owner reported it; every refusal is logged as an error, which the
---    shared error UI surfaces.
--- 3. Karabiner itself is never quit, launched or reconfigured from here.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local Notifications = require("infra.notifications")

local LOG = "menu.remap_switch"





-- ===============================
-- ===============================
-- ======= 1/ Switch State =======
-- ===============================
-- ===============================

--- Reports whether Ergopti currently uses Karabiner.
--- @param karabiner table|nil Remap module.
--- @return boolean enabled
function M.is_enabled(karabiner)
	if type(karabiner) ~= "table" or type(karabiner.get_enabled) ~= "function" then return false end
	local ok, enabled = pcall(karabiner.get_enabled)
	if not ok then
		Logger.error(LOG, "The Karabiner switch state could not be read: %s.", tostring(enabled))
		return false
	end
	return enabled == true
end

--- Refreshes the tray after a transition settled.
--- @param update_menu function|nil Menu refresh callback.
local function refresh(update_menu)
	if type(update_menu) == "function" then update_menu() end
end

--- Confirms that Ergopti's rules left karabiner.json.
local function notify_removed()
	local ok, err = pcall(Notifications.notify, i18n.get("notify.karabiner.removed"), nil, "info")
	if not ok then Logger.error(LOG, "The removal confirmation could not be shown: %s.", tostring(err)) end
end





-- ===========================
-- ===========================
-- ======= 2/ Commands =======
-- ===========================
-- ===========================

--- Turns « Ergopti uses Karabiner » to the opposite of its current state.
--- @param karabiner table Remap module.
--- @param update_menu function|nil Menu refresh callback.
--- @return boolean accepted
function M.toggle(karabiner, update_menu)
	if type(karabiner) ~= "table" or type(karabiner.set_enabled) ~= "function" then
		Logger.error(LOG, "« Ergopti uses Karabiner » is unavailable: the remap owner is missing.")
		return false
	end
	local target = not M.is_enabled(karabiner)
	Logger.start(LOG, "Turning « Ergopti uses Karabiner » %s…", target and "on" or "off")
	local call_ok, accepted = pcall(karabiner.set_enabled, target, function(ok, reason)
		if ok == true then
			Logger.success(LOG, "« Ergopti uses Karabiner » is now %s (%s).",
				target and "on" or "off", tostring(reason))
			if not target then notify_removed() end
		else
			Logger.error(LOG, "« Ergopti uses Karabiner » could not be turned %s: %s.",
				target and "on" or "off", tostring(reason))
		end
		refresh(update_menu)
	end)
	if not call_ok then
		Logger.error(LOG, "« Ergopti uses Karabiner » request raised: %s.", tostring(accepted))
		return false
	end
	return accepted == true
end

--- « Remove Ergopti from Karabiner »: off, then no ErgoptiPlus rule left.
--- @param karabiner table Remap module.
--- @param update_menu function|nil Menu refresh callback.
--- @return boolean accepted
function M.remove(karabiner, update_menu)
	if type(karabiner) ~= "table" or type(karabiner.remove_from_karabiner) ~= "function" then
		Logger.error(LOG, "« Remove Ergopti from Karabiner » is unavailable: the remap owner is missing.")
		return false
	end
	Logger.start(LOG, "Removing Ergopti from Karabiner…")
	local call_ok, accepted = pcall(karabiner.remove_from_karabiner, function(ok, reason)
		if ok == true then
			Logger.success(LOG, "Ergopti was removed from Karabiner (%s).", tostring(reason))
			notify_removed()
		else
			Logger.error(LOG, "Ergopti could not be removed from Karabiner: %s.", tostring(reason))
		end
		refresh(update_menu)
	end)
	if not call_ok then
		Logger.error(LOG, "« Remove Ergopti from Karabiner » raised: %s.", tostring(accepted))
		return false
	end
	return accepted == true
end

--- The Configuration rows' commands and checkbox state, keyed by manifest id.
--- @param karabiner table Remap module.
--- @param update_menu function|nil Menu refresh callback.
--- @return table commands
--- @return table state_getters
function M.rows(karabiner, update_menu)
	return {
		["karabiner_integration"] = function() return M.toggle(karabiner, update_menu) end,
		["remove_from_karabiner"] = function() return M.remove(karabiner, update_menu) end,
	}, {
		["karabiner_integration_enabled"] = function() return M.is_enabled(karabiner) end,
	}
end

return M
