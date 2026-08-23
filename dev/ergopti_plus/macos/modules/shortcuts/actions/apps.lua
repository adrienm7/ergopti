--- modules/shortcuts/actions/apps.lua

--- ==============================================================================
--- MODULE: Shortcuts — App Navigation Actions
--- DESCRIPTION:
--- Implements shortcuts that launch or focus applications and perform file-system
--- or web navigation: Finder / Downloads, ChatGPT, System Settings, and the
--- "copy path or search the web" smart action.
---
--- FEATURES & RATIONALE:
--- 1. File-Manager Agnosticism: Tries popular third-party managers (QSpace,
---    ForkLift, etc.) before falling back to stock Finder, so the shortcuts work
---    regardless of the user's setup.
--- 2. Smart Copy/Search: Detects whether the frontmost app is a file manager to
---    decide between copying the current path vs. opening the selection in a
---    browser or running a Google search.
--- ==============================================================================

local M = {}

local hs            = hs
local pasteboard    = hs.pasteboard
local urlevent      = hs.urlevent
local http          = hs.http
local notifications = require("infra.notifications")
local Logger        = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n          = require("infra.i18n")
local AppLauncher   = require("adapters.app_launcher")
local WindowInfo    = require("adapters.window_info")
local WindowManager = require("adapters.window_manager")
local ShellRunner   = require("adapters.shell_runner")
local SyntheticInput = require("adapters.synthetic_input")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "shortcuts.actions.apps"

-- Explicit inter-key delay for simulated keystrokes. hs.eventtap.keyStroke()
-- defaults this argument to 200 000 us and implements it as a BLOCKING usleep on
-- the main run loop, so an omitted delay stalls the loop that services the typing
-- event tap — long enough for macOS to disable it (kCGEventTapDisabledByTimeout).
local KEYSTROKE_NO_DELAY_US = 0





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Priority-ordered list of file managers to try before falling back to stock Finder
local FILE_MANAGERS = {
	"qspace", "path finder", "forklift", "commander one",
	"totalfinder", "xtrafinder", "finder",
}

-- Google search base URL used when the selection is not a URL
local GOOGLE_SEARCH_URL = "https://www.google.com/search?q="

-- Wait after Cmd+Opt+C for Finder to populate the clipboard with the path
local FINDER_PATH_SETTLE_SEC = 0.15

-- Wait after Cmd+C for a text selection to reach the clipboard
local COPY_SETTLE_SEC        = 0.2

-- Delay before centering newly opened windows (give them time to appear)
local CENTER_DELAY_SEC       = 0.3

-- Additional delay for navigating to a sub-folder after the app focuses
local FOLDER_OPEN_DELAY_SEC  = 0.12

-- Clipboard ownership for copy_or_open_path. Overlapping actions keep the first
-- user snapshot, and a native false/nil restore retains ownership for retry.
local _copy_capture_in_flight = false
local _copy_saved_prior = nil
local _copy_capture_generation = 0
local _copy_capture_apps_generation = nil
local _copy_recovery_only = false
local _copy_capture_timer = nil
local _copy_restore_retry_timer = nil

-- App navigation owns two kinds of asynchronous native capabilities: deferred
-- timers and ShellRunner processes.  They share one admission generation so a
-- Bindings PAUSE can fence every callback before attempting fallible cleanup.
-- Refused cleanup retains the exact handle and blocks every successor until a
-- callback/onSettled observer proves that capability terminal.
local _apps_paused = false
local _apps_generation = 0
local _apps_acquisitions = 0
local _apps_callback_depth = 0
local _next_apps_owner_id = 0
local _apps_timers = {}
local _apps_shells = {}





-- ===================================
-- ===================================
-- ======= 2/ Internal Helpers =======
-- ===================================
-- ===================================

local function next_apps_owner_id()
	_next_apps_owner_id = _next_apps_owner_id + 1
	return _next_apps_owner_id
end

local function apps_entry_authorized(entry)
	return _apps_paused ~= true
		and entry.discard ~= true
		and entry.generation == _apps_generation
end

local function apps_shell_authorized(entry)
	return apps_entry_authorized(entry)
		and entry.released ~= true
		and _apps_shells[entry.id] == entry
end

local function apps_generation_authorized(generation)
	return _apps_paused ~= true and generation == _apps_generation
end

local function copy_capture_authorized(capture_generation, apps_generation)
	return apps_generation_authorized(apps_generation)
		and _copy_capture_in_flight == true
		and capture_generation == _copy_capture_generation
		and apps_generation == _copy_capture_apps_generation
end

local function apps_owner_pending()
	return _apps_acquisitions ~= 0 or _apps_callback_depth ~= 0
		or next(_apps_timers) ~= nil
		or next(_apps_shells) ~= nil
		or _copy_capture_in_flight == true
end

local function apps_cleanup_debt()
	if _apps_acquisitions ~= 0 then return true end
	for _, entry in pairs(_apps_timers) do
		if entry.discard == true or entry.committed ~= true then return true end
	end
	for _, entry in pairs(_apps_shells) do
		if entry.discard == true or entry.committed ~= true then return true end
	end
	return _copy_recovery_only == true
end

local function apps_admission_open()
	return _apps_paused ~= true and not apps_cleanup_debt()
end

local function invoke_apps_callback(label, fn, ...)
	if type(fn) ~= "function" then return true end
	local args = table.pack(...)
	_apps_callback_depth = _apps_callback_depth + 1
	local ok, err = xpcall(function()
		return fn(table.unpack(args, 1, args.n))
	end, debug.traceback)
	_apps_callback_depth = _apps_callback_depth - 1
	if not ok then
		Logger.error(LOG, "%s callback failed — %s.", tostring(label), tostring(err))
		return false
	end
	return true
end

local drain_apps_timer

local function observe_apps_timer(entry)
	if entry.observing == true or type(entry.handle) ~= "table" then return end
	entry.observing = true
	local observed_ok, observed = pcall(TimerScheduler.onSettled, entry.handle, function()
		-- TimerScheduler settles before invoking an ordinary due callback.  Keep
		-- that entry until the callback marks it due; cancellation/debt paths can
		-- retire immediately from this observer.
		if entry.due == true or entry.discard == true
			or entry.generation ~= _apps_generation or _apps_paused == true then
			drain_apps_timer(entry)
		end
	end)
	if not observed_ok or observed ~= true then
		entry.observing = false
		Logger.error(LOG, "%s timer settlement observer was refused: %s.",
			tostring(entry.label), tostring(observed))
	end
end

drain_apps_timer = function(entry)
	if _apps_timers[entry.id] ~= entry then return true end
	if type(entry.handle) == "table" and entry.handle.timer ~= nil then return false end
	local deliver = entry.due == true and apps_entry_authorized(entry)
	entry.committed = false
	entry.callback_active = true
	if type(entry.on_settled) == "function" then
		invoke_apps_callback(entry.label .. " settlement", entry.on_settled, entry)
	end
	if deliver then
		invoke_apps_callback(entry.label, entry.callback)
	end
	entry.callback_active = false
	if _apps_timers[entry.id] == entry then _apps_timers[entry.id] = nil end
	return true
end

local function cancel_apps_timer(entry)
	if entry == nil or _apps_timers[entry.id] ~= entry then return true end
	entry.discard = true
	entry.committed = false
	if entry.callback_active == true then return false end
	local cancel_ok, cancelled = pcall(TimerScheduler.cancel, entry.handle)
	if cancel_ok and cancelled == true then
		if _apps_timers[entry.id] == entry then drain_apps_timer(entry) end
		return _apps_timers[entry.id] ~= entry
	end
	observe_apps_timer(entry)
	Logger.error(LOG, "%s timer cleanup remains pending: %s.",
		tostring(entry.label), tostring(cancel_ok and cancelled or cancelled))
	return false
end

local function schedule_apps_timer(delay, label, callback, on_settled, cleanup_only)
	if _apps_paused == true or (cleanup_only ~= true and not apps_admission_open()) then
		return nil, false
	end
	local entry = {
		id = next_apps_owner_id(),
		label = label,
		callback = callback,
		on_settled = on_settled,
		generation = _apps_generation,
		committed = false,
		discard = false,
		due = false,
	}
	_apps_acquisitions = _apps_acquisitions + 1
	local call_ok, handle, committed = pcall(TimerScheduler.after, delay, function()
		entry.due = true
		drain_apps_timer(entry)
	end)
	_apps_acquisitions = _apps_acquisitions - 1
	if call_ok and type(handle) == "table" then
		entry.handle = handle
		if handle.timer ~= nil or committed == true then
			_apps_timers[entry.id] = entry
			observe_apps_timer(entry)
		end
	end
	if not call_ok or type(handle) ~= "table" or committed ~= true
		or handle.timer == nil or not apps_entry_authorized(entry) then
		entry.discard = true
		if _apps_timers[entry.id] == entry then cancel_apps_timer(entry) end
		return entry, false
	end
	entry.committed = true
	return entry, true
end

local function release_apps_shell(entry)
	if _apps_shells[entry.id] == entry then _apps_shells[entry.id] = nil end
	entry.released = true
	entry.committed = false
end

local function observe_apps_shell(entry)
	if entry.released == true or entry.observing == true
		or type(entry.handle) ~= "table" then return end
	entry.observing = true
	local observed_ok, observed = pcall(entry.handle.onSettled, function()
		if entry.callback_active ~= true then release_apps_shell(entry) end
	end)
	if not observed_ok or observed ~= true then
		entry.observing = false
		Logger.error(LOG, "%s process settlement observer was refused: %s.",
			tostring(entry.label), tostring(observed))
	end
end

local function terminate_apps_shell(entry)
	if entry == nil or _apps_shells[entry.id] ~= entry then return true end
	entry.discard = true
	entry.committed = false
	if entry.callback_active == true then return false end
	if type(entry.handle) ~= "table" then
		-- The logical owner is published before ShellRunner returns its native
		-- handle. A re-entrant PAUSE must wait for that acquisition boundary.
		return false
	end
	local terminate_ok, accepted, state = pcall(entry.handle.terminate)
	local settled_ok, settled = pcall(entry.handle.isSettled)
	if settled_ok and settled == true then
		release_apps_shell(entry)
		return true
	end
	observe_apps_shell(entry)
	if not terminate_ok or accepted ~= true or state ~= "settled" then
		Logger.error(LOG, "%s process cleanup remains pending: %s (%s).",
			tostring(entry.label), tostring(terminate_ok and accepted or accepted),
			tostring(state))
	end
	return false
end

local function start_owned_shell(method, payload, label, on_done)
	if not apps_admission_open() then return false end
	local entry = {
		id = next_apps_owner_id(),
		label = label,
		generation = _apps_generation,
		committed = false,
		discard = false,
		released = false,
		dispatching = true,
		terminal_sent = false,
	}
	_apps_shells[entry.id] = entry
	_apps_acquisitions = _apps_acquisitions + 1
	local function terminal(...)
		if entry.terminal_sent == true then return end
		entry.terminal_sent = true
		entry.terminal_args = table.pack(...)
		if entry.dispatching == true then return end
		if entry.committed == true and apps_shell_authorized(entry) then
			entry.callback_active = true
			invoke_apps_callback(label, on_done,
				table.unpack(entry.terminal_args, 1, entry.terminal_args.n))
			entry.callback_active = false
			local settled_ok, settled = pcall(entry.handle.isSettled)
			if settled_ok and settled == true and apps_shell_authorized(entry) then
				release_apps_shell(entry)
			end
		end
	end
	local call_ok, started, handle = pcall(method, payload, terminal)
	entry.dispatching = false
	_apps_acquisitions = _apps_acquisitions - 1
	if call_ok and type(handle) == "table" then
		entry.handle = handle
	end
	if not call_ok or started ~= true or type(handle) ~= "table"
		or type(handle.isSettled) ~= "function"
		or type(handle.onSettled) ~= "function"
		or type(handle.terminate) ~= "function"
		or not apps_shell_authorized(entry) then
		entry.discard = true
		entry.committed = false
		if type(handle) == "table" then terminate_apps_shell(entry)
		else release_apps_shell(entry) end
		return false
	end
	entry.committed = true
	if entry.terminal_args ~= nil and apps_shell_authorized(entry) then
		entry.callback_active = true
		invoke_apps_callback(label, on_done,
			table.unpack(entry.terminal_args, 1, entry.terminal_args.n))
		entry.callback_active = false
	end
	-- Register only after the owner is committed. onSettled is permitted to call
	-- back synchronously for an already-terminal process; release must therefore
	-- be the last word and must never be followed by re-committing this entry.
	observe_apps_shell(entry)
	return true
end

local function start_owned_open(target, label, on_done)
	return start_owned_shell(ShellRunner.open, target, label, on_done)
end

local function start_owned_applescript(script, label, on_done)
	return start_owned_shell(ShellRunner.applescript, script, label, on_done)
end
-- ===================================

--- Trims leading and trailing whitespace from a string.
--- @param s string The input string.
--- @return string The trimmed string.
local function trim(s)
	if type(s) ~= "string" then return "" end
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function begin_copy_capture()
	if not apps_admission_open() or _copy_capture_in_flight then
		Logger.debug(LOG, "copy_or_open_path ignored while another capture owns the clipboard.")
		return nil, nil
	end
	-- Publish the acquisition before crossing into the native pasteboard. A
	-- re-entrant PAUSE must see an in-progress boundary even though there is no
	-- clipboard snapshot to restore until readAllData returns.
	local acquisition_generation = _apps_generation
	_apps_acquisitions = _apps_acquisitions + 1
	local ok_read, prior_or_error = pcall(pasteboard.readAllData)
	_apps_acquisitions = _apps_acquisitions - 1
	if not ok_read or type(prior_or_error) ~= "table" then
		Logger.error(LOG, "copy_or_open_path: clipboard snapshot failed — %s.",
			tostring(prior_or_error))
		return nil, nil
	end
	if not apps_generation_authorized(acquisition_generation) then
		return nil, nil
	end
	_copy_saved_prior = prior_or_error
	_copy_capture_in_flight = true
	_copy_capture_generation = _copy_capture_generation + 1
	_copy_capture_apps_generation = acquisition_generation
	return _copy_saved_prior, _copy_capture_generation, acquisition_generation
end

local function stop_copy_timer(handle)
	if handle == nil then return true end
	return cancel_apps_timer(handle)
end

local function release_copy_capture(generation)
	if generation ~= _copy_capture_generation then return false end
	_copy_capture_in_flight = false
	_copy_saved_prior = nil
	_copy_capture_apps_generation = nil
	_copy_recovery_only = false
	_copy_capture_generation = _copy_capture_generation + 1
	return true
end

local function restore_copy_capture(prior, generation)
	if generation ~= _copy_capture_generation or not _copy_capture_in_flight then
		return false, "stale copy generation"
	end
	local ok_restore, restore_result
	if type(prior) == "table" and next(prior) ~= nil then
		ok_restore, restore_result = pcall(pasteboard.writeAllData, prior)
		ok_restore = ok_restore and restore_result == true
	else
		ok_restore, restore_result = pcall(pasteboard.clearContents)
	end
	if ok_restore then
		release_copy_capture(generation)
		return true, nil
	end
	_copy_recovery_only = true
	return false, restore_result
end

local queue_copy_restore_retry
local abort_copy_capture

local function arm_copy_timer(slot, delay, label, generation, callback)
	local entry
	local committed
	local function clear_slot()
		if slot == "capture" and _copy_capture_timer == entry then
			_copy_capture_timer = nil
		elseif slot == "restore" and _copy_restore_retry_timer == entry then
			_copy_restore_retry_timer = nil
		end
	end
	entry, committed = schedule_apps_timer(delay,
		"copy_or_open_path " .. label, function()
			if generation ~= _copy_capture_generation then return end
			local ok_callback, callback_error = xpcall(callback, debug.traceback)
			if not ok_callback then
				Logger.error(LOG, "copy_or_open_path %s callback failed — %s.",
					label, tostring(callback_error))
				if abort_copy_capture then
					abort_copy_capture(_copy_saved_prior, generation,
						label .. " callback failed", callback_error)
				end
			end
		end, clear_slot, slot == "restore")
	if committed ~= true then
		return false, "timer acquisition refused"
	end
	if slot == "capture" then _copy_capture_timer = entry
	else _copy_restore_retry_timer = entry end
	return true, nil
end

queue_copy_restore_retry = function(prior, generation)
	if _copy_restore_retry_timer then return true end
	if _apps_paused == true then return false end
	local function attempt_restore()
		local restored, restore_error = restore_copy_capture(prior, generation)
		if restored or generation ~= _copy_capture_generation then return end
		Logger.error(LOG, "copy_or_open_path clipboard restore retry refused — %s.",
			tostring(restore_error))
		queue_copy_restore_retry(prior, generation)
	end
	local armed, timer_error = arm_copy_timer(
		"restore", COPY_SETTLE_SEC, "restore retry", generation, attempt_restore)
	if armed then return true end
	-- A clean timer-construction refusal leaves no future native terminal to wake
	-- a retry. Make one immediate exact restore attempt; a second refusal remains
	-- explicit lifecycle debt and is retried by the next action or PAUSE boundary.
	local restored, restore_error = restore_copy_capture(prior, generation)
	if restored then return true end
	Logger.error(LOG, "copy_or_open_path clipboard restore retry could not be armed — %s.",
		tostring(timer_error or restore_error))
	return false
end

abort_copy_capture = function(prior, generation, reason, detail)
	stop_copy_timer(_copy_capture_timer)
	local restored, restore_error = restore_copy_capture(prior, generation)
	if not restored and generation == _copy_capture_generation then
		queue_copy_restore_retry(prior, generation)
	end
	Logger.error(LOG, "copy_or_open_path %s — %s (restore=%s).",
		reason, tostring(detail), tostring(restore_error))
end

--- Heuristically checks whether a string looks like a URL and normalises it.
--- @param s string The candidate string.
--- @return string|nil Normalised URL, or nil if not a URL.
local function is_probable_url(s)
	local x = trim(s)
	if x:match("^https?://") then return x end
	if x:match("^www%.") or (x:match("%.%a%a") and not x:match("%s")) then
		return "http://" .. x
	end
	return nil
end

--- Returns true when the given app name matches a known file manager.
--- @param appname string Application name to test.
--- @return boolean True if it is a file manager.
local function is_finder_like(appname)
	if type(appname) ~= "string" then return false end
	local ln = appname:lower()
	for _, v in ipairs(FILE_MANAGERS) do
		if ln:find(v, 1, true) then return true end
	end
	return false
end

--- Tries to focus or launch the first matching application from a priority list.
--- @param apps table Ordered list of application names.
--- @return boolean True if one was successfully activated.
local function launch_first_available(apps)
	if type(apps) ~= "table" then return false end

	local ok_run, running = pcall(hs.application.runningApplications)
	running = ok_run and running or {}

	for _, name in ipairs(apps) do
		local lname = name:lower()

		-- Prefer an already-running instance to avoid a slow cold launch
		for _, a in ipairs(running) do
			local ok_n, an = pcall(function() return a:name() end)
			if ok_n and an and an:lower():find(lname, 1, true) then
				local ok_activate, activated = pcall(function() return a:activate() end)
				if ok_activate and activated == true then return true end
			end
		end

		if WindowManager.activate(name) or AppLauncher.launch(name) then return true end
	end

	return false
end

--- Centers all visible standard windows of an application on their respective screens.
--- @param app userdata The hs.application object.
local function center_windows_of_app(app)
	if not app or type(app.allWindows) ~= "function" then return end
	local ok, wins = pcall(function() return app:allWindows() end)
	if not ok or not wins then return end

	for _, w in ipairs(wins) do
		if w:isStandard() and w:isVisible() then
			local screen = w:screen()
			if screen then
				local sf = screen:frame()
				local wf = w:frame()
				pcall(function()
					w:setFrame({
						x = sf.x + math.floor((sf.w - wf.w) / 2),
						y = sf.y + math.floor((sf.h - wf.h) / 2),
						w = wf.w,
						h = wf.h,
					})
				end)
			end
		end
	end
end

--- Centers the frontmost application's windows after a short delay.
--- @param delay number Seconds to wait before centering.
local function center_frontmost_after(delay)
	local _, committed = schedule_apps_timer(tonumber(delay) or 0.2,
		"center frontmost application", function()
		local ok, f = pcall(hs.application.frontmostApplication)
		if ok and f then center_windows_of_app(f) end
	end)
	return committed == true
end

--- Opens a URL directly, or falls back to a Google search for plain text.
--- @param text string The selected text or path to act on.
local function open_or_search(text)
	local trimmed = trim(text)
	local url     = is_probable_url(trimmed)
	if url then
		pcall(urlevent.openURL, url)
	else
		local q = http.encodeForQuery(trimmed)
		pcall(urlevent.openURL, GOOGLE_SEARCH_URL .. q)
	end
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Focuses an existing Finder window already showing the given folder path.
--- Compares each Finder window's target via AppleScript (handles localised
--- titles like "Téléchargements" vs "Downloads" reliably).
--- The result is delivered to a callback rather than returned: this script walks
--- every open Finder window, so running it synchronously froze the whole driver —
--- the keyboard tap included — for as long as that took, on a keystroke.
--- @param folder_path string POSIX path of the folder to look for.
--- @param on_result function Called as on_result(focused) with a boolean.
local function focus_existing_finder_window(folder_path, on_result)
	local script = text_utils.applescript_format([[
		tell application "Finder"
			set targetPath to POSIX file "%s" as alias
			repeat with w in windows
				try
					if (target of w as alias) is targetPath then
						set index of w to 1
						activate
						return "ok"
					end if
				end try
			end repeat
		end tell
		return "none"
	]], folder_path)

	return start_owned_applescript(script, "Finder window probe", function(ok, result)
		on_result(ok and result == "ok")
	end)
end

--- Opens the Downloads folder via the best available file manager.
--- Reuses an existing window if one is already showing Downloads.
function M.open_downloads()
	if not apps_admission_open() then return false end
	local home = os.getenv("HOME") or "~"
	local downloads = home .. "/Downloads"

	-- The probe is asynchronous now, so everything that depended on its answer
	-- moves into the continuation.
	return focus_existing_finder_window(downloads, function(focused)
		if focused then
			Logger.info(LOG, "Focused existing Finder window for Downloads.")
			center_frontmost_after(CENTER_DELAY_SEC)
			return
		end

		if not launch_first_available(FILE_MANAGERS) then
			start_owned_open(downloads, "open Downloads")
		else
			schedule_apps_timer(FOLDER_OPEN_DELAY_SEC,
				"deferred Downloads open", function()
					start_owned_open(downloads, "open Downloads")
				end)
		end
		center_frontmost_after(CENTER_DELAY_SEC)
	end)
end

--- Opens the home directory via the best available file manager.
function M.open_finder()
	if not apps_admission_open() then return false end
	local home = os.getenv("HOME") or "~"
	if not launch_first_available(FILE_MANAGERS) then
		start_owned_open(home, "open home folder")
	else
		schedule_apps_timer(FOLDER_OPEN_DELAY_SEC,
			"deferred home folder open", function()
				start_owned_open(home, "open home folder")
			end)
	end
	center_frontmost_after(CENTER_DELAY_SEC)
	return true
end

--- Opens the given ChatGPT URL in the default browser. The caller resolves the
--- URL (live-configured value or the manifest default) — this function is a
--- thin, side-effect-only opener so there is a single source of truth for URL
--- resolution (modules.shortcuts.bindings) instead of a second config reader here.
--- @param url string The ChatGPT URL to open.
function M.open_chatgpt(url)
	if not apps_admission_open() then return false end
	Logger.debug(LOG, "Opening ChatGPT URL: %s.", url)
	local ok, opened = pcall(urlevent.openURL, url)
	return ok and opened ~= false
end

--- Opens macOS System Settings (falls back to System Preferences on older macOS).
function M.open_settings()
	if not apps_admission_open() then return false end
	if not AppLauncher.launch("System Settings") then
		AppLauncher.launch("System Preferences")
	end
	center_frontmost_after(CENTER_DELAY_SEC)
	return true
end

--- In a file manager: copies the current path (Cmd+Opt+C).
--- Elsewhere: copies the text selection and opens it as a URL or Google search.
function M.copy_or_open_path()
	if not apps_admission_open() then return false end
	local name = WindowInfo.getFocused().appId
	if name == "" then
		local ok, front = pcall(hs.application.frontmostApplication)
		name = (ok and front) and front:name() or ""
	end

	if is_finder_like(name) then
		-- Snapshot and CLEAR before asking Finder for the path. A non-empty clipboard
		-- afterwards only proves Finder wrote something if it was empty beforehand —
		-- without this, whatever the user had copied earlier was read back as "the
		-- path", reported in the success notification, and the selection fallback
		-- below became unreachable. The sibling branch already clears for exactly
		-- this reason; this one did not.
		local prior, capture_generation, capture_apps_generation = begin_copy_capture()
		if capture_generation == nil then return false end
		local ok_clear, clear_error = pcall(pasteboard.clearContents)
		if not ok_clear then
			abort_copy_capture(prior, capture_generation, "clipboard clear failed", clear_error)
			return false
		end
		if not copy_capture_authorized(capture_generation, capture_apps_generation) then
			return false
		end
		local function read_finder_path()
			if not copy_capture_authorized(capture_generation, capture_apps_generation) then
				return
			end
			local ok_p, p = pcall(pasteboard.getContents)
			if not copy_capture_authorized(capture_generation, capture_apps_generation) then
				return
			end
			if ok_p and p and p ~= "" then
				if release_copy_capture(capture_generation) ~= true
					or not apps_generation_authorized(capture_apps_generation) then
					return
				end
				notifications.notify(string.format(i18n.get("shortcuts.copy_path_notif"), p), nil, "success")
				return
			end
			if not ok_p then
				abort_copy_capture(prior, capture_generation, "Finder path read failed", p)
				return
			end

			-- Finder did not populate the clipboard — copy the selection instead
			Logger.debug(LOG, "Finder did not write a path — falling back to copying the selection.")
			local function read_fallback_selection()
				if not copy_capture_authorized(capture_generation, capture_apps_generation) then
					return
				end
				local ok_sel, sel = pcall(pasteboard.getContents)
				if not copy_capture_authorized(capture_generation, capture_apps_generation) then
					return
				end
				local restored, restore_error = restore_copy_capture(prior, capture_generation)
				if not apps_generation_authorized(capture_apps_generation) then return end
				if not restored and capture_generation == _copy_capture_generation then
					queue_copy_restore_retry(prior, capture_generation)
				end
				if not ok_sel then
					Logger.error(LOG, "copy_or_open_path selection read failed — %s.", tostring(sel))
					return
				end
				if sel and sel ~= "" then open_or_search(sel) end
			end
			local armed, timer_error = arm_copy_timer(
				"capture", COPY_SETTLE_SEC, "fallback selection", capture_generation,
				read_fallback_selection)
			if not armed then
				abort_copy_capture(prior, capture_generation, "fallback timer refused", timer_error)
				return
			end
			local ok_copy, copied = pcall(
				SyntheticInput.emit_key_stroke, { "cmd" }, "c", KEYSTROKE_NO_DELAY_US)
			if not ok_copy or copied ~= true then
				abort_copy_capture(prior, capture_generation,
					"fallback copy shortcut refused", copied)
			end
		end
		local armed, timer_error = arm_copy_timer(
			"capture", FINDER_PATH_SETTLE_SEC, "Finder path", capture_generation,
			read_finder_path)
		if not armed then
			abort_copy_capture(prior, capture_generation, "Finder timer refused", timer_error)
			return false
		end
		local ok_copy, copied = pcall(
			SyntheticInput.emit_key_stroke, { "cmd", "alt" }, "c", KEYSTROKE_NO_DELAY_US)
		if not ok_copy or copied ~= true then
			abort_copy_capture(prior, capture_generation, "Finder copy shortcut refused", copied)
			return false
		end
		if not copy_capture_authorized(capture_generation, capture_apps_generation) then
			return false
		end
		return true
	end

	-- Outside a file manager: copy selection and open or search
	local prior, capture_generation, capture_apps_generation = begin_copy_capture()
	if capture_generation == nil then return false end
	local ok_clear, clear_error = pcall(pasteboard.clearContents)
	if not ok_clear then
		abort_copy_capture(prior, capture_generation, "clipboard clear failed", clear_error)
		return false
	end
	if not copy_capture_authorized(capture_generation, capture_apps_generation) then
		return false
	end
	local function read_selection()
		if not copy_capture_authorized(capture_generation, capture_apps_generation) then
			return
		end
		local ok_sel, sel = pcall(pasteboard.getContents)
		if not copy_capture_authorized(capture_generation, capture_apps_generation) then
			return
		end
		local restored, restore_error = restore_copy_capture(prior, capture_generation)
		if not apps_generation_authorized(capture_apps_generation) then return end
		if not restored and capture_generation == _copy_capture_generation then
			queue_copy_restore_retry(prior, capture_generation)
		end
		if not ok_sel then
			Logger.error(LOG, "copy_or_open_path selection read failed — %s.", tostring(sel))
			return
		end
		if sel and sel ~= "" then open_or_search(sel) end
	end
	local armed, timer_error = arm_copy_timer(
		"capture", COPY_SETTLE_SEC, "selection", capture_generation, read_selection)
	if not armed then
		abort_copy_capture(prior, capture_generation, "selection timer refused", timer_error)
		return false
	end
	local ok_copy, copied = pcall(
		SyntheticInput.emit_key_stroke, { "cmd" }, "c", KEYSTROKE_NO_DELAY_US)
	if not ok_copy or copied ~= true then
		abort_copy_capture(prior, capture_generation, "copy shortcut refused", copied)
		return false
	end
	if not copy_capture_authorized(capture_generation, capture_apps_generation) then
		return false
	end
	return true
end





-- ========================================
-- ========================================
-- ======= 4/ Bindings Child Owner ========
-- ========================================
-- ========================================

local function settle_apps_actions(boundary)
	local timers = {}
	for _, entry in pairs(_apps_timers) do timers[#timers + 1] = entry end
	local shells = {}
	for _, entry in pairs(_apps_shells) do shells[#shells + 1] = entry end

	local settled = _apps_acquisitions == 0 and _apps_callback_depth == 0
	for _, entry in ipairs(timers) do
		if cancel_apps_timer(entry) ~= true then settled = false end
	end
	for _, entry in ipairs(shells) do
		if terminate_apps_shell(entry) ~= true then settled = false end
	end
	if _copy_capture_in_flight == true then
		local generation = _copy_capture_generation
		local prior = _copy_saved_prior
		local restored, restore_error = restore_copy_capture(prior, generation)
		if not restored then
			settled = false
			Logger.error(LOG, "%s clipboard restore remains pending: %s.",
				tostring(boundary), tostring(restore_error))
		end
	end
	return settled == true and not apps_owner_pending()
end

--- Fences and joins all app-navigation timers, processes and clipboard state.
--- @return boolean settled
function M.pause_apps_actions()
	if _apps_paused ~= true then
		_apps_generation = _apps_generation + 1
		_apps_paused = true
	end
	return settle_apps_actions("apps pause") == true
end

--- Reopens admission only after every pre-pause capability has settled. User
--- navigation interrupted by PAUSE is deliberately not replayed.
--- @return boolean settled
function M.resume_apps_actions()
	if _apps_paused ~= true then
		-- RESUME is an idempotent state transition. In particular it must not
		-- settle/cancel legitimate ACTIVE work merely because the caller repeats it.
		return not apps_cleanup_debt()
	end
	if settle_apps_actions("apps resume cleanup") ~= true then
		_apps_paused = true
		return false
	end
	_apps_generation = _apps_generation + 1
	_apps_paused = false
	return true
end

--- Stops app work for Bindings.stop(); a later start may reopen it via resume.
--- @return boolean settled
function M.stop_apps_actions()
	return M.pause_apps_actions()
end

--- @return boolean paused
function M.is_apps_actions_paused()
	return _apps_paused == true
end

--- @return boolean pending
function M.has_pending_apps_action()
	return apps_owner_pending()
end

return M
