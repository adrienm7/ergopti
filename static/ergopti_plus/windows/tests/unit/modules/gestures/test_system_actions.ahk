; tests/unit/modules/gestures/test_system_actions.ahk

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
		this.ExistingAppPaths := Map()
		this.Terminal := ""
		this.CreateStatuses := []
		this.Pointer := { X: 0, Y: 0 }
		this.MonitorList := []
		this.ClipboardWritable := true
		this.RefusedCloses := Map()
	}
	_Log(Name, Args*) {
		Entry := [Name]
		Entry.Push(Args*)
		this.Calls.Push(Entry)
		return true
	}
	Launch(Target, WorkingDir := "", Options := "") => (this._Log("Launch", Target, WorkingDir, Options), 1)
	PostBroadcast(Msg, WParam, LParam) => this._Log("PostBroadcast", Msg, WParam, LParam)
	PostClose(Hwnd) => (this._Log("PostClose", Hwnd), !this.RefusedCloses.Has(Hwnd))
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
	IsExistingFile(Path) => this.ExistingAppPaths.Has(Path)
	FilesUnder(Dir) => this.Directories[Dir]
	EnumerateUnblockFiles(Dir) => { Files: this.FilesUnder(Dir), Failed: 0 }
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

; SystemControl.PostClose returns the Win32 receipt instead of throwing, so a
; WM_CLOSE refused for every window (an elevated application, a window gone
; meanwhile) was summed into a zero count and logged as INFO: the errors-only
; diagnostic channel never saw the failed quit (WDS-001).
_SysActions_QuitRefusedCloses(Case) {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	switch Case {
	case "all-refused":
		Fake.Windows := [0x100, 0x200]
		Fake.RefusedCloses := Map(0x100, true, 0x200, true)
		Expected := "[ERROR]"
	case "partial":
		Fake.Windows := [0x100, 0x200]
		Fake.RefusedCloses := Map(0x200, true)
		Expected := "[WARNING]"
	case "no-window":
		Fake.Windows := []
		Expected := "[WARNING]"
	case "all-accepted":
		Fake.Windows := [0x100, 0x200]
		Expected := ""
	default:
		throw ValueError("Unknown quit receipt case: " . Case)
	}
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try GestureSysQuitFrontmostApp(Fake)
	finally LoggerClearTestSink()
	AssertEqual(Fake.Windows.Length, _SysActions_CallsNamed(Fake, "PostClose").Length,
		"every window of the process is still asked, whatever an earlier receipt said")
	Reported := false
	for Line in Lines {
		if !(InStr(Line, "quit_frontmost_app") || InStr(Line, "process 812"))
			continue
		if Expected == "" {
			; INFO repeats may be collapsed, so the control asserts the absence of
			; a failure diagnostic instead of the presence of the progress line.
			AssertFalse(InStr(Line, "[ERROR]") || InStr(Line, "[WARNING]"),
				"accepted closes raise no failure diagnostic: " . Line)
			continue
		}
		if InStr(Line, Expected)
			Reported := true
		AssertFalse(InStr(Line, "close its"), "a refused close is not reported as an ordinary request")
	}
	if Expected != ""
		AssertTrue(Reported, "the quit outcome is logged at " . Expected . " for " . Case)
}
for _SysActionsQuitCase in ["all-refused", "partial", "no-window", "all-accepted"]
	Test("system actions: quit_frontmost_app reports refused close receipts: " . _SysActionsQuitCase . " (wds-001)",
		_SysActions_QuitRefusedCloses.Bind(_SysActionsQuitCase))

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
		GestureActionParameters := Map(GestureActionParameterKey("keyboard__primary_k", "open_app"), Target)
		Fake := _SysActionsFake()
		GestureSysOpenApp("keyboard__primary_k", Fake)
		Launches := _SysActions_CallsNamed(Fake, "Launch")
		AssertEqual(1, Launches.Length)
		AssertEqual(Target, Launches[1][2], "the binding's own application, as the shell runs it")
		for FilePath in ["C:\Program Files\Demo\demo.exe", "C:\Start Menu\Demo.lnk"] {
			GestureActionParameters := Map(GestureActionParameterKey("keyboard__primary_k", "open_app"), FilePath)
			Fake := _SysActionsFake(), Fake.ExistingAppPaths[FilePath] := true
			GestureSysOpenApp("keyboard__primary_k", Fake)
			AssertEqual('"' . FilePath . '"', _SysActions_CallsNamed(Fake, "Launch")[1][2],
				"an existing whole file is passed as one argument")
		}
		Folder := "C:\Folder With Spaces"
		GestureActionParameters := Map(GestureActionParameterKey("keyboard__primary_k", "open_app"), Folder)
		Fake := _SysActionsFake(), Fake.Directories[Folder] := true
		GestureSysOpenApp("keyboard__primary_k", Fake)
		AssertEqual('"' . Folder . '"', _SysActions_CallsNamed(Fake, "Launch")[1][2],
			"an existing whole directory is passed as one shell target")
		Command := '"C:\Program Files\Demo\demo.exe" --option'
		GestureActionParameters := Map(GestureActionParameterKey("keyboard__primary_k", "open_app"), Command)
		Fake := _SysActionsFake()
		GestureSysOpenApp("keyboard__primary_k", Fake)
		AssertEqual(Command, _SysActions_CallsNamed(Fake, "Launch")[1][2], "a command line stays intact")
		Fake := _SysActionsFake()
		GestureSysOpenApp("tap_3", Fake)
		AssertEqual(0, Fake.Calls.Length, "a binding with no application opens nothing")
	} finally {
		GestureActionParameters := Saved
	}
}
Test("system actions: open_app launches the application stored for its binding", _SysActions_OpenApp)

#Include test_microphone_endpoint_owner.ahk

; File creation uses the real native adapter. Explorer documents are explicit
; port doubles so a navigation during that external call is deterministic.
class _SNFO_Folder {
	__New(Path) {
		this.Self := {Path: Path}
	}
	ParseName(Name) {
		Path := this.Self.Path . "\" . Name
		return FileExist(Path) ? {Path: Path} : 0
	}
}

class _SNFO_Document {
	__New(Path, Selected) {
		this.Folder := _SNFO_Folder(Path)
		this.Selected := Selected
	}
	SelectItem(Item, Flags) {
		this.Selected.Push({Path: Item.Path, Flags: Flags})
	}
}

class _SNFO_System extends _SysActionsFake {
	CreateNewFile(Path) {
		Status := SystemControl().CreateNewFile(Path)
		this.CreatedPath := Path
		if this.Navigate
			this.Explorer.Document := this.NextDocument
		return Status
	}
}

_SNFO_Run(Navigate) {
	Root := A_Temp . "\ergopti_new_file_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, PreviousSuspended := A_IsSuspended
	try {
		if A_IsSuspended
			Suspend(false)
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created)
		Original := Root . "\original", Changed := Root . "\navigated"
		DirCreate(Original)
		DirCreate(Changed)
		Base := t("system_actions.new_text_file_name") . ".txt"
		Foreign := Changed . "\" . Base
		AssertTrue(FSWriteCreateDurable(Foreign, "unrelated file in the newly navigated folder"))
		Selected := []
		InitialDocument := _SNFO_Document(Original, Selected)
		NextDocument := _SNFO_Document(Changed, Selected)
		Explorer := {HWND: 0x42, Document: InitialDocument}
		Sys := _SNFO_System()
		Sys.Active := {Hwnd: 0x42, Pid: 7, Class: "CabinetWClass"}
		Sys.Shell := {Windows: (this) => [Explorer]}
		Sys.Navigate := Navigate
		Sys.Explorer := Explorer
		Sys.NextDocument := NextDocument
		Sys.CreatedPath := ""
		GestureSysNewTextFileHere(Sys)
		AssertEqual(Original . "\" . Base, Sys.CreatedPath)
		AssertTrue(FileExist(Sys.CreatedPath) != "", "the actual native adapter must create the requested original-folder file")
		AssertEqual("", FileRead(Sys.CreatedPath, "UTF-8"))
		AssertEqual("unrelated file in the newly navigated folder", FileRead(Foreign, "UTF-8"))
		_TestPrint("# new-file-document-owner navigation=" . Navigate . " selections=" . Selected.Length
			. " selected_created_file=" . (Selected.Length ? StrCompare(Selected[1].Path, Sys.CreatedPath, true) == 0 : false))
		if Navigate
			AssertEqual(0, Selected.Length, "navigation cannot start renaming a same-named unrelated file in the replacement folder")
		else {
			AssertEqual(1, Selected.Length, "an unchanged original document must still prepare the created file's rename")
			AssertEqual(Sys.CreatedPath, Selected[1].Path)
			AssertEqual(GESTURE_SYS_SVSI_RENAME, Selected[1].Flags)
		}
	} finally {
		if Created
			DirDelete(Root, true)
		if A_IsSuspended != PreviousSuspended
			Suspend(PreviousSuspended)
	}
}

for _SNFO_Navigation in [false, true]
	Test("new text file rename owns its original Explorer folder: navigation=" . _SNFO_Navigation . " (new-file-document-owner)",
		_SNFO_Run.Bind(_SNFO_Navigation))


; A selected directory must not lend authority to an external junction target.
class _SAJ_NativeControl extends _SysActionsFake {
	__New(Selected) {
		super.__New()
		this.Native := SystemControl()
		this.Active := { Hwnd: 0x42, Pid: 7, Class: "CabinetWClass" }
		this.Shell := _SysActions_Shell(0x42, Selected, [Selected])
	}
	IsDirectory(Path) => this.Native.IsDirectory(Path)
	FilesUnder(Path) => this.Native.FilesUnder(Path)
	EnumerateUnblockFiles(Path) => this.Native.EnumerateUnblockFiles(Path)
	DeleteZoneIdentifier(Path) => this.Native.DeleteZoneIdentifier(Path)
}
_SAJ_RunIsolated(Control) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, _LOGGER_VOLUME
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED", "_LOGGER_VOLUME"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := { Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0 }
	try {
		AssertFalse(SavedLogger.FlushActive, "no foreign logger flush may be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_VOLUME := _LOGGER_VOLUME.Clone()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_INFO_ENABLED := true, _LOGGER_ERROR_ENABLED := true
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Lines := []
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Critical("Off")
		GestureSysUnblockFileSelection(Control)
		return Lines
	} finally {
		Critical("On")
		_TLOG_RestoreLoggerState(SavedLogger)
		for Name, Value in SavedExtra
			%Name% := Value
		for Name, Saved in SavedOptional
			%Name% := Saved.Present ? Saved.Value : unset
		Critical(PreviousCritical)
	}
}
_SAJ_StreamExists(Path) {
	try Stream := FileOpen(Path . ":Zone.Identifier", "r")
	catch as Err {
		if Err is OSError && Err.Number == 2
			return false
		throw Err
	}
	Stream.Close()
	return true
}
_SAJ_JunctionDoesNotUnblockOutside() {
	Root := A_Temp . "\ergopti-action-junction-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	if !(Created is Integer) || Created != 1
		throw Error("Exclusive fixture ownership was not confirmed.")
	Link := Root . "\selected\outside-link"
	try {
		DirCreate(Root . "\selected\nested")
		DirCreate(Root . "\outside")
		Inside := Root . "\selected\nested\inside.txt", Outside := Root . "\outside\outside.txt"
		FileAppend("inside", Inside), FileAppend("outside", Outside)
		FileAppend("[ZoneTransfer]`r`nZoneId=3`r`n", Inside . ":Zone.Identifier")
		FileAppend("[ZoneTransfer]`r`nZoneId=3`r`n", Outside . ":Zone.Identifier")
		AssertTrue(_SAJ_StreamExists(Inside) && _SAJ_StreamExists(Outside), "NTFS fixture streams exist before action")
		ExitCode := RunWait('"' . A_ComSpec . '" /D /C mklink /J "' . Link . '" "' . Root . '\outside"', , "Hide")
		AssertEqual(0, ExitCode, "native junction creation succeeded")
		AssertTrue(InStr(FileExist(Link), "L") > 0, "selected child is a reparse point")
		AssertEqual("outside", FileRead(Link . "\outside.txt"), "junction reaches the owned external sibling")
		_SAJ_RunIsolated(_SAJ_NativeControl(Root . "\selected"))
		InsideAfter := _SAJ_StreamExists(Inside), OutsideAfter := _SAJ_StreamExists(Outside)
		_TestAppendProgress("# unblock junction inside_stream=" . InsideAfter . " outside_stream=" . OutsideAfter)
		AssertFalse(InsideAfter, "ordinary nested selected file is unblocked")
		AssertTrue(OutsideAfter, "external target retains its Zone.Identifier")
	} finally {
		; Never recursively clean the root until the exact owned junction is detached.
		if DirExist(Link)
			DirDelete(Link)
		DirDelete(Root, true)
	}
}
Test("system actions: selected directory does not unblock external junction target (unblock-native-junction)", _SAJ_JunctionDoesNotUnblockOutside)


; The real Explorer-selection action must report an inaccessible subtree.
class _SAA_NativeControl extends _SysActionsFake {
	__New(Selected) {
		super.__New()
		this.Native := SystemControl()
		this.Active := { Hwnd: 0x42, Pid: 7, Class: "CabinetWClass" }
		this.Shell := _SysActions_Shell(0x42, Selected, [Selected])
	}
	IsDirectory(Path) => this.Native.IsDirectory(Path)
	FilesUnder(Path) => this.Native.FilesUnder(Path)
	EnumerateUnblockFiles(Path) => this.Native.EnumerateUnblockFiles(Path)
	DeleteZoneIdentifier(Path) => this.Native.DeleteZoneIdentifier(Path)
}
_SAA_RunIsolated(Control) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, _LOGGER_VOLUME
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED", "_LOGGER_VOLUME"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := { Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0 }
	try {
		AssertFalse(SavedLogger.FlushActive, "no foreign logger flush may be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_VOLUME := _LOGGER_VOLUME.Clone()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_INFO_ENABLED := true, _LOGGER_ERROR_ENABLED := true
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Lines := []
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Critical("Off")
		GestureSysUnblockFileSelection(Control)
		return Lines
	} finally {
		Critical("On")
		_TLOG_RestoreLoggerState(SavedLogger)
		for Name, Value in SavedExtra
			%Name% := Value
		for Name, Saved in SavedOptional
			%Name% := Saved.Present ? Saved.Value : unset
		Critical(PreviousCritical)
	}
}
_SAA_StreamExists(Path) {
	try Stream := FileOpen(Path . ":Zone.Identifier", "r")
	catch as Err {
		if Err is OSError && Err.Number == 2
			return false
		throw Err
	}
	Stream.Close()
	return true
}
_SAA_InaccessibleSubtreeReported() {
	Root := A_Temp . "\ergopti-action-acl-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	if !(Created is Integer) || Created != 1
		throw Error("Exclusive fixture ownership was not confirmed.")
	Handle := 0, Descriptor := 0, OriginalDacl := 0, RestoreFlags := 0, Changed := false
	try {
		Selected := Root . "\selected", Blocked := Selected . "\blocked"
		DirCreate(Blocked), DirCreate(Selected . "\accessible")
		BlockedFile := Blocked . "\blocked.txt", OpenFile := Selected . "\accessible\open.txt"
		FileAppend("blocked", BlockedFile), FileAppend("open", OpenFile)
		FileAppend("[ZoneTransfer]`r`nZoneId=3`r`n", BlockedFile . ":Zone.Identifier")
		FileAppend("[ZoneTransfer]`r`nZoneId=3`r`n", OpenFile . ":Zone.Identifier")
		AssertTrue(_SAA_StreamExists(BlockedFile) && _SAA_StreamExists(OpenFile), "both streams exist before the action")
		; Retain WRITE_DAC and READ_CONTROL on the exact directory before denying access.
		Handle := DllCall("Kernel32\CreateFileW", "Str", Blocked, "UInt", 0x60000, "UInt", 7,
			"Ptr", 0, "UInt", 3, "UInt", 0x02000000, "Ptr", 0, "Ptr")
		if Handle == -1
			throw OSError(A_LastError, -1, "open owned ACL directory")
		Status := DllCall("Advapi32\GetSecurityInfo", "Ptr", Handle, "UInt", 1, "UInt", 4,
			"Ptr", 0, "Ptr", 0, "Ptr*", &OriginalDacl, "Ptr", 0, "Ptr*", &Descriptor, "UInt")
		if Status
			throw OSError(Status, -1, "get original DACL")
		Control := 0, Revision := 0
		if !DllCall("Advapi32\GetSecurityDescriptorControl", "Ptr", Descriptor, "UShort*", &Control, "UInt*", &Revision)
			throw OSError(A_LastError, -1, "get original DACL control")
		RestoreFlags := 4 | ((Control & 0x1000) ? 0x80000000 : 0x20000000)
		Sid := Buffer(68, 0), SidSize := Sid.Size, Acl := Buffer(128, 0)
		if !DllCall("Advapi32\CreateWellKnownSid", "Int", 1, "Ptr", 0, "Ptr", Sid, "UInt*", &SidSize)
			throw OSError(A_LastError, -1, "create world SID")
		if !DllCall("Advapi32\InitializeAcl", "Ptr", Acl, "UInt", Acl.Size, "UInt", 2)
			throw OSError(A_LastError, -1, "initialize deny ACL")
		if !DllCall("Advapi32\AddAccessDeniedAceEx", "Ptr", Acl, "UInt", 2, "UInt", 0, "UInt", 1, "Ptr", Sid)
			throw OSError(A_LastError, -1, "add list-directory deny")
		Changed := true ; restore even if the native setter reports an error after touching metadata
		Status := DllCall("Advapi32\SetSecurityInfo", "Ptr", Handle, "UInt", 1, "UInt", 0x80000004,
			"Ptr", 0, "Ptr", 0, "Ptr", Acl, "Ptr", 0, "UInt")
		if Status
			throw OSError(Status, -1, "apply private deny ACL")
		FindData := Buffer(592, 0)
		Find := DllCall("Kernel32\FindFirstFileW", "Str", Blocked . "\*", "Ptr", FindData, "Ptr")
		FindError := A_LastError
		if Find != -1
			DllCall("Kernel32\FindClose", "Ptr", Find)
		AssertEqual(-1, Find, "real blocked enumeration is refused")
		AssertEqual(5, FindError, "refusal is ERROR_ACCESS_DENIED")
		Lines := _SAA_RunIsolated(_SAA_NativeControl(Selected))
		OpenAfter := _SAA_StreamExists(OpenFile)
		Status := DllCall("Advapi32\SetSecurityInfo", "Ptr", Handle, "UInt", 1, "UInt", RestoreFlags,
			"Ptr", 0, "Ptr", 0, "Ptr", OriginalDacl, "Ptr", 0, "UInt")
		if Status
			throw OSError(Status, -1, "restore original DACL")
		Changed := false
		BlockedAfter := _SAA_StreamExists(BlockedFile), Reported := false, Success := false
		for Line in Lines {
			if InStr(Line, "[ERROR]") && InStr(Line, "unblock_file_selection")
				Reported := true
			if InStr(Line, "[INFO]") && InStr(Line, "unblock_file_selection:")
				Success := true
		}
		_TestAppendProgress("# unblock acl error=" . FindError . " open_stream=" . OpenAfter
			. " blocked_stream=" . BlockedAfter . " error_log=" . Reported . " success_log=" . Success)
		AssertFalse(OpenAfter, "accessible nested file is unblocked")
		AssertTrue(BlockedAfter, "the inaccessible file remains blocked")
		AssertTrue(Reported, "incomplete enumeration must be reported")
		AssertFalse(Success, "partial enumeration cannot be reported as complete")
	} finally {
		if Changed {
			Status := DllCall("Advapi32\SetSecurityInfo", "Ptr", Handle, "UInt", 1, "UInt", RestoreFlags,
				"Ptr", 0, "Ptr", 0, "Ptr", OriginalDacl, "Ptr", 0, "UInt")
			if Status
				throw OSError(Status, -1, "restore original DACL; private fixture retained")
			Changed := false
		}
		if Descriptor
			DllCall("Kernel32\LocalFree", "Ptr", Descriptor, "Ptr")
		if Handle && Handle != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Handle)
		DirDelete(Root, true)
	}
}
Test("system actions: inaccessible selected subtree is reported (unblock-native-acl)", _SAA_InaccessibleSubtreeReported)

_SAA_EnumerationBoundsReported() {
	Root := A_Temp . "\ergopti-unblock-limits-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	if !(Created is Integer) || Created != 1
		throw Error("Exclusive fixture ownership was not confirmed.")
	try {
		FileAppend("one", Root . "\one.txt"), FileAppend("two", Root . "\two.txt")
		Native := SystemControl()
		ByCount := Native.EnumerateUnblockFiles(Root, 1)
		AssertEqual(1, ByCount.Files.Length, "one native entry is retained within the count bound")
		AssertEqual(1, ByCount.Failed, "entry bound reports incomplete traversal")
		ByUnits := Native.EnumerateUnblockFiles(Root, 100, StrLen(Root))
		AssertEqual(0, ByUnits.Files.Length, "path budget refuses the first entry")
		AssertEqual(1, ByUnits.Failed, "path bound reports incomplete traversal")
	} finally DirDelete(Root, true)
}
Test("system actions: native unblock enumeration reports both resource bounds (unblock-native-limits)", _SAA_EnumerationBoundsReported)

global _OAP_RetirementDebt := 0

; The chooser stores one path; an unquoted path with spaces must not launch an
; executable whose name is an earlier prefix of that path.
class _OAP_NativeControl extends _SysActionsFake {
	__New() {
		super.__New()
		this.Native := SystemControl(), this.ProcessHandle := 0, this.UnownedPid := 0, this.Admitted := false
	}
	IsDirectory(Path) => this.Native.IsDirectory(Path)
	IsExistingFile(Path) => this.Native.IsExistingFile(Path)
	Launch(Target, WorkingDir := "", Options := "") {
		Pid := this.Native.Launch(Target, WorkingDir, "Hide")
		if !(Pid is Integer) || Pid <= 0
			throw Error("The owned witness did not return a process id.")
		this.UnownedPid := Pid
		this.ProcessHandle := DllCall("Kernel32\OpenProcess", "UInt", 0x101000, "Int", false, "UInt", Pid, "Ptr")
		if !this.ProcessHandle
			throw OSError(A_LastError, -1, "open owned witness process")
		this.UnownedPid := 0
		return Pid
	}
}
_OAP_RunAction(Control, Target) {
	global GestureActionParameters
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, _LOGGER_VOLUME
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	SavedParameters := GestureActionParameters
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED", "_LOGGER_VOLUME"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := { Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0 }
	try {
		AssertFalse(SavedLogger.FlushActive, "no foreign logger flush may be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_VOLUME := _LOGGER_VOLUME.Clone()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		GestureActionParameters := Map(GestureActionParameterKey("tap_3", "open_app"), Target)
		Critical("Off")
		GestureSysOpenApp("tap_3", Control)
	} finally {
		Critical("On")
		GestureActionParameters := SavedParameters
		_TLOG_RestoreLoggerState(SavedLogger)
		for Name, Value in SavedExtra
			%Name% := Value
		for Name, Saved in SavedOptional
			%Name% := Saved.Present ? Saved.Value : unset
		Critical(PreviousCritical)
	}
}
_OAP_AwaitReceipt(Path, Control, Prefix, Target) {
	AssertTrue(Control.ProcessHandle != 0, "the exact launched process is retained")
	Start := A_TickCount, Observed := ""
	while TickElapsed64(Start, A_TickCount) < 5000 {
		try Observed := FileRead(Path, "UTF-8")
		if Observed != ""
			break
		Sleep(20)
	}
	Parts := StrSplit(Observed, "|")
	if Parts.Length != 3 || !RegExMatch(Parts[1], "^[0-9]+$") || !RegExMatch(Parts[2], "^[0-9]+$")
		throw Error("The retained witness did not publish a complete identity receipt.")
	Pid := DllCall("Kernel32\GetProcessId", "Ptr", Control.ProcessHandle, "UInt")
	if !Pid
		throw OSError(A_LastError, -1, "get witness process id")
	Created := Buffer(8, 0), Exited := Buffer(8, 0), Kernel := Buffer(8, 0), User := Buffer(8, 0)
	if !DllCall("Kernel32\GetProcessTimes", "Ptr", Control.ProcessHandle, "Ptr", Created,
		"Ptr", Exited, "Ptr", Kernel, "Ptr", User, "Int")
		throw OSError(A_LastError, -1, "get witness process creation time")
	Image := Buffer(65536, 0), ImageLength := 32768
	if !DllCall("Kernel32\QueryFullProcessImageNameW", "Ptr", Control.ProcessHandle, "UInt", 0,
		"Ptr", Image, "UInt*", &ImageLength, "Int")
		throw OSError(A_LastError, -1, "get witness process image")
	ActualImage := StrGet(Image, ImageLength, "UTF-16")
	if Pid != Integer(Parts[1]) || NumGet(Created, 0, "Int64") != Integer(Parts[2])
		throw Error("Receipt does not belong to the retained process object.")
	if StrLower(ActualImage) != StrLower(Parts[3])
		throw Error("Receipt image does not match the retained process object.")
	if StrLower(ActualImage) != StrLower(Prefix) && StrLower(ActualImage) != StrLower(Target)
		throw Error("Retained process is not an owned witness image.")
	Control.Admitted := true
	return ActualImage
}
_OAP_Join(Control, EventHandle) {
	if Control.UnownedPid
		throw Error("An unowned witness process prevents private fixture cleanup.")
	if !Control.ProcessHandle
		return
	if !Control.Admitted
		throw Error("Unverified retained process prevents fixture cleanup.")
	if !DllCall("Kernel32\SetEvent", "Ptr", EventHandle, "Int")
		throw OSError(A_LastError, -1, "release owned witness")
	Status := DllCall("Kernel32\WaitForSingleObject", "Ptr", Control.ProcessHandle, "UInt", 10000, "UInt")
	if Status != 0
		throw Error("The exact witness process did not retire; private fixture retained.")
	ExitCode := 0
	if !DllCall("Kernel32\GetExitCodeProcess", "Ptr", Control.ProcessHandle, "UInt*", &ExitCode, "Int")
		throw OSError(A_LastError, -1, "read witness exit code")
	if !DllCall("Kernel32\CloseHandle", "Ptr", Control.ProcessHandle, "Int")
		throw OSError(A_LastError, -1, "close witness process")
	Control.ProcessHandle := 0, Control.Admitted := false
	if ExitCode != 0
		throw Error("The native witness reported failure: " . ExitCode)
}
; Explicit retry only; never adopt a numeric PID or release an unverified process.
_OAP_RetireDebt() {
	global _OAP_RetirementDebt
	if !IsObject(_OAP_RetirementDebt)
		return true
	Debt := _OAP_RetirementDebt
	try {
		_OAP_Join(Debt.Control, Debt.EventHandle)
		if Debt.EventHandle {
			if !DllCall("Kernel32\CloseHandle", "Ptr", Debt.EventHandle, "Int")
				return false
			Debt.EventHandle := 0
		}
		DirDelete(Debt.Root, true)
		_OAP_RetirementDebt := 0
		return true
	} catch {
		return false
	}
}
_OAP_ChosenPathDoesNotLaunchPrefix() {
	global _OAP_RetirementDebt
	if IsObject(_OAP_RetirementDebt)
		throw Error("A prior witness retirement debt blocks this probe.")
	Root := A_Temp . "\ergopti-openapp-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
	; No earlier whitespace component can resolve to a foreign executable.
	if RegExMatch(Root, "[\s]")
		throw Error("This native fixture requires a temporary path without whitespace.")
	Created := FSCreateDirectoryExclusiveStrict(Root)
	if !(Created is Integer) || Created != 1
		throw Error("Exclusive fixture ownership was not confirmed.")
	EventHandle := 0, Control := _OAP_NativeControl()
	try {
		Name := "Local\ErgoptiOpenAppWitness-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
		EventHandle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true, "Int", false, "Str", Name, "Ptr")
		EventError := A_LastError
		if !EventHandle || EventError == 183
			throw Error("Exclusive witness event was not acquired.")
		Compiler := A_WinDir . "\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
		AssertTrue(FileExist(Compiler) != "", "the native C# compiler is available")
		Folder := Root . "\witness.exe folder", Prefix := Root . "\witness.exe"
		DirCreate(Folder)
		Target := Folder . "\target.exe", Source := Root . "\witness.cs", Receipt := Root . "\receipt.txt"
		Code := 'using System; using System.IO; using System.Diagnostics; using System.Threading; '
			. 'class Witness { static int Main() { try { var p = Process.GetCurrentProcess(); '
			. 'File.WriteAllText(@"' . Receipt . '.pending", p.Id.ToString() + "|" + '
			. 'p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() + "|" + p.MainModule.FileName); '
			. 'File.Move(@"' . Receipt . '.pending", @"' . Receipt . '"); '
			. 'using (var e = EventWaitHandle.OpenExisting(@"' . Name
			. '")) { return e.WaitOne(30000) ? 0 : 3; } } catch { return 4; } } }'
		FileAppend(Code, Source, "UTF-8")
		CompileCode := RunWait('"' . Compiler . '" /nologo /target:exe /out:"' . Prefix . '" "' . Source . '"', , "Hide")
		AssertEqual(0, CompileCode, "native inert witness compiled successfully")
		FileCopy(Prefix, Target)
		Control.Launch('"' . Target . '"')
		ControlReceipt := _OAP_AwaitReceipt(Receipt, Control, Prefix, Target)
		_OAP_Join(Control, EventHandle)
		AssertEqual(Target, ControlReceipt, "quoted control launches the selected executable")
		FileDelete(Receipt)
		if !DllCall("Kernel32\ResetEvent", "Ptr", EventHandle, "Int")
			throw OSError(A_LastError, -1, "reset witness event")
		_OAP_RunAction(Control, Target)
		ActualReceipt := _OAP_AwaitReceipt(Receipt, Control, Prefix, Target)
		_OAP_Join(Control, EventHandle)
		_TestAppendProgress("# open_app native expected=" . Target . " observed=" . ActualReceipt)
		AssertEqual(Target, ActualReceipt, "the action launches the chosen path, not its executable prefix")
	} finally {
		try _OAP_Join(Control, EventHandle)
		finally {
			if Control.ProcessHandle || Control.UnownedPid {
				_OAP_RetirementDebt := { Control: Control, Root: Root, EventHandle: EventHandle }
			} else {
				if EventHandle && !DllCall("Kernel32\CloseHandle", "Ptr", EventHandle, "Int") {
					ErrorCode := A_LastError
					_OAP_RetirementDebt := { Control: Control, Root: Root, EventHandle: EventHandle }
					throw OSError(ErrorCode, -1, "close witness event; private fixture retained")
				}
				EventHandle := 0
				try DirDelete(Root, true)
				catch as Err {
					_OAP_RetirementDebt := { Control: Control, Root: Root, EventHandle: 0 }
					throw Err
				}
			}
		}
	}
}
Test("system actions: chosen executable path with spaces does not launch its prefix (open-app-native-quoted-path)", _OAP_ChosenPathDoesNotLaunchPrefix)


; A real shortcut is classified as one file, while shell expressions and
; wildcard patterns remain untouched by the path-specific quoting policy.
class _OAP_RecordingControl extends _SysActionsFake {
	__New() {
		super.__New()
		this.Native := SystemControl()
	}
	IsExistingFile(Path) => this.Native.IsExistingFile(Path)
}
_OAP_NativeShortcutControl() {
	Root := A_Temp . "\ergopti-shortcut-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	if !(Created is Integer) || Created != 1
		throw Error("Exclusive fixture ownership was not confirmed.")
	try {
		Link := Root . "\chosen shortcut.lnk"
		FileCreateShortcut(A_AhkPath, Link)
		Control := _OAP_RecordingControl()
		AssertTrue(Control.IsExistingFile(Link), "the OS recognizes the real shortcut")
		AssertFalse(Control.IsExistingFile(Root . "\*.lnk"), "wildcards are never treated as one path")
		_OAP_RunAction(Control, Link)
		Launches := _SysActions_CallsNamed(Control, "Launch")
		AssertEqual(1, Launches.Length)
		AssertEqual('"' . Link . '"', Launches[1][2], "the selected shortcut is one shell target")
	} finally DirDelete(Root, true)
}
Test("system actions: existing shortcut path stays one shell target (open-app-native-shortcut)", _OAP_NativeShortcutControl)


class _OAP_PauseOnFileProbe extends _SysActionsFake {
	IsExistingFile(Path) {
		Suspend(true)
		return true
	}
}
_OAP_PauseAfterPathProbe() {
	PriorPause := A_IsSuspended, Control := _OAP_PauseOnFileProbe()
	try {
		Suspend(false)
		_OAP_RunAction(Control, "C:\Program Files\Example\app.exe")
		AssertEqual(0, _SysActions_CallsNamed(Control, "Launch").Length,
			"a suspension during the new file query cancels the launch")
	} finally Suspend(PriorPause)
}
Test("system actions: pause during open_app path probe prevents launch (open-app-probe-pause)", _OAP_PauseAfterPathProbe)


class _OAP_ResumeOnFileProbe extends _SysActionsFake {
	__New(DoResume) {
		super.__New()
		this.DoResume := DoResume
	}
	IsExistingFile(Path) {
		if this.DoResume {
			Suspend(true)
			try AssertTrue(TapHoldReleaseSyntheticKeys(), "native lifecycle drain acknowledged")
			finally Suspend(false)
		}
		return true
	}
}
_OAP_ResumeAfterPathProbe() {
	global _TapCopyPending
	AssertFalse(IsObject(_TapCopyPending), "a foreign pending copy cannot be retired by this fixture")
	_TSUH_Begin(Map(), Map())
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		Control := _OAP_ResumeOnFileProbe(false)
		_OAP_RunAction(Control, "C:\Program Files\Example\app.exe")
		AssertEqual(1, _SysActions_CallsNamed(Control, "Launch").Length,
			"an unchanged invocation may launch")
		Control := _OAP_ResumeOnFileProbe(true)
		_OAP_RunAction(Control, "C:\Program Files\Example\app.exe")
		AssertFalse(A_IsSuspended, "the native driver resumed before the probe returned")
		AssertEqual(0, _SysActions_CallsNamed(Control, "Launch").Length,
			"the original lifecycle owner cannot launch after pause and resume")
	} finally {
		Suspend(PriorPause)
		_TSUH_End()
	}
}
Test("system actions: pause and resume during open_app probe retires launch (open-app-probe-resume)", _OAP_ResumeAfterPathProbe)

; Run's first stage is CreateProcessW. The quoted branch below exercises that
; real stage in suspended mode and deliberately does not open shared Explorer.
; The unquoted danger branch delegates to the actual SystemControl.Launch.
global _OAF_RetirementDebt := 0
class _OAF_Control extends _OAP_NativeControl {
	__New(Prefix) {
		super.__New()
		this.Prefix := Prefix, this.Quoted := false, this.QuotedError := 0, this.Suspended := 0
	}
	Launch(Target, WorkingDir := "", Options := "") {
		if SubStr(Target, 1, 1) != '"'
			return super.Launch(Target, WorkingDir, Options)
		this.Quoted := true
		TextBuffer := Buffer(StrPut(Target, "UTF-16") * 2, 0)
		StrPut(Target, TextBuffer, "UTF-16")
		Startup := Buffer(A_PtrSize == 8 ? 104 : 68, 0)
		NumPut("UInt", Startup.Size, Startup, 0)
		Info := Buffer(A_PtrSize == 8 ? 24 : 16, 0)
		Created := DllCall("Kernel32\CreateProcessW", "Ptr", 0, "Ptr", TextBuffer, "Ptr", 0, "Ptr", 0,
			"Int", false, "UInt", 4, "Ptr", 0, "Ptr", 0, "Ptr", Startup, "Ptr", Info, "Int")
		this.QuotedError := A_LastError
		if Created {
			this.Suspended := { Process: NumGet(Info, 0, "Ptr"), Thread: NumGet(Info, A_PtrSize, "Ptr"),
				Prefix: this.Prefix, Stopped: false }
			throw Error("Quoted directory unexpectedly created a suspended process.")
		}
		if this.QuotedError == 0
			throw Error("Quoted directory refusal had no native error.")
		return 0
	}
}
_OAF_RetireSuspended(Control) {
	if !IsObject(Control.Suspended)
		return true
	Owned := Control.Suspended
	if !Owned.Stopped {
		Image := Buffer(65536, 0), ImageLength := 32768
		if !DllCall("Kernel32\QueryFullProcessImageNameW", "Ptr", Owned.Process, "UInt", 0,
			"Ptr", Image, "UInt*", &ImageLength, "Int")
			return false
		if StrLower(StrGet(Image, ImageLength, "UTF-16")) != StrLower(Owned.Prefix)
			return false
		Status := DllCall("Kernel32\WaitForSingleObject", "Ptr", Owned.Process, "UInt", 0, "UInt")
		if Status != 0 {
			if Status != 258 || !DllCall("Kernel32\TerminateProcess", "Ptr", Owned.Process, "UInt", 1, "Int")
				return false
			if DllCall("Kernel32\WaitForSingleObject", "Ptr", Owned.Process, "UInt", 10000, "UInt") != 0
				return false
		}
		Owned.Stopped := true
	}
	if Owned.Thread {
		if !DllCall("Kernel32\CloseHandle", "Ptr", Owned.Thread, "Int")
			return false
		Owned.Thread := 0
	}
	if Owned.Process {
		if !DllCall("Kernel32\CloseHandle", "Ptr", Owned.Process, "Int")
			return false
		Owned.Process := 0
	}
	Control.Suspended := 0
	return true
}
; Explicit retry retains all exact handles and the root until each acknowledgement.
_OAF_RetireDebt() {
	global _OAF_RetirementDebt
	if !IsObject(_OAF_RetirementDebt)
		return true
	Debt := _OAF_RetirementDebt
	try {
		if !_OAF_RetireSuspended(Debt.Control)
			return false
		_OAP_Join(Debt.Control, Debt.EventHandle)
		if Debt.EventHandle {
			if !DllCall("Kernel32\CloseHandle", "Ptr", Debt.EventHandle, "Int")
				return false
			Debt.EventHandle := 0
		}
		DirDelete(Debt.Root, true)
		_OAF_RetirementDebt := 0
		return true
	} catch {
		return false
	}
}
_OAF_FolderPathDoesNotLaunchPrefix() {
	global _OAF_RetirementDebt, _OAP_RetirementDebt
	if IsObject(_OAF_RetirementDebt) || IsObject(_OAP_RetirementDebt)
		throw Error("A prior witness retirement debt blocks this probe.")
	Root := A_Temp . "\ergopti-openfolder-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
	if RegExMatch(Root, "[\s]")
		throw Error("This native fixture requires a temporary path without whitespace.")
	Created := FSCreateDirectoryExclusiveStrict(Root)
	if !(Created is Integer) || Created != 1
		throw Error("Exclusive fixture ownership was not confirmed.")
	Prefix := Root . "\witness.exe", Control := _OAF_Control(Prefix), EventHandle := 0
	try {
		Name := "Local\ErgoptiOpenFolderWitness-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount . "-" . Random(100000, 999999)
		EventHandle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true, "Int", false, "Str", Name, "Ptr")
		EventError := A_LastError
		if !EventHandle || EventError == 183
			throw Error("Exclusive witness event was not acquired.")
		Compiler := A_WinDir . "\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
		AssertTrue(FileExist(Compiler) != "", "the native C# compiler is available")
		Folder := Root . "\witness.exe folder", Source := Root . "\witness.cs", Receipt := Root . "\receipt.txt"
		DirCreate(Folder)
		Code := 'using System; using System.IO; using System.Diagnostics; using System.Threading; '
			. 'class Witness { static int Main() { try { var p = Process.GetCurrentProcess(); '
			. 'File.WriteAllText(@"' . Receipt . '.pending", p.Id.ToString() + "|" + '
			. 'p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() + "|" + p.MainModule.FileName); '
			. 'File.Move(@"' . Receipt . '.pending", @"' . Receipt . '"); '
			. 'using (var e = EventWaitHandle.OpenExisting(@"' . Name
			. '")) { return e.WaitOne(30000) ? 0 : 3; } } catch { return 4; } } }'
		FileAppend(Code, Source, "UTF-8")
		CompileCode := RunWait('"' . Compiler . '" /nologo /target:exe /out:"' . Prefix . '" "' . Source . '"', , "Hide")
		AssertEqual(0, CompileCode, "native inert witness compiled successfully")
		AssertTrue(Control.Native.IsDirectory(Folder), "the selected path is a real directory")
		Control.Launch('"' . Folder . '"')
		AssertTrue(Control.Quoted && Control.QuotedError != 0, "the native quoted CreateProcess stage refuses the folder")
		Control.Quoted := false, Control.QuotedError := 0
		_OAP_RunAction(Control, Folder)
		Observed := ""
		if Control.ProcessHandle {
			Observed := _OAP_AwaitReceipt(Receipt, Control, Prefix, Prefix)
			_OAP_Join(Control, EventHandle)
		}
		_TestAppendProgress("# open_app folder quoted=" . Control.Quoted . " observed=" . Observed)
		AssertTrue(Control.Quoted, "an existing folder is passed as one quoted shell target")
		AssertEqual("", Observed, "its executable prefix did not run")
	} finally {
		_OAF_RetirementDebt := { Control: Control, Root: Root, EventHandle: EventHandle }
		if !_OAF_RetireDebt()
			throw Error("Owned folder witness retirement remains outstanding.")
	}
}
Test("system actions: existing folder path does not launch an executable prefix (open-app-native-folder)", _OAF_FolderPathDoesNotLaunchPrefix)


class _OAN_Control extends _OAP_NativeControl {
	__New() {
		super.__New()
		this.LaunchCalls := 0, this.FileProbes := 0, this.LaunchError := ""
	}
	IsExistingFile(Path) {
		this.FileProbes += 1
		return super.IsExistingFile(Path)
	}
	Launch(Target, WorkingDir := "", Options := "") {
		this.LaunchCalls += 1
		try return super.Launch(Target, WorkingDir, Options)
		catch as Err {
			this.LaunchError := Err.Message
			throw
		}
	}
}

; JSON really constructs a counted NUL String. The application action and native
; adapter are measured separately: a safe action refusal is not an adapter ACK.
_OAN_OriginalJsonNul(Mode) {
	global _OAP_RetirementDebt
	AssertFalse(IsObject(_OAP_RetirementDebt), "a foreign retained witness prevents another launcher")
	Root := A_Temp . "\ergopti_openapp_nul_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . "_" . Random(100000, 999999)
	AssertFalse(RegExMatch(Root, "\s"), "no earlier whitespace component may resolve to an unowned executable")
	Creation := FSCreateDirectoryExclusiveStrict(Root)
	Created := (Creation is Integer) && Creation == 1
	AssertTrue(Created, "the launcher owns an exclusive private directory")
	EventHandle := 0, Control := _OAN_Control()
	try {
		EventName := "Local\ErgoptiNulLaunch_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . "_" . Random(100000, 999999)
		EventHandle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true, "Int", false, "Str", EventName, "Ptr")
		EventError := A_LastError
		AssertTrue(EventHandle && EventError != 183, "the private witness event must be created exclusively")
		Compiler := A_WinDir . "\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
		AssertTrue(FileExist(Compiler) != "", "the actual C# witness compiler is available")
		Target := Root . "\witness.exe", SourcePath := Root . "\witness.cs", Receipt := Root . "\receipt.txt"
		Code := 'using System; using System.IO; using System.Diagnostics; using System.Threading; '
			. 'class Witness { static int Main() { try { var p = Process.GetCurrentProcess(); '
			. 'File.WriteAllText(@"' . Receipt . '.pending", p.Id.ToString() + "|" + '
			. 'p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() + "|" + p.MainModule.FileName); '
			. 'File.Move(@"' . Receipt . '.pending", @"' . Receipt . '"); '
			. 'using (var e = EventWaitHandle.OpenExisting(@"' . EventName
			. '")) { return e.WaitOne(30000) ? 0 : 3; } } catch { return 4; } } }'
		AssertEqual(1, FSWriteCreateDurable(SourcePath, Code))
		AssertEqual(0, RunWait('"' . Compiler . '" /nologo /target:exe /out:"' . Target . '" "' . SourcePath . '"', , "Hide"))
		; Prequalify the genuine native launch and authenticate the handle before
		; claiming that a later no-process result represents a safe refusal.
		Control.Launch('"' . Target . '"')
		AssertEqual(Target, _OAP_AwaitReceipt(Receipt, Control, Target, Target))
		_OAP_Join(Control, EventHandle)
		FileDelete(Receipt)
		AssertTrue(DllCall("Kernel32\ResetEvent", "Ptr", EventHandle, "Int"))
		Control.LaunchCalls := 0, Control.FileProbes := 0, Control.LaunchError := ""
		AssertFalse(A_IsSuspended, "the action boundary must be unpaused before a refusal verdict")
		Before := FSReadBytesStrict(Target)
		Encoded := JsonStringLiteral(Target)
		if Mode != "valid"
			Encoded := SubStr(Encoded, 1, StrLen(Encoded) - 1) . '\u0000unrepresentable-suffix"'
		JsonText := '{"application_path":' . Encoded . '}'
		Value := JsonParse(JsonText)["application_path"]
		ExpectedUnits := StrLen(Target) + (Mode == "valid" ? 0 : 1 + StrLen("unrepresentable-suffix"))
		AssertEqual(ExpectedUnits, StrLen(Value), "the real JSON producer retains every original UTF-16 unit")
		if Mode != "valid" {
			AssertEqual(0, NumGet(StrPtr(Value), StrLen(Target) * 2, "UShort"), "the original embedded NUL really precedes the suffix")
			AssertEqual(0x75, NumGet(StrPtr(Value), (StrLen(Target) + 1) * 2, "UShort"))
		}
		Admitted := false, BoundaryRefused := false
		try Admitted := GestureAppParameterIsValid(Value)
		catch as Err {
			if Mode == "valid"
				throw
			BoundaryRefused := true
		}
		FileAlias := -1
		if Mode == "adapter" {
			; Use a separately parsed String for the native classifier, retaining
			; the original launch input and its counted metadata unchanged.
			try FileAlias := Control.Native.IsExistingFile(JsonParse(JsonText)["application_path"])
			catch {
				FileAlias := -2
			}
			try Control.Launch(Value)
			catch {
				BoundaryRefused := true
			}
		} else {
			try _OAP_RunAction(Control, Value)
			catch as Err {
				if Mode == "valid"
					throw
				BoundaryRefused := true
			}
		}
		Launched := Control.ProcessHandle != 0 || Control.UnownedPid != 0
		ActualImage := "<none>"
		if Control.ProcessHandle {
			ActualImage := _OAP_AwaitReceipt(Receipt, Control, Target, Target)
			_OAP_Join(Control, EventHandle)
		}
		After := FSReadBytesStrict(Target)
		_TestPrint("# original-nul-launch mode=" . Mode . " units=" . StrLen(Value) . " expected_units=" . ExpectedUnits
			. " app_admitted=" . Admitted . " boundary_refused=" . BoundaryRefused
			. " file_alias=" . FileAlias . " file_probes=" . Control.FileProbes
			. " launch_calls=" . Control.LaunchCalls . " launched=" . Launched . " actual_image=" . ActualImage
			. " native_error=" . (Control.LaunchError != ""))
		AssertEqual(ExpectedUnits, StrLen(Value), "a native boundary cannot shorten the producer's original String")
		AssertEqual(Before.Size, After.Size)
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before, "Ptr", After,
			"UPtr", Before.Size, "UPtr"), "launch or refusal cannot mutate the selected executable")
		if Mode == "valid" {
			AssertTrue(Admitted && Launched, "the valid JSON path must reach the real action and genuine native launcher")
			AssertEqual(Target, ActualImage)
		} else
			AssertFalse(Launched, "an unrepresentable original path cannot launch the different prefix executable")
	} finally {
		try _OAP_Join(Control, EventHandle)
		finally {
			if Control.ProcessHandle || Control.UnownedPid {
				_OAP_RetirementDebt := {Control: Control, Root: Root, EventHandle: EventHandle}
			} else {
				if EventHandle && !DllCall("Kernel32\CloseHandle", "Ptr", EventHandle, "Int") {
					_OAP_RetirementDebt := {Control: Control, Root: Root, EventHandle: EventHandle}
					throw OSError(A_LastError, -1, "close private original-NUL launch event")
				}
				if Created
					try DirDelete(Root, true)
					catch as Err {
						_OAP_RetirementDebt := {Control: Control, Root: Root, EventHandle: 0}
						throw
					}
			}
		}
	}
}
for _OAN_Mode in ["action", "adapter", "valid"]
	Test("open app original NUL: " . _OAN_Mode . " observes a private native process (open-app-original-nul)",
		_OAN_OriginalJsonNul.Bind(_OAN_Mode))


; The native Run target is deliberately not a StrArg. Even a regressed guard
; cannot start a process: coercion is forbidden and this object returns no path.
class _SCN_NoNativeTarget {
	__New() {
		this.Coercions := 0
	}
	ToString() {
		this.Coercions += 1
		throw Error("The pure launch-argument test forbids native target coercion")
	}
}
_SCN_RejectOriginalArgument(Field) {
	Left := Field == "working-dir" ? "C:\é😀\kept" : "Hide"
	Encoded := JsonStringLiteral(Left)
	Value := JsonParse(SubStr(Encoded, 1, StrLen(Encoded) - 1) . '\u0000ignored"')
	Units := StrLen(Left) + 1 + StrLen("ignored")
	AssertEqual(Units, StrLen(Value), "the actual JSON decoder retains the complete original argument")
	AssertEqual(0, NumGet(StrPtr(Value), StrLen(Left) * 2, "UShort"))
	Poison := _SCN_NoNativeTarget(), Caught := 0
	try SystemControl().Launch(Poison, Field == "working-dir" ? Value : "", Field == "options" ? Value : "Hide")
	catch as Err
		Caught := Err
	_TestPrint("# native launch argument field=" . Field . " original_units=" . StrLen(Value)
		. " value_error=" . (Caught is ValueError) . " target_coercions=" . Poison.Coercions)
	AssertTrue(Caught is ValueError, "the adapter must reject its original NUL argument before native Run argument binding")
	AssertContains(Caught.Message, "embedded NUL", "the refusal must come from the whole-string native ABI guard")
	AssertEqual(0, Poison.Coercions, "argument validation must precede target coercion")
	AssertEqual(Units, StrLen(Value), "the original String must not be truncated or normalized")
	AssertEqual(0, NumGet(StrPtr(Value), StrLen(Left) * 2, "UShort"))
}
for _SCN_Field in ["working-dir", "options"]
	Test("SystemControl original NUL argument: " . _SCN_Field . " refuses before native ABI (system-control-original-nul-args)",
		_SCN_RejectOriginalArgument.Bind(_SCN_Field))


_SCN_WholeNativePath(Kind) {
	Root := A_Temp . "\ergopti_native_path_nul_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue((Created is Integer) && Created == 1, "the path classifier fixture exclusively owns its real directory")
	try {
		FilePath := Root . "\réel😀.txt"
		AssertEqual(1, FSWriteCreateDurable(FilePath, "owned classifier control"))
		Path := Kind == "file" ? FilePath : Root
		Encoded := JsonStringLiteral(Path)
		Value := JsonParse(SubStr(Encoded, 1, StrLen(Encoded) - 1) . '\u0000trailer"')
		Units := StrLen(Path) + 1 + StrLen("trailer")
		AssertEqual(Units, StrLen(Value))
		AssertEqual(0, NumGet(StrPtr(Value), StrLen(Path) * 2, "UShort"))
		Adapter := SystemControl()
		GoodFile := Adapter.IsExistingFile(Path), GoodDir := Adapter.IsDirectory(Path)
		BadFile := Adapter.IsExistingFile(Value), BadDir := Adapter.IsDirectory(Value)
		_TestPrint("# native path NUL kind=" . Kind . " original_units=" . StrLen(Value)
			. " valid_file=" . GoodFile . " valid_dir=" . GoodDir
			. " nul_file=" . BadFile . " nul_dir=" . BadDir)
		AssertEqual(Kind == "file", GoodFile, "the actual adapter must recognize its private existing file")
		AssertEqual(Kind == "directory", GoodDir, "the actual adapter must recognize its private existing directory")
		AssertFalse(BadFile, "an original counted NUL path cannot be an existing file merely because its prefix is")
		AssertFalse(BadDir, "an original counted NUL path cannot be an existing directory merely because its prefix is")
		AssertEqual(Units, StrLen(Value), "classification preserves the complete unrepresentable String")
		AssertEqual(0, NumGet(StrPtr(Value), StrLen(Path) * 2, "UShort"))
	} finally {
		if Created
			DirDelete(Root, true)
	}
}
for _SCN_Kind in ["file", "directory"]
	Test("SystemControl whole native path: " . _SCN_Kind . " rejects NUL prefix identity (system-control-original-nul-predicates)",
		_SCN_WholeNativePath.Bind(_SCN_Kind))
