; tests/unit/test_paths_editor_logs_dir.ahk

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
