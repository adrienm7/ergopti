--- ui/config_cleanup/init.lua

--- Presents the shared configuration cleanup session in an owned WebView.
local M = {}
local Logger = require("infra.logger")
local ui_builder = require("ui.ui_builder")
local Session = require("config_cleanup_session")
local LOG = "config_cleanup"
local BRIDGE = "config_cleanup_bridge"
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
		Logger.error(LOG, "Configuration cleanup retained native close ownership.")
		return false
	end
	retiring = nil
	Logger.info(LOG, "Configuration cleanup window closed.")
	return true
end

--- Delivers a controller result only to its current native page.
--- @param owner table Window owner.
--- @param state table Host-owned cleanup state.
local function send(owner, state)
	if active ~= owner or not owner.view then return end
	local encoded = hs.json.encode(state)
	if type(encoded) ~= "string" then error("cleanup state could not be encoded") end
	if type(state.keys) == "table" and next(state.keys) == nil then
		encoded = encoded:gsub('"keys"%s*:%s*%{%}', '"keys":[]', 1)
	end
	owner.token = state.session
	owner.view:evaluateJavaScript("if(window.receiveConfigCleanup)window.receiveConfigCleanup(" .. encoded .. ")")
end

--- Opens or focuses the cleanup page without performing a scan or deletion.
--- @param options table Trusted path, collector, file adapter and removal callback.
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
	Logger.start(LOG, "Opening configuration cleanup…")
	local owner = { session = Session.new(options) }
	active = owner
	local ok, result = xpcall(function()
		local geometry = assert(ui_builder.get_app_geometry("config_cleanup"), "configuration cleanup geometry is missing")
		local screen = assert(hs.screen.mainScreen(), "the main screen is unavailable"):frame()
		local width, height = math.min(geometry.width, screen.w), math.min(geometry.height, screen.h)
		local frame = { x = screen.x + (screen.w - width) / 2, y = screen.y + (screen.h - height) / 2,
			w = width, h = height }
		owner.controller = assert(hs.webview.usercontent.new(BRIDGE), "cleanup bridge creation failed")
		local callback_result = owner.controller:setCallback(function(message)
			if active ~= owner then return end
			local payload = type(message) == "table" and message.body or nil
			local accepted_close = type(payload) == "table" and payload.action == "close"
				and (payload.session == "" or (owner.token ~= nil and payload.session == owner.token))
			local handled, state = xpcall(function() return owner.session:handle(payload) end, debug.traceback)
			if not handled then
				Logger.error(LOG, "Configuration cleanup request failed: %s.", tostring(state))
				return
			end
			if accepted_close then close(owner); return end
			if type(state) == "table" then
				local pushed, detail = pcall(send, owner, state)
				if not pushed then Logger.error(LOG, "Configuration cleanup response failed: %s.", tostring(detail)) end
			end
		end)
		if callback_result == false then error("cleanup bridge callback was refused") end
		local masks = assert(hs.webview.windowMasks, "native window styles are unavailable")
		return ui_builder.show_webview({
			frame = frame, title = require("infra.i18n").get("dialog.unused_keys.title"),
			style_masks = masks.titled + masks.closable + masks.resizable,
			assets_dir = require("infra.paths").shared("ui/config_cleanup") .. "/",
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
		Logger.error(LOG, "Configuration cleanup window could not open: %s.", tostring(result))
		return false
	end
	Logger.success(LOG, "Configuration cleanup window opened.")
	return true
end

return M
