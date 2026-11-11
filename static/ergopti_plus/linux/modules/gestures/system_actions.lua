--- modules/gestures/system_actions.lua

--- ==============================================================================
--- MODULE: System Actions (Linux)
--- DESCRIPTION:
--- The system actions of the shared catalogue that run a desktop command:
--- show the desktop, minimize every window, sleep the displays, toggle dark
--- mode and the microphone, quit or kill the active window's process, empty
--- the trash, eject the removable disks, clear the notifications and the
--- clipboard, open an emoji chooser, pick a screen colour, make the file
--- manager's selection executable, and open a terminal or create a text file
--- in the active file manager folder. modules/gestures/manager.lua dispatches
--- them.
---
--- FEATURES & RATIONALE:
--- 1. Data first: COMMANDS maps each fixed action to its exact shell command,
---    so the executor can list what it runs and the suite pins each command.
--- 2. Backgrounded: every command is handed to the executor's background
---    runner. The daemon holds the grabbed keyboard, so a command that waits
---    for a window manager or a dialog must never be waited for here; the
---    runner (modules/gestures/background_commands.lua) still logs a command
---    that fails, with its exit status.
--- 3. A catalogue action with `confirm = true` gets its question from
---    confirmed_command(): Ergopti's own dialog (ui/native_dialog.lua) in the
---    same background shell, chained to the command with &&, so Cancel (or a
---    dialog that cannot open) runs nothing. The window an action targets (TARGETS) is read before the
---    question, so a confirmed force quit kills the application the user acted
---    from, never the one focused once the dialog is gone. Its process id is
---    read before the question too, and the signal goes only to a window that
---    still belongs to it: a window closed meanwhile leaves no XID to resolve,
---    and its freed process id may already be another program's.
--- 4. open_terminal_here and new_text_file_here act only in a folder whose
---    owner adapters/file_manager_folder.lua proved: the active Nautilus
---    window showing one local folder. Every other case is refused with a
---    notice that names why, never guessed from a title or a working
---    directory. The new file is created exclusively (O_EXCL) under the first
---    free name, then selected in that same Nautilus process's window.
--- ==============================================================================

local M = {}
local WindowTitles = require("window_titles")

local Logger = require("logger.shim")
local i18n = require("infra.i18n")
local ShellRunner = require("adapters.shell_runner")
local NativeDialog = require("ui.native_dialog")
local FileSelection = require("file_selection")
local Timings = require("infra.timings")

local LOG = "modules.gestures.system_actions"
local EEXIST = 17 -- Linux exclusive-create collision receipt.

local quote = ShellRunner.quote





-- ==================================
-- ==================================
-- ======= 1/ Fixed Commands ========
-- ==================================
-- ==================================

--- Reads the active X11 window into `$win` and the process owning it into
--- `$pid`. `$PPID` is the daemon (the shell that runs this is its child): its
--- own windows are refused, as are pid 0 and 1, so the action can neither kill
--- the driver nor init. The desktop and the panels (EWMH DESKTOP and DOCK
--- windows) are refused too: they belong to the desktop shell (plasmashell,
--- xfdesktop…), which a clean SIGTERM exit leaves gone for the session.
local ACTIVE_WINDOW_OWNER = "win=$(xdotool getactivewindow 2>/dev/null)"
	.. ' && kind=$(xprop -id "$win" _NET_WM_WINDOW_TYPE 2>/dev/null)'
	.. ' && case "$kind" in *_NET_WM_WINDOW_TYPE_DESKTOP*|*_NET_WM_WINDOW_TYPE_DOCK*) false;; esac'
	.. ' && pid=$(xdotool getwindowpid "$win" 2>/dev/null)'
	.. ' && [ "$pid" -gt 1 ] && [ "$pid" != "$PPID" ]'

--- The shell command that signals `$pid`, read with `$win` beforehand, only
--- while `$win` still belongs to it.
--- @param signal string "TERM" or "KILL".
--- @return string
local function window_signal(signal)
	return '[ "$(xdotool getwindowpid "$win" 2>/dev/null)" = "$pid" ] && kill -' .. signal .. ' "$pid"'
end

--- The GNOME interface setting dark mode lives in, and its two values.
local COLOR_SCHEME = "org.gnome.desktop.interface color-scheme"

--- minimize_all: EWMH has no "minimize every window" request, so each window
--- the window manager lists (wmctrl -l) is minimized in turn. A window on
--- desktop -1 is sticky (a panel, the desktop itself) and is left alone.
M.MINIMIZE_ALL = 'wmctrl -l 2>/dev/null | while read -r win desk _; do'
	.. ' [ "$desk" = "-1" ] || xdotool windowminimize "$win"; done'

--- empty_trash: GVfs empties every trash; without GVfs, `gio trash --empty`
--- exits 0 and empties nothing (measured on Ubuntu 24.04), which read as done.
--- The home trash of the XDG trash specification must then be empty.
M.EMPTY_TRASH = 'gio trash --empty && { t="${XDG_DATA_HOME:-$HOME/.local/share}/Trash/files";'
	.. ' [ ! -d "$t" ] || [ -z "$(ls -A "$t")" ]; }'

--- The mount points that make a disk the running system's own, which
--- eject_all_disks never powers off even when it is hot-pluggable (a live or
--- installed-to-USB system).
local SYSTEM_MOUNTS = "^(/|/boot|/boot/efi|/usr|/var|/home|\\[SWAP\\])$"

--- eject_all_disks: every removable or hot-plugged disk lsblk lists, its
--- mounted partitions unmounted, then the drive powered off, as Finder's
--- "Eject" does. udisksctl goes through udisks and polkit, the same path the
--- file managers use, so no root is needed for a drive the session mounted.
--- lsblk -r escapes the spaces of a mount point, so `read` splits it right.
M.EJECT_ALL_DISKS = 'lsblk -nrpo NAME,TYPE,RM,HOTPLUG 2>/dev/null | while read -r dev kind rm hot; do'
	.. ' [ "$kind" = disk ] || continue;'
	.. ' [ "$rm" = 1 ] || [ "$hot" = 1 ] || continue;'
	.. ' mounts=$(lsblk -nrpo MOUNTPOINT "$dev") || continue;'
	.. " printf '%s\\n' \"$mounts\" | grep -qE '" .. SYSTEM_MOUNTS .. "' && continue;"
	.. ' parts=$(lsblk -nrpo NAME,MOUNTPOINT "$dev") || continue;'
	.. ' printf "%s\\n" "$parts" | while read -r part mnt; do'
	.. ' [ -n "$mnt" ] || continue; udisksctl unmount -b "$part" </dev/null || exit 1; done'
	.. ' && udisksctl power-off -b "$dev" </dev/null; done'


--- Every action this module runs as one fixed shell command, by action id.
M.COMMANDS = {
	-- wmctrl -m reports the EWMH "showing the desktop" mode; -k sets it.
	show_desktop = "desktop=$(wmctrl -m 2>/dev/null) && case \"$desktop\" in"
		.. " *'mode: ON'*) wmctrl -k off;; *'mode: OFF'*) wmctrl -k on;; *) false;; esac",
	-- Releasing the keys that fired it is input that would wake the displays
	-- straight back up: they are powered off once that release has happened.
	sleep_displays = "sleep 1 && xset dpms force off",
	toggle_dark_mode = "scheme=$(gsettings get " .. COLOR_SCHEME .. " 2>/dev/null) && case \"$scheme\" in"
		.. " \"'prefer-dark'\") gsettings set " .. COLOR_SCHEME .. " default;;"
		.. " \"'default'\"|\"'prefer-light'\") gsettings set " .. COLOR_SCHEME .. " prefer-dark;;"
		.. " *) false;; esac",

	mic_mute_toggle = "pactl set-source-mute @DEFAULT_SOURCE@ toggle",
	empty_trash = M.EMPTY_TRASH,
	minimize_all = M.MINIMIZE_ALL,
	eject_all_disks = M.EJECT_ALL_DISKS,
	quit_frontmost_app = window_signal("TERM"),
	force_quit_frontmost = window_signal("KILL"),
}

--- What an action of COMMANDS reads before it runs, by action id: the state
--- the user acted on. A confirmation reads it before its question, whose own
--- window would otherwise be what a force quit finds active.
M.TARGETS = {
	quit_frontmost_app = ACTIVE_WINDOW_OWNER,
	force_quit_frontmost = ACTIVE_WINDOW_OWNER,
}

--- The actions of COMMANDS that read a state and write the one derived from
--- it. Each accepted toggle backgrounds its own shell: unserialized, two of
--- them both read the old state and one toggle is lost. They queue on one
--- flock in the session lock folder install/launch.sh creates (`flock` is a
--- launcher dependency), so the second reads what the first wrote.
M.SERIALIZED = { show_desktop = true, toggle_dark_mode = true }
local SERIAL_LOCK = '"${XDG_RUNTIME_DIR:-$HOME/.cache}/ergopti/system-toggle.lock"'

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
--- @return string confirmed The chained command.
function M.confirmed_command(action_label, command)
	local title = WindowTitles.compose(i18n.get("dialog.confirm_action.title"))
	local message = i18n.get("dialog.confirm_action.message"):gsub("{1}", function() return action_label end)
	local continue = i18n.get("dialog.confirm_action.confirm")
	local cancel = i18n.get("button.cancel")
	local ask = NativeDialog.command() .. " --question --no-markup --default-cancel --title=" .. quote(title)
		.. " --text=" .. quote(message)
		.. " --ok-label=" .. quote(continue) .. " --cancel-label=" .. quote(cancel)
	return ask .. " && { " .. command .. "; }"
end

--- The complete command one fixed action backgrounds: grouped, and asked
--- for first when the catalogue says so.
--- @param action_name string
--- @param action_label string
--- @param confirm boolean
--- @return string command
function M.command_for(action_name, action_label, confirm)
	local command = M.COMMANDS[action_name]
	if not command then error("system_actions: no command for '" .. tostring(action_name) .. "'", 2) end
	if M.SERIALIZED[action_name] then command = "flock " .. SERIAL_LOCK .. " sh -c " .. quote(command) end
	local target = M.TARGETS[action_name]
	local read_target = target and (target .. " && ") or ""
	if not confirm then return "{ " .. read_target .. command .. "; }" end
	local confirmed = M.confirmed_command(action_label, command)
	if not target then return confirmed end
	return "{ " .. read_target .. confirmed .. "; }"
end





-- ==================================
-- ==================================
-- ======= 2/ Handlers ==============
-- ==================================
-- ==================================

--- The emoji choosers open_emoji_picker tries, in order. Linux desktops share
--- none: KDE Plasma ships plasma-emojier, GNOME's IBus answers `ibus emoji`
--- (the panel its text fields open on Ctrl+.), and Smile is the chooser the
--- other desktops install. Each picks an emoji and copies it, so the user
--- pastes it where they were typing.
M.EMOJI_PICKERS = {
	{ binary = "plasma-emojier", command = "plasma-emojier" },
	{ binary = "ibus", command = "ibus emoji" },
	{ binary = "smile", command = "smile" },
}

--- The colour pickers pick_color tries, by session, in order. Each lets the
--- user click a pixel and leaves its #RRGGBB on the clipboard, as the macOS
--- and Windows actions do. Under Wayland only a compositor-side picker can
--- read the screen (hyprpicker, for wlroots compositors); X11 lets xcolor and
--- gpick read it directly.
M.COLOR_PICKERS = {
	wayland = {
		{ binary = "hyprpicker", command = "hyprpicker --autocopy --format=hex" },
	},
	x11 = {
		{ binary = "xcolor", command = "xcolor --selection clipboard" },
		{ binary = "gpick", command = '{ colour=$(gpick --single --output --no-newline) && [ -n "$colour" ] && printf "%s" "$colour" | xclip -selection clipboard; }' },
	},
}

--- The installed candidates of `candidates`, chained with ||: a chooser that
--- is installed but cannot start (IBus without its daemon) hands over to the
--- next one instead of leaving the user with nothing.
--- @param candidates table List of { binary, command }.
--- @param has_command function binary -> boolean.
--- @return string|nil command Nil when none is installed.
function M.first_installed(candidates, has_command)
	local commands = {}
	for _, candidate in ipairs(candidates) do
		if has_command(candidate.binary) then commands[#commands + 1] = candidate.command end
	end
	if #commands == 0 then return nil end
	return "{ " .. table.concat(commands, " || ") .. "; }"
end

--- Lists the binaries of `candidates` for an error message.
--- @param candidates table
--- @return string
local function binaries(candidates)
	local names = {}
	for index, candidate in ipairs(candidates) do names[index] = candidate.binary end
	return table.concat(names, ", ")
end

--- Shows a short notice for an action that had nothing to act on.
--- @param key string Locale key.
--- @param value string|nil Replaces {1} in the message.
local function notify(key, value)
	local ok, Notifier = pcall(require, "adapters.application_notifier")
	if not ok or type(Notifier.send) ~= "function" then
		Logger.warn(LOG, "No notifier to show '%s'.", key)
		return
	end
	local message = i18n.get(key)
	if value ~= nil then message = message:gsub("{1}", function() return value end) end
	Notifier.send(message, { level = "info" })
end

--- How many free names new_text_file_here tries before it gives up.
M.NEW_FILE_NAME_ATTEMPTS = Timings.count("gestures", "new_text_file_name_attempts")

--- The extension of the file new_text_file_here creates.
M.NEW_FILE_EXTENSION = ".txt"

--- The notice of each reason adapters/file_manager_folder.lua refuses a folder.
M.FOLDER_REFUSALS = {
	no_window = "system_actions.no_folder",
	not_file_manager = "system_actions.no_folder",
	no_folder = "system_actions.no_folder",
	unsupported_file_manager = "system_actions.file_manager_unsupported",
	ambiguous_tabs = "system_actions.folder_tabs_ambiguous",
	not_local = "system_actions.folder_not_local",
	not_directory = "system_actions.folder_not_local",
	focus_changed = "system_actions.folder_changed",
	query_failed = "system_actions.folder_unreadable",
}

--- Runs `on_folder` with the active file manager's proven folder, or tells
--- the user why there is none.
--- @param action string The action id, for the log.
--- @param on_folder function Receives the folder and the adapter.
local function with_file_manager_folder(action, on_folder)
	local Folder = require("adapters.file_manager_folder")
	local available, missing = Folder.available()
	if not available then
		Logger.warn(LOG, "%s: the file manager folder cannot be read in this session (%s).", action, tostring(missing))
		notify("platform_reason.action_file_manager_folder_is_unreadable_on_linux")
		return
	end
	local folder, reason, name = Folder.read_active_folder()
	if not folder then
		local key = M.FOLDER_REFUSALS[reason]
		if not key then error("system_actions: no notice for the folder refusal '" .. tostring(reason) .. "'") end
		Logger.info(LOG, "%s refused: %s%s.", action, tostring(reason), name and (" (" .. name .. ")") or "")
		notify(key, name)
		return
	end
	on_folder(folder, Folder)
end

--- Creates an empty text file with a free name in a folder, exclusively: a
--- name another program creates meanwhile is skipped, never overwritten.
--- @param folder string Absolute folder path.
--- @param write_new function|nil path, content -> written, reason (tests).
--- @return string|nil path The created file, nil when none could be created.
function M.create_new_text_file(folder, write_new)
	write_new = write_new or require("adapters.file_system").write_new
	local base = i18n.get("system_actions.new_text_file_name")
	local prefix = folder:sub(-1) == "/" and folder or (folder .. "/")
	for attempt = 1, M.NEW_FILE_NAME_ATTEMPTS do
		local name = attempt == 1 and base or (base .. " " .. attempt)
		local path = prefix .. name .. M.NEW_FILE_EXTENSION
		-- write_new hands back the exclusive create's errno: only a name already
		-- taken moves on to the next candidate.
		local created, errno = write_new(path, "")
		if created then return path end
		if errno ~= EEXIST and errno ~= "EEXIST" then
			Logger.error(LOG, "A new text file could not be created in the folder (%s).", tostring(errno))
			return nil
		end
	end
	Logger.error(LOG, "The folder already holds %d new text files: none created.", M.NEW_FILE_NAME_ATTEMPTS)
	return nil
end

--- Actions that need more than one fixed command, by action id. Each
--- receives { run_background = fn(cmd), clipboard = adapter, emit_combo = fn,
--- sleep_ms = fn } from the executor.
M.HANDLERS = {
	activity_simulation = function()
		return require("modules.keep_awake").toggle()
	end,
	take_note = function(deps)
		return require("modules.take_note").open(deps.run_background)
	end,
	-- X11 pointer moves (modules/gestures/pointer_warp.lua); Wayland refuses.
	center_mouse = function(deps) require("modules.gestures.pointer_warp").center_mouse(deps) end,
	teleport_mouse = function(deps)
		require("modules.gestures.pointer_warp").teleport_mouse({ run_background = deps.run_background, notify = notify })
	end,
	-- X11 overlay (modules/gestures/pointer_spotlight.lua); Wayland refuses.
	spotlight_mouse = function() require("modules.gestures.pointer_spotlight").spotlight_mouse() end,
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
	open_emoji_picker = function(deps)
		local command = M.first_installed(M.EMOJI_PICKERS, ShellRunner.has_command)
		if not command then
			Logger.error(LOG, "open_emoji_picker: none of %s is installed — no emoji chooser opened.",
				binaries(M.EMOJI_PICKERS))
			return
		end
		Logger.info(LOG, "Opening the emoji chooser.")
		deps.run_background(command)
	end,
	pick_color = function(deps)
		local session = (os.getenv("WAYLAND_DISPLAY") or "") ~= "" and "wayland" or "x11"
		local candidates = M.COLOR_PICKERS[session]
		local command = M.first_installed(candidates, ShellRunner.has_command)
		if not command then
			Logger.error(LOG, "pick_color: none of %s is installed for this %s session — no colour picked.",
				binaries(candidates), session)
			return
		end
		Logger.info(LOG, "Picking a screen colour (%s session).", session)
		deps.run_background(command)
	end,
	clear_clipboard = function(deps)
		if deps.clipboard.write("") then
			Logger.info(LOG, "Clipboard cleared.")
		else
			Logger.error(LOG, "The clipboard could not be cleared (no clipboard tool for this session?).")
		end
	end,
	make_executable_selection = function(deps)
		local admitted = require("modules.shortcuts.open_selection").capture_file_manager()
		if not admitted then
			Logger.warn(LOG, "make_executable_selection: no focused file manager; copy refused.")
			return
		end
		local function guarded_copy(combo)
			if admitted() ~= true then return false end
			return deps.emit_combo(combo)
		end
		local ok, uri_list, reason = deps.clipboard.read_selection_uri_list(guarded_copy, deps.sleep_ms)
		if admitted() ~= true then return end
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
	-- The session's terminal, started detached in the folder: it outlives the
	-- action, so it is not a one-shot background command.
	open_terminal_here = function()
		with_file_manager_folder("open_terminal_here", function(folder)
			local UserActions = require("modules.gestures.user_actions")
			local terminal = UserActions.resolve_terminal(ShellRunner.has_command, os.getenv("TERMINAL"))
			if not terminal then
				Logger.error(LOG, "open_terminal_here: no known terminal is installed.")
				notify("user_actions.terminal_unavailable")
				return
			end
			local command = "cd -- " .. quote(folder.path) .. " && " .. UserActions.detached_command({ terminal.binary })
			if ShellRunner.run(command) then
				Logger.info(LOG, "Opened %s in the file manager folder.", terminal.binary)
			else
				Logger.error(LOG, "open_terminal_here: %s could not start in the folder.", terminal.binary)
				notify("user_actions.terminal_unavailable")
			end
		end)
	end,
	new_text_file_here = function(deps)
		with_file_manager_folder("new_text_file_here", function(folder, Folder)
			local path = M.create_new_text_file(folder.path)
			if not path then
				notify("system_actions.new_text_file_failed")
				return
			end
			Logger.info(LOG, "Created a text file in the file manager folder.")
			deps.run_background(Folder.reveal_command(folder, path))
		end)
	end,
}

return M
