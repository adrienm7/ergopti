--- ui/physical_shortcuts/init.lua

--- Native WebView ownership for the shared physical shortcut editor.
local M = {}
local hs = hs
local Window = require("shortcuts.physical_editor_window")
local Slots = require("shortcuts.physical_slots")
local PhysicalAvailability = require("shortcuts.physical_availability")
local Json = require("json")
local JsonCodec = require("adapters.json_codec")
local Paths = require("infra.paths")
local Files = require("adapters.file_system")
local I18n = require("infra.i18n")
local ui_builder = require("ui.ui_builder")
local Logger = require("infra.logger")
local active = nil

--- Checks the native window constructor and declared geometry without input capture.
--- @return boolean available
function M.native_available()
	return type(hs) == "table" and type(hs.webview) == "table" and type(hs.webview.usercontent) == "table"
		and type(hs.webview.usercontent.new) == "function" and ui_builder.get_app_geometry("physical_shortcuts") ~= nil
end

--- Reads the driver's native delivery capability without creating a scope or window.
--- @return boolean available Strict physical source/output acknowledgement.
function M.physical_delivery_available()
	local keyboard = require("modules.shortcuts.keyboard_shortcuts")
	return PhysicalAvailability.ready(keyboard.physical_delivery_available)
end

--- Requires actual native source/publication methods rather than browser state.
--- @param scope table Existing menu shortcut-scope owner.
--- @return boolean available
function M.available(scope)
	if type(scope) ~= "table" then return false end
	for _, name in ipairs({ "capture_editor_inventory", "editor_source_current", "edit", "physical_delivery_available" }) do
		if type(scope[name]) ~= "function" then return false end
	end
	return PhysicalAvailability.ready(scope.physical_delivery_available) and M.native_available()
end

local function close(candidate)
	if active ~= candidate or candidate.closing or candidate.constructing then return false end
	candidate.closing = true
	candidate.cancelled = true
	if candidate.window then candidate.window.retire() end
	local called, acknowledged = pcall(function()
		if candidate.webview then
			if getmetatable(candidate.webview) ~= nil then
				local removed = candidate.webview:delete(0)
				if removed ~= nil then return false end
			end
		end
		return candidate.webview == nil or getmetatable(candidate.webview) == nil
	end)
	called = called and acknowledged == true
	if called then candidate.webview = nil end
	if called and candidate.bridge then
		local detached, accepted = pcall(function() return candidate.bridge:setCallback(nil) end)
		called = detached and accepted == candidate.bridge
		if called then candidate.bridge = nil end
	end
	candidate.closing = false
	if not called then
		Logger.error("ui.physical_shortcuts", "Physical shortcut window close refused; exact native owner retained.")
		return false
	end
	if active == candidate then active = nil end
	if candidate.window then candidate.window.retire() end
	return true
end

--- Opens the shared form through existing native geometry and action picker owners.
--- @param options table Existing scope and gesture facade.
--- @return boolean opened
function M.open(options)
	if type(options) ~= "table" or not M.available(options.scope) or type(options.gestures) ~= "table" then return false end
	if active and close(active) ~= true then return false end
	local keycodes, decode_error = JsonCodec.decode(assert(Files.read(Paths.shared("data/keycodes/physical_keys.json"))))
	if decode_error ~= nil or type(keycodes) ~= "table" then return false end
	local model = Slots.new(keycodes)
	local positions = {}
	for _, code in ipairs(model.candidates("hs")) do
		local slot = model.encode(code)
		local native = model.stable_native_code(slot,"hs")
		local available = native ~= nil and model.key_group(slot) ~= "media"
		positions[#positions + 1] = {code=code,available=available,
			reason=not available and I18n.get("physical_shortcuts.position_unavailable") or nil}
	end
	local scope, gestures = options.scope, options.gestures
	local candidate = { constructing = true, webview = nil, closing = false }
	active = candidate
	local function current() return active == candidate and not candidate.closing and not candidate.cancelled end
	local function send(name,packet)
		if not current() or candidate.webview == nil then return false end
		local called, accepted = pcall(function() return candidate.webview:evaluateJavaScript(name.."("..Json.encode(packet)..")") end)
		return called and accepted ~= false and current()
	end
	candidate.window = Window.new({model=model,catalogue=gestures,parameter_section="gestures.action_parameters",
		positions=positions,translate=I18n.get,label=gestures.get_action_label,page_current=current,send=send,
		capture=scope.capture_editor_inventory,current=scope.editor_source_current,
		commit=function(rows,receipt) return scope.edit(rows,receipt) end,
		close=function() return close(candidate) end,
		picker=function(binding,action,on_confirm)
			local items = require("ui.menu.menu_keyboard_slots").build_action_items(gestures)
			local fields = require("ui.menu.shortcut_utils").picker_parameter_fields(gestures,items,binding)
			fields.title, fields.current, fields.items = I18n.get("physical_shortcuts.window_title"),action,items
			return require("ui.action_picker").open(fields,function(id,parameter)
				local spec = gestures.get_action_parameter_spec(id)
				if spec and parameter == nil then
					parameter = require("ui.menu.shortcut_utils").ask_parameter_value(gestures,id,spec,
						I18n.get("physical_shortcuts.window_title"),gestures.get_action_parameter(binding,id))
				end
				return on_confirm(id,parameter)
			end)
		end,
	})
	local constructed, bridge = pcall(hs.webview.usercontent.new,"physical_shortcuts_bridge")
	if not constructed or bridge == nil or bridge == false then active = nil; candidate.window.retire(); return false end
	candidate.bridge = bridge
	local bound, accepted = pcall(function() return bridge:setCallback(function(message)
		if not current() or type(message) ~= "table" or type(message.body) ~= "table" then return end
		if candidate.constructing and message.body.action == "ready" then candidate.pending_ready = true; return end
		local called = pcall(candidate.window.receive,message.body)
		if not called then Logger.error("ui.physical_shortcuts", "Physical shortcut page request refused.") end
	end) end)
	if not bound or accepted ~= bridge then candidate.constructing = false; close(candidate); return false end
	local geometry = ui_builder.get_app_geometry("physical_shortcuts")
	if not geometry then candidate.constructing = false; close(candidate); return false end
	local called, view = pcall(ui_builder.show_webview,{frame=ui_builder.get_centered_frame(geometry.width,geometry.height),
		title=I18n.get("physical_shortcuts.window_title"),usercontent=bridge,assets_dir=Paths.shared("ui/physical_shortcuts").."/",
		style_masks={"titled","closable","resizable"},
		on_webview_created=function(view)
			if active ~= candidate or candidate.webview ~= nil then return false end
			candidate.webview = view
			return not candidate.cancelled
		end,
		is_current=function() return current() and not candidate.cancelled end,
		on_close=function()
			if candidate.closing then return end
			candidate.cancelled = true
			candidate.window.retire()
			if not candidate.constructing and active == candidate then close(candidate) end
		end,
	})
	candidate.constructing = false
	if candidate.webview == nil and called and view ~= nil and view ~= false then candidate.webview = view end
	if not called or view == nil or view == false or candidate.cancelled then
		candidate.window.retire()
		if close(candidate) ~= true then return false end
		return false
	end
	if candidate.pending_ready then candidate.window.receive({action="ready"}) end
	return current()
end

--- Closes only the retained native editor; failed deletion blocks a successor.
--- @return boolean closed
function M.close() return active == nil or close(active) end
return M
