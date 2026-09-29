; modules/gestures/system_actions.ahk

; ==============================================================================
; MODULE: System Actions (Windows)
; DESCRIPTION:
; The system actions of the shared catalogue that run a native command: sleep
; the displays, toggle dark mode and the microphone, clear the clipboard,
; center the pointer, quit or force-quit the active app, empty the Recycle Bin,
; eject the removable drives, and the Explorer helpers (unblock the selected
; files, open a terminal or create a text file in the current folder).
; show_desktop and minimize_all are plain keystrokes (Win+D, Win+M) generated
; from the catalogue. Mirrors macos/modules/gestures/system_actions.lua.
;
; FEATURES & RATIONALE:
; 1. Every native effect goes through a SystemControl adapter
;    (adapters/system_control.ahk) passed in as `Sys`, so the suite pins the
;    exact command line, window message and path with a recording double.
; 2. Registered deferred: the hotkey or gesture thread only schedules the
;    action (Sys.Defer) and returns; COM, broadcasts and Explorer queries run
;    in their own thread afterwards.
; 3. Explorer's selection is read from the Shell.Application window whose HWND
;    is the active window. A virtual item (This PC, a library root, Control
;    Panel) has no path a file operation can take: it refuses the whole
;    selection rather than acting on part of it.
; 4. Confirmation is not asked here: GestureInvokeAction (config.ahk) asks for
;    every action the catalogue declares `confirm = true` before it runs.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================
; ======================================
; ======= 1/ Native Constants ==========
; ======================================
; ======================================

; WM_SYSCOMMAND / SC_MONITORPOWER, lParam 2 = power the monitors off.
global GESTURE_SYS_WM_SYSCOMMAND := 0x0112
global GESTURE_SYS_SC_MONITORPOWER := 0xF170
global GESTURE_SYS_MONITOR_OFF := 2

; Where Windows stores the app and system light/dark choice, and the settings
; area Explorer and the apps re-read it for.
global GESTURE_SYS_PERSONALIZE_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
global GESTURE_SYS_COLOR_SETTING_AREA := "ImmersiveColorSet"

; Empties every drive's Recycle Bin in a hidden PowerShell, never in the
; driver's own thread: a large bin takes seconds.
global GESTURE_SYS_EMPTY_TRASH_COMMAND := 'powershell.exe -NoProfile -NonInteractive -Command "Clear-RecycleBin -Force -ErrorAction Stop"'

; The shell namespace of "This PC", whose drive items carry the Eject verb.
global GESTURE_SYS_CSIDL_DRIVES := 17

; The windows that are the shell itself: closing them logs the user out or
; restarts Explorer, which "quit the active app" never means.
global GESTURE_SYS_SHELL_CLASSES := Map("Progman", true, "WorkerW", true,
	"Shell_TrayWnd", true, "Shell_SecondaryTrayWnd", true)

; The desktop windows: their folder actions act on the Desktop folder.
global GESTURE_SYS_DESKTOP_CLASSES := Map("Progman", true, "WorkerW", true)

; The window class of an Explorer folder window.
global GESTURE_SYS_EXPLORER_CLASS := "CabinetWClass"

; SVSI_EDIT | SVSI_DESELECTOTHERS | SVSI_ENSUREVISIBLE | SVSI_FOCUSED: select
; the new file alone, scrolled into view, with its name ready to be typed.
global GESTURE_SYS_SVSI_RENAME := 0x1F

; How many "<name> (N).txt" candidates a new text file tries.
global GESTURE_SYS_NEW_FILE_ATTEMPTS := 100





; ======================================
; ======================================
; ======= 2/ Registration ==============
; ======================================
; ======================================

; Resolves the SystemControl the actions use: the suite passes a double.
_GestureSys(Sys) {
	return IsObject(Sys) ? Sys : SystemControl()
}

; Built in a helper rather than inline: a closure created in a loop would
; capture the loop variable, and every action would run the last one.
_GestureMakeSystemRunner(ActionFn) {
	return (*) => SystemControl().Defer(ActionFn)
}

for _SysActionId, _SysActionFn in Map(
	"sleep_displays", GestureSysSleepDisplays,
	"toggle_dark_mode", GestureSysToggleDarkMode,
	"mic_mute_toggle", GestureSysMicMuteToggle,
	"clear_clipboard", GestureSysClearClipboard,
	"center_mouse", GestureSysCenterMouse,
	"quit_frontmost_app", GestureSysQuitFrontmostApp,
	"force_quit_frontmost", GestureSysForceQuitFrontmost,
	"empty_trash", GestureSysEmptyTrash,
	"eject_all_disks", GestureSysEjectAllDisks,
	"unblock_file_selection", GestureSysUnblockFileSelection,
	"open_terminal_here", GestureSysOpenTerminalHere,
	"new_text_file_here", GestureSysNewTextFileHere) {
	GESTURE_ACTIONS[_SysActionId] := { Fn: _GestureMakeSystemRunner(_SysActionFn) }
}





; ======================================
; ======================================
; ======= 3/ System State ==============
; ======================================
; ======================================

; Powers the monitors off, as their own sleep timeout does.
GestureSysSleepDisplays(Sys := 0) {
	global GESTURE_SYS_WM_SYSCOMMAND, GESTURE_SYS_SC_MONITORPOWER, GESTURE_SYS_MONITOR_OFF
	Sys := _GestureSys(Sys)
	if Sys.PostBroadcast(GESTURE_SYS_WM_SYSCOMMAND, GESTURE_SYS_SC_MONITORPOWER, GESTURE_SYS_MONITOR_OFF)
		LoggerInfo("gestures", "Displays put to sleep.")
	else
		LoggerError("gestures", "The displays could not be put to sleep (PostMessage refused).")
}

; Switches apps and the system between the light and the dark theme, then
; tells the open windows to re-read it.
GestureSysToggleDarkMode(Sys := 0) {
	global GESTURE_SYS_PERSONALIZE_KEY, GESTURE_SYS_COLOR_SETTING_AREA
	Sys := _GestureSys(Sys)
	try {
		Light := Sys.ReadDword(GESTURE_SYS_PERSONALIZE_KEY, "AppsUseLightTheme")
		; Absent is Windows' own default, the light theme.
		NewLight := (Light = "" || Light != 0) ? 0 : 1
		Sys.WriteDword(GESTURE_SYS_PERSONALIZE_KEY, "AppsUseLightTheme", NewLight)
		Sys.WriteDword(GESTURE_SYS_PERSONALIZE_KEY, "SystemUsesLightTheme", NewLight)
		if !Sys.BroadcastSettingChange(GESTURE_SYS_COLOR_SETTING_AREA)
			LoggerWarn("gestures", "The theme changed but the open windows were not all told.")
		LoggerInfo("gestures", "Theme switched to {1}.", NewLight ? "light" : "dark")
	} catch as Err {
		LoggerError("gestures", "The theme could not be switched: {1}", Err.Message)
	}
}

; Mutes the default microphone, or unmutes it.
GestureSysMicMuteToggle(Sys := 0) {
	Sys := _GestureSys(Sys)
	try {
		Muted := !Sys.CaptureMuted()
		Sys.SetCaptureMuted(Muted)
		LoggerInfo("gestures", Muted ? "Microphone muted." : "Microphone unmuted.")
	} catch as Err {
		LoggerError("gestures", "The microphone could not be toggled (no capture device?): {1}", Err.Message)
	}
}

GestureSysClearClipboard(Sys := 0) {
	Sys := _GestureSys(Sys)
	Sys.ClearClipboard()
	LoggerInfo("gestures", "Clipboard cleared.")
}

; The centre of the monitor holding (X, Y).
; @param {Array} Monitors { Left, Top, Right, Bottom } rectangles.
; @returns {Object|String} { X, Y }, or "" when no monitor holds the point.
GestureSysMonitorCenter(X, Y, Monitors) {
	for Monitor in Monitors {
		if (X >= Monitor.Left && X < Monitor.Right && Y >= Monitor.Top && Y < Monitor.Bottom)
			return { X: (Monitor.Left + Monitor.Right) // 2, Y: (Monitor.Top + Monitor.Bottom) // 2 }
	}
	return ""
}

; Moves the pointer to the centre of the monitor it is on.
GestureSysCenterMouse(Sys := 0) {
	Sys := _GestureSys(Sys)
	Position := Sys.MousePosition()
	Center := GestureSysMonitorCenter(Position.X, Position.Y, Sys.Monitors())
	if !IsObject(Center) {
		LoggerError("gestures", "center_mouse: no monitor holds the pointer at {1},{2}.", Position.X, Position.Y)
		return
	}
	Sys.MoveMouse(Center.X, Center.Y)
	LoggerInfo("gestures", "Pointer centred at {1},{2}.", Center.X, Center.Y)
}





; ======================================
; ======================================
; ======= 4/ Applications ==============
; ======================================
; ======================================

; Why the active window's process must not be closed.
; @param {Object|String} Active { Hwnd, Pid, Class } or "".
; @param {Integer} OwnPid This script's process id.
; @returns {String} The reason, or "" when it may be closed.
GestureSysQuitRefusal(Active, OwnPid) {
	global GESTURE_SYS_SHELL_CLASSES
	if !IsObject(Active)
		return "there is no active window"
	if (Active.Pid = OwnPid)
		return "it is ErgoptiPlus itself (use its Quit command)"
	if GESTURE_SYS_SHELL_CLASSES.Has(Active.Class)
		return "it is the Windows shell"
	return ""
}

; Asks the active application to quit: WM_CLOSE to each of its windows, as
; their close buttons do, so it can still ask to save.
GestureSysQuitFrontmostApp(Sys := 0) {
	Sys := _GestureSys(Sys)
	Active := Sys.ActiveWindow()
	Refusal := GestureSysQuitRefusal(Active, Sys.OwnPid())
	if (Refusal != "") {
		LoggerWarn("gestures", "quit_frontmost_app refused: {1}.", Refusal)
		return
	}
	Closed := 0
	for Hwnd in Sys.WindowsOfProcess(Active.Pid)
		Closed += Sys.PostClose(Hwnd) ? 1 : 0
	LoggerInfo("gestures", "Asked process {1} to close its {2} window(s).", Active.Pid, Closed)
}

; Terminates the active application at once, unsaved work included.
GestureSysForceQuitFrontmost(Sys := 0) {
	Sys := _GestureSys(Sys)
	Active := Sys.ActiveWindow()
	Refusal := GestureSysQuitRefusal(Active, Sys.OwnPid())
	if (Refusal != "") {
		LoggerWarn("gestures", "force_quit_frontmost refused: {1}.", Refusal)
		return
	}
	if Sys.CloseProcess(Active.Pid)
		LoggerInfo("gestures", "Process {1} terminated.", Active.Pid)
	else
		LoggerError("gestures", "Process {1} could not be terminated.", Active.Pid)
}

; Empties the Recycle Bin of every drive. Confirmed by GestureInvokeAction.
GestureSysEmptyTrash(Sys := 0) {
	global GESTURE_SYS_EMPTY_TRASH_COMMAND
	Sys := _GestureSys(Sys)
	try {
		Sys.Launch(GESTURE_SYS_EMPTY_TRASH_COMMAND, "", "Hide")
		LoggerInfo("gestures", "Emptying the Recycle Bin.")
	} catch as Err {
		LoggerError("gestures", "The Recycle Bin could not be emptied: {1}", Err.Message)
	}
}

; Ejects every removable drive through its Eject verb, as Explorer does.
GestureSysEjectAllDisks(Sys := 0) {
	global GESTURE_SYS_CSIDL_DRIVES
	Sys := _GestureSys(Sys)
	Letters := Sys.RemovableDrives()
	if (Letters = "") {
		LoggerInfo("gestures", "eject_all_disks: no removable drive.")
		Sys.Notify(t("system_actions.no_disk_to_eject"))
		return
	}
	Computer := Sys.ShellApplication().Namespace(GESTURE_SYS_CSIDL_DRIVES)
	Ejected := 0
	for Letter in StrSplit(Letters) {
		try {
			Computer.ParseName(Letter . ":\").InvokeVerb("Eject")
			Ejected += 1
		} catch as Err {
			LoggerError("gestures", "Drive {1}: could not be ejected: {2}", Letter, Err.Message)
		}
	}
	LoggerInfo("gestures", "{1} removable drive(s) ejected.", Ejected)
}





; ======================================
; ======================================
; ======= 5/ Explorer ==================
; ======================================
; ======================================

; Whether a path names a file or folder a file operation can take: a drive
; path or a UNC share, not a shell namespace ("::{…}").
GestureSysIsFileSystemPath(Path) {
	return (Path is String) && RegExMatch(Path, "^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)") > 0
}

; The Shell.Application window whose HWND is Hwnd.
; @param Windows Shell.Application.Windows(), or any enumerable of windows.
; @returns {Object|String} The window, or "".
GestureSysExplorerWindowFor(Windows, Hwnd) {
	for Window in Windows {
		if (Window.HWND = Hwnd)
			return Window
	}
	return ""
}

; The paths of the items an Explorer window has selected.
; @returns {Array|String} The paths in selection order, or "" when one of the
;   items is virtual (the whole selection is then refused).
GestureSysExplorerSelectedPaths(Window) {
	Paths := []
	for Item in Window.Document.SelectedItems() {
		Path := Item.Path
		if !GestureSysIsFileSystemPath(Path)
			return ""
		Paths.Push(Path)
	}
	return Paths
}

; The folder an Explorer window shows.
; @returns {String} Its path, or "" for a virtual folder.
GestureSysExplorerFolderPath(Window) {
	Path := Window.Document.Folder.Self.Path
	return GestureSysIsFileSystemPath(Path) ? Path : ""
}

; The Explorer window the user acted on.
; @returns {Object|String} Its Shell.Application window, or "".
_GestureSysActiveExplorer(Sys, Active) {
	global GESTURE_SYS_EXPLORER_CLASS
	if !IsObject(Active) || (Active.Class != GESTURE_SYS_EXPLORER_CLASS)
		return ""
	return GestureSysExplorerWindowFor(Sys.ShellApplication().Windows(), Active.Hwnd)
}

; The folder of the active Explorer window, or the Desktop when the desktop
; itself is active.
; @returns {Object} { Folder, Window } — Folder "" when there is none.
_GestureSysActiveFolder(Sys) {
	global GESTURE_SYS_DESKTOP_CLASSES
	Active := Sys.ActiveWindow()
	if IsObject(Active) && GESTURE_SYS_DESKTOP_CLASSES.Has(Active.Class)
		return { Folder: A_Desktop, Window: "" }
	Window := _GestureSysActiveExplorer(Sys, Active)
	return { Folder: IsObject(Window) ? GestureSysExplorerFolderPath(Window) : "", Window: Window }
}

; Removes the Mark of the Web (the Zone.Identifier stream) from the selected
; files, and from every file inside a selected folder. Confirmed by
; GestureInvokeAction.
GestureSysUnblockFileSelection(Sys := 0) {
	Sys := _GestureSys(Sys)
	Window := _GestureSysActiveExplorer(Sys, Sys.ActiveWindow())
	Paths := IsObject(Window) ? GestureSysExplorerSelectedPaths(Window) : ""
	if !(Paths is Array) || (Paths.Length = 0) {
		LoggerInfo("gestures", "unblock_file_selection: no file is selected in Explorer.")
		Sys.Notify(t("system_actions.no_file_selected"))
		return
	}
	Removed := 0, Failed := 0
	for Path in Paths {
		for Target in (Sys.IsDirectory(Path) ? Sys.FilesUnder(Path) : [Path]) {
			Result := Sys.DeleteZoneIdentifier(Target)
			if (Result = "removed")
				Removed += 1
			else if (Result = "failed")
				Failed += 1
		}
	}
	if Failed
		LoggerError("gestures", "unblock_file_selection: {1} file(s) unblocked, {2} could not be.", Removed, Failed)
	else
		LoggerInfo("gestures", "unblock_file_selection: {1} file(s) unblocked.", Removed)
}

; Opens a terminal in the current Explorer folder: Windows Terminal when it is
; installed, the command prompt otherwise.
GestureSysOpenTerminalHere(Sys := 0) {
	Sys := _GestureSys(Sys)
	Here := _GestureSysActiveFolder(Sys)
	if (Here.Folder = "") {
		LoggerInfo("gestures", "open_terminal_here: no Explorer folder is active.")
		Sys.Notify(t("system_actions.no_folder"))
		return
	}
	Terminal := Sys.WindowsTerminalPath()
	try {
		; "-d ." starts in the working directory, so the folder is never quoted
		; into a command line (a trailing backslash would escape the quote).
		Sys.Launch((Terminal != "") ? '"' . Terminal . '" -d .' : A_ComSpec, Here.Folder)
		LoggerInfo("gestures", "Terminal opened in '{1}'.", Here.Folder)
	} catch as Err {
		LoggerError("gestures", "The terminal could not be opened in '{1}': {2}", Here.Folder, Err.Message)
	}
}

; Creates an empty text file with a free name in a folder.
; @returns {String} The created path, or "" when none could be created.
GestureSysCreateTextFile(Folder, BaseName, Sys) {
	global GESTURE_SYS_NEW_FILE_ATTEMPTS
	Loop GESTURE_SYS_NEW_FILE_ATTEMPTS {
		Path := RTrim(Folder, "\") . "\" . BaseName . (A_Index = 1 ? "" : " (" . A_Index . ")") . ".txt"
		Status := Sys.CreateNewFile(Path)
		if (Status = "created")
			return Path
		if (Status != "exists") {
			LoggerError("gestures", "The new text file '{1}' could not be created.", Path)
			return ""
		}
	}
	LoggerError("gestures", "'{1}' already holds {2} new text files — none created.", Folder, GESTURE_SYS_NEW_FILE_ATTEMPTS)
	return ""
}

; Creates an empty text file in the current Explorer folder and selects it
; with its name ready to be typed.
GestureSysNewTextFileHere(Sys := 0) {
	global GESTURE_SYS_SVSI_RENAME
	Sys := _GestureSys(Sys)
	Here := _GestureSysActiveFolder(Sys)
	if (Here.Folder = "") {
		LoggerInfo("gestures", "new_text_file_here: no Explorer folder is active.")
		Sys.Notify(t("system_actions.no_folder"))
		return
	}
	Path := GestureSysCreateTextFile(Here.Folder, t("system_actions.new_text_file_name"), Sys)
	if (Path = "")
		return
	LoggerInfo("gestures", "Created the text file '{1}'.", Path)
	if !IsObject(Here.Window)
		return
	SplitPath(Path, &Name)
	try {
		Here.Window.Document.SelectItem(Here.Window.Document.Folder.ParseName(Name), GESTURE_SYS_SVSI_RENAME)
	} catch as Err {
		LoggerWarn("gestures", "The new text file exists but Explorer could not select it: {1}", Err.Message)
	}
}
