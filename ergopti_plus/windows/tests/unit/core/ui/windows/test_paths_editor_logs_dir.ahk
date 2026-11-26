; tests/unit/core/ui/windows/test_paths_editor_logs_dir.ahk

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
		_LogsDir := "D:\Sync\Ergopti\"
		_DefaultLogsDir := "C:\Local\Ergopti\logs\"
		Js := _PathsEdWeb_InitDataJs()
		AssertContains(Js, 'logsDir:"D:/Sync/Ergopti/"')
		AssertContains(Js, 'defaultLogsDir:"C:/Local/Ergopti/logs/"')
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
		_DefaultLogsDir := "C:\Local\Ergopti\logs\"
		_LogsDir := "D:\Sync\Ergopti\"
		AssertEqual("", _PathsEdWeb_LogsOverride("C:/Local/Ergopti/logs/"),
			"the default folder is stored as no override")
		AssertEqual("", _PathsEdWeb_LogsOverride(""), "an empty field is the default")
		AssertEqual("E:\Picked\" . AppDirsFolderName() . "\", _PathsEdWeb_LogsOverride("E:/Picked/"),
			"a picked folder gets the application subfolder")
		AssertEqual("D:\Sync\Ergopti\", _PathsEdWeb_LogsOverride(0),
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
		_DefaultLogsDir := "C:\Local\Ergopti\logs\"
		_LogsDir := "D:\Sync\Ergopti\"
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
		Fresh := Root . "\fresh\" . AppDirsFolderName() . "\"
		_PathsEdWeb_PrepareLogsFolder(Fresh)
		AssertTrue(DirExist(Fresh) != "", "a new logs folder is created before it is stored")
		_PathsEdWeb_PrepareLogsFolder("")
		AssertThrows(() => _PathsEdWeb_PrepareLogsFolder(Blocker . "\" . AppDirsFolderName() . "\"),
			"a logs folder that cannot be created is refused")
	} finally {
		try DirDelete(Root, true)
	}
}
Test("paths editor: a logs folder that cannot be created is refused (paths-editor-logs-dir)",
	_PELD_UncreatableLogsFolderIsRefused)

; A native modal's completion belongs to the session that opened it, even when
; the process remains alive and now holds another WebView in the same globals.
_FPB_Pick(World, RootDir, Options, Prompt, Title, OwnerHwnd) {
	global _PathsEdWeb_SessionEpoch, _OnbWeb_SessionEpoch
	World.Picks += 1
	AssertEqual(World.Host == "onboarding" ? 3 : 1, Options, "the native creation policy stays unchanged")
	AssertEqual(0, OwnerHwnd)
	if World.Mode == "closed" || World.Mode == "reopened" {
		Advance := World.Mode == "closed" ? 1 : 2
		if World.Host == "paths"
			_PathsEdWeb_SessionEpoch += Advance
		else
			_OnbWeb_SessionEpoch += Advance
	} else if World.Mode == "pause"
		Suspend(true)
	return World.Mode == "cancel" ? "" : "D:\Picked folder"
}

_FPB_ResultOwnsSession(Host, Target, Mode) {
	global _PathsEdWeb_SessionEpoch, _OnbWeb_SessionEpoch, _ConfigDir
	Saved := [_PathsEdWeb_SessionEpoch, _OnbWeb_SessionEpoch, _ConfigDir, A_IsSuspended]
	World := { Host: Host, Mode: Mode, Picks: 0, Scripts: [] }
	try {
		_PathsEdWeb_SessionEpoch := 1001
		_OnbWeb_SessionEpoch := 2001
		_ConfigDir := "C:\Private configuration\"
		Suspend(Mode == "already-paused")
		Pick := _FPB_Pick.Bind(World)
		Eval := (Js) => World.Scripts.Push(Js)
		if Host == "paths"
			_PathsEdWeb_Browse(Target, Pick, Eval)
		else
			_OnbWeb_PickConfigDir("C:\Private configuration", Pick, Eval)
		; A pause stops typing, not configuration (EDD-1): the paths editor picks
		; a folder while paused, so a pause delivers as a live session does. The
		; onboarding keeps its pause guard.
		Paused := Mode == "pause" || Mode == "already-paused"
		Delivered := Mode == "live" || (Paused && Host != "onboarding")
		AssertEqual(Mode == "already-paused" && Host == "onboarding" ? 0 : 1, World.Picks)
		AssertEqual(Delivered ? 1 : 0, World.Scripts.Length,
			"only a still-current session may receive the picked folder, paused or not")
		if Delivered {
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
}
