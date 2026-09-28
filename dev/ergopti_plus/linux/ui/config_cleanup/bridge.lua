--- ui/config_cleanup/bridge.lua

--- Binds the shared cleanup session to the WebKit manager's exact page epoch.
local M = { bridge_name = "config_cleanup_bridge" }
local Logger = require("logger.shim")
local Session = require("config_cleanup_session")
local Json = require("json")
local APP = "config_cleanup"
local LOG = "config_cleanup"
local active

--- Revokes one session without touching a replacement page.
--- @param owner table Session owner.
local function retire(owner)
	if active ~= owner then return end
	active = nil
	owner.session:close()
end

--- Opens the shared page; scanning waits for its ready message.
--- @param options table Trusted configuration ownership and file ports.
--- @return boolean opened
function M.open(options)
	local manager = require("ui.webview_manager")
	if active and active.opening then return false end
	if active and manager.current_epoch(APP) == active.epoch then return manager.show(APP) == true end
	if active then retire(active) end
	local owner = { session = Session.new(options), opening = true }
	active = owner
	Logger.start(LOG, "Opening configuration cleanup…")
	local ok, opened = pcall(manager.show, APP)
	if not ok or opened ~= true then
		retire(owner)
		Logger.error(LOG, "Configuration cleanup window could not open: %s.", tostring(opened))
		return false
	end
	if active ~= owner then return false end
	owner.opening = false
	owner.epoch = manager.current_epoch(APP)
	if owner.epoch == nil then
		retire(owner)
		Logger.error(LOG, "Configuration cleanup has no native page ownership.")
		return false
	end
	Logger.success(LOG, "Configuration cleanup window opened.")
	return true
end

--- Handles only messages from the currently owned native page.
--- @param payload any Page message; paths and targets never come from it.
--- @param state table|nil Unused daemon state.
--- @param context table Native manager context with epoch and close capability.
--- @return nil Responses use the shared receiveConfigCleanup callback.
function M.on_message(payload, state, context)
	local owner = active
	local manager = require("ui.webview_manager")
	local epoch = type(context) == "table" and context.epoch or nil
	if not owner or epoch == nil or manager.current_epoch(APP) ~= epoch then return nil end
	-- WebKit can deliver ready while show() is still creating the native view.
	if owner.epoch == nil then owner.epoch = epoch end
	if owner.epoch ~= epoch then return nil end
	local accepted_close = type(payload) == "table" and payload.action == "close"
		and (payload.session == "" or (owner.token ~= nil and payload.session == owner.token))
	local result = owner.session:handle(payload)
	if active ~= owner or manager.current_epoch(APP) ~= epoch then return nil end
	if accepted_close then
		retire(owner)
		if type(context.close_owned_window) == "function" then context.close_owned_window() end
		return nil
	end
	if type(result) == "table" then
		owner.token = result.session
		local encoded = Json.encode(result)
		if type(encoded) ~= "string" then error("cleanup state could not be encoded") end
		if type(result.keys) == "table" and next(result.keys) == nil then
			encoded = encoded:gsub('"keys"%s*:%s*%{%}', '"keys":[]', 1)
		end
		manager.eval_js(APP, "if(window.receiveConfigCleanup)window.receiveConfigCleanup(" .. encoded .. ")")
	end
	return nil
end

--- Retires only the session belonging to the closed page.
--- @param epoch number Closed native page epoch.
function M.on_window_closed(epoch)
	if active and active.epoch == epoch then retire(active) end
end

return M
