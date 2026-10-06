--- ui/physical_shortcuts/bridge.lua

--- Native WebKit routing for the shared physical shortcut editor.
local M = { bridge_name = "physical_shortcuts_bridge" }
local Window = require("shortcuts.physical_editor_window")
local Slots = require("shortcuts.physical_slots")
local PhysicalAvailability = require("shortcuts.physical_availability")
local Json = require("json")
local Paths = require("infra.paths")
local I18n = require("infra.i18n")
local Logger = require("logger.shim")
local session = nil
local APP = "physical_shortcuts"

--- Reads the existing manager's acknowledged native initialization state.
--- @return boolean available
function M.native_available()
	local Manager = require("ui.webview_manager")
	return type(Manager.native_available) == "function" and Manager.native_available() == true
end

--- Reads the driver's native delivery capability without creating a scope or window.
--- @return boolean available Strict physical source/output acknowledgement.
function M.physical_delivery_available()
	local keyboard = require("modules.shortcuts.keyboard_shortcuts")
	return PhysicalAvailability.ready(keyboard.physical_delivery_available)
end

--- Checks the actual source/publication owner before opening a native window.
--- @param scope table Existing native shortcut-scope owner.
--- @return boolean available
function M.available(scope)
	if type(scope) ~= "table" then return false end
	for _, name in ipairs({ "capture_editor_inventory", "editor_source_current", "edit", "physical_delivery_available" }) do
		if type(scope[name]) ~= "function" then return false end
	end
	return PhysicalAvailability.ready(scope.physical_delivery_available) and M.native_available()
end

--- Opens one shared form over the existing acknowledged native scope.
--- @param options table Scope owner and live pause getter.
--- @return boolean opened
function M.open(options)
	if type(options) ~= "table" or type(options.is_paused) ~= "function" or options.is_paused() ~= false
		or not M.available(options.scope) then return false end
	if session ~= nil and M.close() ~= true then return false end
	local Manager = require("ui.webview_manager")
	local Gestures = require("modules.gestures.manager")
	local registry = assert(io.open(assert(Paths.shared("data/keycodes/physical_keys.json")), "r"))
	local bytes = registry:read("*a"); registry:close()
	local model = Slots.new(Json.decode(bytes))
	local positions = {}
	for _, code in ipairs(model.candidates("evdev")) do positions[#positions + 1] = { code = code, available = true } end
	local scope, candidate = options.scope, { epoch = nil, constructing = true }
	session = candidate
	local function current()
		return session == candidate and not candidate.cancelled and candidate.epoch ~= nil
			and Manager.current_epoch(APP) == candidate.epoch
			and Manager.page_current(APP,candidate.epoch) == true
	end
	local function send(name, packet)
		if not current() then return false end
		return Manager.eval_js(APP, name .. "(" .. Json.encode(packet) .. ")") == true and current()
	end
	candidate.window = Window.new({model=model,catalogue=Gestures,parameter_section="gesture_parameters",
		positions=positions,translate=I18n.get,label=Gestures.get_action_label,
		page_current=current,send=send,capture=scope.capture_editor_inventory,current=scope.editor_source_current,
		commit=function(rows,receipt) return scope.edit(rows,receipt) end,
		close=function()
			if not current() or Manager.hide(APP,candidate.epoch) ~= true then return false end
			if session == candidate then session = nil end
			return true
		end,
		picker=function(binding,action,on_confirm)
			local items = Gestures.get_picker_items()
			local fields = Gestures.get_picker_parameter_fields(items,binding)
			fields.title, fields.current, fields.items = I18n.get("physical_shortcuts.window_title"), action, items
			return require("ui.action_picker.bridge").open(fields,function(id,_,parameter)
				local spec = Gestures.get_action_parameter_spec(id)
				if spec and parameter == nil then
					if spec == "app" then
						parameter = require("ui.app_chooser").pick(require("adapters.shell_runner"),Gestures.get_action_parameter_prompt(id))
					else
						parameter = require("ui.text_prompt").ask(I18n.get("physical_shortcuts.window_title"),
							Gestures.get_action_parameter_prompt(id),Gestures.get_action_parameter(binding,id))
					end
				end
				return on_confirm(id,parameter)
			end)
		end,
	})
	local called, opened = pcall(Manager.show,APP)
	candidate.constructing = false
	if not called or opened ~= true then
		candidate.cancelled = true
		candidate.window.retire()
		if session == candidate and (candidate.epoch == nil or Manager.current_epoch(APP) ~= candidate.epoch) then session = nil end
		Logger.error("ui.physical_shortcuts", "Physical shortcut window acquisition refused.")
		return false
	end
	candidate.epoch = candidate.epoch or Manager.current_epoch(APP)
	if candidate.cancelled then candidate.window.retire(); if session == candidate then session = nil end; return false end
	if candidate.pending_ready then candidate.window.receive({action="ready"}) end
	return current()
end

--- Routes only the still-owned page epoch; JSON fields carry no source authority.
--- @param payload table|string Shared form message.
--- @param state table Daemon state; publication belongs to the retained scope.
--- @param context table Trusted native page identity and epoch.
--- @return boolean handled
function M.on_message(payload,state,context)
	local candidate = session
	if not candidate or candidate.cancelled or type(context) ~= "table" or context.app_name ~= APP then return false end
	local Manager = require("ui.webview_manager")
	if context.epoch == nil or context.epoch ~= Manager.current_epoch(APP) then return false end
	if candidate.epoch == nil and candidate.constructing then candidate.epoch = context.epoch end
	if candidate.epoch ~= context.epoch then return false end
	local message = type(payload) == "string" and Json.decode(payload) or payload
	if candidate.constructing then
		if type(message) == "table" and message.action == "ready" then candidate.pending_ready = true; return true end
		return false
	end
	return candidate.window.receive(message)
end
--- Retries only the retained exact native page cleanup before a successor.
--- @return boolean closed Native destruction and input release both acknowledged.
function M.close()
	local candidate = session
	if not candidate then return true end
	if candidate.constructing or candidate.epoch == nil then return false end
	local Manager = require("ui.webview_manager")
	local called, accepted = pcall(Manager.hide, APP, candidate.epoch)
	if not called or accepted ~= true then return false end
	candidate.window.retire()
	if session == candidate then session = nil end
	return true
end

--- Adopts the exact Manager page epoch before its native constructor callbacks.
--- @param epoch number Trusted reserved page identity.
--- @return boolean acquired
function M.on_window_acquiring(epoch)
	local candidate = session
	local Manager = require("ui.webview_manager")
	if not candidate or not candidate.constructing or candidate.epoch ~= nil
		or epoch ~= Manager.current_epoch(APP) then return false end
	candidate.epoch = epoch
	return true
end

--- Revokes only the native page epoch reported by the actual WebKit manager.
--- @param epoch number Closed page identity.
function M.on_window_closed(epoch)
	local candidate = session
	if not candidate or candidate.epoch ~= epoch then return end
	candidate.cancelled = true
	candidate.window.retire()
	if not candidate.constructing and session == candidate then session = nil end
end
return M
