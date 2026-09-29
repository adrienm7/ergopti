--- modules/gestures/system_actions.lua

--- ==============================================================================
--- MODULE: System Actions (macOS)
--- DESCRIPTION:
--- The system actions of the shared catalogue that run a native command:
--- open an application, minimize every window, quit or force-quit the active
--- app, clear the clipboard, center the pointer, toggle the microphone and dark
--- mode, sleep the displays, empty the trash, eject the disks, and the Finder selection
--- helpers (quarantine removal, make executable, terminal and new text file in
--- the current folder). modules/gestures/actions.lua registers each one.
---
--- FEATURES & RATIONALE:
--- 1. Never blocks the runloop that feeds the keyboard tap: every command is an
---    owned asynchronous process (actions_aux_owner), started under the parent
---    that dispatched the action, so PAUSE of that parent fences its callback.
--- 2. Argument vectors, never a shell: a Finder path with a quote or a `$` in
---    it reaches xattr and chmod verbatim.
--- 3. The Finder selection is read as the recompilable AppleScript list that
---    `osascript -ss` prints and parsed by _shared/lua/file_selection, which
---    refuses a report it cannot read exactly instead of acting on part of it.
--- 4. Confirmation is not asked here: modules/gestures/actions.lua asks for
---    every action the catalogue declares `confirm = true` before it runs, and
---    hands a confirmed force quit the application that was frontmost when it
---    asked, since its alert has brought the driver to the front since.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local i18n = require("infra.i18n")
local notifications = require("infra.notifications")
local AuxOwner = require("modules.gestures.actions_aux_owner")
local Clipboard = require("adapters.clipboard")
local MouseControl = require("adapters.mouse_control")
local FileSystem = require("adapters.file_system")
local TccGrant = require("adapters.tcc_grant")
local WindowInfo = require("adapters.window_info")
local FileSelection = require("file_selection")
local AppParameter = require("app_parameter")

local LOG = "gestures.system_actions"





-- ===============================
-- ===============================
-- ======= 1/ Native Tools =======
-- ===============================
-- ===============================

-- Absolute paths: the Hammerspoon process does not inherit a login shell's PATH.
M.OSASCRIPT_BIN = "/usr/bin/osascript"
M.PMSET_BIN = "/usr/bin/pmset"
M.XATTR_BIN = "/usr/bin/xattr"
M.CHMOD_BIN = "/bin/chmod"
M.KILL_BIN = "/bin/kill"
M.OPEN_BIN = "/usr/bin/open"

-- The Gatekeeper attribute a downloaded file carries until the user opens it.
M.QUARANTINE_ATTRIBUTE = "com.apple.quarantine"

-- The terminal open_terminal_here opens: the one every macOS ships.
M.TERMINAL_APPLICATION = "Terminal"

-- The input level the microphone gets back when it was already muted before
-- the first toggle of the session, so no earlier level is known: macOS's own
-- default input level for a built-in microphone.
M.MIC_DEFAULT_RESTORE_LEVEL = 50

-- How many "<name> N.txt" candidates new_text_file_here tries before it gives
-- up on a folder that already holds every one of them.
M.NEW_FILE_NAME_ATTEMPTS = 100

-- The extension of the file new_text_file_here creates.
M.NEW_FILE_EXTENSION = ".txt"

-- Every AppleScript this module runs, by purpose. Data, so a test can pin the
-- exact source each action hands to osascript.
M.SCRIPTS = {
	minimize_all = table.concat({
		'tell application "System Events"',
		"\trepeat with visibleProcess in (every application process whose visible is true)",
		"\t\trepeat with processWindow in (every window of visibleProcess)",
		"\t\t\ttry",
		'\t\t\t\tset value of attribute "AXMinimized" of processWindow to true',
		"\t\t\tend try",
		"\t\tend repeat",
		"\tend repeat",
		"end tell",
	}, "\n"),
	-- %s is the driver's own bundle identifier: quitting it here would bypass
	-- the teardown of script_quit.
	frontmost_process = table.concat({
		'tell application "System Events"',
		"\tset frontProcess to first application process whose frontmost is true",
		"\tset frontId to bundle identifier of frontProcess",
		'\tif frontId is "%s" then return "self"',
		"\treturn (unix id of frontProcess as text) & \" \" & frontId",
		"end tell",
	}, "\n"),
	quit_application = 'tell application id "%s" to quit',
	-- The level before muting is returned so the next toggle can restore it;
	-- %d is the level restored when the microphone is muted.
	mic_toggle = table.concat({
		"set currentLevel to input volume of (get volume settings)",
		"if currentLevel > 0 then",
		"\tset volume input volume 0",
		'\treturn "muted " & currentLevel',
		"end if",
		"set volume input volume %d",
		'return "unmuted"',
	}, "\n"),
	toggle_dark_mode = table.concat({
		'tell application "System Events" to tell appearance preferences',
		"\tset dark mode to not dark mode",
		"end tell",
	}, "\n"),
	empty_trash = 'tell application "Finder" to empty trash',
	eject_all_disks = table.concat({
		'tell application "Finder"',
		"\tset ejectableDisks to every disk whose ejectable is true",
		"\trepeat with ejectableDisk in ejectableDisks",
		"\t\teject ejectableDisk",
		"\tend repeat",
		"\treturn count of ejectableDisks",
		"end tell",
	}, "\n"),
	finder_selection = table.concat({
		'tell application "Finder"',
		"\tset selectedPaths to {}",
		"\trepeat with selectedItem in (get selection)",
		"\t\tset end of selectedPaths to POSIX path of (selectedItem as alias)",
		"\tend repeat",
		"\treturn selectedPaths",
		"end tell",
	}, "\n"),
	finder_folder = 'tell application "Finder" to return {POSIX path of (insertion location as alias)}',
}

-- The level the microphone had before this session muted it. Declared above
-- every reader.
local _mic_restore_level = nil

--- Shows a short notice for an action that had nothing to act on.
--- @param key string Locale key of the notice.
local function notify(key)
	local shown, err = notifications.notify(i18n.get(key), nil, "info")
	if shown ~= true then
		Logger.warn(LOG, "Notice '%s' could not be shown: %s.", key, tostring(err))
	end
end

--- Runs one AppleScript through osascript, optionally in recompilable form.
--- @param script string AppleScript source.
--- @param recompilable boolean True for `-ss` output (lists stay parseable).
--- @param label string Diagnostic label.
--- @param callback function|nil fn(ok, stdout).
--- @param parent string|nil Action parent.
--- @return boolean started
local function run_script(script, recompilable, label, callback, parent)
	local args = recompilable and { "-ss", "-e", script } or { "-e", script }
	return AuxOwner.run(M.OSASCRIPT_BIN, args, label, callback, parent)
end

--- Runs one command, logging its start and outcome as one lifecycle.
--- @param executable string
--- @param args table
--- @param label string What the command does, for the log.
--- @param parent string|nil Action parent.
--- @return boolean started
local function run_logged(executable, args, label, parent)
	Logger.start(LOG, "%s…", label)
	local started = AuxOwner.run(executable, args, label, function(ok, _, stderr)
		if ok then
			Logger.success(LOG, "%s: done.", label)
		else
			Logger.error(LOG, "%s failed: %s.", label, tostring(stderr))
		end
	end, parent)
	if not started then Logger.error(LOG, "%s could not start.", label) end
	return started
end

--- Runs one AppleScript whose only result is success, as one lifecycle.
--- @param script string
--- @param label string
--- @param parent string|nil
--- @return boolean started
local function run_script_logged(script, label, parent)
	return run_logged(M.OSASCRIPT_BIN, { "-e", script }, label, parent)
end





-- =================================
-- =================================
-- ======= 2/ Windows & Apps =======
-- =================================
-- =================================

--- Minimizes every window of every visible application.
--- @param parent string|nil
--- @return boolean started
function M.minimize_all(parent)
	return run_script_logged(M.SCRIPTS.minimize_all, "Minimize every window", parent)
end

--- The applications that are the desktop shell itself: quitting Finder removes
--- the desktop until it is relaunched (its own Cmd+Q is disabled), and the
--- Dock and loginwindow run the session.
M.SHELL_BUNDLES = {
	["com.apple.finder"] = true,
	["com.apple.dock"] = true,
	["com.apple.loginwindow"] = true,
}

--- Hands on the application a confirmation read before its question, once it
--- is checked to be neither the driver nor the shell and to still run under
--- the same identity: the pid of an application that quit meanwhile may name
--- another process.
--- @param label string
--- @param acted_from table { pid, bundle_id } from WindowInfo.frontmost_application.
--- @param own_bundle string The driver's own bundle identifier.
--- @param on_front function fn(pid, bundle_id) for another application.
--- @return boolean started What on_front returned.
local function with_acted_from(label, acted_from, own_bundle, on_front)
	local pid, bundle_id = acted_from.pid, acted_from.bundle_id
	if type(pid) ~= "number" or pid ~= math.floor(pid) or pid <= 1 or type(bundle_id) ~= "string" then
		Logger.error(LOG, "%s refused: unreadable application '%s' (pid %s).", label, tostring(bundle_id), tostring(pid))
		return false
	end
	if bundle_id == own_bundle then
		Logger.warn(LOG, "%s refused: ErgoptiPlus itself was frontmost (use Quit in its menu).", label)
		return false
	end
	if M.SHELL_BUNDLES[bundle_id] then
		Logger.warn(LOG, "%s refused: %s is the macOS desktop shell.", label, bundle_id)
		return false
	end
	local running = WindowInfo.application_bundle_id(pid)
	if running ~= bundle_id then
		Logger.warn(LOG, "%s refused: %s (pid %d) no longer runs (that pid now runs %s).", label, bundle_id, pid,
			running or "nothing")
		return false
	end
	return on_front(string.format("%d", pid), bundle_id) == true
end

--- Reads the frontmost application, refusing the driver itself and the shell.
--- A confirmed action passes the application read before its question
--- (action_confirm): its alert has since brought the driver to the front.
--- @param label string
--- @param on_front function fn(pid, bundle_id) for another application.
--- @param parent string|nil
--- @param acted_from table|nil { pid, bundle_id }, read before a confirmation.
--- @return boolean started
local function with_frontmost(label, on_front, parent, acted_from)
	local own_bundle, detail = TccGrant.bundle_id()
	if not own_bundle then
		Logger.error(LOG, "%s refused: the driver's own bundle identifier is unknown (%s).", label, tostring(detail))
		return false
	end
	if acted_from ~= nil then return with_acted_from(label, acted_from, own_bundle, on_front) end
	return run_script(string.format(M.SCRIPTS.frontmost_process, own_bundle), false, label, function(ok, out)
		if not ok or type(out) ~= "string" then
			Logger.error(LOG, "%s: the frontmost application could not be read.", label)
			return
		end
		if out == "self" then
			Logger.warn(LOG, "%s refused: ErgoptiPlus itself is frontmost (use Quit in its menu).", label)
			return
		end
		local pid, bundle_id = out:match("^(%d+) (%S+)$")
		if not pid then
			Logger.error(LOG, "%s: unreadable frontmost application '%s'.", label, out)
			return
		end
		if M.SHELL_BUNDLES[bundle_id] then
			Logger.warn(LOG, "%s refused: %s is the macOS desktop shell.", label, bundle_id)
			return
		end
		on_front(pid, bundle_id)
	end, parent)
end

--- Opens an application by name, path or bundle identifier.
--- @param value string A valid app parameter (_shared/lua/app_parameter).
--- @param parent string|nil
--- @return boolean started
function M.open_app(value, parent)
	local args = AppParameter.macos_open_args(value)
	if not args then
		Logger.error(LOG, "open_app refused an invalid application '%s'.", tostring(value))
		return false
	end
	return run_logged(M.OPEN_BIN, args, "Open " .. value, parent)
end

--- Asks the frontmost application to quit, as its own Quit command does.
--- @param parent string|nil
--- @param acted_from table|nil The application a confirmation read before its question.
--- @return boolean started
function M.quit_frontmost_app(parent, acted_from)
	return with_frontmost("Quit the frontmost application", function(_, bundle_id)
		return run_script_logged(string.format(M.SCRIPTS.quit_application, bundle_id),
			"Quit " .. bundle_id, parent)
	end, parent, acted_from)
end

--- Kills the frontmost application at once (SIGKILL), as Force Quit does.
--- Confirmed first (catalogue `confirm = true`), it kills the application
--- that was frontmost when the question was asked.
--- @param parent string|nil
--- @param acted_from table|nil The application a confirmation read before its question.
--- @return boolean started
function M.force_quit_frontmost(parent, acted_from)
	return with_frontmost("Force quit the frontmost application", function(pid, bundle_id)
		return run_logged(M.KILL_BIN, { "-KILL", pid }, "Force quit " .. bundle_id, parent)
	end, parent, acted_from)
end





-- ============================================
-- ============================================
-- ======= 3/ Clipboard, Pointer, Audio =======
-- ============================================
-- ============================================

--- Empties the clipboard of every type it holds.
--- @return boolean cleared
function M.clear_clipboard()
	-- restore(nil) is the adapter's clear: it drops every pasteboard type.
	local cleared = Clipboard.restore(nil)
	if cleared then
		Logger.info(LOG, "Clipboard cleared.")
	else
		Logger.error(LOG, "The clipboard could not be cleared.")
	end
	return cleared
end

--- Moves the pointer to the center of the screen it is on.
--- @return boolean moved
function M.center_mouse()
	local frame = MouseControl.screen_frame_under_cursor()
	if type(frame) ~= "table" then
		Logger.error(LOG, "center_mouse: no screen holds the pointer.")
		return false
	end
	local moved = MouseControl.setPos(frame.x + frame.w / 2, frame.y + frame.h / 2)
	if not moved then Logger.error(LOG, "center_mouse: the pointer could not be moved.") end
	return moved
end

--- Mutes the microphone by setting its input level to zero, or gives it back
--- the level it had before.
--- @param parent string|nil
--- @return boolean started
function M.mic_mute_toggle(parent)
	local restore = _mic_restore_level or M.MIC_DEFAULT_RESTORE_LEVEL
	Logger.start(LOG, "Toggle the microphone…")
	local started = run_script(string.format(M.SCRIPTS.mic_toggle, restore), false, "Toggle the microphone",
		function(ok, out)
			if not ok or type(out) ~= "string" then
				Logger.error(LOG, "The microphone could not be toggled.")
				return
			end
			local level = out:match("^muted (%d+)$")
			if level then
				_mic_restore_level = tonumber(level)
				Logger.success(LOG, "Microphone muted (level %s kept for unmuting).", level)
			elseif out == "unmuted" then
				Logger.success(LOG, "Microphone unmuted at level %d.", restore)
			else
				Logger.error(LOG, "Unexpected microphone toggle result '%s'.", out)
			end
		end, parent)
	if not started then Logger.error(LOG, "The microphone toggle could not start.") end
	return started
end





-- ===============================
-- ===============================
-- ======= 4/ System State =======
-- ===============================
-- ===============================

--- Puts every display to sleep now.
--- @param parent string|nil
--- @return boolean started
function M.sleep_displays(parent)
	return run_logged(M.PMSET_BIN, { "displaysleepnow" }, "Sleep the displays", parent)
end

--- Switches the system appearance between light and dark.
--- @param parent string|nil
--- @return boolean started
function M.toggle_dark_mode(parent)
	return run_script_logged(M.SCRIPTS.toggle_dark_mode, "Toggle dark mode", parent)
end

--- Empties the Finder trash. Confirmed by the dispatcher first.
--- @param parent string|nil
--- @return boolean started
function M.empty_trash(parent)
	return run_script_logged(M.SCRIPTS.empty_trash, "Empty the trash", parent)
end

--- Ejects every ejectable disk, and says so when there is none.
--- @param parent string|nil
--- @return boolean started
function M.eject_all_disks(parent)
	Logger.start(LOG, "Eject every disk…")
	local started = run_script(M.SCRIPTS.eject_all_disks, false, "Eject every disk", function(ok, out)
		if not ok then
			Logger.error(LOG, "The disks could not be ejected.")
			return
		end
		Logger.success(LOG, "%s disk(s) ejected.", tostring(out))
		if out == "0" then notify("system_actions.no_disk_to_eject") end
	end, parent)
	if not started then Logger.error(LOG, "Ejecting the disks could not start.") end
	return started
end





-- ======================================
-- ======================================
-- ======= 5/ Finder Selection ==========
-- ======================================
-- ======================================

--- Reads the Finder selection and hands its paths to `on_paths`.
--- @param label string
--- @param on_paths function fn(paths) with at least one absolute path.
--- @param parent string|nil
--- @return boolean started
local function with_finder_selection(label, on_paths, parent)
	return run_script(M.SCRIPTS.finder_selection, true, label .. " (read the Finder selection)",
		function(ok, out)
			if not ok then
				Logger.error(LOG, "%s: the Finder selection could not be read.", label)
				return
			end
			local paths, reason = FileSelection.parse_applescript_paths(out)
			if not paths then
				Logger.error(LOG, "%s refused: unreadable Finder selection (%s).", label, tostring(reason))
				return
			end
			if #paths == 0 then
				Logger.info(LOG, "%s: nothing is selected in Finder.", label)
				notify("system_actions.no_file_selected")
				return
			end
			on_paths(paths)
		end, parent)
end

--- Reads the folder Finder would put a new item in: the front window's, or
--- the Desktop when no window is open.
--- @param label string
--- @param on_folder function fn(folder) with an absolute path ending in "/".
--- @param parent string|nil
--- @return boolean started
local function with_finder_folder(label, on_folder, parent)
	return run_script(M.SCRIPTS.finder_folder, true, label .. " (read the Finder folder)", function(ok, out)
		local paths = ok and FileSelection.parse_applescript_paths(out) or nil
		if not paths or #paths ~= 1 then
			Logger.error(LOG, "%s: the Finder folder could not be read.", label)
			notify("system_actions.no_folder")
			return
		end
		local folder = paths[1]
		if folder:sub(-1) ~= "/" then folder = folder .. "/" end
		on_folder(folder)
	end, parent)
end

--- Joins a command's fixed arguments and the selected paths.
--- @param fixed table
--- @param paths table
--- @return table
local function with_paths(fixed, paths)
	local args = {}
	for _, value in ipairs(fixed) do args[#args + 1] = value end
	for _, path in ipairs(paths) do args[#args + 1] = path end
	return args
end

--- Removes the Gatekeeper quarantine from the selected items, recursively.
--- Confirmed by the dispatcher first.
--- @param parent string|nil
--- @return boolean started
function M.remove_quarantine_selection(parent)
	return with_finder_selection("Remove the quarantine", function(paths)
		run_logged(M.XATTR_BIN, with_paths({ "-r", "-d", M.QUARANTINE_ATTRIBUTE }, paths),
			string.format("Remove the quarantine from %d item(s)", #paths), parent)
	end, parent)
end

--- Makes the selected items executable (chmod +x).
--- @param parent string|nil
--- @return boolean started
function M.make_executable_selection(parent)
	return with_finder_selection("Make executable", function(paths)
		run_logged(M.CHMOD_BIN, with_paths({ "+x" }, paths),
			string.format("Make %d item(s) executable", #paths), parent)
	end, parent)
end

--- Opens Terminal in the current Finder folder.
--- @param parent string|nil
--- @return boolean started
function M.open_terminal_here(parent)
	return with_finder_folder("Open a terminal here", function(folder)
		run_logged(M.OPEN_BIN, { "-a", M.TERMINAL_APPLICATION, folder }, "Open Terminal in the Finder folder", parent)
	end, parent)
end

--- Creates an empty text file with a free name in a folder.
--- @param folder string Absolute path ending in "/".
--- @return string|nil path The created file, nil when none could be created.
function M.create_new_text_file(folder)
	local base = i18n.get("system_actions.new_text_file_name")
	for attempt = 1, M.NEW_FILE_NAME_ATTEMPTS do
		local name = attempt == 1 and base or (base .. " " .. attempt)
		local path = folder .. name .. M.NEW_FILE_EXTENSION
		local created, status, detail = FileSystem.create_if_absent(path, "")
		if created then return path end
		if status ~= "exists" then
			Logger.error(LOG, "The new text file '%s' could not be created: %s.", path, tostring(detail))
			return nil
		end
	end
	Logger.error(LOG, "'%s' already holds %d new text files — none created.", folder, M.NEW_FILE_NAME_ATTEMPTS)
	return nil
end

--- Creates an empty text file in the current Finder folder and reveals it.
--- @param parent string|nil
--- @return boolean started
function M.new_text_file_here(parent)
	return with_finder_folder("New text file here", function(folder)
		local path = M.create_new_text_file(folder)
		if not path then return end
		Logger.info(LOG, "Created the text file '%s'.", path)
		run_logged(M.OPEN_BIN, { "-R", path }, "Reveal the new text file", parent)
	end, parent)
end

return M
