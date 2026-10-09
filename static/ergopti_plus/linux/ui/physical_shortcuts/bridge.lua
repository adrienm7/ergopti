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
	local Hook = require("adapters.keyboard_hook")
	local capture_position, cancel_position, position_available = rawget(Hook, "capture_position"),
		rawget(Hook, "cancel_position"), rawget(Hook, "position_capture_available")
	local current_epoch, page_current = rawget(Manager, "current_epoch"), rawget(Manager, "page_current")
	local eval_js = rawget(Manager, "eval_js")
	local pause_current = options.is_paused
	local registry = assert(io.open(assert(Paths.shared("data/keycodes/physical_keys.json")), "r"))
	local bytes = registry:read("*a"); registry:close()
	local model = Slots.new(Json.decode(bytes))
	local positions = {}
	for _, code in ipairs(model.candidates("evdev")) do positions[#positions + 1] = { code = code, available = true } end
	local scope, candidate = options.scope, { epoch = nil, constructing = true,
		manager = Manager, current_epoch = current_epoch, page_current = page_current }
	session = candidate
	local function page_owner()
		return rawequal(package.loaded["ui.webview_manager"], Manager)
			and rawget(Manager, "current_epoch") == current_epoch and rawget(Manager, "page_current") == page_current
			and type(eval_js) == "function" and rawget(Manager, "eval_js") == eval_js
			and session == candidate and not candidate.cancelled and candidate.epoch ~= nil
	end
	local function current()
		if not page_owner() then return false end
		local epoch = candidate.epoch
		local seen, observed = pcall(current_epoch, APP)
		if not seen or observed ~= epoch or not page_owner() then return false end
		local called, acknowledged = pcall(page_current, APP, epoch)
		if not called or acknowledged ~= true or not page_owner() then return false end
		local reread, final = pcall(current_epoch, APP)
		return reread and final == epoch and page_owner() and candidate.epoch == epoch
	end
	local function observation_current()
		if not current() or rawget(options, "is_paused") ~= pause_current then return false end
		local called, paused = pcall(pause_current)
		return called and paused == false and current() and rawget(options, "is_paused") == pause_current
			and rawequal(package.loaded["adapters.keyboard_hook"], Hook)
			and rawget(Hook, "capture_position") == capture_position
			and rawget(Hook, "cancel_position") == cancel_position
			and rawget(Hook, "position_capture_available") == position_available
	end
	local function retire_observation()
		if candidate.position == nil then return true end
		if candidate.position_retiring then return false end
		local token = candidate.position
		candidate.position_retiring = true
		local called, retired = pcall(cancel_position, token)
		candidate.position_retiring = false
		if not called or retired ~= true or not rawequal(candidate.position, token) then return false end
		candidate.position = nil
		return true
	end
	candidate.retire_observation = retire_observation
	local function send(name, packet)
		if not current() then return false end
		local script = name .. "(" .. Json.encode(packet) .. ")"
		-- Serialization and page getters may revoke or replace the original port.
		if not current() then return false end
		local called, sent = pcall(eval_js, APP, script)
		return called and sent == true and current()
	end
	candidate.window = Window.new({model=model,catalogue=Gestures,parameter_section="gesture_parameters",
		positions=positions,translate=I18n.get,label=Gestures.get_action_label,position_field="evdev",
		page_current=current,send=send,capture=scope.capture_editor_inventory,current=scope.editor_source_current,
		commit=function(rows,receipt) return scope.edit(rows,receipt) end,
		position_available=function()
			if not observation_current() or type(position_available) ~= "function" then return false end
			local called, available = pcall(position_available)
			return called and available == true and observation_current()
		end,
		capture_position=function(guard, receive)
			if not observation_current() or retire_observation() ~= true or type(capture_position) ~= "function" then return nil end
			local function exact() return observation_current() and guard() == true and observation_current() end
			local called, token = pcall(capture_position, exact, function(facts)
				return exact() and receive(facts) == true and exact()
			end)
			if not called or type(token) ~= "table" then return nil end
			candidate.position = token
			if not exact() then retire_observation(); return nil end
			return token
		end,
		cancel_position=function(token)
			if candidate.position ~= nil and not rawequal(token, candidate.position) then return false end
			if candidate.position == nil then
				local called, retired = pcall(cancel_position, token)
				return called and retired == true
			end
			return retire_observation()
		end,
		close=function()
			if retire_observation() ~= true or not current() or Manager.hide(APP,candidate.epoch) ~= true then return false end
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
	local Manager = package.loaded["ui.webview_manager"]
	if not rawequal(Manager, candidate.manager) or rawget(Manager, "current_epoch") ~= candidate.current_epoch
		or rawget(Manager, "page_current") ~= candidate.page_current then return false end
	if context.epoch == nil or context.epoch ~= candidate.current_epoch(APP) then return false end
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
	if candidate.retire_observation() ~= true then return false end
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
	if candidate.retire_observation() ~= true then return end
	candidate.window.retire()
	if not candidate.constructing and session == candidate then session = nil end
end
return M
