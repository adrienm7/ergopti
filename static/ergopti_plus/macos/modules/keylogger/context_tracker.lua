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
local i18n   = require("lib.i18n")
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
-- Tracks previous window title for intra-app window-switch logging
local _last_win_title       = nil
local _last_win_time        = 0

-- Incognito / private browsing window title keywords across all major browsers
local PRIVATE_KEYWORDS = {
	-- Populated at first use via i18n to pick the locale-correct term
	"Private Browsing", "Incognito", "InPrivate", "Anonymous",
}
local function get_private_keywords()
	local localized = i18n.get("keylogger.category_private")
	if localized ~= "keylogger.category_private" then
		PRIVATE_KEYWORDS[#PRIVATE_KEYWORDS + 1] = localized
	end
	return PRIVATE_KEYWORDS
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





-- =========================================
-- ==========================================
-- ======= 2/ Accessibility Observers =======
-- ==========================================
-- =========================================

--- Inspects a focused UI element and updates the secure-field flag on CoreState.
--- Called whenever the focused element changes so the engine can stop logging
--- immediately when a password field receives focus.
--- @param element table The newly focused AX element (may be nil).
local function update_secure_field_state(element)
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
		_state.is_secure_field = in_secure_app
		return
	end
	local ok_role,    role    = pcall(function() return element:attributeValue("AXRole") end)
	local ok_subrole, subrole = pcall(function() return element:attributeValue("AXSubrole") end)
	local is_secure = (ok_role    and role    == "AXSecureTextField")
	               or (ok_subrole and subrole == "AXSecureTextField")
	               or in_secure_app
	if is_secure ~= _state.is_secure_field then
		_state.is_secure_field = is_secure
		if is_secure then
			-- Discard any buffered input that may have been captured before detection
			_state.buffer_events = {}
			_state.buffer_text   = ""
			_state.rich_chunks   = {}
			-- Also drop the synthetic queue: a suppressed expansion in a secure field
			-- leaves stale synth_queue entries that would mis-tag the first real
			-- keystroke on return as synthetic (C6 made deterministic, not drain-timed)
			_state.synth_queue   = {}
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
		pcall(function() observer:addWatcher(focused, "AXValueChanged") end)
		_last_focused_element = focused
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
-- =============================================
-- ======= 3/ Application Switch Tracker =======
-- =============================================
-- ==========================================

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
	M.app_watcher_cb(app_name, hs.application.watcher.activated, app)
	return true
end

--- Checks whether the currently focused browser window is in private/incognito
--- mode, and captures window fullscreen state and document file path.
--- Called on every app switch and on browser window focus/title changes.
function M.update_private_status()
	if not require_state("update_private_status") then return end
	-- « pause = tout éteint »: a paused script records NOTHING
	-- (project-suspend-pause-invariant). Window TITLES are the most identifying
	-- payload this module handles, and hs.window.filter keeps firing while paused.
	if _is_paused() then return end

	local win = hs.window.focusedWindow()
	_state.is_private_window    = false
	_state.is_fullscreen        = false
	_state.session_document_path = nil

	if not win then return end

	-- hs.window:isFullScreen() returns nil for a window that does not expose the
	-- attribute, and is_fullscreen feeds an INTEGER NOT NULL column — coerce to a
	-- boolean here so a nil can never reach the writer in the first place.
	_state.is_fullscreen = win:isFullScreen() == true

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
	for _, keyword in ipairs(get_private_keywords()) do
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
			-- Pure-Lua percent-decode to avoid hs.http dependency.
			-- Note: '+' must NOT be decoded as space here — '+' is a literal path
			-- character in file:// URIs (only form-encoded bodies use + for space).
			local path = doc_url:sub(8)
			_state.session_document_path = path:gsub("%%(%x%x)", function(h)
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
	if not _state or not _log_manager or not _is_paused then return end  -- called before init — silently skip
	-- « pause = tout éteint »: a paused script records NOTHING
	-- (project-suspend-pause-invariant). ProcessLifecycle.onAppActivate keeps
	-- delivering activations while paused, so the gate has to live here.
	if _is_paused() then return end

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

	-- Any app activation is a context boundary: clear the synthetic queue so a
	-- synthetic echo suppressed in the previous app (disabled/private/secure)
	-- cannot mis-tag the first keystroke in the new app as synthetic (C6)
	_state.synth_queue = {}
	_state.active_app_name   = app_name
	_state.active_app_start  = now
	_state.active_app_bundle = new_bundle
	_state.active_app_path   = new_path
	_state.active_app_pid    = new_pid

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
	SecureFieldDetector.refresh()
	_state.is_secure_field = SecureFieldDetector.isSecureField()
		or SecureFieldDetector.isSecureApp(app_name)

	-- Reset per-switch window tracking
	_last_win_title = nil
	_last_win_time  = now

	M.update_private_status()
	M.update_ax_observer(new_pid)
end

--- Re-synchronises the cached context with the app that is frontmost RIGHT NOW,
--- without logging anything. Called on resume.
---
--- app_watcher_cb returns early while paused — correctly, since « pause = tout
--- éteint » — but that early return also skips the pure state synchronisation that
--- follows its single write: active_app_*, the synthetic queue, is_secure_field and
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

	local ok_name, app_name = pcall(function() return app:title() end)
	if not ok_name or type(app_name) ~= "string" then return false end

	local now = hs.timer.absoluteTime() / 1000000

	-- A resume is a context boundary exactly like an app activation: a synthetic
	-- echo suppressed before the pause must not mis-tag the first key after it.
	_state.synth_queue       = {}
	_state.active_app_name   = app_name
	_state.active_app_start  = now
	pcall(function() _state.active_app_bundle = app:bundleID() end)
	pcall(function() _state.active_app_path   = app:path() end)
	local ok_pid, new_pid = pcall(function() return app:pid() end)
	if ok_pid then _state.active_app_pid = new_pid end

	SecureFieldDetector.refresh()
	_state.is_secure_field = SecureFieldDetector.isSecureField()
		or SecureFieldDetector.isSecureApp(app_name)

	_last_win_title = nil
	_last_win_time  = now

	M.update_private_status()
	if ok_pid then M.update_ax_observer(new_pid) end

	Logger.debug(LOG, "Context re-synchronised on resume (app '%s', secure=%s).",
		app_name, tostring(_state.is_secure_field))
	return true
end





-- =============================
-- ============================
-- ======= 4/ Lifecycle =======
-- ============================
-- =============================

--- Initializes the context tracker with its three injected dependencies.
--- Must be called exactly once before any callbacks are registered.
--- The pause predicate is mandatory: without it the tracker would keep writing
--- app switches, window titles and autocorrect events while the script is
--- paused, so a missing predicate makes the module non-functional by design
--- rather than silently privacy-leaky.
--- @param core_state table The shared state object from init.lua.
--- @param log_manager_mod table The log manager module reference.
--- @param is_paused_fn function Predicate returning true while the script is paused.
function M.init(core_state, log_manager_mod, is_paused_fn)
	Logger.start(LOG, "Initializing context tracker…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — context tracker non-functional.")
		return
	end
	if type(log_manager_mod) ~= "table" then
		Logger.error(LOG, "M.init(): log_manager_mod must be a table — context tracker non-functional.")
		return
	end
	if type(is_paused_fn) ~= "function" then
		Logger.error(LOG, "M.init(): is_paused_fn must be a function — context tracker non-functional.")
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_state       = core_state
	_log_manager = log_manager_mod
	_is_paused   = is_paused_fn
	Logger.success(LOG, "Context tracker initialized.")
end

return M
