; tests/unit/test_system_actions.ahk

; ==============================================================================
; MODULE: System Actions (Windows)
; DESCRIPTION:
; Runs every system action of modules/gestures/system_actions.ahk against a
; recording SystemControl double and asserts the exact window message,
; command line, registry value and path each one hands to Windows; replays the
; Explorer selection reader over fake Shell.Application windows; and proves the
; confirmation gate of GestureInvokeAction.
;
; ROOT CAUSES ENCODED:
; 1. minimize_all pressed Win+D, which is Show Desktop (a toggle): it now
;    presses Win+M, and show_desktop is its own action.
; 2. The approved system actions did not exist on Windows.
; 3. The catalogue's `confirm` field was read by no driver: emptying the
;    Recycle Bin or unblocking files from a stray gesture ran unasked.
; ==============================================================================

#Requires AutoHotkey v2.0

; A recording SystemControl: every native call is logged in Calls, and the
; answers come from the fields a test sets.
class _SysActionsFake {
	__New() {
		this.Calls := []
		this.Deferred := []
		this.Answer := "Cancel"
		this.Active := ""
		this.OwnPidValue := 4000
		this.Windows := []
		this.Registry := Map()
		this.Muted := false
		this.Drives := ""
		this.Shell := ""
		this.Directories := Map()
		this.Terminal := ""
		this.CreateStatuses := []
		this.Pointer := { X: 0, Y: 0 }
		this.MonitorList := []
	}
	_Log(Name, Args*) {
		Entry := [Name]
		Entry.Push(Args*)
		this.Calls.Push(Entry)
		return true
	}
	Launch(Target, WorkingDir := "", Options := "") => (this._Log("Launch", Target, WorkingDir, Options), 1)
	PostBroadcast(Msg, WParam, LParam) => this._Log("PostBroadcast", Msg, WParam, LParam)
	PostClose(Hwnd) => this._Log("PostClose", Hwnd)
	BroadcastSettingChange(Area) => this._Log("BroadcastSettingChange", Area)
	ReadDword(Key, Name) => this.Registry.Get(Name, "")
	WriteDword(Key, Name, Value) => (this._Log("WriteDword", Key, Name, Value), this.Registry[Name] := Value)
	CaptureMuted() => this.Muted
	SetCaptureMuted(Muted) => (this._Log("SetCaptureMuted", Muted), this.Muted := Muted)
	CloseProcess(Pid) => this._Log("CloseProcess", Pid)
	OwnPid() => this.OwnPidValue
	ActiveWindow() => this.Active
	WindowsOfProcess(Pid) => (this._Log("WindowsOfProcess", Pid), this.Windows)
	Activate(Hwnd) => this._Log("Activate", Hwnd)
	ShellApplication() => this.Shell
	RemovableDrives() => this.Drives
	DeleteZoneIdentifier(Path) => (this._Log("DeleteZoneIdentifier", Path), "removed")
	CreateNewFile(Path) {
		this._Log("CreateNewFile", Path)
		return this.CreateStatuses.Length ? this.CreateStatuses.RemoveAt(1) : "created"
	}
	IsDirectory(Path) => this.Directories.Has(Path)
	FilesUnder(Dir) => this.Directories[Dir]
	WindowsTerminalPath() => this.Terminal
	MousePosition() => this.Pointer
	Monitors() => this.MonitorList
	MoveMouse(X, Y) => this._Log("MoveMouse", X, Y)
	ClearClipboard() => this._Log("ClearClipboard")
	Defer(Fn) => this.Deferred.Push(Fn)
	Notify(Text) => this._Log("Notify", Text)
	Ask(Text, Title) => (this._Log("Ask", Text, Title), this.Answer)
}

; The recorded calls named Name, in order.
_SysActions_CallsNamed(Fake, Name) {
	Found := []
	for Call in Fake.Calls {
		if (Call[1] = Name)
			Found.Push(Call)
	}
	return Found
}

; A fake Shell.Application: one Explorer window over Folder, with Selected.
_SysActions_Shell(Hwnd, Folder, Selected) {
	Items := []
	for Path in Selected
		Items.Push({ Path: Path })
	Document := { Folder: { Self: { Path: Folder } }, SelectedItems: (this) => Items }
	Window := { HWND: Hwnd, Document: Document }
	return { Windows: (this) => [{ HWND: Hwnd + 1, Document: Document }, Window] }
}





; ======================================
; ======================================
; ======= 1/ Catalogue =================
; ======================================
; ======================================

_SysActions_KeystrokesAreDistinct() {
	global GESTURE_ACTIONS
	Rows := GestureEmitActionsData()
	AssertEqual("m", Rows["minimize_all"].Key, "minimize_all is Win+M")
	AssertEqual("d", Rows["show_desktop"].Key, "show_desktop is Win+D")
	AssertEqual("Win", Rows["minimize_all"].Mods[1])
	AssertEqual("Win", Rows["show_desktop"].Mods[1])
	for Id in ["sleep_displays", "toggle_dark_mode", "mic_mute_toggle", "clear_clipboard", "center_mouse",
		"quit_frontmost_app", "force_quit_frontmost", "empty_trash", "eject_all_disks",
		"unblock_file_selection", "open_terminal_here", "new_text_file_here"]
		AssertTrue(GESTURE_ACTIONS.Has(Id), Id . " must be a registered action")
}
Test("system actions: minimize_all presses Win+M and every action is registered", _SysActions_KeystrokesAreDistinct)

_SysActions_ConfirmedSet() {
	global GESTURE_ACTION_CATALOGUE
	Confirmed := []
	for Id, Meta in GESTURE_ACTION_CATALOGUE.Actions {
		if Meta.Confirm
			Confirmed.Push(Id)
	}
	AssertEqual(2, Confirmed.Length, "exactly two confirmed actions on Windows")
	AssertTrue(GestureActionNeedsConfirm("empty_trash"), "empty_trash asks first")
	AssertTrue(GestureActionNeedsConfirm("unblock_file_selection"), "unblocking asks first")
	AssertFalse(GestureActionNeedsConfirm("sleep_displays"), "sleep_displays does not ask")
}
Test("system actions: the catalogue confirms empty_trash and unblock_file_selection", _SysActions_ConfirmedSet)





; ======================================
; ======================================
; ======= 2/ Native Commands ===========
; ======================================
; ======================================

_SysActions_SleepDisplays() {
	Fake := _SysActionsFake()
	GestureSysSleepDisplays(Fake)
	Posts := _SysActions_CallsNamed(Fake, "PostBroadcast")
	AssertEqual(1, Posts.Length)
	AssertEqual(0x0112, Posts[1][2], "WM_SYSCOMMAND")
	AssertEqual(0xF170, Posts[1][3], "SC_MONITORPOWER")
	AssertEqual(2, Posts[1][4], "power off")
}
Test("system actions: sleep_displays posts SC_MONITORPOWER off", _SysActions_SleepDisplays)

_SysActions_ToggleDarkMode() {
	Fake := _SysActionsFake()
	GestureSysToggleDarkMode(Fake)
	Writes := _SysActions_CallsNamed(Fake, "WriteDword")
	AssertEqual(2, Writes.Length)
	AssertEqual("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", Writes[1][2])
	AssertEqual("AppsUseLightTheme", Writes[1][3])
	AssertEqual(0, Writes[1][4], "an absent value is the light default, switched to dark")
	AssertEqual("SystemUsesLightTheme", Writes[2][3])
	AssertEqual(0, Writes[2][4])
	AssertEqual("ImmersiveColorSet", _SysActions_CallsNamed(Fake, "BroadcastSettingChange")[1][2])
	GestureSysToggleDarkMode(Fake)
	Writes := _SysActions_CallsNamed(Fake, "WriteDword")
	AssertEqual(1, Writes[3][4], "dark switches back to light")
	AssertEqual(1, Writes[4][4])
}
Test("system actions: toggle_dark_mode flips both Personalize values and broadcasts", _SysActions_ToggleDarkMode)

_SysActions_MicToggle() {
	Fake := _SysActionsFake()
	GestureSysMicMuteToggle(Fake)
	GestureSysMicMuteToggle(Fake)
	Sets := _SysActions_CallsNamed(Fake, "SetCaptureMuted")
	AssertEqual(true, Sets[1][2], "the first toggle mutes")
	AssertEqual(false, Sets[2][2], "the second unmutes")
}
Test("system actions: mic_mute_toggle flips the default capture endpoint", _SysActions_MicToggle)

_SysActions_ClearClipboardAndCenter() {
	Fake := _SysActionsFake()
	GestureSysClearClipboard(Fake)
	AssertEqual(1, _SysActions_CallsNamed(Fake, "ClearClipboard").Length)
	Fake.MonitorList := [{ Left: 0, Top: 0, Right: 1920, Bottom: 1080 },
		{ Left: 1920, Top: 0, Right: 4480, Bottom: 1440 }]
	Fake.Pointer := { X: 2000, Y: 10 }
	GestureSysCenterMouse(Fake)
	Moves := _SysActions_CallsNamed(Fake, "MoveMouse")
	AssertEqual(3200, Moves[1][2], "centre of the second monitor")
	AssertEqual(720, Moves[1][3])
	AssertEqual("", GestureSysMonitorCenter(-5, 10, Fake.MonitorList), "no monitor holds the point")
}
Test("system actions: clear_clipboard and center_mouse", _SysActions_ClearClipboardAndCenter)

_SysActions_QuitAndForceQuit() {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Windows := [0x100, 0x200]
	GestureSysQuitFrontmostApp(Fake)
	Closes := _SysActions_CallsNamed(Fake, "PostClose")
	AssertEqual(2, Closes.Length, "WM_CLOSE to each window of the process")
	AssertEqual(0x200, Closes[2][2])
	AssertEqual(812, _SysActions_CallsNamed(Fake, "WindowsOfProcess")[1][2])
	GestureSysForceQuitFrontmost(Fake)
	AssertEqual(812, _SysActions_CallsNamed(Fake, "CloseProcess")[1][2])

	for Refused in [{ Hwnd: 1, Pid: 4000, Class: "AutoHotkeyGUI" }, { Hwnd: 1, Pid: 9, Class: "Progman" },
		{ Hwnd: 1, Pid: 9, Class: "Shell_TrayWnd" }] {
		Fake := _SysActionsFake()
		Fake.Active := Refused
		GestureSysQuitFrontmostApp(Fake)
		GestureSysForceQuitFrontmost(Fake)
		AssertEqual(0, Fake.Calls.Length, "the driver itself and the shell are never closed")
	}
}
Test("system actions: quit and force quit the active process, never the driver or the shell", _SysActions_QuitAndForceQuit)

_SysActions_EmptyTrashAndEject() {
	Fake := _SysActionsFake()
	GestureSysEmptyTrash(Fake)
	Launches := _SysActions_CallsNamed(Fake, "Launch")
	AssertEqual('powershell.exe -NoProfile -NonInteractive -Command "Clear-RecycleBin -Force -ErrorAction Stop"',
		Launches[1][2])
	AssertEqual("Hide", Launches[1][4])

	Verbs := []
	Drive(Letter) => ({ InvokeVerb: (this, Verb) => Verbs.Push(Letter . ">" . Verb) })
	Computer := { ParseName: (this, Name) => Drive(Name) }
	Fake := _SysActionsFake()
	Namespaces := []
	Fake.Shell := { Namespace: (this, Id) => (Namespaces.Push(Id), Computer) }
	Fake.Drives := "EF"
	GestureSysEjectAllDisks(Fake)
	AssertEqual(17, Namespaces[1], "This PC")
	AssertEqual("E:\>Eject", Verbs[1])
	AssertEqual("F:\>Eject", Verbs[2])
	Fake := _SysActionsFake()
	GestureSysEjectAllDisks(Fake)
	AssertEqual(1, _SysActions_CallsNamed(Fake, "Notify").Length, "no removable drive is announced")
}
Test("system actions: empty_trash and eject_all_disks run their exact commands", _SysActions_EmptyTrashAndEject)





; ======================================
; ======================================
; ======= 3/ Explorer ==================
; ======================================
; ======================================

_SysActions_ExplorerSelectionReader() {
	Shell := _SysActions_Shell(0x42, "C:\Users\ana\Downloads", ["C:\Users\ana\Downloads\a.exe", "\\nas\share\b.msi"])
	Window := GestureSysExplorerWindowFor(Shell.Windows(), 0x42)
	AssertTrue(IsObject(Window), "the window whose HWND is active")
	Paths := GestureSysExplorerSelectedPaths(Window)
	AssertEqual(2, Paths.Length)
	AssertEqual("\\nas\share\b.msi", Paths[2])
	AssertEqual("C:\Users\ana\Downloads", GestureSysExplorerFolderPath(Window))
	AssertEqual("", GestureSysExplorerWindowFor(Shell.Windows(), 0x99), "no window, no selection")
	Virtual := _SysActions_Shell(0x42, "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}",
		["C:\a.txt", "::{645FF040-5081-101B-9F08-00AA002F954E}"])
	Window := GestureSysExplorerWindowFor(Virtual.Windows(), 0x42)
	AssertEqual("", GestureSysExplorerSelectedPaths(Window), "one virtual item refuses the whole selection")
	AssertEqual("", GestureSysExplorerFolderPath(Window), "a virtual folder has no path")
}
Test("system actions: the Explorer selection reader keeps real paths and refuses virtual items", _SysActions_ExplorerSelectionReader)

_SysActions_UnblockSelection() {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x42, Pid: 7, Class: "CabinetWClass" }
	Fake.Shell := _SysActions_Shell(0x42, "C:\Dl", ["C:\Dl\tool.exe", "C:\Dl\kit"])
	Fake.Directories := Map("C:\Dl\kit", ["C:\Dl\kit\a.dll", "C:\Dl\kit\sub\b.ps1"])
	GestureSysUnblockFileSelection(Fake)
	Deletes := _SysActions_CallsNamed(Fake, "DeleteZoneIdentifier")
	AssertEqual(3, Deletes.Length, "the file, then every file inside the folder")
	AssertEqual("C:\Dl\tool.exe", Deletes[1][2])
	AssertEqual("C:\Dl\kit\sub\b.ps1", Deletes[3][2])

	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x42, Pid: 7, Class: "Notepad" }
	GestureSysUnblockFileSelection(Fake)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "DeleteZoneIdentifier").Length, "not an Explorer window")
	AssertEqual(1, _SysActions_CallsNamed(Fake, "Notify").Length)
}
Test("system actions: unblock_file_selection deletes each Zone.Identifier stream", _SysActions_UnblockSelection)

_SysActions_TerminalAndNewFile() {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x42, Pid: 7, Class: "CabinetWClass" }
	Fake.Shell := _SysActions_Shell(0x42, "C:\Work\", [])
	Fake.Terminal := "C:\Users\ana\AppData\Local\Microsoft\WindowsApps\wt.exe"
	GestureSysOpenTerminalHere(Fake)
	Launch := _SysActions_CallsNamed(Fake, "Launch")[1]
	AssertEqual('"C:\Users\ana\AppData\Local\Microsoft\WindowsApps\wt.exe" -d .', Launch[2])
	AssertEqual("C:\Work\", Launch[3], "the folder is the working directory, never quoted")
	Fake.Terminal := ""
	GestureSysOpenTerminalHere(Fake)
	AssertEqual(A_ComSpec, _SysActions_CallsNamed(Fake, "Launch")[2][2], "the command prompt without Windows Terminal")

	Fake.CreateStatuses := ["exists", "created"]
	GestureSysNewTextFileHere(Fake)
	Creates := _SysActions_CallsNamed(Fake, "CreateNewFile")
	Base := t("system_actions.new_text_file_name")
	AssertEqual("C:\Work\" . Base . ".txt", Creates[1][2])
	AssertEqual("C:\Work\" . Base . " (2).txt", Creates[2][2])

	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x10, Pid: 7, Class: "WorkerW" }
	GestureSysOpenTerminalHere(Fake)
	AssertEqual(A_Desktop, _SysActions_CallsNamed(Fake, "Launch")[1][3], "the desktop opens in the Desktop folder")
}
Test("system actions: open_terminal_here and new_text_file_here act in the Explorer folder", _SysActions_TerminalAndNewFile)





; ======================================
; ======================================
; ======= 4/ Confirmation Gate =========
; ======================================
; ======================================

_SysActions_ConfirmGate() {
	global GESTURE_ACTIONS
	for Id in ["empty_trash", "unblock_file_selection"] {
		Saved := GESTURE_ACTIONS[Id]
		Ran := []
		GESTURE_ACTIONS[Id] := { Fn: (*) => Ran.Push(Id) }
		try {
			Fake := _SysActionsFake()
			Fake.Active := { Hwnd: 0x77, Pid: 7, Class: "CabinetWClass" }
			GestureInvokeAction(Id, "", Fake)
			AssertEqual(0, Ran.Length, Id . " must not run before the answer")
			AssertEqual(1, Fake.Deferred.Length, Id . ": the question is asked off the hotkey thread")
			Fake.Deferred[1].Call()
			AssertEqual(1, _SysActions_CallsNamed(Fake, "Ask").Length, Id . " asks")
			AssertEqual(0, Ran.Length, Id . ": Cancel runs nothing")

			Fake := _SysActionsFake()
			Fake.Active := { Hwnd: 0x77, Pid: 7, Class: "CabinetWClass" }
			Fake.Answer := "OK"
			GestureInvokeAction(Id, "", Fake)
			Fake.Deferred[1].Call()
			AssertEqual(1, Ran.Length, Id . ": OK runs it once")
			AssertEqual(0x77, _SysActions_CallsNamed(Fake, "Activate")[1][2], "the window it was asked from gets its focus back")
		} finally {
			GESTURE_ACTIONS[Id] := Saved
		}
	}
	Saved := GESTURE_ACTIONS["sleep_displays"]
	Ran := 0
	GESTURE_ACTIONS["sleep_displays"] := { Fn: (*) => Ran += 1 }
	try {
		Fake := _SysActionsFake()
		GestureInvokeAction("sleep_displays", "", Fake)
		AssertEqual(1, Ran, "an action without confirm runs at once")
		AssertEqual(0, Fake.Deferred.Length, "and asks nothing")
	} finally {
		GESTURE_ACTIONS["sleep_displays"] := Saved
	}
}
Test("system actions: GestureInvokeAction asks before every confirm action", _SysActions_ConfirmGate)
