--- modules/keylogger/context_tracker.lua

--- ==============================================================================
--- MODULE: Keylogger Context Tracker
--- DESCRIPTION:
--- Manages OS-level watchers like application switches, private browsing windows,
--- and native text substitutions via the Accessibility (AX) API.
---
--- FEATURES & RATIONALE:
--- 1. Context Awareness: Captures window titles and roles to tag events correctly.
--- 2. Autocorrect Detection: Isolates macOS text substitution events to prevent log errors.
--- ==============================================================================

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "keylogger.context_tracker"
local M      = {}

local _state = nil
local _log_manager = nil

local _last_focused_element = nil
local _last_ax_value        = ""





-- =======================================
-- =======================================
-- ======= 1/ Accessibility System =======
-- =======================================
-- =======================================

--- Callbacks for when the native text input modifies its buffer natively (Autocorrect).
--- @param element table The UI element firing the event.
--- @param event string The event name.
--- @param watcher table The AX observer instance.
--- @param user_data table Custom data.
local function handle_ax_value_changed(element, event, watcher, user_data)
	if event == "AXValueChanged" then
		local ok, val = pcall(function() return element:attributeValue("AXValue") end)
		if ok and type(val) == "string" then
			local now = hs.timer.absoluteTime() / 1000000
			
			-- If the value changed significantly but no physical keys were pressed in the last 100ms
			-- it is highly likely macOS triggered a native text replacement or autocorrect
			if (now - _state.last_time) > 100 and #val > 0 and #_last_ax_value > 0 and math.abs(#val - #_last_ax_value) > 1 then
				Logger.debug(LOG, string.format("System autocorrect detected for app: %s.", _state.session_app_name))
				_log_manager.flush_buffer()
				_log_manager.append_log({
					type  = "sys_autocorrect",
					tag   = "<sys_autocorrect_detected>",
					app   = _state.session_app_name,
					title = _state.session_win_title
				})
			end
			
			_last_ax_value = val
		end
	end
end

--- Hooks the accessibility observer to the new active application.
--- @param app_pid number The Process ID of the active application.
function M.update_ax_observer(app_pid)
	if _state.ax_observer then
		Logger.debug(LOG, "Stopping previous accessibility observer…")
		_state.ax_observer:stop()
		_state.ax_observer = nil
	end
	if not app_pid then return end
	
	Logger.debug(LOG, string.format("Starting accessibility observer for PID %s…", tostring(app_pid)))
	_state.ax_observer = hs.axuielement.observer.new(app_pid)
	if _state.ax_observer then
		local app_element = hs.axuielement.applicationElement(app_pid)
		if app_element then
			_state.ax_observer:addWatcher(app_element, "AXFocusedUIElementChanged")
			
			-- Instantly hook the currently focused sub-element
			local focused = app_element:attributeValue("AXFocusedUIElement")
			if focused then
				pcall(function() _state.ax_observer:addWatcher(focused, "AXValueChanged") end)
			end
		end
		
		_state.ax_observer:callback(function(element, event, watcher, user_data)
			if event == "AXFocusedUIElementChanged" then
				if _last_focused_element then
					pcall(function() watcher:removeWatcher(_last_focused_element, "AXValueChanged") end)
				end
				_last_focused_element = element
				if element then
					pcall(function() watcher:addWatcher(element, "AXValueChanged") end)
					local ok, val = pcall(function() return element:attributeValue("AXValue") end)
					if ok and type(val) == "string" then _last_ax_value = val end
				end
			elseif event == "AXValueChanged" then
				handle_ax_value_changed(element, event, watcher, user_data)
			end
		end)
		
		_state.ax_observer:start()
		Logger.info(LOG, "Accessibility observer started successfully.")
	end
end





-- =======================================
-- =======================================
-- ======= 2/ Application Switches =======
-- =======================================
-- =======================================

--- Checks if focused browser is in incognito mode.
function M.update_private_status()
	local win = hs.window.focusedWindow()
	_state.is_private_window = false
	if win then
		local title = win:title()
		local keywords = { "Navigation privée", "Private Browsing", "Incognito", "InPrivate", "Anonymous" }
		for _, kw in ipairs(keywords) do
			if title:find(kw) then _state.is_private_window = true break end
		end
	end
end

--- Watches for application context switches.
--- @param app_name string The name of the application.
--- @param event_type number The application event type.
--- @param app_object table The hs.application object.
function M.app_watcher_cb(app_name, event_type, app_object)
	if event_type == hs.application.watcher.activated and app_object then
		_state.active_app_bundle = app_object:bundleID()
		_state.active_app_path   = app_object:path()
		_state.active_app_pid    = app_object:pid()
		M.update_private_status()
		M.update_ax_observer(_state.active_app_pid)
	end
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Mounts the shared state and submodules.
--- @param core_state table The shared state object.
--- @param log_manager_mod table The log manager module reference.
function M.init(core_state, log_manager_mod)
	Logger.debug(LOG, "Initializing context tracker dependencies…")
	_state = core_state
	_log_manager = log_manager_mod
	Logger.info(LOG, "Context tracker initialized successfully.")
end

return M
