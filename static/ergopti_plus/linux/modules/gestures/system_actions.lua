--- modules/gestures/system_actions.lua

--- ==============================================================================
--- MODULE: System Actions (Linux)
--- DESCRIPTION:
--- The system actions of the shared catalogue that run a desktop command:
--- show the desktop, sleep the displays, toggle dark mode and the microphone,
--- quit or kill the active window's process, empty the trash, clear the
--- notifications and the clipboard, and make the file manager's selection
--- executable. modules/gestures/manager.lua dispatches them.
---
--- FEATURES & RATIONALE:
--- 1. Data first: COMMANDS maps each fixed action to its exact shell command,
---    so the executor can list what it runs and the suite pins each command.
--- 2. Backgrounded: every command is handed to the executor's background
---    runner. The daemon holds the grabbed keyboard, so a command that waits
---    for a window manager or a dialog must never be waited for here.
--- 3. A catalogue action with `confirm = true` gets its question from
---    confirmed_command(): zenity or kdialog in the same background shell,
---    chained to the command with &&, so Cancel (or no dialog tool at all)
---    runs nothing. The window an action targets (TARGETS) is read before the
---    question, so a confirmed force quit kills the application the user acted
---    from, never the one focused once the dialog is gone.
--- ==============================================================================

local M = {}
local WindowTitles = require("window_titles")

local Logger = require("logger.shim")
local i18n = require("infra.i18n")
local ShellRunner = require("adapters.shell_runner")
local FileSelection = require("file_selection")

local LOG = "modules.gestures.system_actions"

local quote = ShellRunner.quote





-- ==================================
-- ==================================
-- ======= 1/ Fixed Commands ========
-- ==================================
-- ==================================

--- Reads the active X11 window into `$win`.
local ACTIVE_WINDOW = "win=$(xdotool getactivewindow 2>/dev/null)"

--- The shell command that signals the process owning the window `$win`.
--- `$PPID` is the daemon (the shell that runs this is its child): its own
--- windows are refused, as are pid 0 and 1, so the action can neither kill the
--- driver nor init. The desktop and the panels (EWMH DESKTOP and DOCK windows)
--- are refused too: they belong to the desktop shell (plasmashell,
--- xfdesktop…), which a clean SIGTERM exit leaves gone for the session.
--- @param signal string "TERM" or "KILL".
--- @return string
local function window_signal(signal)
	return 'kind=$(xprop -id "$win" _NET_WM_WINDOW_TYPE 2>/dev/null)'
		.. ' && case "$kind" in *_NET_WM_WINDOW_TYPE_DESKTOP*|*_NET_WM_WINDOW_TYPE_DOCK*) false;; esac'
		.. ' && pid=$(xdotool getwindowpid "$win" 2>/dev/null)'
		.. ' && [ "$pid" -gt 1 ] && [ "$pid" != "$PPID" ] && kill -' .. signal .. ' "$pid"'
end

--- The GNOME interface setting dark mode lives in, and its two values.
local COLOR_SCHEME = "org.gnome.desktop.interface color-scheme"

--- Every action this module runs as one fixed shell command, by action id.
M.COMMANDS = {
	-- wmctrl -m reports the EWMH "showing the desktop" mode; -k sets it.
	show_desktop = "case \"$(wmctrl -m 2>/dev/null)\" in *'mode: ON'*) wmctrl -k off;; *) wmctrl -k on;; esac",
	-- Releasing the keys that fired it is input that would wake the displays
	-- straight back up: they are powered off once that release has happened.
	sleep_displays = "sleep 1 && xset dpms force off",
	toggle_dark_mode = "case \"$(gsettings get " .. COLOR_SCHEME .. " 2>/dev/null)\" in"
		.. " *prefer-dark*) gsettings set " .. COLOR_SCHEME .. " default;;"
		.. " *) gsettings set " .. COLOR_SCHEME .. " prefer-dark;; esac",
	mic_mute_toggle = "pactl set-source-mute @DEFAULT_SOURCE@ toggle",
	empty_trash = "gio trash --empty",
	quit_frontmost_app = window_signal("TERM"),
	force_quit_frontmost = window_signal("KILL"),
}

--- What an action of COMMANDS reads before it runs, by action id: the state
--- the user acted on. A confirmation reads it before its question, whose own
--- window would otherwise be what a force quit finds active.
M.TARGETS = {
	quit_frontmost_app = ACTIVE_WINDOW,
	force_quit_frontmost = ACTIVE_WINDOW,
}

--- The notification daemons whose client can dismiss every notification.
--- GNOME Shell and KDE Plasma expose no such command.
M.NOTIFICATION_CLIENTS = { "dunstctl", "makoctl", "swaync-client" }

--- Best effort, one daemon after the other: the installed client of a daemon
--- that is not the running one fails, and the next one is tried.
M.CLEAR_NOTIFICATIONS = "dunstctl close-all 2>/dev/null || makoctl dismiss --all 2>/dev/null"
	.. " || swaync-client --close-all 2>/dev/null"

--- The command that asks the user first, then runs `command` on Continue.
--- @param action_label string The action's localized label.
--- @param command string The command to confirm.
--- @param has_command function|nil binary -> boolean; ShellRunner.has_command by default.
--- @return string|nil confirmed The chained command, nil when no dialog tool exists.
function M.confirmed_command(action_label, command, has_command)
	has_command = has_command or ShellRunner.has_command
	local title = WindowTitles.compose(i18n.get("dialog.confirm_action.title"))
	local message = i18n.get("dialog.confirm_action.message"):gsub("{1}", function() return action_label end)
	local continue = i18n.get("dialog.confirm_action.confirm")
	local cancel = i18n.get("button.cancel")
	local ask
	if has_command("zenity") then
		ask = "zenity --question --no-markup --default-cancel --title=" .. quote(title)
			.. " --text=" .. quote(message)
			.. " --ok-label=" .. quote(continue) .. " --cancel-label=" .. quote(cancel)
	elseif has_command("kdialog") then
		-- kdialog has no "dangerous" option: Return always presses its first
		-- (Yes) button. That button is therefore Cancel, and only No, labelled
		-- Continue, confirms (exit 1); Escape and closing the window exit 2.
		ask = "{ kdialog --title " .. quote(title) .. " --warningyesno " .. quote(message)
			.. " --yes-label " .. quote(cancel) .. " --no-label " .. quote(continue) .. "; [ $? -eq 1 ]; }"
	else
		return nil
	end
	return ask .. " && { " .. command .. "; }"
end

--- The complete command one fixed action backgrounds: grouped, and asked
--- for first when the catalogue says so.
--- @param action_name string
--- @param action_label string
--- @param confirm boolean
--- @param has_command function|nil
--- @return string|nil command Nil when a confirmation cannot be asked.
function M.command_for(action_name, action_label, confirm, has_command)
	local command = M.COMMANDS[action_name]
	if not command then error("system_actions: no command for '" .. tostring(action_name) .. "'", 2) end
	local target = M.TARGETS[action_name]
	local read_target = target and (target .. " && ") or ""
	if not confirm then return "{ " .. read_target .. command .. "; }" end
	local confirmed = M.confirmed_command(action_label, command, has_command)
	if not confirmed then
		Logger.error(LOG, "'%s' needs a confirmation, and neither zenity nor kdialog is installed — not run.",
			action_name)
		return nil
	end
	if not target then return confirmed end
	return "{ " .. read_target .. confirmed .. "; }"
end





-- ==================================
-- ==================================
-- ======= 2/ Handlers ==============
-- ==================================
-- ==================================

--- Shows a short notice for an action that had nothing to act on.
--- @param key string Locale key.
local function notify(key)
	local ok, Notifier = pcall(require, "adapters.application_notifier")
	if not ok or type(Notifier.send) ~= "function" then
		Logger.warn(LOG, "No notifier to show '%s'.", key)
		return
	end
	Notifier.send(i18n.get(key), { level = "info" })
end

--- Actions that need more than one fixed command, by action id. Each
--- receives { run_background = fn(cmd), clipboard = adapter, emit_combo = fn,
--- sleep_ms = fn } from the executor.
M.HANDLERS = {
	-- Backgrounded, the command's failure is invisible: with none of the
	-- clients installed nothing could ever be cleared, which is said here.
	clear_notifications = function(deps)
		for _, client in ipairs(M.NOTIFICATION_CLIENTS) do
			if ShellRunner.has_command(client) then
				deps.run_background("{ " .. M.CLEAR_NOTIFICATIONS .. "; }")
				Logger.info(LOG, "Clearing the notifications.")
				return
			end
		end
		Logger.error(LOG, "clear_notifications: none of %s is installed; this desktop's notifications"
			.. " cannot be cleared by a command.", table.concat(M.NOTIFICATION_CLIENTS, ", "))
	end,
	clear_clipboard = function(deps)
		if deps.clipboard.write("") then
			Logger.info(LOG, "Clipboard cleared.")
		else
			Logger.error(LOG, "The clipboard could not be cleared (no clipboard tool for this session?).")
		end
	end,
	make_executable_selection = function(deps)
		local ok, uri_list, reason = deps.clipboard.read_selection_uri_list(deps.emit_combo, deps.sleep_ms)
		if not ok then
			if reason == "no_file_selection" then
				Logger.info(LOG, "make_executable_selection: no file is selected.")
				notify("system_actions.no_file_selected")
			else
				Logger.error(LOG, "make_executable_selection: the selection could not be read (%s).", tostring(reason))
			end
			return
		end
		local paths, why = FileSelection.parse_uri_list(uri_list)
		if not paths then
			Logger.error(LOG, "make_executable_selection refused: unreadable selection (%s).", tostring(why))
			return
		end
		if #paths == 0 then
			notify("system_actions.no_file_selected")
			return
		end
		local words = {}
		for index, path in ipairs(paths) do words[index] = quote(path) end
		Logger.info(LOG, "Making %d selected item(s) executable.", #paths)
		deps.run_background("chmod +x " .. table.concat(words, " "))
	end,
}

return M
