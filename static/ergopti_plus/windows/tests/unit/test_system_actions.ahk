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
; 4. force_quit_frontmost killed unasked (decision of 2026-09-29); once asked,
;    a window that could not get its focus back left another one active, which
;    the confirmed kill would then have terminated.
; 5. The refusal for that case covered every confirmed action, so emptying the
;    Recycle Bin, which reads no window, was no longer run either.
; 6. A confirmed deferred effect re-read the foreground target after its
;    question; a transient UWP replacement could also overwrite the approved PID.
; 7. Native target queries introduced before deferred containment escaped
;    when a window disappeared during preflight or confirmation.
; ==============================================================================

#Requires AutoHotkey v2.0

; A recording SystemControl: every native call is logged in Calls, and the
; answers come from the fields a test sets.
class _SysActionsFake {
	__New() {
		this.Calls := []
		this.Deferred := []
		this.DeferDelays := []
		this.Answer := "Cancel"
		this.ActivateResult := true
		this.Active := ""
		this.Snapshots := Map()
		this.OwnPidValue := 4000
		this.ShellPidValue := 0
		this.FramedApp := 0
		this.Windows := []
		this.Registry := Map()
		this.Muted := false
		this.Drives := ""
		this.Shell := ""
		this.ActiveTab := 0
		this.Directories := Map()
		this.Terminal := ""
		this.CreateStatuses := []
		this.Pointer := { X: 0, Y: 0 }
		this.MonitorList := []
		this.ClipboardWritable := true
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
	AcquireProcessTarget(Pid) => { Pid: Pid, Handle: Pid }
	ProcessTargetIsLive(Lease) => Lease.Handle != 0
	TerminateProcessTarget(Lease) => this.CloseProcess(Lease.Pid)
	ReleaseProcessTarget(Lease) => Lease.Handle := 0
	OwnPid() => this.OwnPidValue
	ShellPid() => this.ShellPidValue
	FramedAppPid(FrameHwnd) => (this._Log("FramedAppPid", FrameHwnd), this.FramedApp)
	ActiveWindow() {
		if IsObject(this.Active)
			this.Snapshots[this.Active.Hwnd] := { Hwnd: this.Active.Hwnd, Pid: this.Active.Pid, Class: this.Active.Class }
		return this.Active
	}
	WindowSnapshot(Hwnd) {
		if !this.Snapshots.Has(Hwnd)
			return ""
		Window := this.Snapshots[Hwnd]
		return { Hwnd: Window.Hwnd, Pid: Window.Pid, Class: Window.Class }
	}
	Activate(Hwnd) {
		this._Log("Activate", Hwnd)
		if !this.ActivateResult || !this.Snapshots.Has(Hwnd)
			return false
		this.Active := this.WindowSnapshot(Hwnd)
		return true
	}
	WindowsOfProcess(Pid) => (this._Log("WindowsOfProcess", Pid), this.Windows)
	ShellApplication() => this.Shell
	ActiveExplorerTab(FrameHwnd) => this.ActiveTab
	ExplorerTabOf(Window) => Window.Tab
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
	ClearClipboard() => (this._Log("ClearClipboard"), this.ClipboardWritable)
	Defer(Fn, DelayMs := 1) => (this.Deferred.Push(Fn), this.DeferDelays.Push(DelayMs))
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
	AssertEqual(3, Confirmed.Length, "exactly three confirmed actions on Windows")
	AssertTrue(GestureActionNeedsConfirm("empty_trash"), "empty_trash asks first")
	AssertTrue(GestureActionNeedsConfirm("unblock_file_selection"), "unblocking asks first")
	AssertTrue(GestureActionNeedsConfirm("force_quit_frontmost"), "force quitting asks first")
	AssertFalse(GestureActionNeedsConfirm("sleep_displays"), "sleep_displays does not ask")
}
Test("system actions: the catalogue confirms empty_trash, unblock_file_selection and force_quit_frontmost",
	_SysActions_ConfirmedSet)





; ======================================
; ======================================
; ======= 2/ Native Commands ===========
; ======================================
; ======================================

; Powering the displays off at once let the release of the keys that fired the
; action wake them straight back up.
_SysActions_SleepDisplays() {
	global GESTURE_SYS_DISPLAY_SLEEP_DELAY_MS
	Fake := _SysActionsFake()
	GestureSysSleepDisplays(Fake)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "PostBroadcast").Length, "nothing is powered off while the keys are held")
	AssertEqual(1, Fake.Deferred.Length)
	AssertEqual(GESTURE_SYS_DISPLAY_SLEEP_DELAY_MS, Fake.DeferDelays[1], "the release happens first")
	AssertTrue(GESTURE_SYS_DISPLAY_SLEEP_DELAY_MS >= 500, "long enough for a chord to be released")
	Fake.Deferred[1].Call()
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

; SystemControl.ClearClipboard writes through the clipboard owner (CB_Write),
; which refuses while an earlier restore is still owed: the action then reports
; the failure instead of claiming an empty clipboard.
_SysActions_ClearClipboardRefused() {
	Fake := _SysActionsFake()
	Fake.ClipboardWritable := false
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try GestureSysClearClipboard(Fake)
	finally LoggerClearTestSink()
	AssertEqual(1, _SysActions_CallsNamed(Fake, "ClearClipboard").Length)
	Reported := false
	for Line in Lines {
		AssertFalse(InStr(Line, "Clipboard cleared."), "a refused write is not reported as done")
		if InStr(Line, "[ERROR]") && InStr(Line, "could not be cleared")
			Reported := true
	}
	AssertTrue(Reported, "the refused write is logged as an error")
}
Test("system actions: clear_clipboard reports a clipboard it could not write", _SysActions_ClearClipboardRefused)

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

; A File Explorer folder runs in the shell's explorer.exe by default, and a
; packaged app's frame in the ApplicationFrameHost.exe every packaged app
; shares: acting on the whole process closed the desktop and the taskbar, or
; every packaged app, instead of the active one.
_SysActions_QuitSharedHosts() {
	Fake := _SysActionsFake()
	Fake.ShellPidValue := 900
	Fake.Active := { Hwnd: 0x300, Pid: 900, Class: "CabinetWClass" }
	Fake.Windows := [0x300, 0x301, 0x302]
	GestureSysQuitFrontmostApp(Fake)
	Closes := _SysActions_CallsNamed(Fake, "PostClose")
	AssertEqual(1, Closes.Length, "only the active folder window of the shell's process is closed")
	AssertEqual(0x300, Closes[1][2])
	AssertEqual(0, _SysActions_CallsNamed(Fake, "WindowsOfProcess").Length, "the desktop and the taskbar are not enumerated")
	GestureSysForceQuitFrontmost(Fake)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length, "the shell's process is never terminated")

	Fake := _SysActionsFake()
	Fake.ShellPidValue := 900
	Fake.Active := { Hwnd: 0x400, Pid: 610, Class: "ApplicationFrameWindow" }
	Fake.Windows := [0x400, 0x401]
	Fake.FramedApp := 7120
	GestureSysQuitFrontmostApp(Fake)
	Closes := _SysActions_CallsNamed(Fake, "PostClose")
	AssertEqual(1, Closes.Length, "only the active packaged app's frame is closed")
	AssertEqual(0x400, Closes[1][2])
	GestureSysForceQuitFrontmost(Fake)
	AssertEqual(0x400, _SysActions_CallsNamed(Fake, "FramedAppPid")[1][2])
	Kills := _SysActions_CallsNamed(Fake, "CloseProcess")
	AssertEqual(1, Kills.Length)
	AssertEqual(7120, Kills[1][2], "the packaged app's own process, not the shared frame host")

	Fake.Calls := []
	Fake.FramedApp := 0
	GestureSysForceQuitFrontmost(Fake)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length, "an unresolved frame is refused, never the host")

	Fake := _SysActionsFake()
	Fake.ShellPidValue := 900
	Fake.Active := { Hwnd: 0x500, Pid: 1500, Class: "CabinetWClass" }
	Fake.Windows := [0x500, 0x501]
	GestureSysQuitFrontmostApp(Fake)
	AssertEqual(2, _SysActions_CallsNamed(Fake, "PostClose").Length, "a separate folder process is still quit whole")
	GestureSysForceQuitFrontmost(Fake)
	AssertEqual(1500, _SysActions_CallsNamed(Fake, "CloseProcess")[1][2])
}
Test("system actions: quit and force quit act on the active app, never the shell or the frame host", _SysActions_QuitSharedHosts)

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

; Windows 11 lists one Shell.Application window per Explorer tab, every one
; with the frame's HWND: the first one was taken, so a confirmed unblock acted
; on a background tab's selection and the folder helpers on its folder.
_SysActions_ExplorerTabs() {
	Background := { HWND: 0x42, Tab: 0x501, Document: { Folder: { Self: { Path: "C:\Users\ana\Downloads" } },
		SelectedItems: (this) => [{ Path: "C:\Users\ana\Downloads\setup.exe" }] } }
	Foreground := { HWND: 0x42, Tab: 0x502, Document: { Folder: { Self: { Path: "C:\Users\ana\Documents" } },
		SelectedItems: (this) => [{ Path: "C:\Users\ana\Documents\report.pdf" }] } }
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x42, Pid: 7, Class: "CabinetWClass" }
	Fake.Shell := { Windows: (this) => [Background, Foreground] }
	Fake.ActiveTab := 0x502
	GestureSysUnblockFileSelection(Fake)
	Deletes := _SysActions_CallsNamed(Fake, "DeleteZoneIdentifier")
	AssertEqual(1, Deletes.Length)
	AssertEqual("C:\Users\ana\Documents\report.pdf", Deletes[1][2], "the active tab's selection, not the first tab's")
	GestureSysOpenTerminalHere(Fake)
	AssertEqual("C:\Users\ana\Documents", _SysActions_CallsNamed(Fake, "Launch")[1][3], "the active tab's folder")
}
Test("system actions: the Explorer helpers act on the active tab of a tabbed window", _SysActions_ExplorerTabs)

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

; One confirm action through GestureInvokeAction, Cancel then OK. A function
; of its own, called once per id, rather than a loop body: the recorder closure
; reads Id, and no closure of the driver reads a for-loop variable of the
; function that creates it (production binds it through an immediately called
; arrow). This one did, and on CI it recorded no run: _GestureRunAction
; contains and logs whatever an action throws, so the OK case saw neither a run
; nor an error. The log lines of the OK run are part of the failure message.
; @param Id {String} A catalogue action declaring confirm = true.
_SysActions_ConfirmGateCase(Id) {
	global GESTURE_ACTIONS, _LOGGER_INFO_ENABLED
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
		Lines := []
		SavedInfo := _LOGGER_INFO_ENABLED
		_LOGGER_INFO_ENABLED := true
		LoggerSetTestSink((Entry) => Lines.Push(Entry))
		try Fake.Deferred[1].Call()
		finally {
			LoggerClearTestSink()
			_LOGGER_INFO_ENABLED := SavedInfo
		}
		Logged := ""
		for LogLine in Lines
			Logged .= "`n" . LogLine
		AssertEqual(1, Ran.Length, Id . ": OK runs it once" . Logged)
		AssertEqual(0x77, _SysActions_CallsNamed(Fake, "Activate")[1][2], "the window it was asked from gets its focus back")
	} finally {
		GESTURE_ACTIONS[Id] := Saved
	}
}

_SysActions_ConfirmGate() {
	global GESTURE_ACTIONS
	for Id in ["empty_trash", "unblock_file_selection", "force_quit_frontmost"]
		_SysActions_ConfirmGateCase(Id)
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

; The real force quit behind the gate: Cancel kills nothing, OK kills the
; process of the window the question was asked from, and a window that cannot
; get its focus back leaves the one active instead alive.
_SysActions_ForceQuitConfirm() {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS["force_quit_frontmost"]
	try {
		for Answer in ["Cancel", "OK"] {
			Fake := _SysActionsFake()
			Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
			Fake.Answer := Answer
			GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: _SysActions_ForceQuitWith.Bind(Fake) }
			GestureInvokeAction("force_quit_frontmost", "", Fake)
			AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length, "nothing is killed before the answer")
			Fake.Deferred[1].Call()
			Killed := _SysActions_CallsNamed(Fake, "CloseProcess")
			if (Answer = "OK") {
				AssertEqual(1, Killed.Length, "OK kills once")
				AssertEqual(812, Killed[1][2], "the process of the window it was asked from")
			} else {
				AssertEqual(0, Killed.Length, "Cancel kills nothing")
			}
		}
		Fake := _SysActionsFake()
		Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
		Fake.Answer := "OK"
		Fake.ActivateResult := false
		GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: _SysActions_ForceQuitWith.Bind(Fake) }
		GestureInvokeAction("force_quit_frontmost", "", Fake)
		Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "Notepad" }
		Fake.Deferred[1].Call()
		AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length,
			"the window active instead of the one it was asked from is not killed")
	} finally {
		GESTURE_ACTIONS["force_quit_frontmost"] := Saved
	}
}
Test("system actions: force_quit_frontmost kills only on OK, the window it was asked from (force-quit-confirm)",
	_SysActions_ForceQuitConfirm)

; A window that cannot get its focus back (a Start menu or a pop-up that closed
; when the question opened) refuses only the actions that read the active
; window once they run: emptying the Recycle Bin reads none, and ran before
; the confirmation refused every action in that case.
_SysActions_ConfirmWithoutFocusBack() {
	for Id, Runs in Map("empty_trash", 1, "unblock_file_selection", 0, "force_quit_frontmost", 0)
		_SysActions_ConfirmWithoutFocusBackCase(Id, Runs)
}

; One case per call: the recorder closure must read a parameter, because a
; closure over a for-loop variable is not captured and would throw inside the
; runner's try, recording nothing.
_SysActions_ConfirmWithoutFocusBackCase(Id, Runs) {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS[Id]
	Ran := []
	GESTURE_ACTIONS[Id] := { Fn: (*) => Ran.Push(Id) }
	try {
		Fake := _SysActionsFake()
		Fake.Active := { Hwnd: 0x77, Pid: 7, Class: "CabinetWClass" }
		Fake.Answer := "OK"
		Fake.ActivateResult := false
		GestureInvokeAction(Id, "", Fake)
		Fake.Deferred[1].Call()
		AssertEqual(1, _SysActions_CallsNamed(Fake, "Activate").Length, Id . ": the focus is asked back")
		AssertEqual(Runs, Ran.Length, Id . ": runs " . Runs . " time(s) once the focus cannot come back")
	} finally {
		GESTURE_ACTIONS[Id] := Saved
	}
}
Test("system actions: a lost focus refuses only the actions that read the active window (confirm-focus-scope)",
	_SysActions_ConfirmWithoutFocusBack)

; Runs the real force quit against the recording double.
_SysActions_ForceQuitWith(Fake, *) {
	GestureSysForceQuitFrontmost(Fake)
}

_SysActions_Throw(*) {
	throw Error("probe failure")
}

; A system action runs in a deferred thread, after _GestureRunAction's try has
; returned: one that threw escaped into the global error handler instead of
; the single contained log line every other action produces.
_SysActions_DeferredContainment() {
	Fake := _SysActionsFake()
	Runner := _GestureMakeSystemRunner("probe", _SysActions_Throw, Fake)
	Runner()
	AssertEqual(1, Fake.Deferred.Length, "the dispatching thread only schedules the action")
	Threw := false
	try {
		Fake.Deferred[1].Call()
	} catch {
		Threw := true
	}
	AssertEqual(false, Threw, "the deferred body contains its own failure")
}
Test("system actions: a deferred system action that throws is contained", _SysActions_DeferredContainment)





; ======================================
; ======================================
; ======= 5/ open_app ==================
; ======================================
; ======================================

; Replays _shared/tests/corpus/action_parameters/app_vectors.json, which the
; macOS and Linux suites replay too.
_SysActions_AppCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\action_parameters\app_vectors.json"
	AssertTrue(FileExist(Path) != "", "the app corpus must exist at " . Path)
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	AssertEqual("app", GestureActionParameterSpec("open_app"), "open_app parameter kind")
	Checked := 0
	for _, Vector in Corpus["vectors"] {
		Valid := !Vector.Has("valid") || Vector["valid"]
		ErrorText := ""
		AssertEqual(Valid, GestureValidateActionParameter("open_app", Vector["value"], &ErrorText),
			Vector["id"] . ": validation")
		if !Valid
			AssertEqual(t("dialog.gestures.param_err_app"), ErrorText, Vector["id"] . ": the kind's own refusal")
		Checked += 1
	}
	AssertTrue(Checked >= 15, "expected at least 15 app vectors, found " . Checked)
}
Test("system actions: the app parameter replays the shared corpus", _SysActions_AppCorpus)

_SysActions_OpenApp() {
	global GestureActionParameters
	Saved := GestureActionParameters
	try {
		Target := "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
		GestureActionParameters := Map(GestureActionParameterKey("keyboard__ctrl_k", "open_app"), Target)
		Fake := _SysActionsFake()
		GestureSysOpenApp("keyboard__ctrl_k", Fake)
		Launches := _SysActions_CallsNamed(Fake, "Launch")
		AssertEqual(1, Launches.Length)
		AssertEqual(Target, Launches[1][2], "the binding's own application, as the shell runs it")
		Fake := _SysActionsFake()
		GestureSysOpenApp("tap_3", Fake)
		AssertEqual(0, Fake.Calls.Length, "a binding with no application opens nothing")
	} finally {
		GestureActionParameters := Saved
	}
}
Test("system actions: open_app launches the application stored for its binding", _SysActions_OpenApp)





; =======================================
; =======================================
; ======= 6/ SystemControl Probes =======
; =======================================
; =======================================

; The two probes the virtual desktop actions and the touchpad registry owner
; make through SystemControl, run for real: both only read.
_SysActions_ControlProbes() {
	Adapter := SystemControl()
	AssertTrue(Adapter.CurrentUserKeyExists("Software"), "HKEY_CURRENT_USER\Software exists")
	AssertFalse(Adapter.CurrentUserKeyExists("Software\ErgoptiTests\Absent_" . A_TickCount),
		"an absent key is reported absent, not as a failure")
	AssertTrue(_TouchpadRegistryKeyExists("HKEY_CURRENT_USER\Software"),
		"the touchpad owner probes its key through the adapter")
	AssertThrows(() => _TouchpadRegistryKeyExists("HKEY_LOCAL_MACHINE\Software"),
		"the touchpad owner refuses a key outside HKEY_CURRENT_USER")
	Expected := 0
	AssertTrue(DllCall("ProcessIdToSessionId", "UInt", DllCall("GetCurrentProcessId", "UInt"),
		"UInt*", &Expected), "the test must know its session")
	AssertEqual(Expected, Adapter.SessionId(), "the script's own session")
}
Test("system actions: SystemControl probes a registry key and names the session", _SysActions_ControlProbes)

_SysActions_PauseReceipt(Replay, Fragment) {
	global _LOGGER_INFO_ENABLED
	PriorPause := A_IsSuspended
	PriorInfo := _LOGGER_INFO_ENABLED
	Entries := []
	_LOGGER_INFO_ENABLED := true
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		Suspend(true)
		Replay.Call()
	} finally {
		Suspend(PriorPause)
		LoggerClearTestSink()
		_LOGGER_INFO_ENABLED := PriorInfo
	}
	Found := 0
	for Entry in Entries {
		if InStr(Entry, Fragment)
			Found += 1
	}
	return Found
}

_SysActions_PausedDeferredDispatch() {
	Fake := _SysActionsFake()
	Runner := _GestureMakeSystemRunner("clear_clipboard", GestureSysClearClipboard.Bind(Fake), Fake)
	Runner.Call()
	Receipts := _SysActions_PauseReceipt(Fake.Deferred[1], "cancelled before its deferred execution")
	AssertEqual(0, _SysActions_CallsNamed(Fake, "ClearClipboard").Length,
		"a callback admitted before pause cannot clear the clipboard while paused")
	AssertEqual(1, Receipts, "the deferred action cancellation is logged once")
}
Test("system actions: deferred clipboard action cancels during pause (system-action-pause-boundaries)",
	_SysActions_PausedDeferredDispatch)

_SysActions_PausedDelayedSleep() {
	Fake := _SysActionsFake()
	GestureSysSleepDisplays(Fake)
	Receipts := _SysActions_PauseReceipt(Fake.Deferred[1], "Display sleep was cancelled")
	AssertEqual(0, _SysActions_CallsNamed(Fake, "PostBroadcast").Length,
		"the second display timer must not power monitors off after pause")
	AssertEqual(1, Receipts, "the delayed display cancellation is logged once")
}
Test("system actions: delayed display sleep cancels during pause (system-action-pause-boundaries)",
	_SysActions_PausedDelayedSleep)

_SysActions_PausedConfirmationAdmission() {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	GestureInvokeAction("force_quit_frontmost", "keyboard__pause_probe", Fake)
	Receipts := _SysActions_PauseReceipt(Fake.Deferred[1], "cancelled before its confirmation")
	AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length,
		"a queued confirmation must not open a dialog after pause")
	AssertEqual(1, Receipts, "the confirmation cancellation is logged once")
}
Test("system actions: deferred confirmation cancels before Ask during pause (system-action-pause-boundaries)",
	_SysActions_PausedConfirmationAdmission)

class _SysActions_PausingFocus extends _SysActionsFake {
	Activate(Hwnd) {
		this._Log("Activate", Hwnd)
		Suspend(true)
		return true
	}
}

_SysActions_PausedDuringFocusRestore() {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS["force_quit_frontmost"]
	Ran := []
	Fake := _SysActions_PausingFocus()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: () => Ran.Push("ran") }
	PriorPause := A_IsSuspended
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__pause_probe", Fake)
		Fake.Deferred[1].Call()
		AssertEqual(0, Ran.Length, "a pause during activation cannot dispatch a confirmed extension")
	} finally {
		Suspend(PriorPause)
		GESTURE_ACTIONS["force_quit_frontmost"] := Saved
	}
}
Test("system actions: confirmation rechecks pause after focus restoration (system-action-pause-boundaries)",
	_SysActions_PausedDuringFocusRestore)
; All actual process effects stay inside the existing recording adapter.
_SysActions_InstallOwnedForce(Fake) {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS["force_quit_frontmost"]
	Entry := { Fn: _GestureMakeSystemRunner("force_quit_frontmost", GestureSysForceQuitFrontmost.Bind(Fake), Fake) }
	if Saved.HasOwnProp("ConfirmedFn")
		Entry.ConfirmedFn := Saved.ConfirmedFn
	GESTURE_ACTIONS["force_quit_frontmost"] := Entry
	return Saved
}

_SysActions_TargetCase(Race) {
	global GESTURE_ACTIONS, GESTURE_SYS_APP_FRAME_CLASS
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	if Race == "missing"
		Fake.Active := ""
	else if Race == "own"
		Fake.Active.Pid := Fake.OwnPidValue
	else if Race == "shell"
		Fake.Active.Class := "Shell_TrayWnd"
	else if Race == "shared"
		Fake.ShellPidValue := 812
	else if Race == "uwp" || Race == "uwp_changed" || Race == "uwp_missing" {
		Fake.Active.Class := GESTURE_SYS_APP_FRAME_CLASS
		Fake.FramedApp := Race == "uwp_missing" ? 0 : 7001
	}
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		if Race == "missing" || Race == "own" || Race == "shell" || Race == "shared" || Race == "uwp_missing" {
			AssertEqual(0, Fake.Deferred.Length, Race . ": no destructive question is admitted")
			return
		}
		if Race == "question_absent"
			(Fake.Snapshots.Delete(0x100), Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "Notepad" })
		else if Race == "question_pid" || Race == "question_class"
			Fake.Active := Fake.Snapshots[0x100] := { Hwnd: 0x100, Pid: Race == "question_pid" ? 913 : 812,
				Class: Race == "question_class" ? "OtherWindow" : "Notepad" }
		Fake.Deferred.RemoveAt(1).Call()
		if InStr(Race, "question_") == 1 {
			AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length, Race . ": stale source cannot open a question")
			AssertEqual(0, Fake.Deferred.Length)
			return
		}
		AssertEqual(1, Fake.Deferred.Length, "the actual registered runner retains its second deferral")
		if Race == "foreground"
			Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "Notepad" }
		else if Race == "effect_absent"
			(Fake.Snapshots.Delete(0x100), Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "Notepad" })
		else if Race == "effect_pid" || Race == "effect_class"
			Fake.Active := Fake.Snapshots[0x100] := { Hwnd: 0x100, Pid: Race == "effect_pid" ? 913 : 812,
				Class: Race == "effect_class" ? "OtherWindow" : "Notepad" }
		else if Race == "uwp_changed"
			Fake.FramedApp := 7002
		Fake.Deferred.RemoveAt(1).Call()
		Killed := _SysActions_CallsNamed(Fake, "CloseProcess")
		Refused := InStr(Race, "effect_") == 1 || Race == "uwp_changed"
		AssertEqual(Refused ? 0 : 1, Killed.Length, Race . ": only a currently owned source may be terminated")
		if !Refused
			AssertEqual(Race == "uwp" ? 7001 : 812, Killed[1][2], "the approved source PID is never replaced by the new foreground PID")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}

; A factory binds a function parameter, never the loop variable.
_SysActions_TargetTest(Race) => () => _SysActions_TargetCase(Race)
for _SysTargetCase in ["foreground", "missing", "question_absent", "question_pid", "question_class",
	"effect_absent", "effect_pid", "effect_class", "own", "shell", "shared", "uwp_missing", "uwp", "uwp_changed", "unchanged"]
	Test("system actions: native confirmed target " . _SysTargetCase . " (confirmed-target-owner)", _SysActions_TargetTest(_SysTargetCase))

class _SysActions_TargetChangingAsk extends _SysActionsFake {
	Ask(Text, Title) {
		this._Log("Ask", Text, Title)
		this.Snapshots[0x100] := { Hwnd: 0x100, Pid: 913, Class: "Notepad" }
		this.Active := this.Snapshots[0x100]
		return "OK"
	}
}

_SysActions_SourceChangesDuringQuestion() {
	global GESTURE_ACTIONS
	Fake := _SysActions_TargetChangingAsk()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(1, _SysActions_CallsNamed(Fake, "Ask").Length)
		AssertEqual(0, _SysActions_CallsNamed(Fake, "Activate").Length, "a replaced window is refused before activation")
		AssertEqual(0, Fake.Deferred.Length, "OK cannot authorize the replacement process")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
Test("system actions: original window changes during question (confirmed-target-owner)", _SysActions_SourceChangesDuringQuestion)

_SysActions_ConfirmedExtensionKeepsNoArguments() {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS["force_quit_frontmost"]
	Ran := []
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: () => Ran.Push("zero_args") }
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(1, Ran.Length, "ordinary extensions retain strict zero-argument calls")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
Test("system actions: confirmed extension retains zero arguments (confirmed-target-owner)", _SysActions_ConfirmedExtensionKeepsNoArguments)

_SysActions_HiddenWindowSnapshot() {
	Adapter := SystemControl()
	Window := Gui()
	PriorHidden := A_DetectHiddenWindows
	try {
		DetectHiddenWindows(false)
		Snapshot := Adapter.WindowSnapshot(Window.Hwnd)
		AssertTrue(IsObject(Snapshot), "hidden owned window is captured without activation")
		AssertEqual(Window.Hwnd, Snapshot.Hwnd)
		AssertEqual(Adapter.OwnPid(), Snapshot.Pid)
		AssertEqual("AutoHotkeyGUI", Snapshot.Class)
		AssertFalse(A_DetectHiddenWindows, "the native read restores its caller's policy")
		Hwnd := Window.Hwnd
		Window.Destroy()
		AssertEqual("", Adapter.WindowSnapshot(Hwnd), "destroyed HWND has no source receipt")
		AssertFalse(A_DetectHiddenWindows)
	} finally {
		DetectHiddenWindows(PriorHidden)
		try Window.Destroy()
	}
}
Test("system actions: hidden native source capture is read only (confirmed-target-owner)", _SysActions_HiddenWindowSnapshot)

class _SysActions_SourceChangingFocus extends _SysActionsFake {
	Activate(Hwnd) {
		this._Log("Activate", Hwnd)
		this.Active := this.Snapshots[Hwnd] := { Hwnd: Hwnd, Pid: 913, Class: "Notepad" }
		return true
	}
}

_SysActions_SourceChangesDuringFocus() {
	global GESTURE_ACTIONS
	Fake := _SysActions_SourceChangingFocus()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(1, _SysActions_CallsNamed(Fake, "Activate").Length)
		AssertEqual(0, Fake.Deferred.Length, "activation cannot replace the approved source receipt")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
Test("system actions: original source changes during focus restoration (confirmed-target-owner)", _SysActions_SourceChangesDuringFocus)

_SysActions_ConfirmedExplorerKeepsSource() {
	global GESTURE_ACTIONS
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "CabinetWClass" }
	Fake.Answer := "OK"
	Fake.Shell := _SysActions_Shell(0x100, "C:\original", ["C:\original\\approved.txt"])
	Saved := GESTURE_ACTIONS["unblock_file_selection"]
	Entry := { Fn: _GestureMakeSystemRunner("unblock_file_selection", GestureSysUnblockFileSelection.Bind(Fake), Fake) }
	if Saved.HasOwnProp("ConfirmedFn")
		Entry.ConfirmedFn := Saved.ConfirmedFn
	GESTURE_ACTIONS["unblock_file_selection"] := Entry
	try {
		GestureInvokeAction("unblock_file_selection", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "CabinetWClass" }
		Fake.Deferred.RemoveAt(1).Call()
		Deleted := _SysActions_CallsNamed(Fake, "DeleteZoneIdentifier")
		AssertEqual(1, Deleted.Length, "the explicit approved Explorer window remains the selection owner")
		AssertEqual("C:\original\\approved.txt", Deleted[1][2])
	} finally GESTURE_ACTIONS["unblock_file_selection"] := Saved
}
Test("system actions: confirmed Explorer mutation retains its original window (confirmed-target-owner)", _SysActions_ConfirmedExplorerKeepsSource)


class _SysActions_AlternatingFrame extends _SysActionsFake {
	FramedAppPid(FrameHwnd) {
		this._Log("FramedAppPid", FrameHwnd)
		return this.FrameReads.RemoveAt(1)
	}
}

_SysActions_ApprovedUwpPidCannotChange() {
	Fake := _SysActions_AlternatingFrame()
	Fake.FrameReads := [7001, 7002, 7001]
	Target := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow", TargetPid: 7001 }
	if Target.HasOwnProp("TargetPid")
		Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	GestureSysForceQuitFrontmost(Fake, Target)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length,
		"a transiently resolved replacement PID cannot become approved effect authority")
}
Test("system actions: UWP approved PID refuses transient retarget (confirmed-target-review)", _SysActions_ApprovedUwpPidCannotChange)

_SysActions_MissingApprovedUwpPidRefuses() {
	Fake := _SysActionsFake()
	Fake.FramedApp := 7001
	Target := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow" }
	if Target.HasOwnProp("TargetPid")
		Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	GestureSysForceQuitFrontmost(Fake, Target)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length,
		"a confirmed receipt without its approved process cannot authorize a fresh process")
}
Test("system actions: confirmed UWP requires approved PID (confirmed-target-review)", _SysActions_MissingApprovedUwpPidRefuses)

class _SysActions_ThrowingNativeQuery extends _SysActionsFake {
	FramedAppPid(FrameHwnd) {
		if this.ThrowQuery && this.Query == "frame"
			throw TargetError("injected native frame disappearance")
		return 7001
	}
	WindowSnapshot(Hwnd) {
		if this.ThrowQuery && this.Query == "window"
			throw TargetError("injected native window disappearance")
		return super.WindowSnapshot(Hwnd)
	}
}

_SysActions_NativeQueryFailureIsContained(Phase, Query) {
	global GESTURE_ACTIONS
	Fake := _SysActions_ThrowingNativeQuery()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow" }
	Fake.Answer := "OK"
	Fake.Query := Query
	Fake.ThrowQuery := Phase == "preflight"
	Saved := _SysActions_InstallOwnedForce(Fake)
	Entries := []
	Threw := false
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		try {
			GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
			if Phase == "callback" {
				Fake.ThrowQuery := true
				Fake.Deferred.RemoveAt(1).Call()
			}
		} catch {
			Threw := true
		}
		AssertEqual(false, Threw, "native target queries remain inside their owning dispatch boundary")
		AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length, "failed ownership cannot ask a destructive question")
		AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length)
		AssertEqual(0, Fake.Deferred.Length, "query failure schedules no later effect")
		Errors := 0
		for Entry in Entries {
			if InStr(Entry, "failed during confirmation " . Phase) && InStr(Entry, "injected native")
				Errors += 1
		}
		AssertEqual(1, Errors, "the original native query failure has exactly one contained diagnostic")
	} finally {
		LoggerClearTestSink()
		GESTURE_ACTIONS["force_quit_frontmost"] := Saved
	}
}

_SysActions_NativeQueryTest(Phase, Query) => () => _SysActions_NativeQueryFailureIsContained(Phase, Query)
for _SysQueryPhase in ["preflight", "callback"] {
	for _SysQueryKind in ["frame", "window"]
		Test("system actions: native query " . _SysQueryPhase . " " . _SysQueryKind . " is contained (confirmed-target-review)",
			_SysActions_NativeQueryTest(_SysQueryPhase, _SysQueryKind))
}


_SysActions_ApprovedUwpStillRuns() {
	Fake := _SysActions_AlternatingFrame()
	Fake.FrameReads := [7001, 7001, 7001]
	Target := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow", TargetPid: 7001 }
	if Target.HasOwnProp("TargetPid")
		Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	GestureSysForceQuitFrontmost(Fake, Target)
	Killed := _SysActions_CallsNamed(Fake, "CloseProcess")
	AssertEqual(1, Killed.Length, "an unchanged approved UWP source runs exactly once")
	AssertEqual(7001, Killed[1][2], "the captured approved app PID reaches the effect")
}
Test("system actions: unchanged approved UWP remains executable (confirmed-target-review)", _SysActions_ApprovedUwpStillRuns)

_SysActions_DirectLegacyForceStillRuns() {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	GestureSysForceQuitFrontmost(Fake)
	Killed := _SysActions_CallsNamed(Fake, "CloseProcess")
	AssertEqual(1, Killed.Length, "the direct unconfirmed adapter API remains available")
	AssertEqual(812, Killed[1][2], "direct legacy execution uses its current source PID")
}
Test("system actions: direct legacy force API keeps its contract (confirmed-target-review)", _SysActions_DirectLegacyForceStillRuns)

class _QueryPauseFake extends _SysActionsFake {
	__New(At) {
		super.__New()
		this.At := At
		this.ReadCount := 0
	}
	WindowSnapshot(Hwnd) {
		this.ReadCount += 1
		Current := super.WindowSnapshot(Hwnd)
		if this.ReadCount == this.At
			Suspend(true)
		return Current
	}
	IsDirectory(Path) {
		if this.At == 4
			Suspend(true)
		return false
	}
}
class _QueryDoc {
	SelectedItems() => [{Path: "C:\owned\selected.txt"}]
}
class _QueryShell {
	Windows() => [{HWND: 0x100, Document: _QueryDoc()}]
}
_QueryPauseCase(At) {
	Fake := _QueryPauseFake(At)
	Target := { Hwnd: 0x100, Pid: 812, Class: "Notepad", TargetPid: 812 }
	Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureScheduleConfirmedSystemAction("force_quit_frontmost", GestureSysForceQuitFrontmost, Target, Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length,
			"pause during ownership read cannot reach destructive effect")
	} finally Suspend(PriorPause)
}
_QueryPauseFactory(At) => () => _QueryPauseCase(At)
_QueryPauseQuestionCase(At, Forbidden) {
	Fake := _QueryPauseFake(At)
	Fake.Answer := "OK"
	Target := { Hwnd: 0x100, Pid: 812, Class: "Notepad", TargetPid: 812 }
	Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureConfirmThenInvoke("force_quit_frontmost", "", Target, Fake)
		AssertEqual(0, Forbidden == "Deferred" ? Fake.Deferred.Length : _SysActions_CallsNamed(Fake, Forbidden).Length,
			"pause during ownership read refuses next observable boundary")
	} finally Suspend(PriorPause)
}
_QueryPauseQuestionFactory(At, Forbidden) => () => _QueryPauseQuestionCase(At, Forbidden)
_QueryPauseUnblockCase(At) {
	Fake := _QueryPauseFake(At)
	Fake.Shell := _QueryShell()
	Target := {Hwnd: 0x100, Pid: 812, Class: "CabinetWClass"}
	Fake.Snapshots[0x100] := Target.Clone()
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureScheduleConfirmedSystemAction("unblock_file_selection", GestureSysUnblockFileSelection, Target, Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(0, _SysActions_CallsNamed(Fake, "DeleteZoneIdentifier").Length,
			"paused confirmed explorer callback cannot mutate a recorded file")
	} finally Suspend(PriorPause)
}
_QueryPauseUnblockFactory(At) => () => _QueryPauseUnblockCase(At)
_QueryPausePositive(ActionName) {
	Fake := _QueryPauseFake(0)
	Fake.Shell := _QueryShell()
	IsForce := ActionName == "force_quit_frontmost"
	Target := {Hwnd: 0x100, Pid: 812, Class: IsForce ? "Notepad" : "CabinetWClass"}
	if IsForce
		Target.TargetPid := 812
	if IsForce
		Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		Fn := IsForce ? GestureSysForceQuitFrontmost : GestureSysUnblockFileSelection
		_GestureScheduleConfirmedSystemAction(ActionName, Fn, Target, Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(1, _SysActions_CallsNamed(Fake, IsForce ? "CloseProcess" : "DeleteZoneIdentifier").Length,
			"unchanged unpaused receipt still permits exactly one recorded effect")
	} finally Suspend(PriorPause)
}
_QueryPausePositiveFactory(ActionName) => () => _QueryPausePositive(ActionName)
for _SysActions_QueryPauseRead in [1, 2, 3]
	Test("confirmed callback pause during ownership read  (confirmed-query-pause)" . _SysActions_QueryPauseRead, _QueryPauseFactory(_SysActions_QueryPauseRead))
Test("confirmation read pause cannot ask (confirmed-query-pause)", _QueryPauseQuestionFactory(1, "Ask"))
Test("post-answer read pause cannot reactivate (confirmed-query-pause)", _QueryPauseQuestionFactory(2, "Activate"))
Test("post-focus ownership read pause cannot queue effect (confirmed-query-pause)", _QueryPauseQuestionFactory(4, "Deferred"))
for _SysActions_QueryPauseRead in [1, 3, 4]
	Test("unblock callback pause during ownership/directory read  (confirmed-query-pause)" . _SysActions_QueryPauseRead, _QueryPauseUnblockFactory(_SysActions_QueryPauseRead))
for _SysActions_QueryPausePositiveAction in ["force_quit_frontmost", "unblock_file_selection"]
	Test("confirmed callback unchanged  (confirmed-query-pause)" . _SysActions_QueryPausePositiveAction, _QueryPausePositiveFactory(_SysActions_QueryPausePositiveAction))

class _SiblingQueryFake extends _SysActionsFake {
	__New() {
		super.__New()
		this.PauseQuery := true
	}
	ActiveWindow() {
		Current := super.ActiveWindow()
		if this.PauseQuery
			Suspend(true)
		return Current
	}
	CaptureMuted() {
		Current := super.CaptureMuted()
		if this.PauseQuery
			Suspend(true)
		return Current
	}
	ReadDword(Key, Name) {
		Current := super.ReadDword(Key, Name)
		if this.PauseQuery
			Suspend(true)
		return Current
	}
}
_SiblingQueryCase(ActionName, Fn, Effect, PauseQuery := true) {
	Fake := _SiblingQueryFake()
	Fake.Active := {Hwnd: 0x100, Pid: 812, Class: "Notepad"}
	Fake.Windows := [0x100]
	Fake.PauseQuery := PauseQuery
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureMakeSystemRunner(ActionName, Fn.Bind(Fake), Fake).Call()
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(PauseQuery ? 0 : (Effect == "WriteDword" ? 2 : 1), _SysActions_CallsNamed(Fake, Effect).Length,
			"deferred sibling emitted effect after query observed pause")
	} finally Suspend(PriorPause)
}
_SiblingQueryFactory(ActionName, Fn, Effect, PauseQuery := true) => () => _SiblingQueryCase(ActionName, Fn, Effect, PauseQuery)
class _SiblingThemeMidWriteFake extends _SiblingQueryFake {
	WriteDword(Key, Name, Value) {
		Written := super.WriteDword(Key, Name, Value)
		if Name == "AppsUseLightTheme"
			Suspend(true)
		return Written
	}
}
_SiblingThemeMidWriteStillSettles() {
	Fake := _SiblingThemeMidWriteFake()
	Fake.PauseQuery := false
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureMakeSystemRunner("toggle_dark_mode", GestureSysToggleDarkMode.Bind(Fake), Fake).Call()
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(2, _SysActions_CallsNamed(Fake, "WriteDword").Length,
			"an admitted theme transaction must publish both settings")
		AssertEqual(Fake.Registry["AppsUseLightTheme"], Fake.Registry["SystemUsesLightTheme"],
			"mid-write pause cannot leave applications and system themes inconsistent")
		AssertEqual(1, _SysActions_CallsNamed(Fake, "BroadcastSettingChange").Length,
			"the admitted write phase still tells applications its committed state")
	} finally Suspend(PriorPause)
}
Test("quit runner after active query pause", _SiblingQueryFactory("quit_frontmost_app", GestureSysQuitFrontmostApp, "PostClose"))
Test("microphone runner after capture query pause", _SiblingQueryFactory("mic_mute_toggle", GestureSysMicMuteToggle, "SetCaptureMuted"))
Test("theme runner after registry query pause", _SiblingQueryFactory("toggle_dark_mode", GestureSysToggleDarkMode, "WriteDword"))
Test("quit unchanged recording", _SiblingQueryFactory("quit_frontmost_app", GestureSysQuitFrontmostApp, "PostClose", false))
Test("microphone unchanged recording", _SiblingQueryFactory("mic_mute_toggle", GestureSysMicMuteToggle, "SetCaptureMuted", false))
Test("theme unchanged recording", _SiblingQueryFactory("toggle_dark_mode", GestureSysToggleDarkMode, "WriteDword", false))
Test("theme mid-first-write pause completes transaction", _SiblingThemeMidWriteStillSettles)

class _QEFF_Path {
	__New(Sys) => this.Sys := Sys
	Path {
		get {
			this.Sys.PauseAt("folder")
			return this.Sys.FolderPath
		}
	}
}
class _QEFF_Folder {
	__New(Sys) {
		this.Sys := Sys
		this.Self := _QEFF_Path(Sys)
	}
	ParseName(Name) {
		this.Sys.PauseAt("rename_item")
		return {Name: Name}
	}
}
class _QEFF_Document {
	__New(Sys) {
		this.Sys := Sys
		this.Folder := _QEFF_Folder(Sys)
	}
	SelectItem(Item, Flags) => this.Sys._Log("SelectItem", Item.Name, Flags)
}
class _QEFF_DriveItem {
	__New(Sys, Name) {
		this.Sys := Sys
		this.Name := Name
	}
	InvokeVerb(Verb) {
		this.Sys._Log("Eject", this.Name, Verb)
		this.Sys.PauseAt("ejected")
	}
}
class _QEFF_Computer {
	__New(Sys) => this.Sys := Sys
	ParseName(Name) {
		this.Sys.PauseAt("drive_item")
		return _QEFF_DriveItem(this.Sys, Name)
	}
}
class _QEFF_Shell {
	__New(Sys) => this.Sys := Sys
	Windows() => [{HWND: 0x100, Tab: 1, Document: _QEFF_Document(this.Sys)}]
	Namespace(Id) {
		this.Sys.PauseAt("namespace")
		return _QEFF_Computer(this.Sys)
	}
}
class _QEFF_Fake extends _SysActionsFake {
	__New(Mode) {
		super.__New()
		this.Mode := Mode
		this.Active := {Hwnd: 0x100, Pid: 812, Class: "CabinetWClass"}
		this.ActiveTab := 1
		this.Drives := "EF"
		this.FolderPath := "C:\owned"
		this.MonitorList := [{Left: 0, Top: 0, Right: 100, Bottom: 100}]
		this.Pointer := {X: 10, Y: 10}
	}
	PauseAt(Phase) {
		if this.Mode == Phase
			Suspend(true)
	}
	ActiveWindow() {
		Current := super.ActiveWindow()
		this.PauseAt("active")
		return Current
	}
	MousePosition() {
		Current := super.MousePosition()
		this.PauseAt("pointer")
		return Current
	}
	Monitors() {
		Current := super.Monitors()
		this.PauseAt("monitors")
		return Current
	}
	RemovableDrives() {
		Current := super.RemovableDrives()
		this.PauseAt("drives")
		return Current
	}
	ShellApplication() {
		this.PauseAt("shell")
		return _QEFF_Shell(this)
	}
	WindowsTerminalPath() {
		Current := super.WindowsTerminalPath()
		this.PauseAt("terminal")
		return Current
	}
	CreateNewFile(Path) {
		Status := super.CreateNewFile(Path)
		this.PauseAt(Status == "exists" ? "collision" : "created")
		return Status
	}
}
_QEFF_Case(ProbeRow) {
	Fake := _QEFF_Fake(ProbeRow.Mode)
	if ProbeRow.HasOwnProp("EmptyDrives")
		Fake.Drives := ""
	if ProbeRow.HasOwnProp("EmptyFolder")
		Fake.FolderPath := ""
	if ProbeRow.HasOwnProp("Collision")
		Fake.CreateStatuses := ["exists", "created"]
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureMakeSystemRunner(ProbeRow.Action, ProbeRow.Fn.Bind(Fake), Fake).Call()
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(ProbeRow.Count, _SysActions_CallsNamed(Fake, ProbeRow.Effect).Length,
			ProbeRow.Name . ": the next effect must respect the admitted query state")
		if ProbeRow.HasOwnProp("CreatedCount")
			AssertEqual(ProbeRow.CreatedCount, _SysActions_CallsNamed(Fake, "CreateNewFile").Length,
				"already-created file receipt is preserved without retry or rollback")
	} finally Suspend(PriorPause)
}
_QEFF_CaseFactory(ProbeRow) => () => _QEFF_Case(ProbeRow)
for _SysActions_QueryEffectCase in [
	{Name: "center pointer pause", Action: "center_mouse", Fn: GestureSysCenterMouse, Mode: "pointer", Effect: "MoveMouse", Count: 0},
	{Name: "center monitor pause", Action: "center_mouse", Fn: GestureSysCenterMouse, Mode: "monitors", Effect: "MoveMouse", Count: 0},
	{Name: "center unchanged", Action: "center_mouse", Fn: GestureSysCenterMouse, Mode: "", Effect: "MoveMouse", Count: 1},
	{Name: "eject drive query pause", Action: "eject_all_disks", Fn: GestureSysEjectAllDisks, Mode: "drives", Effect: "Eject", Count: 0},
	{Name: "eject namespace pause", Action: "eject_all_disks", Fn: GestureSysEjectAllDisks, Mode: "namespace", Effect: "Eject", Count: 0},
	{Name: "eject drive item pause", Action: "eject_all_disks", Fn: GestureSysEjectAllDisks, Mode: "drive_item", Effect: "Eject", Count: 0},
	{Name: "eject first effect pause retains one receipt", Action: "eject_all_disks", Fn: GestureSysEjectAllDisks, Mode: "ejected", Effect: "Eject", Count: 1},
	{Name: "eject empty query pause cannot notify", Action: "eject_all_disks", Fn: GestureSysEjectAllDisks, Mode: "drives", EmptyDrives: true, Effect: "Notify", Count: 0},
	{Name: "eject unchanged", Action: "eject_all_disks", Fn: GestureSysEjectAllDisks, Mode: "", Effect: "Eject", Count: 2},
	{Name: "eject empty unchanged notice", Action: "eject_all_disks", Fn: GestureSysEjectAllDisks, Mode: "", EmptyDrives: true, Effect: "Notify", Count: 1},
	{Name: "terminal active query pause", Action: "open_terminal_here", Fn: GestureSysOpenTerminalHere, Mode: "active", Effect: "Launch", Count: 0},
	{Name: "terminal folder query pause", Action: "open_terminal_here", Fn: GestureSysOpenTerminalHere, Mode: "folder", Effect: "Launch", Count: 0},
	{Name: "terminal alias query pause", Action: "open_terminal_here", Fn: GestureSysOpenTerminalHere, Mode: "terminal", Effect: "Launch", Count: 0},
	{Name: "terminal empty query pause cannot notify", Action: "open_terminal_here", Fn: GestureSysOpenTerminalHere, Mode: "folder", EmptyFolder: true, Effect: "Notify", Count: 0},
	{Name: "terminal unchanged", Action: "open_terminal_here", Fn: GestureSysOpenTerminalHere, Mode: "", Effect: "Launch", Count: 1},
	{Name: "terminal empty unchanged notice", Action: "open_terminal_here", Fn: GestureSysOpenTerminalHere, Mode: "", EmptyFolder: true, Effect: "Notify", Count: 1},
	{Name: "newfile active query pause", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "active", Effect: "CreateNewFile", Count: 0},
	{Name: "newfile folder query pause", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "folder", Effect: "CreateNewFile", Count: 0},
	{Name: "newfile created pause cannot open rename", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "created", Effect: "SelectItem", Count: 0, CreatedCount: 1},
	{Name: "newfile collision pause cannot retry create", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "collision", Collision: true, Effect: "CreateNewFile", Count: 1},
	{Name: "newfile rename query pause cannot select", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "rename_item", Effect: "SelectItem", Count: 0, CreatedCount: 1},
	{Name: "newfile empty query pause cannot notify", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "folder", EmptyFolder: true, Effect: "Notify", Count: 0},
	{Name: "newfile unchanged creates once", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "", Effect: "CreateNewFile", Count: 1},
	{Name: "newfile unchanged selects once", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "", Effect: "SelectItem", Count: 1},
	{Name: "newfile collision unchanged retries", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "", Collision: true, Effect: "CreateNewFile", Count: 2},
	{Name: "newfile empty unchanged notice", Action: "new_text_file_here", Fn: GestureSysNewTextFileHere, Mode: "", EmptyFolder: true, Effect: "Notify", Count: 1}
] {
	Test(_SysActions_QueryEffectCase.Name . " (system-query-effects)", _QEFF_CaseFactory(_SysActions_QueryEffectCase))
}

; The native process port has handle authority; the numeric PID registry can
; change independently while a confirmation or one of its timers is waiting.
class _SysActions_ProcessLeaseFake extends _SysActionsFake {
	__New(Mode, Uwp := false) {
		super.__New()
		this.Mode := Mode
		this.Active := { Hwnd: 0x100, Pid: Uwp ? 812 : 7001,
			Class: Uwp ? "ApplicationFrameWindow" : "Notepad" }
		this.FramedApp := 7001
		this.Answer := "OK"
		this.Instance := "approved-A"
		this.Leases := []
		this.Effects := []
		this.Releases := 0
		this.DeferCount := 0
		this.ExtensionCalls := 0
	}
	Retire() {
		this.Instance := "replacement-B"
		for Lease in this.Leases
			Lease.Alive := false
	}
	AcquireProcessTarget(Pid) {
		if this.Mode == "acquire_error"
			throw Error("injected process acquisition failure")
		if this.Mode == "acquire_window_change" {
			this.Instance := "replacement-B"
			this.Snapshots[this.Active.Hwnd] := { Hwnd: this.Active.Hwnd, Pid: 8002, Class: this.Active.Class }
		}
		Lease := { Pid: Pid, Handle: 1, Instance: this.Instance, Alive: true }
		this.Leases.Push(Lease)
		if this.Mode == "acquire_exit"
			this.Retire()
		return Lease
	}
	ProcessTargetIsLive(Lease) {
		if this.Mode == "query_error"
			throw Error("injected retained process query failure")
		return Lease.Handle != 0 && Lease.Alive
	}
	CloseProcess(Pid) {
		if this.Mode == "effect_replacement"
			this.Retire()
		this.Effects.Push({ Pid: Pid, Instance: this.Instance })
		return true
	}
	TerminateProcessTarget(Lease) {
		if this.Mode == "effect_replacement"
			this.Retire()
		if this.Mode == "effect_error"
			throw Error("injected retained process effect failure")
		if this.Mode == "effect_refused"
			return false
		if !Lease.Handle || !Lease.Alive
			return false
		this.Effects.Push({ Pid: Lease.Pid, Instance: Lease.Instance })
		return true
	}
	ReleaseProcessTarget(Lease) {
		if !Lease.Handle
			throw Error("process lease released twice")
		Lease.Handle := 0
		this.Releases += 1
		if this.Mode == "release_error"
			throw Error("injected process release failure")
		if this.Mode == "release_reentry"
			_GestureReleaseProcessTarget(this.CapturedTarget, this)
	}
	Ask(Text, Title) {
		this._Log("Ask", Text, Title)
		this.ApprovalLeaseCount := this.Leases.Length
		if this.Mode == "question_replacement"
			this.Retire()
		if this.Mode == "question_pause"
			Suspend(true)
		if this.Mode == "question_error"
			throw Error("injected process confirmation failure")
		return this.Mode == "cancel" ? "Cancel" : "OK"
	}
	Activate(Hwnd) {
		if this.Mode == "activation_refused"
			return false
		return super.Activate(Hwnd)
	}
	Defer(Fn, Delay := 1) {
		this.DeferCount += 1
		if this.Mode == "first_defer_error" || (this.Mode == "second_defer_error" && this.DeferCount == 2)
			throw Error("injected process scheduling failure")
		if this.Mode == "defer_reentry"
			return Fn.Call()
		return super.Defer(Fn, Delay)
	}
}

_SysActions_ProcessLeaseCase(Mode, Uwp := false) {
	global GESTURE_ACTIONS
	Fake := _SysActions_ProcessLeaseFake(Mode, Uwp)
	Saved := _SysActions_InstallOwnedForce(Fake)
	PriorPause := A_IsSuspended
	Entries := []
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		Suspend(false)
		if Mode == "extension"
			GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: () => Fake.ExtensionCalls += 1 }
		GestureInvokeAction("force_quit_frontmost", "keyboard__process_lease", Fake)
		if Mode == "pre_question_replacement"
			Fake.Retire()
		while Fake.Deferred.Length {
			if Fake.DeferCount == 2 {
				if Mode == "second_timer_replacement"
					Fake.Retire()
				if Mode == "second_timer_pause"
					Suspend(true)
			}
			Fake.Deferred.RemoveAt(1).Call()
		}
		for Effect in Fake.Effects
			AssertEqual("approved-A", Effect.Instance,
				"confirmation cannot authorize a replacement process that reused the approved PID")
		ExpectedEffects := Mode == "unchanged" || Mode == "defer_reentry" || Mode == "release_error" ? 1 : 0
		AssertEqual(ExpectedEffects, Fake.Effects.Length, "only the originally admitted process can receive the effect")
		ExpectedLeases := Mode == "acquire_error" ? 0 : 1
		AssertEqual(ExpectedLeases, Fake.Leases.Length, "acquire one process capability before the question")
		AssertEqual(ExpectedLeases, Fake.Releases, "every terminal path releases the retained process exactly once")
		for Lease in Fake.Leases
			AssertEqual(0, Lease.Handle, "released capabilities cannot be used by later callbacks")
		if Fake.HasOwnProp("ApprovalLeaseCount")
			AssertEqual(1, Fake.ApprovalLeaseCount, "the native capability is acquired before destructive approval")
		if Mode == "acquire_window_change" || Mode == "acquire_exit"
			AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length,
				"an acquisition that lost its original window or process never opens confirmation")
		if Mode == "extension"
			AssertEqual(1, Fake.ExtensionCalls, "a synchronous extension retains its exact zero-argument contract")
		if InStr(Mode, "error") {
			Diagnostics := 0
			for Entry in Entries
				if InStr(Entry, "injected process") || InStr(Entry, "injected retained")
					Diagnostics += 1
			AssertEqual(1, Diagnostics, "the native failure is contained and reported exactly once")
		}
	} finally {
		Suspend(PriorPause)
		LoggerClearTestSink()
		GESTURE_ACTIONS["force_quit_frontmost"] := Saved
	}
}
_SysActions_ProcessLeaseTest(Mode, Uwp) => () => _SysActions_ProcessLeaseCase(Mode, Uwp)
for _SysActions_ProcessLeaseMode in ["effect_replacement", "question_replacement", "pre_question_replacement",
	"second_timer_replacement", "unchanged", "cancel", "question_pause", "second_timer_pause",
	"question_error", "acquire_error", "acquire_exit", "acquire_window_change", "query_error", "first_defer_error",
	"second_defer_error", "activation_refused", "effect_error", "effect_refused", "release_error",
	"defer_reentry", "extension"] {
	Test("system actions: retained process " . _SysActions_ProcessLeaseMode . " (confirmed-process-lease)",
		_SysActions_ProcessLeaseTest(_SysActions_ProcessLeaseMode, false))
}
for _SysActions_ProcessLeaseMode in ["effect_replacement", "question_replacement", "second_timer_replacement", "unchanged"]
	Test("system actions: retained UWP process " . _SysActions_ProcessLeaseMode . " (confirmed-process-lease)",
		_SysActions_ProcessLeaseTest(_SysActions_ProcessLeaseMode, true))

_SysActions_BareConfirmedProcessRefuses() {
	Fake := _SysActions_ProcessLeaseFake("unchanged")
	Target := { Hwnd: 0x100, Pid: 7001, Class: "Notepad", TargetPid: 7001 }
	Fake.Snapshots[Target.Hwnd] := Target.Clone()
	Entries := []
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		GestureSysForceQuitFrontmost(Fake, Target)
		AssertEqual(0, Fake.Effects.Length, "a bare confirmed PID never authorizes a newly opened process")
		AssertEqual(0, Fake.Leases.Length, "incomplete approval cannot acquire replacement authority")
		Diagnostics := 0
		for Entry in Entries
			if InStr(Entry, "already-owned process lease")
				Diagnostics += 1
		AssertEqual(1, Diagnostics, "an incomplete confirmed receipt has an explicit ownership diagnostic")
	} finally LoggerClearTestSink()
}
Test("system actions: bare confirmed process refuses fresh authority (confirmed-process-lease)",
	_SysActions_BareConfirmedProcessRefuses)

_SysActions_ProcessReleaseReentry() {
	Fake := _SysActions_ProcessLeaseFake("release_reentry")
	Target := { Hwnd: 0x100, Pid: 7001, Class: "Notepad", TargetPid: 7001,
		ProcessLease: Fake.AcquireProcessTarget(7001) }
	Fake.CapturedTarget := Target
	_GestureReleaseProcessTarget(Target, Fake)
	_GestureReleaseProcessTarget(Target, Fake)
	AssertEqual(1, Fake.Releases, "reentrant cancellation claims the native cleanup debt only once")
}
Test("system actions: process release reentry is exactly once (confirmed-process-lease)",
	_SysActions_ProcessReleaseReentry)

_SysActions_InvalidApprovedLease(Released) {
	Fake := _SysActions_ProcessLeaseFake("unchanged")
	Lease := Fake.AcquireProcessTarget(Released ? 7001 : 9000)
	if Released
		Fake.ReleaseProcessTarget(Lease)
	Target := { Hwnd: 0x100, Pid: 7001, Class: "Notepad", TargetPid: 7001, ProcessLease: Lease }
	Fake.Snapshots[Target.Hwnd] := Target.Clone()
	try {
		GestureSysForceQuitFrontmost(Fake, Target)
		AssertEqual(0, Fake.Effects.Length, "a released or mismatched process capability cannot authorize an effect")
		AssertEqual(1, Fake.Leases.Length, "invalid approval cannot acquire a new capability")
	} finally {
		if Lease.Handle
			Fake.ReleaseProcessTarget(Lease)
	}
}
Test("system actions: invalid approved lease is already released (confirmed-process-lease)",
	() => _SysActions_InvalidApprovedLease(true))
Test("system actions: invalid approved lease belongs to another PID (confirmed-process-lease)",
	() => _SysActions_InvalidApprovedLease(false))

_SysActions_ResolvedGuard(TargetPid, Mode) {
	global GESTURE_ACTIONS
	Fake := _SysActions_ProcessLeaseFake("unchanged", true)
	Fake.ShellPidValue := 6000
	Fake.FramedApp := TargetPid
	Protected := TargetPid == Fake.OwnPidValue || TargetPid == Fake.ShellPidValue
	if Mode == "resolver" {
		Resolved := GestureSysForceQuitTarget(Fake.Active, Fake)
		AssertEqual(Protected, Resolved.Refusal != "", "the resolved app PID obeys the same self and shell refusal as its frame")
		AssertEqual(Protected ? 0 : TargetPid, Resolved.Pid, "a refused resolved process has no effect authority")
		return
	}
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		if Mode == "confirmed" {
			GestureInvokeAction("force_quit_frontmost", "keyboard__resolved_guard", Fake)
			while Fake.Deferred.Length
				Fake.Deferred.RemoveAt(1).Call()
			AssertEqual(Protected ? 0 : 1, _SysActions_CallsNamed(Fake, "Ask").Length,
				"a resolved protected process is refused before destructive confirmation")
		} else {
			GestureSysForceQuitFrontmost(Fake)
		}
		AssertEqual(Protected ? 0 : 1, Fake.Effects.Length, "neither confirmed nor direct execution can terminate a resolved self or shell PID")
		AssertEqual(Protected ? 0 : 1, Fake.Leases.Length, "a protected child process never acquires termination authority")
		AssertEqual(Fake.Leases.Length, Fake.Releases, "the accepted UWP capability still releases exactly once")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
_SysActions_ResolvedGuardTest(Pid, Mode) => () => _SysActions_ResolvedGuard(Pid, Mode)
for _SysActions_ResolvedGuardMode in ["resolver", "confirmed", "direct"] {
	for _SysActions_ResolvedGuardPid in [4000, 6000, 7001]
		Test("system actions: resolved process " . _SysActions_ResolvedGuardMode . " " . _SysActions_ResolvedGuardPid . " (resolved-process-guards)",
			_SysActions_ResolvedGuardTest(_SysActions_ResolvedGuardPid, _SysActions_ResolvedGuardMode))
}

class _SysActions_DirectForcePause extends _SysActions_ProcessLeaseFake {
	__New(At, Pauses) {
		super.__New("unchanged")
		this.At := At
		this.Pauses := Pauses
		this.TerminationAttempts := 0
	}
	PauseAt(Phase) {
		if this.Pauses && this.At == Phase
			Suspend(true)
	}
	ShellPid() {
		Pid := super.ShellPid()
		this.PauseAt("shell")
		return Pid
	}
	AcquireProcessTarget(Pid) {
		Lease := super.AcquireProcessTarget(Pid)
		this.PauseAt("acquire")
		return Lease
	}
	ProcessTargetIsLive(Lease) {
		Alive := super.ProcessTargetIsLive(Lease)
		this.PauseAt("alive")
		return Alive
	}
	TerminateProcessTarget(Lease) {
		this.TerminationAttempts += 1
		return super.TerminateProcessTarget(Lease)
	}
	ReleaseProcessTarget(Lease) {
		super.ReleaseProcessTarget(Lease)
		this.PauseAt("release")
	}
}
_SysActions_DirectForcePauseCase(At, Pauses) {
	Fake := _SysActions_DirectForcePause(At, Pauses)
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureMakeSystemRunner("force_quit_frontmost", GestureSysForceQuitFrontmost.Bind(Fake), Fake).Call()
		if Pauses && At == "entry"
			Suspend(true)
		Fake.Deferred.RemoveAt(1).Call()
		Expected := Pauses && At != "release" ? 0 : 1
		AssertEqual(Expected, Fake.TerminationAttempts, "a direct runner cannot enter termination after a native query suspended the driver")
		AssertEqual(Expected, Fake.Effects.Length, "only an unpaused effect admission can terminate its retained target")
		ExpectedLeases := Pauses && At == "entry" ? 0 : 1
		AssertEqual(ExpectedLeases, Fake.Leases.Length, "the original deferred admission still refuses pause before acquisition")
		AssertEqual(ExpectedLeases, Fake.Releases, "an acquired direct capability always releases, including during pause")
		for Lease in Fake.Leases
			AssertEqual(0, Lease.Handle, "cancelled direct work leaves no retained native resource")
	} finally Suspend(PriorPause)
}
_SysActions_DirectForcePauseTest(At, Pauses) => () => _SysActions_DirectForcePauseCase(At, Pauses)
for _SysActions_DirectForcePhase in ["shell", "acquire", "alive"] {
	Test("system actions: direct force pause after " . _SysActions_DirectForcePhase . " (direct-force-query-pause)",
		_SysActions_DirectForcePauseTest(_SysActions_DirectForcePhase, true))
	Test("system actions: direct force unchanged " . _SysActions_DirectForcePhase . " (direct-force-query-pause)",
		_SysActions_DirectForcePauseTest(_SysActions_DirectForcePhase, false))
}
Test("system actions: direct force pause before deferred entry (direct-force-query-pause)",
	_SysActions_DirectForcePauseTest("entry", true))
Test("system actions: direct force release completes during pause (direct-force-query-pause)",
	_SysActions_DirectForcePauseTest("release", true))

class _SysActions_DirectSelectionPath {
	__New(Sys, Value) {
		this.Sys := Sys
		this.Value := Value
	}
	Path {
		get {
			this.Sys.PauseAt("path")
			return this.Value
		}
	}
}
class _SysActions_DirectSelectionDoc {
	__New(Sys) => this.Sys := Sys
	SelectedItems() {
		this.Sys.PauseAt("selection")
		return this.Sys.EmptySelection ? [] : [_SysActions_DirectSelectionPath(this.Sys, "C:\owned\a"), _SysActions_DirectSelectionPath(this.Sys, "C:\owned\b")]
	}
}
class _SysActions_DirectQueryFake extends _SysActionsFake {
	__New(Action, At, Pauses, EmptySelection := false) {
		super.__New()
		this.At := At
		this.Pauses := Pauses
		this.EmptySelection := EmptySelection
		this.Active := { Hwnd: 0x100, Pid: 812, Class: Action == "quit_frontmost_app" ? "Notepad" : "CabinetWClass" }
		this.Windows := [0x100, 0x101]
		if Action == "quit_frontmost_app" && At == "shell"
			this.ShellPidValue := 812
	}
	PauseAt(Phase) {
		if this.Pauses && this.At == Phase
			Suspend(true)
	}
	ActiveWindow() {
		Current := super.ActiveWindow()
		this.PauseAt("active")
		return Current
	}
	ShellApplication() {
		this.PauseAt("shell")
		return { Windows: (*) => [{ HWND: this.Active.Hwnd, Document: _SysActions_DirectSelectionDoc(this) }] }
	}
	IsDirectory(Path) {
		this.PauseAt("directory")
		return this.At == "files"
	}
	FilesUnder(Path) {
		this.PauseAt("files")
		return [Path . "\one", Path . "\two"]
	}
	DeleteZoneIdentifier(Path) {
		Result := super.DeleteZoneIdentifier(Path)
		this.PauseAt("deleted")
		return Result
	}
	ShellPid() {
		Pid := super.ShellPid()
		this.PauseAt("shell")
		return Pid
	}
	WindowsOfProcess(Pid) {
		Windows := super.WindowsOfProcess(Pid)
		this.PauseAt("windows")
		return Windows
	}
	PostClose(Hwnd) {
		Result := super.PostClose(Hwnd)
		this.PauseAt("closed")
		return Result
	}
}
_SysActions_DirectQueryCase(Action, At, Pauses, EmptySelection := false) {
	Fake := _SysActions_DirectQueryFake(Action, At, Pauses, EmptySelection)
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		Fn := Action == "quit_frontmost_app" ? GestureSysQuitFrontmostApp : GestureSysUnblockFileSelection
		_GestureMakeSystemRunner(Action, Fn.Bind(Fake), Fake).Call()
		Fake.Deferred.RemoveAt(1).Call()
		Effect := Action == "quit_frontmost_app" ? "PostClose" : "DeleteZoneIdentifier"
		Expected := EmptySelection ? 0 : (Pauses ? (At == "deleted" || At == "closed" ? 1 : 0) : (At == "shell" && Action == "quit_frontmost_app" ? 1 : (At == "files" ? 4 : 2)))
		AssertEqual(Expected, _SysActions_CallsNamed(Fake, Effect).Length,
			"every direct query boundary admits the next effect only while unpaused; committed earlier effects stay owned")
		AssertEqual(EmptySelection && !Pauses ? 1 : 0, _SysActions_CallsNamed(Fake, "Notify").Length,
			"a paused empty selection cannot publish a deferred notice")
	} finally Suspend(PriorPause)
}
_SysActions_DirectQueryTest(Action, At, Pauses, EmptySelection := false) => () => _SysActions_DirectQueryCase(Action, At, Pauses, EmptySelection)
for _SysActions_DirectSelectionPhase in ["active", "shell", "selection", "path", "directory", "files", "deleted"] {
	for _SysActions_DirectSelectionPauses in [true, false]
		Test("system actions: direct selection " . _SysActions_DirectSelectionPhase . " pause=" . _SysActions_DirectSelectionPauses . " (direct-selection-query-pause)",
			_SysActions_DirectQueryTest("unblock_file_selection", _SysActions_DirectSelectionPhase, _SysActions_DirectSelectionPauses))
}
for _SysActions_DirectSelectionPauses in [true, false]
	Test("system actions: direct empty selection pause=" . _SysActions_DirectSelectionPauses . " (direct-selection-query-pause)",
		_SysActions_DirectQueryTest("unblock_file_selection", "selection", _SysActions_DirectSelectionPauses, true))
for _SysActions_DirectQuitPhase in ["shell", "windows", "closed"] {
	for _SysActions_DirectQuitPauses in [true, false]
		Test("system actions: direct quit " . _SysActions_DirectQuitPhase . " pause=" . _SysActions_DirectQuitPauses . " (direct-quit-query-pause)",
			_SysActions_DirectQueryTest("quit_frontmost_app", _SysActions_DirectQuitPhase, _SysActions_DirectQuitPauses))
}

; A native DWORD must never truncate a supplied process target identifier.
; These probes only acquire, query and release this test process; they never terminate.
_SysActions_ProcessPidDomain(Pid, Valid := false) {
	Adapter := SystemControl()
	Lease := ""
	RejectedType := false
	try {
		try Lease := Adapter.AcquireProcessTarget(Pid)
		catch TypeError
			RejectedType := true
		catch OSError {
			; Native refusal is not the required input-domain refusal.
		}
		if !Valid {
			ObservedPid := IsObject(Lease) ? DllCall("Kernel32\GetProcessId", "Ptr", Lease.Handle, "UInt") : 0
			AssertTrue(RejectedType, "an invalid PID must be rejected before DWORD truncation or native access; requested="
				. Pid . " retained=" . ObservedPid)
			return
		}
		AssertTrue(IsObject(Lease), "a valid owned PID yields a retained native handle")
		if !IsObject(Lease)
			return
		AssertEqual(DllCall("Kernel32\GetProcessId", "Ptr", Lease.Handle, "UInt"), Pid,
			"the native process identity equals the admitted PID")
		AssertTrue(Adapter.ProcessTargetIsLive(Lease), "the owned test process is still live")
	} finally {
		if IsObject(Lease) {
			Adapter.ReleaseProcessTarget(Lease)
			Adapter.ReleaseProcessTarget(Lease)
			AssertEqual(Lease.Handle, 0, "the owned handle release debt is consumed exactly once")
		}
	}
}

for _SysActions_InvalidProcessPid in [0, -1, 1.5, "1", 0x100000000, DllCall("Kernel32\GetCurrentProcessId", "UInt") + 0x100000000]
	Test("system control: invalid process PID " . _SysActions_InvalidProcessPid . " (process-pid-domain)",
		_SysActions_ProcessPidDomain.Bind(_SysActions_InvalidProcessPid))
Test("system control: owned process PID is retained without termination (process-pid-domain)",
	_SysActions_ProcessPidDomain.Bind(DllCall("Kernel32\GetCurrentProcessId", "UInt"), true))
