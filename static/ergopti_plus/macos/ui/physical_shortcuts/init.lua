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
local TimerScheduler = require("adapters.timer_scheduler")
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

local close
local schedule_native_retirement
local NATIVE_RETIREMENT_POLL_SECONDS = 0.05

--- Observes native consumption without requiring another closing notification.
--- The one-shot callback and its exact stop acknowledgement are independent:
--- either can arrive first, but neither alone releases the original bridge.
--- @param candidate table Exact native/editor owner being retired.
--- @param delay number|nil Delay after a previous observation, or zero initially.
--- @return boolean scheduled
schedule_native_retirement = function(candidate, delay)
	if candidate.retirement_timer ~= nil or candidate.retirement_arming or candidate.retirement_uncertain then return false end
	candidate.retirement_arming = true
	local delivered, settled = false, false
	local function finish()
		if candidate.retirement_arming or not delivered or not settled then return end
		if active ~= candidate then return end
		if candidate.webview ~= nil and getmetatable(candidate.webview) ~= nil then
			-- A timer may precede the fade. Reobserve only after this exact
			-- delivery and native stop have both committed; never replay delete.
			schedule_native_retirement(candidate, NATIVE_RETIREMENT_POLL_SECONDS)
		else close(candidate) end
	end
	local ok, committed = xpcall(function()
		local handle, accepted = TimerScheduler.after(delay or 0, function()
			delivered = true
			finish()
		end)
		candidate.retirement_timer = handle
		assert(TimerScheduler.onSettled(handle, function()
			settled = true
			if candidate.retirement_timer == handle then candidate.retirement_timer = nil end
			finish()
		end) == true, "physical shortcut timer settlement observer refused")
		return accepted
	end, debug.traceback)
	candidate.retirement_arming = false
	if not ok then candidate.retirement_uncertain = true end
	if not ok or committed ~= true then
		pcall(Logger.error, "ui.physical_shortcuts", "Physical shortcut deferred retirement refused; exact owner retained: %s.",
			tostring(committed))
		return false
	end
	return true
end

close = function(candidate)
	if active ~= candidate or candidate.closing or candidate.constructing
		or candidate.retirement_arming
		or candidate.retirement_timer ~= nil or candidate.retirement_uncertain then return false end
	candidate.closing = true
	candidate.cancelled = true
	if candidate.retire_observation and candidate.retire_observation() ~= true then
		pcall(Logger.error, "ui.physical_shortcuts", "Physical position cancellation refused; exact owner retained.")
		candidate.closing = false
		return false
	end
	if candidate.window then
		local retired, acknowledged = pcall(candidate.window.retire)
		if not retired or acknowledged ~= true then
			pcall(Logger.error, "ui.physical_shortcuts", "Physical shortcut editor retirement refused; exact owner retained.")
			candidate.closing = false
			return false
		end
	end
	local native_delete_attempted = false
	local called, acknowledged = pcall(function()
		if candidate.webview then
			if getmetatable(candidate.webview) ~= nil then
				if candidate.native_delete_pending then return false end
				local delete = candidate.webview.delete
				-- The public wrapper schedules a native fade even for zero delay.
				-- Any closing callback precedes the fade consuming udRef. Retain
				-- that exact request before crossing a possibly mutating boundary.
				candidate.native_delete_pending = true
				native_delete_attempted = true
				local removed = delete(candidate.webview, 0)
				if removed ~= nil then return false end
				candidate.native_delete_accepted = true
			end
		end
		return candidate.webview == nil or getmetatable(candidate.webview) == nil
	end)
	if not called then
		pcall(Logger.error, "ui.physical_shortcuts", "Physical shortcut native deletion raised; exact ownership retained or observed consumed: %s.",
			tostring(acknowledged))
	end
	-- Metadata consumption remains authoritative even if a wrapper raised after
	-- native GC; indexing that userdata or reissuing delete would be unsafe.
	called = (called and acknowledged == true)
		or (candidate.webview ~= nil and getmetatable(candidate.webview) == nil)
	if called then candidate.webview = nil end
	if called and candidate.bridge then
		local detached, accepted = pcall(function() return candidate.bridge:setCallback(nil) end)
		called = detached and accepted == candidate.bridge
		if called then candidate.bridge = nil end
	end
	if not called then
		if native_delete_attempted and candidate.webview ~= nil and getmetatable(candidate.webview) ~= nil then
			-- Public delete may consume an already closed window without another
			-- notification. Ownership observation belongs to the request itself.
			schedule_native_retirement(candidate)
		end
		-- A nil return acknowledges the public fade request, not its completion.
		-- Keep admission closed while that owner runs without reporting a failure.
		if candidate.native_delete_accepted == true and candidate.webview ~= nil
			and getmetatable(candidate.webview) ~= nil then
			candidate.closing = false
			return false
		end
		pcall(Logger.error, "ui.physical_shortcuts", "Physical shortcut window close refused; exact native owner retained.")
		candidate.closing = false
		return false
	end
	candidate.closing = false
	if active == candidate then active = nil end
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
	-- An optional observer must already belong to the running capture owner.
	-- Requiring it here would create a dormant producer instead of observing one.
	local Capture = package.loaded["modules.keylogger.physical_capture"]
	local capture_position, cancel_position, position_available
	if type(Capture) == "table" then
		capture_position, cancel_position, position_available = rawget(Capture, "capture_position"),
			rawget(Capture, "cancel_position"), rawget(Capture, "position_available")
	end
	local candidate = { constructing = true, webview = nil, closing = false }
	active = candidate
	local function current() return active == candidate and not candidate.closing and not candidate.cancelled end
	local function observation_current()
		return current() and not candidate.constructing and candidate.webview ~= nil
			and type(Capture) == "table" and rawequal(package.loaded["modules.keylogger.physical_capture"], Capture)
			and type(capture_position) == "function" and rawget(Capture, "capture_position") == capture_position
			and type(cancel_position) == "function" and rawget(Capture, "cancel_position") == cancel_position
			and type(position_available) == "function" and rawget(Capture, "position_available") == position_available
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
	local function available_position()
		if not observation_current() then return false end
		local called, available = pcall(position_available)
		return called and available == true and observation_current()
	end
	local function stable_position(facts)
		if type(facts) ~= "table" or getmetatable(facts) ~= nil or type(facts.native_code) ~= "number"
			or type(facts.mods) ~= "table" or getmetatable(facts.mods) ~= nil then return false end
		for field in pairs(facts) do if field ~= "native_code" and field ~= "mods" then return false end end
		for name, held in pairs(facts.mods) do
			if type(name) ~= "string" or type(held) ~= "boolean" then return false end
		end
		local code = model.code_for(facts.native_code, "hs")
		local slot = code and model.encode(code, facts.mods)
		return slot ~= nil and model.stable_native_code(slot, "hs") == facts.native_code and model.key_group(slot) ~= "media"
	end
	local function send(name,packet)
		if not current() or candidate.webview == nil then return false end
		local called, accepted = pcall(function() return candidate.webview:evaluateJavaScript(name.."("..Json.encode(packet)..")") end)
		return called and accepted ~= false and current()
	end
	local window_constructed, window = pcall(function()
		return Window.new({model=model,catalogue=gestures,parameter_section="gestures.action_parameters",
			positions=positions,translate=I18n.get,label=gestures.get_action_label,page_current=current,send=send,
				position_field="hs",position_available=available_position,
				capture_position=function(guard, receive)
					if not observation_current() or retire_observation() ~= true or not available_position() then return nil end
					-- Availability is false during an enrolled request. Its original
					-- producer retains native session/baseline authority; this joins page/source.
					local function exact() return observation_current() and guard() == true and observation_current() end
					local called, token = pcall(capture_position, exact, function(facts)
						return exact() and stable_position(facts) and exact() and receive(facts) == true and exact()
					end)
					if not called or type(token) ~= "table" then return nil end
					candidate.position = token
					if not exact() then retire_observation(); return nil end
					return token
				end,
				cancel_position=function(token)
					if candidate.position ~= nil and not rawequal(token, candidate.position) then return false end
					if candidate.position ~= nil then return retire_observation() end
					local called, retired = pcall(cancel_position, token)
					return called and retired == true
				end,
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
	end)
	if not window_constructed or type(window) ~= "table" then
		candidate.constructing = false
		close(candidate)
		return false
	end
	candidate.window = window
	local constructed, bridge = pcall(hs.webview.usercontent.new,"physical_shortcuts_bridge")
	if not constructed or bridge == nil or bridge == false then
		candidate.constructing = false
		close(candidate)
		return false
	end
	candidate.bridge = bridge
	local bound, accepted = pcall(function() return bridge:setCallback(function(message)
		if not current() or type(message) ~= "table" or type(message.body) ~= "table" then return end
		if candidate.constructing and message.body.action == "ready" then candidate.pending_ready = true; return end
		local called = pcall(candidate.window.receive,message.body)
		if not called then Logger.error("ui.physical_shortcuts", "Physical shortcut page request refused.") end
	end) end)
	if not bound or accepted ~= bridge then candidate.constructing = false; close(candidate); return false end
	local called, view = pcall(function()
		local geometry = ui_builder.get_app_geometry("physical_shortcuts")
		if not geometry then return nil end
		return ui_builder.show_webview({frame=ui_builder.get_centered_frame(geometry.width,geometry.height),
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
				if not candidate.constructing and active == candidate and not candidate.native_delete_pending then
					close(candidate)
				end
			end,
		})
	end)
	candidate.constructing = false
	if candidate.webview == nil and called and view ~= nil and view ~= false then candidate.webview = view end
	if not called or view == nil or view == false or candidate.cancelled then
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
