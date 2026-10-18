; tests/unit/modules/gestures/test_system_actions_query_pause.ahk

; ==============================================================================
; MODULE: System Actions Query Pause
; DESCRIPTION:
; A pause during an ownership or directory read of a confirmed or sibling
; action cannot ask, reactivate or queue an effect, and unchanged runs still
; complete their transaction.
; ==============================================================================

#Requires AutoHotkey v2.0





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
