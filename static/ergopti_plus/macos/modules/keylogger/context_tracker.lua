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
local Logger = require("infra.logger")
local i18n   = require("infra.i18n")
local SecureFieldDetector = require("adapters.secure_field_detector")
local LOG    = "keylogger.context_tracker"
local M      = {}

local _state       = nil
local _log_manager = nil

--- Pause predicate injected by M.init(). The tracker's writers are driven by
--- OS watchers (hs.window.filter, the app watcher, the AX observer) that are
--- torn down only by keylogger.M.stop() — pause never calls it — so without
--- this predicate a paused script keeps recording window and app activity.
local _is_paused   = nil

-- Tracks the last focused AX element so watchers can be removed on focus change
local _last_focused_element = nil
-- Tracks the last known AX text value to detect autocorrect jumps
local _last_ax_value        = ""
local _ax_observer_committed = false
local _ax_value_watch_committed = false
-- Tracks previous window title for intra-app window-switch logging
local _last_win_title       = nil
local _last_win_time        = 0

-- Incognito / private browsing window title markers. The list itself lives in
-- _shared/lua/keylogger/private_window.lua: "drop keystrokes typed in a private
-- window" is one of the four categories of the shared no-persist corpus, so it
-- cannot be one driver's private variable — the Linux driver had no such filter
-- at all precisely because this list was never shared.
local PrivateWindow = require("keylogger.private_window")

local function get_private_keywords()
	local localized = i18n.get("keylogger.category_private")
	if localized ~= "keylogger.category_private" then
		return { localized }
	end
end





-- =======================================
-- =======================================
-- ======= 1/ Guard And Validation =======
-- =======================================
-- =======================================

--- Guards every public function against being called before M.init().
--- @param func_name string The calling function name for the error message.
--- @return boolean False if state is not ready, true otherwise.
local function require_state(func_name)
	if not _state or not _log_manager or not _is_paused then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end





-- Dormant observation ownership is separate from native watcher ownership.
-- No cached context is promoted on bind; expected child writers share one ticket.
local _physical_context_binding
local _context_transaction
local _expected_context_transaction

local function mark_context(component, complete)
	local frame = _context_transaction
	if frame and rawequal(_physical_context_binding, frame.binding) then
		frame.binding.channel.mark(frame.ticket, component, complete)
		if component == "app" and frame.binding.correlated then
			local pid = complete == true and math.type(_state.active_app_pid) == "integer"
				and _state.active_app_pid > 0 and _state.active_app_pid or nil
			frame.binding.channel.mark_app_pid(frame.ticket, pid)
		end
	end
end

--- Reads only native window identity while the exact correlated writer owns it.
local function observe_window_identity(window)
	local frame = _context_transaction
	if not frame or not frame.binding.correlated then return end
	local function current()
		return rawequal(_context_transaction, frame) and rawequal(_physical_context_binding, frame.binding)
			and frame.binding.channel.owns(frame.ticket)
	end
	if not current() then return end
	local ok_app, app = pcall(function() return window:application() end)
	if not current() then return end
	local pid
	if ok_app and app then
		local ok_pid, value = pcall(function() return app:pid() end)
		if not current() then return end
		if ok_pid and math.type(value) == "integer" and value > 0 then pid = value end
	end
	frame.binding.channel.mark_window_pid(frame.ticket, pid)
end

local function secure_element_observer(app_pid)
	if not _context_transaction or not _physical_context_binding then return nil end
	return function(complete)
		mark_context("secure", complete == true and math.type(app_pid) == "integer"
			and rawequal(app_pid, _state.active_app_pid))
	end
end

local function secure_refresh_observer()
	if not _context_transaction or not _physical_context_binding then return nil end
	return function(complete, pid)
		mark_context("secure", complete == true and math.type(pid) == "integer"
			and rawequal(pid, _state.active_app_pid))
	end
end

local function invoke_context_writer(writer, ...)
	if not _physical_context_binding and not _context_transaction then return writer(...) end
	local previous = _expected_context_transaction
	_expected_context_transaction = _context_transaction
	local results = table.pack(pcall(writer, ...))
	_expected_context_transaction = previous
	if not results[1] then error(results[2], 0) end
	return table.unpack(results, 2, results.n)
end

--- Runs an observed transaction only for an explicitly bound trusted owner.
local function complete_context_write(source, writer, ...)
	local expected = _expected_context_transaction
	_expected_context_transaction = nil
	local binding = _physical_context_binding
	if not binding or expected then return writer(...) end
	local ticket = binding.channel.begin(source)
	local frame = { binding = binding, ticket = ticket }
	local previous = _context_transaction
	_context_transaction = frame
	local results = table.pack(pcall(writer, ...))
	_context_transaction = previous
	if not results[1] then
		binding.channel.refuse("Physical context writer failed")
		error(results[2], 0)
	end
	if rawequal(_physical_context_binding, binding) then
		local ok, paused = pcall(_is_paused)
		if not ok then binding.channel.refuse("Physical context pause predicate failed")
		else binding.channel.finish(ticket, _state, paused, binding.may_persist) end
	end
	return table.unpack(results, 2, results.n)
end


local function run_context_write(source, writer, ...)
	local binding = _physical_context_binding
	if binding then return binding.channel.run_writer(complete_context_write, source, writer, ...) end
	return complete_context_write(source, writer, ...)
end

local function bind_context_observer(owner, capacity, receive, on_refused, may_persist, correlated)
	assert(type(owner) == "table" and type(receive) == "function" and type(on_refused) == "function"
		and type(may_persist) == "function", "Invalid physical context subscriber")
	assert(math.type(capacity) == "integer" and capacity > 0, "Invalid physical context receipt budget")
	if not require_state("bind_physical_context_observer") then return false, "Context tracker is not initialized" end
	if _physical_context_binding then return false, "Physical context subscriber already bound" end
	local binding = { owner = owner, token = {}, may_persist = may_persist, correlated = correlated }
	binding.detach = function(exact_owner, exact_token)
		return M.unbind_physical_context_observer(exact_owner, exact_token)
	end
	local clock_port = require("adapters.physical_observation_clock").now
	binding.channel = require("keylogger.physical_context_observation").new(capacity,
		function()
			local guard = binding.sample_guard
			if guard and guard() ~= true then error("Physical context sample clock owner unavailable", 0) end
			local at = clock_port()
			if guard and guard() ~= true then error("Physical context sample clock owner changed", 0) end
			return at
		end,
		function(record) return receive(record, binding.token) end,
		function(reason) Logger.callback(LOG, "Physical context refusal observer", on_refused, reason) end, correlated, binding)
	_physical_context_binding = binding
	local accepted, reason = binding.channel.seed()
	if accepted ~= true then
		if rawequal(_physical_context_binding, binding) then
			_physical_context_binding = nil; binding.channel.close()
		end
		return false, reason, binding.channel.subscription()
	end
	return true, binding.token, binding.channel.subscription()
end

--- Binds dormant native-writer receipts; retained permission history is separate.
---@param owner table Exact trusted caller identity, compared without equality hooks.
---@param capacity integer Maximum acknowledged receipts before exact replacement.
---@param receive function Receives (copied record, exact detach token), accepting true.
---@param on_refused function Once-only terminal denial notification.
---@param may_persist function Existing authoritative persistence decision, accepting true.
---@return boolean bound False if initial denied observation is refused.
---@return table|string token Exact detach token or refusal reason.
---@return table|nil scope Exact callback ownership and post-frame retirement, also on acquired bootstrap failure.
function M.bind_physical_context_observer(owner, capacity, receive, on_refused, may_persist)
	return bind_context_observer(owner, capacity, receive, on_refused, may_persist)
end

--- Binds explicit native window/app PID correlation through the same owner slot.
--- Correlation is observed field evidence; retained permission history is separate.
---@param owner table Exact trusted caller identity, compared without equality hooks.
---@param capacity integer Maximum acknowledged receipts before exact replacement.
---@param receive function Receives (copied record, exact detach token), accepting true.
---@param on_refused function Once-only terminal denial notification.
---@param may_persist function Existing authoritative persistence decision, accepting true.
---@return boolean bound False if the initial denied observation is refused.
---@return table|string token Exact detach token or refusal reason.
---@return table|nil scope Exact callback ownership and post-frame retirement, also on acquired bootstrap failure.
function M.bind_physical_correlated_context_observer(owner, capacity, receive, on_refused, may_persist)
	return bind_context_observer(owner, capacity, receive, on_refused, may_persist, true)
end

--- Samples fresh physical permission without changing legacy app/window/AX ownership.
--- Literal true acknowledges the observation, including denied/incomplete receipts.
---@param owner table Exact owner of the already-bound correlated subscription.
---@param token table Exact token returned by that subscription.
---@return boolean acknowledged No permission or capture authority is implied.
function M.sample_physical_context(owner, token)
	local binding, state, pause_port = _physical_context_binding, _state, _is_paused
	if not binding or not binding.correlated or not rawequal(owner, binding.owner)
		or not rawequal(token, binding.token) or not state then return false end
	local previous_guard = binding.sample_guard
	local results = table.pack(pcall(binding.channel.run_writer, function()
		local ticket = binding.channel.begin("fresh_lease_sample")
		if ticket == nil then return false end
		-- Unknown writer names do not reset every cached field in the channel.
		for _, field in ipairs({ "app", "window", "secure" }) do binding.channel.mark(ticket, field, false) end
		binding.channel.mark_app_pid(ticket, nil)
		binding.channel.mark_window_pid(ticket, nil)
		local keys = { "is_enabled", "active_app_name", "active_app_bundle", "active_app_path",
			"active_app_pid", "active_app_start", "private_filter_enabled", "secure_field_filter_enabled",
			"system_auth_filter_enabled", "disabled_apps", "is_private_window", "is_secure_field", "ax_observer" }
		local original = {}
		for _, key in ipairs(keys) do original[key] = rawget(state, key) end
		local function stable()
			if not rawequal(_physical_context_binding, binding) or not rawequal(_state, state)
				or not rawequal(_is_paused, pause_port) then return false end
			for _, key in ipairs(keys) do
				if not rawequal(rawget(state, key), original[key]) then return false end
			end
			return true
		end
		local sampling = false
		local function fence()
			if not stable() then return false end
			if sampling then
				local ok, live_paused = pcall(pause_port)
				if not stable() then return false end
				if not ok or live_paused ~= false then
					binding.channel.refuse("Physical context sample pause changed")
					return false
				end
			end
			return true
		end
		local function current() return fence() and binding.channel.owns(ticket) end
		local function read(operation)
			if not current() then return false end
			local ok, value = pcall(operation)
			if not current() then return false end
			return ok, value
		end
		local function finish(observed, paused, permission)
			if not current() then return false end
			local accepted = binding.channel.finish(ticket, observed, paused, permission)
			return accepted == true and stable()
		end
		if type(pause_port) ~= "function" then return binding.channel.refuse("Missing physical context pause predicate") end
		local ok_pause, paused = read(pause_port)
		if not current() then return false end
		if not ok_pause or type(paused) ~= "boolean" then
			return binding.channel.refuse("Invalid physical context pause predicate")
		end
		if original.is_enabled ~= true or paused then return finish({}, paused, function() return false end) end
		-- Bounded guards belong only to this explicit sample, never a pause poller.
		sampling, binding.sample_guard = true, fence
		local observed = { private_filter_enabled = original.private_filter_enabled,
			secure_field_filter_enabled = original.secure_field_filter_enabled,
			system_auth_filter_enabled = original.system_auth_filter_enabled, disabled_apps = original.disabled_apps }
		local ok_app, app = read(function() return hs.application.frontmostApplication() end)
		if not current() then return false end
		if not ok_app or app == nil then return finish(observed, paused, function() return false end) end
		local app_known = true
		for _, property in ipairs({ { "name", "active_app_name" }, { "bundleID", "active_app_bundle" },
			{ "path", "active_app_path" }, { "pid", "active_app_pid" } }) do
			local ok, value = read(function() return app[property[1]](app) end)
			if not current() then return false end
			observed[property[2]], app_known = value, app_known and ok
		end
		local app_pid = math.type(observed.active_app_pid) == "integer" and observed.active_app_pid > 0
			and observed.active_app_pid or nil
		binding.channel.mark(ticket, "app", app_known and app_pid ~= nil)
		binding.channel.mark_app_pid(ticket, app_pid)
		local ok_window, window = read(function() return hs.window.focusedWindow() end)
		if not current() then return false end
		if ok_window and window ~= nil then
			local ok_application, window_app = read(function() return window:application() end)
			if not current() then return false end
			if ok_application and window_app ~= nil then
				local ok_pid, window_pid = read(function() return window_app:pid() end)
				if not current() then return false end
				binding.channel.mark_window_pid(ticket, ok_pid and math.type(window_pid) == "integer"
					and window_pid > 0 and window_pid or nil)
			end
			local ok_title, title = read(function() return window:title() end)
			if not current() then return false end
			if ok_title and type(title) == "string" then
				local ok_keywords, keywords = read(get_private_keywords)
				if not current() then return false end
				if ok_keywords then
					local ok_private, private = read(function() return PrivateWindow.matches(title, keywords) end)
					if not current() then return false end
					if ok_private and type(private) == "boolean" then
						observed.is_private_window = private
						binding.channel.mark(ticket, "window", true)
					end
				end
			end
		end
		-- Reuse the existing secure classifier, fencing EACH actual AX read.
		-- The proxy never enters CoreState or a native watcher registration.
		local pid = observed.active_app_pid
		if math.type(pid) == "integer" and pid > 0 then
			local ok_element, app_element = read(function() return hs.axuielement.applicationElementForPID(pid) end)
			if not current() then return false end
			if ok_element and app_element ~= nil then
				local ok_focus, focused = read(function() return app_element:attributeValue("AXFocusedUIElement") end)
				if not current() then return false end
				if ok_focus and focused ~= nil then
					local complete = false
					local proxy = { attributeValue = function(_, attribute)
						local ok, value = read(function() return focused:attributeValue(attribute) end)
						if not ok then error("Physical context AX observation refused", 0) end
						return value
					end }
					local ok_secure, secure = read(function()
						return SecureFieldDetector.isElementSecure(proxy, function(known) if current() then complete = known == true end end)
					end)
					if not current() then return false end
					local ok_sensitive, sensitive = read(function() return SecureFieldDetector.isSecureApp(observed.active_app_name) end)
					if not current() then return false end
					if ok_secure and type(secure) == "boolean" and ok_sensitive and type(sensitive) == "boolean" then
						observed.is_secure_field = secure or sensitive
						binding.channel.mark(ticket, "secure", complete)
					end
				end
			end
		end
		local function permission()
			if not current() then return false end
			for _, key in ipairs({ "active_app_name", "active_app_bundle", "active_app_path", "active_app_pid" }) do
				if not rawequal(observed[key], original[key]) then return false end
			end
			local allowed = require("modules.keylogger.privacy_context").allows_logging(observed)
			if not current() or allowed ~= true then return false end
			local permitted = binding.may_persist()
			if not current() then return false end
			return permitted
		end
		return finish(observed, paused, permission)
	end))
	binding.sample_guard = previous_guard
	if not results[1] then error(results[2], 0) end
	return table.unpack(results, 2, results.n)
end

--- Detaches only the exact owner and token, including a retired subscription.
---@param owner table Exact trusted identity.
---@param token table Exact token delivered by this acquisition.
---@return boolean detached False for forged, competing or stale identities.
function M.unbind_physical_context_observer(owner, token)
	local binding = _physical_context_binding
	if not binding or not rawequal(binding.owner, owner) or not rawequal(binding.token, token) then return false end
	if not rawequal(_physical_context_binding, binding) then return false end
	_physical_context_binding = nil; binding.channel.close()
	return true
end





-- ==========================================
-- ==========================================
-- ======= 2/ Accessibility Observers =======
-- ==========================================
-- ==========================================

--- Inspects a focused UI element and updates the secure-field flag on CoreState.
--- Called whenever the focused element changes so the engine can stop logging
--- immediately when a password field receives focus.
--- @param element table The newly focused AX element (may be nil).
local function update_secure_field_state(element, app_pid)
	-- The app-level guard must be OR-ed into EVERY assignment of is_secure_field.
	-- The activation path (handle_app_switch) sets the flag to the union
	-- isSecureField() or isSecureApp(), but this AX callback recomputed it from the
	-- role/subrole axis alone and assigned unconditionally — so focusing any
	-- non-secure element inside a known vault (its search box, a note field) flipped
	-- the flag back to false and RESUMED logging inside the password manager. The
	-- detector's own docstring calls the known-app list "a second line of defence"
	-- for vaults that never expose a secure role; dropping it here defeated exactly
	-- that. Fail-safe: false only when neither axis says secure.
	local in_secure_app = SecureFieldDetector.isSecureApp(_state.active_app_name)

	if not element then
		mark_context("secure", false)
		_state.is_secure_field = in_secure_app
		return
	end
	local is_secure = SecureFieldDetector.isElementSecure(element, secure_element_observer(app_pid)) or in_secure_app
	if is_secure ~= _state.is_secure_field then
		_state.is_secure_field = is_secure
		if is_secure then
			-- Discard any buffered input that may have been captured before detection
			_state.buffer_events = {}
			_state.buffer_text   = ""
			_state.rich_chunks   = {}
			_state.buffer_started_epoch = nil
			Logger.debug(LOG, "Secure text field detected — buffer cleared, logging suppressed.")
		else
			Logger.debug(LOG, "Focus moved away from secure field — logging resumed.")
		end
	end
end

--- Handles AXValueChanged events to detect macOS native autocorrect substitutions.
--- A sudden large delta in the field’s text value (without matching keystrokes)
--- signals a native substitution; we flush the buffer and log the event.
--- @param element table The AX element whose value changed.
local function handle_ax_value_changed(element)
	-- « pause = tout éteint »: a paused script records NOTHING
	-- (project-suspend-pause-invariant). The AX observer survives pause because
	-- only keylogger.M.stop() tears it down, so the gate has to live here.
	if _is_paused() then return end

	local ok, val = pcall(function() return element:attributeValue("AXValue") end)
	if not (ok and type(val) == "string") then return end

	local now = hs.timer.absoluteTime() / 1000000
	-- Only act if: more than 100 ms since last keystroke, both values non-empty,
	-- and the change is larger than 1 character (single-char changes are normal typing)
	-- Use utf8.len for character counting: a single accented char like 'é' is 2
	-- bytes, so #val would differ by 2 and falsely trigger the "> 1" threshold.
	-- utf8.len returns nil on malformed sequences; fall back to byte length.
	local val_chars      = utf8.len(val)           or #val
	local last_val_chars = utf8.len(_last_ax_value) or #_last_ax_value
	if (now - _state.last_time) > 100
	and val_chars > 0
	and last_val_chars > 0
	and math.abs(val_chars - last_val_chars) > 1
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

--- Logically revokes and then releases the exact current AX observer.
--- @param label string Stable diagnostic label.
--- @return boolean settled True only when no native observer remains owned.
local function stop_ax_observer(label)
	local observer = _state and _state.ax_observer or nil
	_ax_observer_committed = false
	_ax_value_watch_committed = false
	if not observer then return true end
	if type(observer.stop) ~= "function" then
		Logger.error(LOG, "%s failed: observer does not implement stop().", label)
		return false
	end
	local stopped, stop_result = xpcall(function() return observer:stop() end, debug.traceback)
	if not stopped or stop_result == false then
		Logger.error(LOG, "%s failed: %s.", label, tostring(stop_result))
		return false
	end
	if _state.ax_observer == observer then _state.ax_observer = nil end
	_last_focused_element = nil
	_last_ax_value = ""
	return true
end

--- Applies one AXValueChanged watcher mutation and checks its explicit refusal.
--- A nil/void result remains valid for Hammerspoon AX methods; false or throw
--- means the exact ownership transition did not commit.
--- @param observer table|userdata Active AX observer.
--- @param method string addWatcher or removeWatcher.
--- @param element table|userdata AX element being attached or detached.
--- @param label string Diagnostic operation label.
--- @return boolean committed
local function mutate_ax_value_watcher(observer, method, element, label)
	local ok, result = xpcall(function()
		return observer[method](observer, element, "AXValueChanged")
	end, debug.traceback)
	if not ok or result == false then
		Logger.error(LOG, "%s failed: %s.", label, tostring(result))
		return false
	end
	return true
end

--- Rejects one observer candidate while retaining ambiguous cleanup debt.
--- @param detail any Setup failure detail.
--- @return false
local function reject_ax_observer_candidate(detail)
	mark_context("secure", false)
	Logger.warn(LOG, "Accessibility observer setup failed: %s.", tostring(detail))
	if stop_ax_observer("Accessibility observer rollback") ~= true then
		Logger.error(LOG, "Accessibility observer cleanup remains pending.")
	end
	return false
end

--- Attaches accessibility observers to the newly active application.
--- Observes focus changes (to detect secure fields) and value changes
--- (to detect native autocorrect substitutions).
--- @param app_pid number The Process ID of the new foreground application.
--- @return boolean attached True only when the requested observer commits.
function M.update_ax_observer(app_pid)
	if not require_state("update_ax_observer") then return false end
	mark_context("secure", false)

	-- Tear down any existing observer before attaching a new one
	if _state.ax_observer then
		Logger.trace(LOG, "Stopping previous accessibility observer…")
		if stop_ax_observer("Previous accessibility observer stop") ~= true then return false end
		Logger.done(LOG, "Previous accessibility observer stopped.")
	end

	if not app_pid then return true end

	Logger.trace(LOG, "Attaching accessibility observer to PID %s…", tostring(app_pid))

	local ok_new, observer = pcall(hs.axuielement.observer.new, app_pid)
	if not ok_new or not observer then
		Logger.warn(LOG, "Failed to create AX observer for PID %s.", tostring(app_pid))
		return false
	end
	_state.ax_observer = observer
	_ax_observer_committed = false
	for _, method in ipairs({ "addWatcher", "removeWatcher", "callback", "start", "stop" }) do
		if type(observer[method]) ~= "function" then
			return reject_ax_observer_candidate("observer does not implement " .. method)
		end
	end

	local ok_app, app_element = pcall(hs.axuielement.applicationElement, app_pid)
	if not ok_app or not app_element then
		return reject_ax_observer_candidate(
			"failed to get AX application element for PID " .. tostring(app_pid))
	end

	-- Watch for focus changes across the whole application
	local focus_watch_ok, focus_watch_result = xpcall(function()
		return observer:addWatcher(app_element, "AXFocusedUIElementChanged")
	end, debug.traceback)
	if not focus_watch_ok or focus_watch_result == false then
		return reject_ax_observer_candidate(focus_watch_result)
	end

	-- Bootstrap: also watch the currently focused element for value changes.
	-- _last_focused_element must be set here so the focus-change handler's
	-- removeWatcher call fires on E1 when E2 gets focus; without this assignment
	-- the guard `if _last_focused_element` is always nil on the first switch and
	-- the bootstrap watcher leaks (orphaned watchers accumulate per app activation).
	-- pcall-guarded like every other AX call in this function: a throw here would
	-- otherwise propagate out of the application-watcher callback that invokes this
	-- function (which reports errors only to the HS Console) and silently leave the
	-- new app's observer unattached, even though `observer` and `app_element` were
	-- already created successfully.
	local ok_focused, focused = pcall(function() return app_element:attributeValue("AXFocusedUIElement") end)
	if not ok_focused then
		Logger.warn(LOG, "Failed to read AXFocusedUIElement for PID %s.", tostring(app_pid))
		focused = nil
	end
	if focused then
		if mutate_ax_value_watcher(observer, "addWatcher", focused,
			"Initial AXValueChanged watcher setup") then
			_last_focused_element = focused
			_ax_value_watch_committed = true
			local ok_val, val = pcall(function() return focused:attributeValue("AXValue") end)
			if ok_val and type(val) == "string" then _last_ax_value = val end
		end
		update_secure_field_state(focused, app_pid)
	end

	local callback_ok, callback_result = xpcall(function()
		return observer:callback(function(element, event, watcher, _)
			if _physical_context_binding and (not _state or not rawequal(_state.ax_observer, observer)
				or not rawequal(watcher, observer)) then return end
			if not _state or _state.ax_observer ~= observer
				or _ax_observer_committed ~= true or _state.is_enabled == false
				or watcher ~= observer then return end
			Logger.callback(LOG, "Accessibility observer", function()
				if event == "AXFocusedUIElementChanged" then
					return run_context_write("secure_focus", function()
					-- Revoke callback authority before crossing the native detach boundary.
					-- The exact old element remains retained until removal commits, so a
					-- later focus notification can retry it without overlapping successors.
					_ax_value_watch_committed = false
					if _last_focused_element then
						if not mutate_ax_value_watcher(watcher, "removeWatcher",
							_last_focused_element, "Previous AXValueChanged watcher cleanup") then
							update_secure_field_state(element, app_pid)
							return
						end
						_last_focused_element = nil
					end
					_last_ax_value = ""

					update_secure_field_state(element, app_pid)

					if element then
						if mutate_ax_value_watcher(watcher, "addWatcher", element,
							"Replacement AXValueChanged watcher setup") then
							_last_focused_element = element
							_ax_value_watch_committed = true
							local ok_val, val = pcall(function()
								return element:attributeValue("AXValue")
							end)
							if ok_val and type(val) == "string" then _last_ax_value = val end
						end
					end
					end)
				elseif event == "AXValueChanged" then
					if _ax_value_watch_committed and element == _last_focused_element then
						handle_ax_value_changed(element)
					end
			end
			end)
		end)
	end, debug.traceback)
	if not callback_ok or callback_result == false then
		return reject_ax_observer_candidate(callback_result)
	end

	local started, start_result = xpcall(function() return observer:start() end, debug.traceback)
	if not started or start_result == false then
		return reject_ax_observer_candidate(start_result)
	end
	_ax_observer_committed = true
	Logger.done(LOG, "Accessibility observer attached to PID %s.", tostring(app_pid))
	return true
end





-- =============================================
-- =============================================
-- ======= 3/ Application Switch Tracker =======
-- =============================================
-- =============================================

--- Returns the unpersisted foreground duration for the active application.
--- App-time events are normally committed only on a focus transition. The
--- dashboard also needs the open interval so a long uninterrupted work block
--- is visible before the user leaves that application.
--- @return table|nil Snapshot { app, duration_ms }, or nil when no app is tracked.
function M.get_active_app_snapshot()
	if not require_state("get_active_app_snapshot") then return nil end
	if type(_state.active_app_name) ~= "string" or _state.active_app_name == ""
		or type(_state.active_app_start) ~= "number"
	then
		return nil
	end
	local now = hs.timer.absoluteTime() / 1000000
	return {
		app         = _state.active_app_name,
		duration_ms = math.max(0, math.floor(now - _state.active_app_start)),
	}
end

--- Persist the foreground interval that is currently open, without creating a
--- synthetic destination in the app-switch graph. This is used before the
--- engine stops, so a Hammerspoon reload cannot discard the user's last
--- uninterrupted work block.
---@return boolean True when an interval was emitted.
function M.close_active_app()
	if not require_state("close_active_app") then return false end
	if type(_state.active_app_name) ~= "string" or _state.active_app_name == ""
		or type(_state.active_app_start) ~= "number"
	then
		return false
	end
	local now = hs.timer.absoluteTime() / 1000000
	local duration_ms = math.max(0, math.floor(now - _state.active_app_start))
	if duration_ms > 0 and type(_log_manager.log_app_switch) == "function" then
		-- `next_app=nil` persists as SQL NULL, so aggregate switches_to is not
		-- polluted with a fictitious "engine stopped" application.
		_log_manager.log_app_switch(_state.active_app_name, nil, duration_ms)
	end
	_state.active_app_name  = nil
	_state.active_app_start = nil
	return duration_ms > 0
end

--- Split the currently open foreground interval at a local midnight boundary.
--- App-switch rows are bucketed by their timestamp date, therefore carrying an
--- interval across midnight without this split credits all of the previous day
--- to the new one when the user next changes applications.
---@param previous_date string Date being closed (YYYY-MM-DD).
---@return boolean True when the previous day received a non-zero interval.
function M.split_active_app_at_midnight(previous_date)
	if not require_state("split_active_app_at_midnight") then return false end
	if type(previous_date) ~= "string" or not previous_date:match("^%d%d%d%d%-%d%d%-%d%d$") then
		return false
	end
	if type(_state.active_app_name) ~= "string" or _state.active_app_name == ""
		or type(_state.active_app_start) ~= "number"
	then
		return false
	end
	local now = hs.timer.absoluteTime() / 1000000
	local wall = os.date("*t")
	local elapsed_today_ms = ((wall.hour * 3600) + (wall.min * 60) + wall.sec) * 1000
	local total_elapsed_ms = math.max(0, math.floor(now - _state.active_app_start))
	local previous_day_ms = math.max(0, total_elapsed_ms - elapsed_today_ms)
	if previous_day_ms > 0 and type(_log_manager.log_app_switch) == "function" then
		_log_manager.log_app_switch(
			_state.active_app_name,
			nil,
			previous_day_ms,
			previous_date .. " 23:59:59.999")
	end
	-- Keep tracking the same foreground app from this calendar day's boundary.
	-- Maintenance can be delayed while Ergopti is paused: resetting to `now`
	-- would silently drop every foreground minute since midnight in that case.
	_state.active_app_start = now - elapsed_today_ms
	return previous_day_ms > 0
end

--- Primes application tracking from the foreground application after a resume.
--- Sleep and lock events deliberately close the former interval. macOS does not
--- guarantee a new activation notification on wake, so explicitly restore the
--- currently focused application instead of leaving all subsequent time unowned.
--- @return boolean True when a foreground application was captured.
function M.capture_frontmost_app()
	if not require_state("capture_frontmost_app") then return false end
	local ok, app = pcall(hs.application.frontmostApplication)
	if not ok or not app then
		Logger.debug(LOG, "capture_frontmost_app(): no foreground application available.")
		return false
	end
	-- hs.application:name() is the stable display-name API. `title()` describes
	-- windows in other HS objects and is absent for some application instances,
	-- which previously left the first post-resume interval untracked.
	local ok_name, app_name = pcall(function() return app:name() end)
	if not ok_name or type(app_name) ~= "string" or app_name == "" then
		Logger.debug(LOG, "capture_frontmost_app(): foreground application has no usable name.")
		return false
	end
	invoke_context_writer(M.app_watcher_cb, app_name, hs.application.watcher.activated, app)
	return true
end

--- Checks whether the currently focused browser window is in private/incognito
--- mode, and captures window fullscreen state and document file path.
--- Called on every app switch and on browser window focus/title changes.
function M.update_private_status()
	if not require_state("update_private_status") then return end
	mark_context("window", false)
	-- « pause = tout éteint »: a paused script records NOTHING
	-- (project-suspend-pause-invariant). Window TITLES are the most identifying
	-- payload this module handles, and hs.window.filter keeps firing while paused.
	if _is_paused() then return end

	local win = hs.window.focusedWindow()
	_state.is_private_window    = false
	_state.is_fullscreen        = false
	_state.session_document_path = nil

	if not win then return end
	observe_window_identity(win)

	-- hs.window:isFullScreen() returns nil for a window that does not expose the
	-- attribute, and is_fullscreen feeds an INTEGER NOT NULL column — coerce to a
	-- boolean here so a nil can never reach the writer in the first place.
	_state.is_fullscreen = win:isFullScreen() == true

	local native_title = win:title()
	local title = native_title or ""
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
	-- Published into the shared state so the keystroke path can read the focused
	-- window title instead of making its own cross-process AX call for it. This
	-- function already has the title in hand on every window change.
	_state.active_win_title = title

	-- Check for private/incognito mode keywords in the window title
	if PrivateWindow.matches(title, get_private_keywords()) then
		_state.is_private_window = true
		Logger.debug(LOG, "Private browsing window detected in '%s'.", _state.active_app_name or "?")
	end

	-- Extract local file path from AXDocument for document-context tagging
	local ok_ax, ax_win = pcall(hs.axuielement.windowElement, win)
	if ok_ax and ax_win then
		local doc_url = ax_win:attributeValue("AXDocument")
		if type(doc_url) == "string" and doc_url:sub(1, 7) == "file://" then
			-- Pure-Lua percent-decode to avoid hs.http dependency.
			-- Note: '+' must NOT be decoded as space here — '+' is a literal path
			-- character in file:// URIs (only form-encoded bodies use + for space).
			local path = doc_url:sub(8)
			_state.session_document_path = path:gsub("%%(%x%x)", function(h)
				return string.char(tonumber(h, 16))
			end)
		end
	end
	mark_context("window", type(native_title) == "string")
end

--- Reads one application property without allowing a dying native object to
--- abort the rest of the foreground-switch transaction.
--- @param app_object table The active hs.application object.
--- @param reader_name string Native reader method name.
--- @param app_name string Display name used only for diagnostics.
--- @return any value The native value, or nil when the read was rejected.
local function read_active_app_property(app_object, reader_name, app_name)
	local ok, value = pcall(function()
		local reader = app_object[reader_name]
		if type(reader) ~= "function" then
			error(reader_name .. "() is unavailable", 0)
		end
		return reader(app_object)
	end)
	if not ok then
		Logger.warn(LOG, "Failed to read %s() for active app '%s': %s.",
			reader_name, tostring(app_name), tostring(value))
		return nil
	end
	return value, true
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
	if not _state or not _log_manager or not _is_paused then return end  -- called before init — silently skip
	-- « pause = tout éteint »: a paused script records NOTHING
	-- (project-suspend-pause-invariant). ProcessLifecycle.onAppActivate keeps
	-- delivering activations while paused, so the gate has to live here.
	if _is_paused() then return end

	local now = hs.timer.absoluteTime() / 1000000

	-- Log time spent in the previous app before switching context
	if _state.active_app_name and _state.active_app_name ~= app_name then
		-- A typing run captures its app/title when its first key arrives. Detach
		-- that immutable owner before any row for the new foreground context is
		-- queued; otherwise separator-free typing in the next app is appended to
		-- the previous app's metrics. flush_buffer also owns mouse-only sessions,
		-- so the LogManager decides whether the current context is empty.
		_log_manager.flush_buffer()
		local duration_ms = now - (_state.active_app_start or now)
		Logger.debug(LOG, "App switch: '%s' → '%s' (%.0f ms).",
			_state.active_app_name, app_name, duration_ms)
		if type(_log_manager.log_app_switch) == "function" then
			_log_manager.log_app_switch(_state.active_app_name, app_name, duration_ms)
		end
	end

	-- Each reader crosses into a process that may already be terminating. Keep
	-- the reads independent so one refusal cannot suppress the remaining state
	-- publication or retain the previous application's AX observer.
	local new_bundle, ok_bundle = read_active_app_property(app_object, "bundleID", app_name)
	local new_path, ok_path = read_active_app_property(app_object, "path", app_name)
	local new_pid, ok_pid = read_active_app_property(app_object, "pid", app_name)

	_state.active_app_name   = app_name
	_state.active_app_start  = now
	_state.active_app_bundle = new_bundle
	_state.active_app_path   = new_path
	_state.active_app_pid    = new_pid
	mark_context("app", ok_bundle and ok_path and ok_pid)

	-- Arm the "time-to-first-key after focus" measurement: the next manual
	-- keystroke in this app will compute (now - focus_pending_at) and feed the
	-- focus_to_first_key_* manifest counters. Cleared after the first hit so
	-- subsequent keystrokes don't all count as zero-latency.
	_state.focus_pending_at  = now
	_state.focus_pending_app = app_name

	-- Refresh the portable secure-field guard before attaching the richer AX
	-- observer. This closes the short activation-to-observer gap for known vaults
	-- and keeps the adapter as the single fallback for environments without AX
	-- notifications.
	SecureFieldDetector.refresh(secure_refresh_observer())
	_state.is_secure_field = SecureFieldDetector.isSecureField()
		or SecureFieldDetector.isSecureApp(app_name)

	-- Reset per-switch window tracking
	_last_win_title = nil
	_last_win_time  = now

	invoke_context_writer(M.update_private_status)
	invoke_context_writer(M.update_ax_observer, new_pid)
end

--- Re-synchronises the cached context with the app that is frontmost RIGHT NOW,
--- without logging anything. Called on resume.
---
--- app_watcher_cb returns early while paused — correctly, since « pause = tout
--- éteint » — but that early return also skips the pure state synchronisation that
--- follows its single write: active_app_*, synthetic action accounting, is_secure_field and
--- the AX observer's target PID. Nothing re-syncs them afterwards, because
--- resume_all() never touched this module and no fresh activation event fires when
--- the user resumes in the app they already switched to while paused. The cached
--- context therefore stayed pinned to whatever was frontmost when pause began.
---
--- The dangerous half is is_secure_field: pausing in an ordinary app, switching to
--- a password manager, then resuming left it stale-false, so the first keystrokes
--- typed in the vault were logged — and attributed to the wrong application.
--- @return boolean True when the context was re-synchronised.
function M.resync_context()
	if not require_state("resync_context") then return false end

	local app = hs.application.frontmostApplication()
	if not app then return false end

	-- app:name(), NOT app:title(). name() is the stable display-name API, which
	-- is what the rest of this pipeline is keyed on: SecureFieldDetector's
	-- isSecureApp exact-matches DISPLAY names, and capture_frontmost_app — the
	-- sibling resume helper — already documents that title() is absent for some
	-- application instances. Reading title() here meant a vault whose title is
	-- nil or differs from its display name was not recognised on resume, so
	-- is_secure_field stayed stale-false and keystrokes typed into a password
	-- manager were logged, and mis-attributed to the previously focused app.
	--
	-- The empty-string check matters as much as the type check: an app with a
	-- blank name must not be adopted as the active context.
	local ok_name, app_name = pcall(function() return app:name() end)
	if not ok_name or type(app_name) ~= "string" or app_name == "" then
		Logger.debug(LOG, "resync_context(): foreground application has no usable name.")
		return false
	end

	local now = hs.timer.absoluteTime() / 1000000

	_state.active_app_name   = app_name
	_state.active_app_start  = now
	local ok_bundle = pcall(function() _state.active_app_bundle = app:bundleID() end)
	local ok_path = pcall(function() _state.active_app_path   = app:path() end)
	local ok_pid, new_pid = pcall(function() return app:pid() end)
	if ok_pid then _state.active_app_pid = new_pid end
	mark_context("app", ok_bundle and ok_path and ok_pid)

	SecureFieldDetector.refresh(secure_refresh_observer())
	_state.is_secure_field = SecureFieldDetector.isSecureField()
		or SecureFieldDetector.isSecureApp(app_name)

	_last_win_title = nil
	_last_win_time  = now

	invoke_context_writer(M.update_private_status)
	if ok_pid then invoke_context_writer(M.update_ax_observer, new_pid) end

	Logger.debug(LOG, "Context re-synchronised on resume (app '%s', secure=%s).",
		app_name, tostring(_state.is_secure_field))
	return true
end





-- ============================
-- ============================
-- ======= 4/ Lifecycle =======
-- ============================
-- ============================

--- Initializes the context tracker with its three injected dependencies.
--- Must be called exactly once before any callbacks are registered.
--- The pause predicate is mandatory: without it the tracker would keep writing
--- app switches, window titles and autocorrect events while the script is
--- paused, so a missing predicate makes the module non-functional by design
--- rather than silently privacy-leaky.
--- @param core_state table The shared state object from init.lua.
--- @param log_manager_mod table The log manager module reference.
--- @param is_paused_fn function Predicate returning true while the script is paused.
--- @return boolean initialized True only when the exact dependency set is active.
function M.init(core_state, log_manager_mod, is_paused_fn)
	Logger.start(LOG, "Initializing context tracker…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — context tracker non-functional.")
		return false
	end
	if type(log_manager_mod) ~= "table" then
		Logger.error(LOG, "M.init(): log_manager_mod must be a table — context tracker non-functional.")
		return false
	end
	if type(is_paused_fn) ~= "function" then
		Logger.error(LOG, "M.init(): is_paused_fn must be a function — context tracker non-functional.")
		return false
	end
	if _state then
		if _state == core_state
		and _log_manager == log_manager_mod
		and _is_paused == is_paused_fn
		then
			Logger.warn(LOG, "M.init() called more than once — exact dependencies already active.")
			return true
		end
		Logger.error(LOG, "M.init() dependency mismatch — refusing split context state.")
		return false
	end
	_state       = core_state
	_log_manager = log_manager_mod
	_is_paused   = is_paused_fn
	Logger.success(LOG, "Context tracker initialized.")
	return true
end

local function observe_writer(name, source)
	local writer = M[name]
	M[name] = function(...) return run_context_write(source, writer, ...) end
end

observe_writer("update_ax_observer", "secure_setup")
observe_writer("update_private_status", "private")
observe_writer("close_active_app", "closure")
observe_writer("capture_frontmost_app", "capture")
observe_writer("resync_context", "resync")
local app_writer = M.app_watcher_cb
M.app_watcher_cb = function(app_name, event_type, app_object)
	if event_type ~= hs.application.watcher.activated then return app_writer(app_name, event_type, app_object) end
	return run_context_write("activation", app_writer, app_name, event_type, app_object)
end

return M
