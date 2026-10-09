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
local SourceIdentity = require("module_source_identity")
local source_same = SourceIdentity.same
local source_directory = require("module_source_directory").capture()
local remap_source = SourceIdentity.sibling(debug.getinfo(1, "S").source,
	"macos/ui/menu/remap_switch.lua", "macos/platform/remap/init.lua", source_directory)

local LOG = "menu.remap_switch"





-- ===============================
-- ===============================
-- ======= 1/ Switch State =======
-- ===============================
-- ===============================

--- Reads admitted settings intent without inferring installed native readiness.
--- Missing, inconsistent or substituted reader ports retain unavailable status.
--- @param karabiner table|nil Exact remap owner.
--- @return string status Shared, owned, or unavailable presentation state.
local function runtime_status(karabiner)
	if type(karabiner) ~= "table" then return "unavailable" end
	local runtime = rawget(karabiner, "get_runtime")
	local selected = rawget(karabiner, "shared_runtime_selected")
	local reason = rawget(karabiner, "runtime_unavailable_reason")
	if type(runtime) ~= "function" or type(selected) ~= "function" or type(reason) ~= "function" then return "unavailable" end
	local read_ok, intent = pcall(runtime)
	local selected_ok, shared = pcall(selected)
	local reason_ok, unavailable = pcall(reason)
	if not read_ok or not selected_ok or not reason_ok
		or rawget(karabiner, "get_runtime") ~= runtime
		or rawget(karabiner, "shared_runtime_selected") ~= selected
		or rawget(karabiner, "runtime_unavailable_reason") ~= reason then return "unavailable" end
	if intent == "shared" and shared == true and unavailable == nil then return "shared" end
	if intent == "owned" and shared == false and type(unavailable) == "string" and unavailable ~= "" then return "owned" end
	return "unavailable"
end

--- Reports supported shared intent, exclusively for native UI command admission.
--- @param karabiner table|nil Exact remap owner.
--- @return boolean supported No native readiness or activation is claimed.
function M.is_shared_runtime(karabiner)
	return runtime_status(karabiner) == "shared"
end

--- Captures only the already-published uninitialized owner's refusal route.
--- Exact cache, reader and scope identities must survive every later boundary.
--- This grants no shared intent, readiness or successful command capability.
--- @param karabiner table|nil Existing published remap owner.
--- @return function|nil guard Current exact uninitialized refusal admission.
function M.uninitialized_clear_guard(karabiner)
	if type(karabiner) ~= "table" or rawget(package.loaded, "platform.remap") ~= karabiner then return nil end
	local runtime = rawget(karabiner, "get_runtime")
	local selected = rawget(karabiner, "shared_runtime_selected")
	local reason = rawget(karabiner, "runtime_unavailable_reason")
	local operation = rawget(karabiner, "apply_scope")
	local token_query = rawget(karabiner, "parser_refusal_token")
	if type(runtime) ~= "function" or type(selected) ~= "function"
		or type(reason) ~= "function" or type(operation) ~= "function"
		or type(token_query) ~= "function" then return nil end
	if not source_same(debug.getinfo(token_query, "S").source, remap_source, source_directory) then return nil end
	local token_ok, token = pcall(token_query)
	if not token_ok or type(token) ~= "table" or rawget(karabiner, "parser_refusal_token") ~= token_query then return nil end
	local function current()
		if rawget(package.loaded, "platform.remap") ~= karabiner
			or rawget(karabiner, "get_runtime") ~= runtime
			or rawget(karabiner, "shared_runtime_selected") ~= selected
			or rawget(karabiner, "runtime_unavailable_reason") ~= reason
			or rawget(karabiner, "apply_scope") ~= operation
			or rawget(karabiner, "parser_refusal_token") ~= token_query then return false end
		local read_ok, intent = pcall(runtime)
		local selected_ok, shared = pcall(selected)
		local reason_ok, unavailable = pcall(reason)
		local current_ok, current_token = pcall(token_query)
		return read_ok and selected_ok and reason_ok and current_ok and current_token == token
			and intent == nil and shared == false and unavailable == nil
			and rawget(package.loaded, "platform.remap") == karabiner
			and rawget(karabiner, "get_runtime") == runtime
			and rawget(karabiner, "shared_runtime_selected") == selected
			and rawget(karabiner, "runtime_unavailable_reason") == reason
			and rawget(karabiner, "apply_scope") == operation
			and rawget(karabiner, "parser_refusal_token") == token_query
	end
	return current() and current or nil
end

--- Projects the shared declaration's inert runtime captions.
--- @param karabiner table|nil Exact remap owner.
--- @return table|nil rows Shared-declared labels with no command capability.
function M.runtime_rows(karabiner)
	return require("infra.manifest_menu").status_rows("configuration_menu", "karabiner_runtime_status", runtime_status(karabiner))
end

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
	if not M.is_shared_runtime(karabiner) then
		Logger.error(LOG, "Shared Karabiner menu command refused unavailable runtime intent.")
		return false
	end
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
	if not M.is_shared_runtime(karabiner) then
		Logger.error(LOG, "Shared Karabiner menu command refused unavailable runtime intent.")
		return false
	end
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
--- @return table providers
function M.rows(karabiner, update_menu)
	return {
		["karabiner_integration"] = function() return M.toggle(karabiner, update_menu) end,
		["remove_from_karabiner"] = function() return M.remove(karabiner, update_menu) end,
	}, {
		["karabiner_integration_enabled"] = function() return M.is_enabled(karabiner) end,
		["karabiner_shared_runtime_selected"] = function() return M.is_shared_runtime(karabiner) end,
	}, {
		["karabiner_runtime_status"] = function() return M.runtime_rows(karabiner) end,
	}
end

return M
