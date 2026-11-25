--- ui/emulation_picker/init.lua

--- ==============================================================================
--- MODULE: Emulation Picker Window
--- DESCRIPTION:
--- « Layout to emulate › Others… » on macOS: presents the shared picker page
--- (_shared/ui/emulation_picker) in an owned WebView and binds it to the shared
--- picker session (_shared/layouts/engine/emulation/picker_session.lua). The
--- menu hands it the catalogue and the same write its radio rows run, so a
--- layout chosen here applies live as a menu click does.
--- ==============================================================================

local M = {}
local Logger = require("core.logger.engine.logger")
local ui_builder = require("core.ui.ui.builder")
local Session = require("layouts.engine.emulation.picker_session")
local WebviewResult = require("core.ui.adapters.webview_result")
local LOG = Session.APP_ID
local BRIDGE = Session.BRIDGE_NAME
local active, retiring

--- Settles exact native handles without reviving their page authority.
--- @param owner table Retired window owner.
--- @return boolean released
local function release(owner)
	if owner.controller then
		local ok, result = pcall(owner.controller.setCallback, owner.controller, nil)
		if not ok or result == false then return false end
		owner.controller = nil
	end
	if owner.view then
		local ok, result = pcall(owner.view.delete, owner.view)
		if not ok or result == false then return false end
		owner.view = nil
	end
	return true
end

--- Revokes callbacks before any native close operation can reenter the host.
--- @param owner table Current window owner.
--- @param native_closed boolean|nil Whether the native close already happened.
--- @return boolean closed
local function close(owner, native_closed)
	if active ~= owner then return false end
	active = nil
	owner.session:close()
	if native_closed then owner.view = nil end
	retiring = owner
	if not release(owner) then
		Logger.error(LOG, "The emulation picker retained native close ownership.")
		return false
	end
	retiring = nil
	Logger.info(LOG, "Emulation picker window closed.")
	return true
end

--- Delivers the session state only to its current native page.
--- @param owner table Window owner.
--- @param state table The session's page state.
--- @return boolean submitted
local function send(owner, state)
	if active ~= owner or not owner.view then return false end
	local view = owner.view
	local encoded_ok, encoded = pcall(hs.json.encode, state)
	if not encoded_ok or type(encoded) ~= "string" then
		Logger.error(LOG, "The emulation picker state could not be encoded.")
		return false
	end
	local accepted, receipt = pcall(function()
		return view:evaluateJavaScript(
			"if(window.receiveEmulationPicker)window.receiveEmulationPicker(" .. encoded .. ")",
			function(_, script_error)
				if WebviewResult.is_error(script_error) then
					Logger.error(LOG, "The emulation picker page refused its state.")
				end
			end)
	end)
	if not accepted or receipt ~= view then
		Logger.error(LOG, "The emulation picker state could not reach its page.")
		return false
	end
	return active == owner and owner.view == view
end

--- Opens or focuses the picker window.
--- @param options table { choices = function() -> choices, choose = function(id) -> committed }
--- @return boolean opened
function M.open(options)
	if retiring then
		if not release(retiring) then return false end
		retiring = nil
	end
	if active then
		local owner = active
		if not owner.view then return false end
		return ui_builder.force_focus(owner.view, false, { is_current = function() return active == owner end }) == true
	end
	Logger.start(LOG, "Opening the emulation picker…")
	local owner = { session = Session.new(options) }
	active = owner
	local ok, result = xpcall(function()
		local geometry = assert(ui_builder.get_app_geometry("emulation_picker"), "emulation picker geometry is missing")
		local screen = assert(hs.screen.mainScreen(), "the main screen is unavailable"):frame()
		local width, height = math.min(geometry.width, screen.w), math.min(geometry.height, screen.h)
		local frame = { x = screen.x + (screen.w - width) / 2, y = screen.y + (screen.h - height) / 2,
			w = width, h = height }
		owner.controller = assert(hs.webview.usercontent.new(BRIDGE), "emulation picker bridge creation failed")
		local callback_result = owner.controller:setCallback(function(message)
			if active ~= owner then return end
			local payload = type(message) == "table" and message.body or nil
			local handled, reply, close_window = xpcall(function() return owner.session:handle(payload) end,
				debug.traceback)
			if not handled then
				Logger.error(LOG, "An emulation picker request failed: %s.", tostring(reply))
				return
			end
			if close_window then close(owner); return end
			if type(reply) == "table" then send(owner, reply) end
		end)
		if callback_result == false then error("emulation picker bridge callback was refused") end
		local masks = assert(hs.webview.windowMasks, "native window styles are unavailable")
		return ui_builder.show_webview({
			delete_on_close = true,
			-- The factory names the window from the shared manifest and brands it once.
			frame = frame, app_id = Session.APP_ID,
			style_masks = masks.titled + masks.closable + masks.resizable,
			assets_dir = require("core.fs.engine.paths").shared("ui/" .. Session.APP_ID) .. "/",
			usercontent = owner.controller, allow_new_windows = false,
			is_current = function() return active == owner end,
			on_webview_created = function(view)
				owner.view = view
				return active == owner
			end,
			on_close = function() if active == owner then close(owner, true) end end,
		})
	end, debug.traceback)
	if not ok or not result or active ~= owner then
		if active == owner then close(owner) end
		Logger.error(LOG, "The emulation picker window could not open: %s.", tostring(result))
		return false
	end
	Logger.success(LOG, "Emulation picker window opened.")
	return true
end

return M
