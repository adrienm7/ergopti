--- modules/keylogger/context_tracker.lua

--- ==============================================================================
--- MODULE: Keylogger Context Tracker
--- DESCRIPTION:
--- Manages OS-level watchers for application switches, private browsing
--- detection, secure text field detection, and native autocorrect events
--- via the macOS Accessibility (AX) API.
---
--- FEATURES & RATIONALE:
--- 1. Context Awareness: Tags every event batch with app name, window title,
---    document path, and field role for deep work categorization.
--- 2. Secure Field Guard: Detects password inputs and sets a persistent flag
---    so the engine never logs keystrokes from secure text fields.
--- 3. Autocorrect Detection: Intercepts native macOS text substitutions to
---    prevent them from corrupting the N-gram index.
--- 4. Time Tracking: Timestamps every app switch for per-app time accounting.
--- 5. Intra-App Tracking: Records tab and window title changes within the
---    same application for fine-grained context data.
--- ==============================================================================

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "keylogger.context_tracker"
local M      = {}

local _state       = nil
local _log_manager = nil

-- Tracks the last focused AX element so watchers can be removed on focus change
local _last_focused_element = nil
-- Tracks the last known AX text value to detect autocorrect jumps
local _last_ax_value        = ""
-- Tracks previous window title for intra-app window-switch logging
local _last_win_title       = nil
local _last_win_time        = 0

-- Incognito / private browsing window title keywords across all major browsers
local PRIVATE_KEYWORDS = {
	"Navigation privée", "Private Browsing", "Incognito",
	"InPrivate", "Anonymous",
}




-- =======================================
-- =======================================
-- ======= 1/ Guard And Validation =======
-- =======================================
-- =======================================

--- Guards every public function against being called before M.init().
--- @param func_name string The calling function name for the error message.
--- @return boolean False if state is not ready, true otherwise.
local function require_state(func_name)
	if not _state or not _log_manager then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end




-- =========================================
-- =========================================
-- ======= 2/ Accessibility Observers =======
-- =========================================
-- =========================================

--- Inspects a focused UI element and updates the secure-field flag on CoreState.
--- Called whenever the focused element changes so the engine can stop logging
--- immediately when a password field receives focus.
--- @param element table The newly focused AX element (may be nil).
local function update_secure_field_state(element)
	if not element then
		_state.is_secure_field = false
		return
	end
	local ok_role,    role    = pcall(function() return element:attributeValue("AXRole") end)
	local ok_subrole, subrole = pcall(function() return element:attributeValue("AXSubrole") end)
	local is_secure = (ok_role    and role    == "AXSecureTextField")
	               or (ok_subrole and subrole == "AXSecureTextField")
	if is_secure ~= _state.is_secure_field then
		_state.is_secure_field = is_secure
		if is_secure then
			-- Discard any buffered input that may have been captured before detection
			_state.buffer_events = {}
			_state.buffer_text   = ""
			_state.rich_chunks   = {}
			Logger.debug(LOG, "Secure text field detected — buffer cleared, logging suppressed.")
		else
			Logger.debug(LOG, "Focus moved away from secure field — logging resumed.")
		end
	end
end

--- Handles AXValueChanged events to detect macOS native autocorrect substitutions.
--- A sudden large delta in the field's text value (without matching keystrokes)
--- signals a native substitution; we flush the buffer and log the event.
--- @param element table The AX element whose value changed.
local function handle_ax_value_changed(element)
	local ok, val = pcall(function() return element:attributeValue("AXValue") end)
	if not (ok and type(val) == "string") then return end

	local now = hs.timer.absoluteTime() / 1000000
	-- Only act if: more than 100 ms since last keystroke, both values non-empty,
	-- and the change is larger than 1 character (single-char changes are normal typing)
	if (now - _state.last_time) > 100
	and #val > 0
	and #_last_ax_value > 0
	and math.abs(#val - #_last_ax_value) > 1
	then
		Logger.debug(LOG, "Native autocorrect detected in '%s' — flushing buffer.", _state.session_app_name)
		_log_manager.flush_buffer()
		_log_manager.append_log({
			type  = "sys_autocorrect",
			tag   = "<sys_autocorrect_detected>",
			app   = _state.session_app_name,
			title = _state.session_win_title,
		})
	end

	_last_ax_value = val
end

--- Attaches accessibility observers to the newly active application.
--- Observes focus changes (to detect secure fields) and value changes
--- (to detect native autocorrect substitutions).
--- @param app_pid number The Process ID of the new foreground application.
function M.update_ax_observer(app_pid)
	if not require_state("update_ax_observer") then return end

	-- Tear down any existing observer before attaching a new one
	if _state.ax_observer then
		Logger.trace(LOG, "Stopping previous accessibility observer…")
		pcall(function() _state.ax_observer:stop() end)
		_state.ax_observer = nil
		_last_focused_element = nil
		_last_ax_value = ""
		Logger.done(LOG, "Previous accessibility observer stopped.")
	end

	if not app_pid then return end

	Logger.trace(LOG, "Attaching accessibility observer to PID %s…", tostring(app_pid))

	local ok_new, observer = pcall(hs.axuielement.observer.new, app_pid)
	if not ok_new or not observer then
		Logger.warn(LOG, "Failed to create AX observer for PID %s.", tostring(app_pid))
		return
	end

	local ok_app, app_element = pcall(hs.axuielement.applicationElement, app_pid)
	if not ok_app or not app_element then
		Logger.warn(LOG, "Failed to get AX application element for PID %s.", tostring(app_pid))
		return
	end

	-- Watch for focus changes across the whole application
	pcall(function() observer:addWatcher(app_element, "AXFocusedUIElementChanged") end)

	-- Bootstrap: also watch the currently focused element for value changes
	local focused = app_element:attributeValue("AXFocusedUIElement")
	if focused then
		pcall(function() observer:addWatcher(focused, "AXValueChanged") end)
		local ok_val, val = pcall(function() return focused:attributeValue("AXValue") end)
		if ok_val and type(val) == "string" then _last_ax_value = val end
		update_secure_field_state(focused)
	end

	observer:callback(function(element, event, watcher, _)
		if event == "AXFocusedUIElementChanged" then
			-- Remove watcher from the old element before attaching to the new one
			if _last_focused_element then
				pcall(function() watcher:removeWatcher(_last_focused_element, "AXValueChanged") end)
			end
			_last_focused_element = element

			update_secure_field_state(element)

			if element then
				pcall(function() watcher:addWatcher(element, "AXValueChanged") end)
				local ok_val, val = pcall(function() return element:attributeValue("AXValue") end)
				if ok_val and type(val) == "string" then _last_ax_value = val end
			end
		elseif event == "AXValueChanged" then
			handle_ax_value_changed(element)
		end
	end)

	pcall(function() observer:start() end)
	_state.ax_observer = observer
	Logger.done(LOG, "Accessibility observer attached to PID %s.", tostring(app_pid))
end




-- ==========================================
-- ==========================================
-- ======= 3/ Application Switch Tracker =======
-- ==========================================
-- ==========================================

--- Checks whether the currently focused browser window is in private/incognito
--- mode, and captures window fullscreen state and document file path.
--- Called on every app switch and on browser window focus/title changes.
function M.update_private_status()
	if not require_state("update_private_status") then return end

	local win = hs.window.focusedWindow()
	_state.is_private_window    = false
	_state.is_fullscreen        = false
	_state.session_document_path = nil

	if not win then return end

	_state.is_fullscreen = win:isFullScreen()

	local title = win:title() or ""
	local now   = hs.timer.absoluteTime() / 1000000

	-- Log intra-app window switches (tab changes, new windows in the same app)
	if _last_win_title and _last_win_title ~= title and _state.active_app_name then
		local duration_ms = math.floor(now - _last_win_time)
		if duration_ms > 1000 then
			_log_manager.append_log({
				type        = "window_switch",
				app         = _state.active_app_name,
				prev_title  = _last_win_title,
				next_title  = title,
				duration_ms = duration_ms,
			})
			Logger.debug(LOG, "Window switch logged in '%s' (%d ms).", _state.active_app_name, duration_ms)
		end
	end
	_last_win_title = title
	_last_win_time  = now

	-- Check for private/incognito mode keywords in the window title
	for _, keyword in ipairs(PRIVATE_KEYWORDS) do
		if title:find(keyword, 1, true) then
			_state.is_private_window = true
			Logger.debug(LOG, "Private browsing window detected in '%s'.", _state.active_app_name or "?")
			break
		end
	end

	-- Extract local file path from AXDocument for document-context tagging
	local ok_ax, ax_win = pcall(hs.axuielement.windowElement, win)
	if ok_ax and ax_win then
		local doc_url = ax_win:attributeValue("AXDocument")
		if type(doc_url) == "string" and doc_url:sub(1, 7) == "file://" then
			-- Pure-Lua percent-decode to avoid hs.http dependency
			local path = doc_url:sub(8)
			_state.session_document_path = path:gsub("+", " "):gsub("%%(%x%x)", function(h)
				return string.char(tonumber(h, 16))
			end)
		end
	end
end

--- Application watcher callback: fires when a new application gains focus.
--- Logs the time spent in the previous app, updates all context fields,
--- and re-attaches the accessibility observer to the new app.
--- @param app_name string Display name of the newly active application.
--- @param event_type number The application watcher event constant.
--- @param app_object table The hs.application object for the new app.
function M.app_watcher_cb(app_name, event_type, app_object)
	if event_type ~= hs.application.watcher.activated then return end
	if not app_object then
		Logger.warn(LOG, "app_watcher_cb() received nil app_object for '%s'.", tostring(app_name))
		return
	end
	if not _state or not _log_manager then return end  -- called before init — silently skip

	local now        = hs.timer.absoluteTime() / 1000000
	local new_bundle = app_object:bundleID()
	local new_path   = app_object:path()
	local new_pid    = app_object:pid()

	-- Log time spent in the previous app before switching context
	if _state.active_app_name and _state.active_app_name ~= app_name then
		local duration_ms = now - (_state.active_app_start or now)
		Logger.debug(LOG, "App switch: '%s' → '%s' (%.0f ms).",
			_state.active_app_name, app_name, duration_ms)
		if type(_log_manager.log_app_switch) == "function" then
			_log_manager.log_app_switch(_state.active_app_name, app_name, duration_ms)
		end
	end

	_state.active_app_name   = app_name
	_state.active_app_start  = now
	_state.active_app_bundle = new_bundle
	_state.active_app_path   = new_path
	_state.active_app_pid    = new_pid

	-- Reset secure field flag on every app switch to avoid false-positive suppression
	_state.is_secure_field = false

	-- Reset per-switch window tracking
	_last_win_title = nil
	_last_win_time  = now

	M.update_private_status()
	M.update_ax_observer(new_pid)
end




-- =============================
-- =============================
-- ======= 4/ Lifecycle =======
-- =============================
-- =============================

--- Initializes the context tracker with its two injected dependencies.
--- Must be called exactly once before any callbacks are registered.
--- @param core_state table The shared state object from init.lua.
--- @param log_manager_mod table The log manager module reference.
function M.init(core_state, log_manager_mod)
	Logger.start(LOG, "Initializing context tracker…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — context tracker non-functional.")
		return
	end
	if type(log_manager_mod) ~= "table" then
		Logger.error(LOG, "M.init(): log_manager_mod must be a table — context tracker non-functional.")
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_state       = core_state
	_log_manager = log_manager_mod
	Logger.success(LOG, "Context tracker initialized.")
end

return M
