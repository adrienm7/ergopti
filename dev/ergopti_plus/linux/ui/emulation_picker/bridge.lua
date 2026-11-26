--- ui/emulation_picker/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Emulation Picker
--- DESCRIPTION:
--- « Layout to emulate › Others… » on Linux: binds the shared picker session
--- (_shared/layouts/engine/emulation/picker_session.lua) to the WebKit manager's
--- exact page epoch. The menu hands it the catalogue and the same write its
--- radio rows run, so a layout chosen here applies live as a tray click does.
--- Bridge name: "emulation_picker_bridge"
--- ==============================================================================

local Session = require("layouts.engine.emulation.picker_session")
local M = { bridge_name = Session.BRIDGE_NAME }
local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local APP = Session.APP_ID
local LOG = Session.APP_ID
local active

--- Revokes one session without touching a replacement page.
--- @param owner table Session owner.
local function retire(owner)
	if active ~= owner then return end
	active = nil
	owner.session:close()
end

--- Opens the shared page; the catalogue waits for its ready message.
--- @param options table { choices = function() -> choices, choose = function(id) -> committed }
--- @return boolean opened
function M.open(options)
	local manager = require("core.ui.ui.webview_manager")
	if active and active.opening then return false end
	-- A window already open is brought forward with the session it holds.
	if active and manager.current_epoch(APP) == active.epoch then return manager.show(APP) == true end
	if active then retire(active) end
	local owner = { session = Session.new(options), opening = true }
	active = owner
	Logger.start(LOG, "Opening the emulation picker…")
	local ok, opened = pcall(manager.show, APP)
	if not ok or opened ~= true then
		retire(owner)
		Logger.error(LOG, "The emulation picker window could not open: %s.", tostring(opened))
		return false
	end
	if active ~= owner then return false end
	owner.opening = false
	owner.epoch = owner.epoch or manager.current_epoch(APP)
	if owner.epoch == nil then
		retire(owner)
		Logger.error(LOG, "The emulation picker has no native page ownership.")
		return false
	end
	Logger.success(LOG, "Emulation picker window opened.")
	return true
end

--- Handles only messages from the currently owned native page.
--- @param payload any Page message; the layout ids come from the offered catalogue.
--- @param _state table|nil Unused daemon state.
--- @param context table Native manager context with epoch and close capability.
--- @return nil Responses use the page's receiveEmulationPicker callback.
function M.on_message(payload, _state, context)
	local owner = active
	local manager = require("core.ui.ui.webview_manager")
	local epoch = type(context) == "table" and context.epoch or nil
	if not owner or epoch == nil or manager.current_epoch(APP) ~= epoch then return nil end
	-- WebKit can deliver ready while show() is still creating the native view.
	if owner.epoch == nil then owner.epoch = epoch end
	if owner.epoch ~= epoch then return nil end
	local reply, close = owner.session:handle(payload)
	if active ~= owner or manager.current_epoch(APP) ~= epoch then return nil end
	if close then
		if type(context.close_owned_window) == "function" and context.close_owned_window() == true then
			retire(owner)
			Logger.info(LOG, "Emulation picker window closed.")
		else
			Logger.warn(LOG, "The emulation picker close was refused; its session is retained.")
		end
		return nil
	end
	if type(reply) == "table" then
		local encoded = Json.encode(reply)
		if type(encoded) ~= "string" then error("the emulation picker state could not be encoded") end
		manager.eval_js(APP, "if(window.receiveEmulationPicker)window.receiveEmulationPicker(" .. encoded .. ")")
	end
	return nil
end

--- Retires only the session belonging to the closed page.
--- @param epoch number Closed native page epoch.
function M.on_window_closed(epoch)
	if active and active.epoch == epoch then retire(active) end
end

--- Test seam: forgets the session.
function M._reset()
	active = nil
end

return M
