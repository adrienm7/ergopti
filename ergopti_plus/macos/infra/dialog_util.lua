--- infra/dialog_util.lua

--- ==============================================================================
--- MODULE: Dialog Util
--- DESCRIPTION:
--- Native dialog wrappers that always bring Hammerspoon to the front
--- before showing a modal. macOS only routes Return/Escape to the dialog's
--- default/cancel button when the owning app is frontmost — without an explicit
--- focus step, dialogs opened from a menubar click appear behind the current
--- app and Enter is captured by whatever the user was typing in instead.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth: Every dialog in the codebase goes through one
---    helper, so the "focus before open" rule cannot drift from site to site.
--- 2. Native captions: Wrappers use hs.dialog.* where its API admits a title;
---    application selection uses the existing in-process hs.osascript port.
--- 3. Safe Focus: hs.focus is wrapped in pcall so a transient focus failure
---    (rare but possible during app-switch races) never prevents the dialog
---    from opening.
--- 4. More than two buttons: an error that offers several fixes needs more
---    buttons than hs.dialog.blockAlert holds, so choose() asks through an
---    AppleScript alert (three buttons) or, beyond that, a list.
--- ==============================================================================

local hs = hs

local Logger         = require("infra.logger")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local text_utils     = require("infra.text_utils")
local WindowTitles   = require("window_titles")

-- Absolute path: this process does not inherit the login shell's PATH.
local OPEN_BIN = "/usr/bin/open"
local LOG    = "dialog_util"

local M = {}
local focus_timer_state = {}

--- Cancels one exact deferred-focus timer and retains failed cleanup for retry.
--- @param handle table TimerScheduler handle.
--- @return boolean settled True only when the native timer was released.
local function cancel_focus_timer(handle)
	local ok, result_or_err = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if ok and result_or_err == true then
		focus_timer_state[handle] = nil
		return true
	end
	focus_timer_state[handle] = false
	Logger.error(LOG, "Deferred dialog-focus timer cleanup remains pending: %s.",
		tostring(result_or_err))
	return false
end

--- Retries only rejected/fired timer cleanup; committed pending nudges stay live.
local function retry_focus_timer_cleanup()
	local snapshot = {}
	for handle, committed in pairs(focus_timer_state) do
		if committed ~= true then snapshot[#snapshot + 1] = handle end
	end
	for _, handle in ipairs(snapshot) do cancel_focus_timer(handle) end
end





-- ==========================================
-- ==========================================
-- ======= 1/ Focused Dialog Wrappers =======
-- ==========================================
-- ==========================================

--- Brings Hammerspoon to the front so the next modal dialog receives keyboard
--- focus. Wrapped in pcall because hs.focus can briefly fail during app
--- transitions and we never want that to stop the caller from opening its
--- dialog.
---
--- @param defer_open boolean|nil True only for the NON-BLOCKING wrapper. The
---   deferred `open` below cannot run before a modal dialog is dismissed — the
---   dialog owns the runloop — so for the blocking wrappers it is dead with
---   respect to its purpose while keeping its side effect: it fires after the
---   user has dismissed the dialog and moved on, and raises Hammerspoon over
---   whatever they switched to. Two synchronous do_focus() calls are what
---   actually focuses the dialog; this third mechanism only helps the case where
---   the runloop keeps turning.
local function focus_hammerspoon(defer_open)
	retry_focus_timer_cleanup()
	local function do_focus()
		local ok, err = pcall(function() return hs.focus(true) end)
		if not ok then
			Logger.debug(LOG, "hs.focus raised before dialog: %s.", tostring(err))
		end
		pcall(function()
			local app = hs.application.get("Hammerspoon")
			if app then app:activate(true) end
		end)
	end

	do_focus()
	do_focus()
	-- Third mechanism: raise the app again a tenth of a second later, for the case
	-- where the dialog was opened from a menubar click and the click itself steals
	-- focus back after the two calls above.
	--
	-- It only reaches a dialog whose runloop keeps turning. hs.dialog.blockAlert
	-- and hs.dialog.textPrompt park the main thread and its default runloop until
	-- the user dismisses them, so a timer armed here cannot fire until after
	-- dismissal — at which point there is no dialog left to focus and the raise
	-- lands on whatever the user switched to instead. That is why only the
	-- non-blocking wrapper asks for it.
	if not defer_open then return end
	local schedule_ok, handle_or_err, committed = xpcall(function()
		local bundlePath = hs.processInfo.bundlePath
		if bundlePath then
			-- Asynchronous, and argv rather than a shell string. `open` waits on
			-- Launch Services, so the blocking form parked the single runloop for that
			-- whole window immediately before putting up a modal dialog — the one
			-- moment the driver can least afford to stop servicing the keyboard tap.
			-- The argv form also retires the hand-rolled single-quote escaping, which
			-- duplicated text_utils.shell_quote and covered only the quote.
			--
			-- The GC pitfall the old comment worried about is handled by the spawner:
			-- it pins the task in its own long-lived table before starting it and
			-- releases it in the completion callback.
			local candidate = nil
			local handle, timer_committed = TimerScheduler.after(0.1, function()
				if focus_timer_state[candidate] ~= true then return end
				focus_timer_state[candidate] = false
				if candidate.timer == nil then
					focus_timer_state[candidate] = nil
				else
					cancel_focus_timer(candidate)
				end
				local spawn_handle = ShellRunner.spawn(OPEN_BIN, { bundlePath })
				if spawn_handle then spawn_handle.start() end
			end)
			candidate = handle
			return handle, timer_committed
		end
		return nil, false
	end, debug.traceback)
	local candidate = handle_or_err
	if type(candidate) == "table" then focus_timer_state[candidate] = committed == true end
	if not schedule_ok or type(candidate) ~= "table" or committed ~= true then
		if type(candidate) == "table" then cancel_focus_timer(candidate) end
		Logger.error(LOG, "Deferred dialog-focus timer could not be committed: %s.",
			tostring(handle_or_err))
		return false
	end
	return true
end

--- Focus-aware wrapper around hs.dialog.blockAlert.
--- Returns whatever hs.dialog.blockAlert returns (clicked button name).
--- @return string The text of the button that was clicked.
function M.block_alert(...)
	focus_hammerspoon()
	return hs.dialog.blockAlert(...)
end

--- Focus-aware wrapper around hs.dialog.textPrompt.
--- Returns whatever hs.dialog.textPrompt returns (clicked button + text).
--- @return string The text of the button that was clicked.
--- @return string The text entered by the user.
function M.text_prompt(...)
	focus_hammerspoon()
	return hs.dialog.textPrompt(...)
end

-- An AppleScript alert holds three buttons: the cancel one and two choices
local MAX_ALERT_CHOICES = 2

--- Quotes a list of labels as an AppleScript list literal, ready to sit in a
--- string.format pattern: a "%" in a label (a model name) is doubled.
--- @param labels table Array of strings.
--- @return string
local function applescript_list(labels)
	local quoted = {}
	for index, label in ipairs(labels) do
		quoted[index] = '"' .. text_utils.applescript_escape(label) .. '"'
	end
	return (("{" .. table.concat(quoted, ", ") .. "}"):gsub("%%", "%%%%"))
end

--- Builds the AppleScript that asks for one of several choices. Up to two are
--- buttons of one alert, the first the default at the right; more are a list,
--- because an alert holds three buttons at most. Both return the chosen label,
--- or "" when the user cancels.
--- @param title string Window title.
--- @param message string Text above the choices.
--- @param choices table Labels, the preferred first.
--- @param cancel_label string Label of the cancel button.
--- @param ok_label string Label of the list's confirm button.
--- @return string script
function M.choose_script(title, message, choices, cancel_label, ok_label)
	title = WindowTitles.compose(title)
	if #choices <= MAX_ALERT_CHOICES then
		-- AppleScript lays the buttons out from left to right
		local buttons = { cancel_label }
		for index = #choices, 1, -1 do buttons[#buttons + 1] = choices[index] end
		return text_utils.applescript_format([[
try
	set answer to display dialog "%s" with title "%s" buttons ]] .. applescript_list(buttons)
			.. [[ default button "%s" cancel button "%s" with icon caution
	return button returned of answer
on error number -128
	return ""
end try]], message, title, choices[1], cancel_label)
	end
	return text_utils.applescript_format([[
set picked to choose from list ]] .. applescript_list(choices)
		.. [[ with title "%s" with prompt "%s" default items {"%s"} OK button name "%s" cancel button name "%s"
if picked is false then return ""
return item 1 of picked]], title, message, choices[1], ok_label, cancel_label)
end

--- Focus-aware choice among several labelled fixes, with a cancel button.
--- Modal like block_alert: opened from a menu or a notification click, never
--- from the keyboard tap.
--- @param title string Window title.
--- @param message string Text above the choices.
--- @param choices table Non-empty array of distinct labels, the preferred first.
--- @param cancel_label string Label of the cancel button.
--- @param ok_label string Label of the confirm button when the choices are a list.
--- @return integer|nil index The chosen label's index, nil when cancelled.
function M.choose(title, message, choices, cancel_label, ok_label)
	if type(choices) ~= "table" or #choices == 0 then
		error("dialog_util.choose: at least one choice is required", 2)
	end
	local seen = { [cancel_label] = true }
	for _, label in ipairs(choices) do
		if type(label) ~= "string" or label == "" or seen[label] then
			error("dialog_util.choose: choices must be distinct non-empty labels", 2)
		end
		seen[label] = true
	end
	for _, value in ipairs({ title, message, cancel_label, ok_label }) do
		if type(value) ~= "string" or value == "" then
			error("dialog_util.choose: title, message and button labels are required", 2)
		end
	end
	focus_hammerspoon()
	local ok, answer, raw = hs.osascript.applescript(
		M.choose_script(title, message, choices, cancel_label, ok_label))
	if ok ~= true or type(answer) ~= "string" then
		error("dialog_util.choose: the dialog failed: " .. tostring(raw), 2)
	end
	if answer == "" then return nil end
	for index, label in ipairs(choices) do
		if label == answer then return index end
	end
	error("dialog_util.choose: the dialog answered an unknown choice", 2)
end

--- The folder the application chooser opens on.
local APPLICATIONS_DIR = "/Applications"

--- Builds the native application-only panel through the in-process AppleScript port.
--- Hammerspoon's chooseFileOrFolder API has no caption argument.
--- @param message string The panel's unchanged message.
--- @param title string|nil The translated, brandless parameter title.
--- @return string script The escaped native panel source.
function M.application_picker_script(message, title)
	return text_utils.applescript_format([[
use framework "AppKit"
use scripting additions
set panel to current application's NSOpenPanel's openPanel()
panel's setTitle:"%s"
panel's setMessage:"%s"
panel's setDirectoryURL:(current application's NSURL's fileURLWithPath:"%s")
panel's setCanChooseFiles:true
panel's setCanChooseDirectories:false
panel's setAllowsMultipleSelection:false
panel's setAllowedFileTypes:{"app"}
panel's setResolvesAliases:true
set response to panel's runModal()
if response is not (current application's NSModalResponseOK) then return missing value
set chosenURLs to panel's |URLs|()
if (chosenURLs's |count|()) is 0 then return missing value
set chosenURL to chosenURLs's firstObject()
return (chosenURL's |path|()) as text
]], WindowTitles.compose(title), message, APPLICATIONS_DIR)
end

--- Focus-aware application chooser: an open panel on /Applications that
--- accepts application bundles only. Modal, like text_prompt, and opened from
--- a menu, never from the keyboard tap.
--- @param message string The panel's message.
--- @param title string|nil The translated, brandless parameter title.
--- @return string|nil path The chosen .app path, nil when cancelled.
function M.choose_application(message, title)
	focus_hammerspoon()
	local ok, path = hs.osascript.applescript(M.application_picker_script(message, title))
	if ok ~= true then
		error("dialog_util.choose_application: the native application picker failed", 2)
	end
	return type(path) == "string" and path ~= "" and path or nil
end

--- Focus-aware wrapper around hs.dialog.alert (the non-blocking variant).
--- Focusing is still useful so the alert renders on top of the user's current
--- app and its auto-dismiss / button-click behaviour is predictable.
function M.alert(...)
	-- The only wrapper whose dialog does not park the runloop, so the only one
	-- the deferred raise can reach in time to do what it is for.
	focus_hammerspoon(true)
	return hs.dialog.alert(...)
end

return M
