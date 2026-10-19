; tests/unit/ui/windows/test_paths_editor_logs_dir.ahk

; ==============================================================================
; MODULE: Paths Editor Logs Folder Tests
; DESCRIPTION:
; The shared paths editor edits two folders: the configuration folder and the
; logs folder (LogsDirPath), each shown with its default.
;
; WHAT IS PINNED (paths-editor-logs-dir):
; 1. The page receives the current and the default logs folder.
; 2. A save stores the logs folder the resolver would use, "" for the default,
;    and keeps the stored one when the page sent none.
; 3. A folder that is not absolute is refused, never saved as the default.
; 4. A folder that cannot be created is refused before paths.toml changes.
; ==============================================================================

#Requires AutoHotkey v2.0

_PELD_InitDataCarriesTheLogsFolder() {
	global _DefaultConfigDir, _LogsDir, _DefaultLogsDir
	Saved := [_LogsDir, _DefaultLogsDir]
	; The headless harness has no boot, so no default configuration folder.
	if !IsSet(_DefaultConfigDir)
		_DefaultConfigDir := A_Temp . "\ergopti_test_config\"
	try {
		_LogsDir := "D:\Sync\ergopti_plus\"
		_DefaultLogsDir := "C:\Local\ergopti_plus\logs\"
		Js := _PathsEdWeb_InitDataJs()
		AssertContains(Js, 'logsDir:"D:/Sync/ergopti_plus/"')
		AssertContains(Js, 'defaultLogsDir:"C:/Local/ergopti_plus/logs/"')
		AssertContains(Js, "paths_editor.label_logs_dir")
	} finally {
		_LogsDir := Saved[1]
		_DefaultLogsDir := Saved[2]
	}
}
Test("paths editor: the page receives the current and default logs folder (paths-editor-logs-dir)",
	_PELD_InitDataCarriesTheLogsFolder)

_PELD_SaveStoresTheResolvedLogsFolder() {
	global _LogsDir, _DefaultLogsDir
	Saved := [_LogsDir, _DefaultLogsDir]
	try {
		_DefaultLogsDir := "C:\Local\ergopti_plus\logs\"
		_LogsDir := "D:\Sync\ergopti_plus\"
		AssertEqual("", _PathsEdWeb_LogsOverride("C:/Local/ergopti_plus/logs/"),
			"the default folder is stored as no override")
		AssertEqual("", _PathsEdWeb_LogsOverride(""), "an empty field is the default")
		AssertEqual("E:\Picked\ergopti_plus\", _PathsEdWeb_LogsOverride("E:/Picked/"),
			"a picked folder gets the application subfolder")
		AssertEqual("D:\Sync\ergopti_plus\", _PathsEdWeb_LogsOverride(0),
			"a page that sends no logs folder keeps the stored one")
	} finally {
		_LogsDir := Saved[1]
		_DefaultLogsDir := Saved[2]
	}
}
Test("paths editor: a save stores the resolved logs folder (paths-editor-logs-dir)",
	_PELD_SaveStoresTheResolvedLogsFolder)

; A folder typed in the editor that is not absolute used to be replaced by the
; default and saved, followed by a reload: the user's entry vanished with only
; a log line to say why. macOS and Linux refuse it and keep the editor open.
_PELD_RelativeLogsFolderIsRefused() {
	global _LogsDir, _DefaultLogsDir
	Saved := [_LogsDir, _DefaultLogsDir]
	try {
		_DefaultLogsDir := "C:\Local\ergopti_plus\logs\"
		_LogsDir := "D:\Sync\ergopti_plus\"
		AssertThrows(() => _PathsEdWeb_LogsOverride("relative\logs"),
			"a relative logs folder is refused, never replaced by the default")
		AssertThrows(() => _PathsEdWeb_LogsOverride("logs"),
			"a bare folder name is refused")
		AssertEqual("", _PathsEdWeb_LogsOverride("  "), "a blank field still means the default")
	} finally {
		_LogsDir := Saved[1]
		_DefaultLogsDir := Saved[2]
	}
}
Test("paths editor: a relative logs folder is refused, not reset to the default (paths-editor-logs-dir)",
	_PELD_RelativeLogsFolderIsRefused)

; The logger creates its folder silently at boot, so a stored folder that
; cannot be created left the next session logging nowhere. The editor creates
; it before storing it, and refuses it when that fails.
_PELD_UncreatableLogsFolderIsRefused() {
	Root := A_Temp . "\ergopti_peld_" . A_TickCount
	Blocker := Root . "\a_file"
	try {
		DirCreate(Root)
		FileAppend("x", Blocker, "UTF-8")
		Fresh := Root . "\fresh\ergopti_plus\"
		_PathsEdWeb_PrepareLogsFolder(Fresh)
		AssertTrue(DirExist(Fresh) != "", "a new logs folder is created before it is stored")
		_PathsEdWeb_PrepareLogsFolder("")
		AssertThrows(() => _PathsEdWeb_PrepareLogsFolder(Blocker . "\ergopti_plus\"),
			"a logs folder that cannot be created is refused")
	} finally {
		try DirDelete(Root, true)
	}
}
Test("paths editor: a logs folder that cannot be created is refused (paths-editor-logs-dir)",
	_PELD_UncreatableLogsFolderIsRefused)

; A native modal's completion belongs to the session that opened it, even when
; the process remains alive and now holds another WebView in the same globals.
class _FPB_NativeWindow {
	Id := 3001
	Live := true
	Hwnd {
		get {
			if !this.Live
				throw Error("Controlled native editor destruction")
			return this.Id
		}
	}
}

_FPB_Pick(World, RootDir, Options, Prompt, Title, OwnerHwnd) {
	global _PathsEdWeb_SessionEpoch, _OnbWeb_SessionEpoch
	World.Picks += 1
	AssertEqual(World.Host == "onboarding" ? 3 : 1, Options, "the native creation policy stays unchanged")
	AssertEqual(0, OwnerHwnd)
	if World.Mode == "closed" || World.Mode == "reopened" {
		Advance := World.Mode == "closed" ? 1 : 2
		if World.Host == "paths"
			_PathsEdWeb_SessionEpoch += Advance
		else if World.Host == "onboarding"
			_OnbWeb_SessionEpoch += Advance
		else if World.Mode == "closed"
			World.Window.Live := false
		else
			World.Window.Id += 1
	} else if World.Mode == "pause"
		Suspend(true)
	return World.Mode == "cancel" ? "" : "D:\Picked folder"
}

_FPB_ResultOwnsSession(Host, Target, Mode) {
	global _PathsEdWeb_SessionEpoch, _OnbWeb_SessionEpoch, _ConfigDir
	Saved := [_PathsEdWeb_SessionEpoch, _OnbWeb_SessionEpoch, _ConfigDir, A_IsSuspended]
	World := { Host: Host, Mode: Mode, Picks: 0, Scripts: [], Window: _FPB_NativeWindow(), Edit: {Value: "C:/Private configuration"} }
	try {
		_PathsEdWeb_SessionEpoch := 1001
		_OnbWeb_SessionEpoch := 2001
		_ConfigDir := "C:\Private configuration\"
		Suspend(Mode == "already-paused")
		Pick := _FPB_Pick.Bind(World)
		Eval := (Js) => World.Scripts.Push(Js)
		if Host == "paths"
			_PathsEdWeb_Browse(Target, Pick, Eval)
		else if Host == "onboarding"
			_OnbWeb_PickConfigDir("C:\Private configuration", Pick, Eval)
		else
			_PathsEdNative_Browse(World.Window, World.Edit, Pick,
				(Hwnd) => World.Window.Live && World.Window.Hwnd == Hwnd)
		AssertEqual(Mode == "already-paused" ? 0 : 1, World.Picks)
		AssertEqual(Mode == "live" && Host != "native" ? 1 : 0, World.Scripts.Length,
			"only a still-current unpaused session may receive the picked folder")
		if Host == "native"
			AssertEqual(Mode == "live" ? "D:/Picked folder" : "C:/Private configuration", World.Edit.Value,
				"the original native field changes only while its window is current")
		else if Mode == "live" {
			if Host == "paths" {
				AssertContains(World.Scripts[1], '"D:/Picked folder/"')
				AssertContains(World.Scripts[1], '"' . Target . '"')
			} else
				AssertContains(World.Scripts[1], JsonStringLiteral("D:\Picked folder"))
		}
	} finally {
		_PathsEdWeb_SessionEpoch := Saved[1]
		_OnbWeb_SessionEpoch := Saved[2]
		_ConfigDir := Saved[3]
		Suspend(Saved[4])
	}
}
for Mode in ["live", "closed", "reopened", "pause", "cancel", "already-paused"] {
	Test("folder picker: config field completion respects " . Mode . " (webview-folder-picker-session)",
		_FPB_ResultOwnsSession.Bind("paths", "config", Mode))
	Test("folder picker: logs field completion respects " . Mode . " (webview-folder-picker-session)",
		_FPB_ResultOwnsSession.Bind("paths", "logs", Mode))
	Test("folder picker: onboarding completion respects " . Mode . " (webview-folder-picker-session)",
		_FPB_ResultOwnsSession.Bind("onboarding", "config", Mode))
	Test("folder picker: native field completion respects " . Mode . " (webview-folder-picker-session)",
		_FPB_ResultOwnsSession.Bind("native", "config", Mode))
}

; Default Close hides a Gui without retiring its HWND. These private hidden
; windows receive targeted messages only; no desktop input is injected.
_PNC_RecordDefaultClose(Receipt, *) {
	Receipt.Closed := true
	return false
}

_PNC_PostClose(Hwnd) {
	AssertTrue(DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int"),
		"the private native window must receive its close request")
}

_PNC_DefaultCloseRetainsHiddenHandle() {
	Window := Gui()
	Edit := Window.Add("Edit", , "retained value")
	Receipt := {Closed: false}
	Window.OnEvent("Close", _PNC_RecordDefaultClose.Bind(Receipt))
	Window.Show("Hide w220 h100")
	Hwnd := Window.Hwnd
	try {
		_PNC_PostClose(Hwnd)
		Started := A_TickCount
		while !Receipt.Closed && A_TickCount - Started < 2000
			Sleep(1)
		AssertTrue(Receipt.Closed, "the native Close event must actually run")
		AssertTrue(WMHandleExists(Hwnd), "default Close preserves the native handle")
		AssertFalse(DllCall("IsWindowVisible", "Ptr", Hwnd, "Int"))
		AssertEqual("retained value", Edit.Value, "a hidden closed editor still owns writable controls")
	} finally Window.Destroy()
}

_PNC_CloseDuringPicker(Window, *) {
	Hwnd := Window.Hwnd
	_PNC_PostClose(Hwnd)
	Started := A_TickCount
	while WMHandleExists(Hwnd) && A_TickCount - Started < 2000
		Sleep(1)
	AssertFalse(WMHandleExists(Hwnd), "owned Close must destroy rather than hide the editor")
	return "D:\obsolete selection"
}

_PNC_OwnedCloseRejectsPickerResult() {
	Window := Gui()
	Edit := Window.Add("Edit", , "C:\original")
	_PathsEdNative_BindCancellation(Window)
	Window.Show("Hide w220 h100")
	Hwnd := Window.Hwnd
	try {
		AssertTrue(WMHandleExists(Hwnd))
		AssertFalse(DllCall("IsWindowVisible", "Ptr", Hwnd, "Int"))
		AssertFalse(_PathsEdNative_Browse(Window, Edit, _PNC_CloseDuringPicker.Bind(Window)),
			"a cancelled native editor cannot accept a late selection or access its dead edit control")
	} finally {
		if WMHandleExists(Hwnd)
			Window.Destroy()
	}
}

class _PNC_EventRegistrar {
	__New(Window) {
		this.Window := Window
		this.Handlers := Map()
	}
	OnEvent(Name, Callback) {
		this.Handlers[Name] := Callback
		this.Window.OnEvent(Name, Callback)
	}
}

_PNC_EscapeRetiresSameWindow() {
	Window := Gui()
	Window.Add("Edit", , "C:\original")
	Window.Show("Hide w220 h100")
	Hwnd := Window.Hwnd
	try {
		Registrar := _PNC_EventRegistrar(Window)
		_PathsEdNative_BindCancellation(Registrar)
		AssertTrue(Registrar.Handlers["Close"] == Registrar.Handlers["Escape"],
			"Close and Escape must share the same definitive cancellation")
		AssertTrue(Registrar.Handlers["Escape"].Call(Window))
		AssertFalse(WMHandleExists(Hwnd), "the registered Escape action retires the hidden HWND too")
	} finally {
		if WMHandleExists(Hwnd)
			Window.Destroy()
	}
}
Test("native paths editor: default Close retains the hidden HWND (native-paths-close-cancellation)",
	_PNC_DefaultCloseRetainsHiddenHandle)
Test("native paths editor: owned Close retires a picker callback's HWND (native-paths-close-cancellation)",
	_PNC_OwnedCloseRejectsPickerResult)
Test("native paths editor: registered Escape destroys the same hidden window (native-paths-close-cancellation)",
	_PNC_EscapeRetiresSameWindow)
