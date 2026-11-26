; tests/unit/core/logger/test_set_level_transaction.ahk

; ==============================================================================
; MODULE: Runtime logger-level transaction
; DESCRIPTION:
; Proves that a config terminal barrier and a refused writer cannot publish a
; new logger level or rebuild its menu projection. The same candidate commits
; disk before refreshing the cached hot-path severity flags.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LSLT_WriterCalls := 0
global _LSLT_NotifyCalls := 0
global _LSLT_RebuildCalls := 0
global _LSLT_SeenUpdates := 0
global _LSLT_WriterResult := true
global _LSLT_ObservedLevel := ""
global _LSLT_ObservedSeverity := -1
global _LSLT_WriterCritical := []
global _LSLT_NotifyCritical := []
global _LSLT_RebuildCritical := []
global _LSLT_UnrelatedDebugCalls := 0

_LSLT_Reset() {
	global _LSLT_WriterCalls, _LSLT_NotifyCalls, _LSLT_RebuildCalls
	global _LSLT_SeenUpdates, _LSLT_WriterResult
	global _LSLT_ObservedLevel, _LSLT_ObservedSeverity
	global _LSLT_WriterCritical, _LSLT_NotifyCritical
	global _LSLT_RebuildCritical
	_LSLT_WriterCalls := 0
	_LSLT_NotifyCalls := 0
	_LSLT_RebuildCalls := 0
	_LSLT_SeenUpdates := 0
	_LSLT_WriterResult := true
	_LSLT_ObservedLevel := ""
	_LSLT_ObservedSeverity := -1
	_LSLT_WriterCritical := []
	_LSLT_NotifyCritical := []
	_LSLT_RebuildCritical := []
}

_LSLT_Writer(Path, Updates) {
	global _LSLT_WriterCalls, _LSLT_SeenUpdates, _LSLT_WriterResult
	global _LSLT_ObservedLevel, _LSLT_ObservedSeverity
	global _LSLT_WriterCritical
	global LOGGER_MIN_LEVEL, _LOGGER_MIN_SEVERITY
	_LSLT_WriterCalls += 1
	_LSLT_WriterCritical.Push(A_IsCritical)
	_LSLT_SeenUpdates := Updates
	_LSLT_ObservedLevel := LOGGER_MIN_LEVEL
	_LSLT_ObservedSeverity := _LOGGER_MIN_SEVERITY
	return _LSLT_WriterResult
}

_LSLT_Notify(Message, Options) {
	global _LSLT_NotifyCalls, _LSLT_NotifyCritical
	_LSLT_NotifyCalls += 1
	_LSLT_NotifyCritical.Push(A_IsCritical)
}

_LSLT_Rebuild(*) {
	global _LSLT_RebuildCalls, _LSLT_RebuildCritical
	_LSLT_RebuildCalls += 1
	_LSLT_RebuildCritical.Push(A_IsCritical)
}

_LSLT_TerminalBarrierLeavesLoggerStateUnchanged() {
	global ConfigurationFile, LOGGER_MIN_LEVEL, LOGGER_SEVERITY
	global _LOGGER_MIN_SEVERITY
	global _LSLT_WriterCalls, _LSLT_NotifyCalls, _LSLT_RebuildCalls
	global _LSLT_SeenUpdates, _LSLT_WriterResult
	global _LSLT_ObservedLevel, _LSLT_ObservedSeverity
	SavedPath := ConfigurationFile
	Fixture := 0
	SavedLevel := LOGGER_MIN_LEVEL
	Bundle := false
	try {
		_LSLT_Reset()
		Fixture := _ScopeOwnerFixture()
		ConfigurationFile := Fixture.path
		TargetLevel := SavedLevel = "ERROR" ? "DEBUG" : "ERROR"
		Bundle := _ConfigWriteTerminalTryAcquire(
			[A_Temp . "\ergopti_unrelated_terminal.toml"])
		AssertTrue(Bundle is Object)
		AssertFalse(LoggerSetLevel(TargetLevel, _LSLT_Writer,
			_LSLT_Notify, _LSLT_Rebuild))
		AssertEqual(SavedLevel, LOGGER_MIN_LEVEL,
			"terminal refusal must not publish the candidate log level")
		AssertEqual(LOGGER_SEVERITY[SavedLevel], _LOGGER_MIN_SEVERITY,
			"terminal refusal must not refresh hot-path flags from rejected state")
		AssertEqual(0, _LSLT_WriterCalls)
		AssertEqual(0, _LSLT_RebuildCalls)
		AssertEqual(1, _LSLT_NotifyCalls)

		_ConfigWriteTerminalRelease(Bundle)
		Bundle := false
		AssertTrue(LoggerSetLevel(TargetLevel, _LSLT_Writer,
			_LSLT_Notify, _LSLT_Rebuild))
		AssertEqual(1, _LSLT_WriterCalls)
		AssertEqual(SavedLevel, _LSLT_ObservedLevel,
			"the candidate level must remain detached during durable I/O")
		AssertEqual(LOGGER_SEVERITY[SavedLevel], _LSLT_ObservedSeverity,
			"hot-path severity flags must remain detached during durable I/O")
		AssertTrue(_LSLT_SeenUpdates is Array)
		AssertEqual("script", _LSLT_SeenUpdates[1].Section)
		AssertEqual("log_level", _LSLT_SeenUpdates[1].Key)
		AssertEqual(TargetLevel, _LSLT_SeenUpdates[1].Value)
		AssertEqual(TargetLevel, LOGGER_MIN_LEVEL)
		AssertEqual(LOGGER_SEVERITY[TargetLevel], _LOGGER_MIN_SEVERITY,
			"publication must refresh the fast flags only after durable success")
		AssertEqual(1, _LSLT_RebuildCalls)

		_LSLT_Reset()
		_LSLT_WriterResult := false
		RejectedLevel := TargetLevel = "WARNING" ? "DEBUG" : "WARNING"
		AssertFalse(LoggerSetLevel(RejectedLevel, _LSLT_Writer,
			_LSLT_Notify, _LSLT_Rebuild))
		AssertEqual(1, _LSLT_WriterCalls)
		AssertEqual(TargetLevel, _LSLT_ObservedLevel)
		AssertEqual(TargetLevel, LOGGER_MIN_LEVEL,
			"a refused durable writer must not publish the candidate level")
		AssertEqual(LOGGER_SEVERITY[TargetLevel], _LOGGER_MIN_SEVERITY)
		AssertEqual(0, _LSLT_RebuildCalls,
			"a rejected candidate must not rebuild a menu projection")
		AssertEqual(1, _LSLT_NotifyCalls)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		ConfigurationFile := SavedPath
		LOGGER_MIN_LEVEL := SavedLevel
		_LoggerRefreshFastFlags()
		_LSLT_Reset()
		if Fixture is Object
			_ScopeOwnerCleanup(Fixture)
	}
}

Test("logger level: terminal barrier refuses disk and live publication "
	. "(config-store-terminal-barrier-logger)",
	_LSLT_TerminalBarrierLeavesLoggerStateUnchanged)

_LSLT_InheritedCriticalStopsAtLoggerAction() {
	global ConfigurationFile, LOGGER_MIN_LEVEL, LOGGER_SEVERITY
	global _LSLT_WriterResult, _LSLT_WriterCritical, _LSLT_NotifyCritical
	global _LSLT_RebuildCritical
	SavedPath := ConfigurationFile
	Fixture := 0
	SavedLevel := LOGGER_MIN_LEVEL
	SavedCritical := A_IsCritical
	try {
		Fixture := _ScopeOwnerFixture()
		ConfigurationFile := Fixture.path
		TargetLevel := SavedLevel = "ERROR" ? "DEBUG" : "ERROR"
		_LSLT_Reset()
		Critical("On")
		AssertTrue(LoggerSetLevel(TargetLevel, _LSLT_Writer,
			_LSLT_Notify, _LSLT_Rebuild))
		AssertTrue(A_IsCritical,
			"LoggerSetLevel must restore its caller's inherited Critical state")
		Critical("Off")
		AssertEqual(1, _LSLT_WriterCritical.Length)
		AssertEqual(0, _LSLT_WriterCritical[1],
			"the log-level writer must run interruptibly")
		AssertEqual(1, _LSLT_RebuildCritical.Length)
		AssertEqual(0, _LSLT_RebuildCritical[1],
			"the post-commit tray rebuild must run interruptibly")

		_LSLT_Reset()
		_LSLT_WriterResult := false
		RejectedLevel := TargetLevel = "WARNING" ? "DEBUG" : "WARNING"
		Critical("On")
		AssertFalse(LoggerSetLevel(RejectedLevel, _LSLT_Writer,
			_LSLT_Notify, _LSLT_Rebuild))
		AssertTrue(A_IsCritical,
			"a refused log-level commit must restore inherited Critical")
		Critical("Off")
		AssertEqual(1, _LSLT_WriterCritical.Length)
		AssertEqual(0, _LSLT_WriterCritical[1])
		AssertEqual(1, _LSLT_NotifyCritical.Length)
		AssertEqual(0, _LSLT_NotifyCritical[1],
			"the log-level failure notification must run interruptibly")
		AssertEqual(0, _LSLT_RebuildCritical.Length)
	} finally {
		Critical("Off")
		ConfigurationFile := SavedPath
		LOGGER_MIN_LEVEL := SavedLevel
		_LoggerRefreshFastFlags()
		_LSLT_Reset()
		try {
			if Fixture is Object
				_ScopeOwnerCleanup(Fixture)
		} finally Critical(SavedCritical)
	}
}
Test("logger level: action defuses inherited Critical through post-commit menu "
	. "rebuild (logger-level-postcommit-inherited-critical)",
	_LSLT_InheritedCriticalStopsAtLoggerAction)

; The runner excludes the lifecycle owner because it also owns suspension and
; timers. The severity tests need its four callback identities, not those effects.
; An unrelated command must remain observable even if a dispatcher catches it.
_LSLT_UnrelatedDebugCommand(*) {
	global _LSLT_UnrelatedDebugCalls
	_LSLT_UnrelatedDebugCalls += 1
	throw Error("Log-level tests must not execute unrelated lifecycle commands")
}

WindowSpy(*) {
	return _LSLT_UnrelatedDebugCommand()
}

ActivateListVars(*) {
	return _LSLT_UnrelatedDebugCommand()
}

ActivateKeyHistory(*) {
	return _LSLT_UnrelatedDebugCommand()
}

ShowHealthCheck(*) {
	return _LSLT_UnrelatedDebugCommand()
}

; The « Detailed log » cases (maintainer, 2026-11-24) the three drivers replay.
_LSLT_DetailedCases() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\logger\parity_vectors.json", "UTF-8"))["detailed_log"]["cases"]
}

; Returns the real Win32 « Detailed log » row and its dispatcher callback.
_LSLT_DetailedRow(Owned, Command := 0) {
	global _MenuDispatchCallbacks, _LSLT_UnrelatedDebugCalls
	PreviousUnrelatedCalls := _LSLT_UnrelatedDebugCalls
	Built := _MI_BuildDebuggingMenu(Command)
	AssertEqual(PreviousUnrelatedCalls, _LSLT_UnrelatedDebugCalls,
		"constructing the Debug menu must not execute unrelated lifecycle commands")
	Owned.Push(Built)
	loop TrayMenuItemCount(Built) {
		Position := A_Index - 1
		if InStr(_CTC_LabelAt(Built, Position), t("menu.debug.detailed_log")) != 1
			continue
		AssertEqual(0, DllCall("GetSubMenu", "ptr", Built.Handle, "int", Position, "ptr"),
			"the detailed log is one switch, not a submenu")
		Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
		Assert(_MenuDispatchCallbacks.Has(Id), "the detailed log uses the real dispatcher")
		return Map("checked", _CTC_IsChecked(Built, Position), "action", _MenuDispatchCallbacks[Id])
	}
	throw Error("the declared Debug « Detailed log » row is missing")
}

_LSLT_DetailedMatrix() {
	global LOGGER_MIN_LEVEL
	SavedLevel := LOGGER_MIN_LEVEL
	Owned := []
	Replayed := 0
	try {
		for Vector in _LSLT_DetailedCases() {
			; The live level is always a resolved name: replay the cases that name one.
			if Vector.Has("stored_absent") || !(Vector["stored"] is String)
				continue
			Resolved := LoggerResolveLevel(Vector["stored"])
			if Resolved["refused"]
				continue
			LOGGER_MIN_LEVEL := Resolved["level"]
			AssertEqual(Vector["ticked"] ? true : false, _LSLT_DetailedRow(Owned)["checked"] ? true : false,
				Vector["id"] . ": the native tick")
			Replayed += 1
		}
		AssertTrue(Replayed >= 4, "the detailed-log matrix replays every declared level case")
	} finally {
		LOGGER_MIN_LEVEL := SavedLevel
		for Built in Owned
			_CTC_ReleaseMenu(Built)
	}
}
Test("logger level: the native « Detailed log » tick replays the shared detailed_log cases", _LSLT_DetailedMatrix)

_LSLT_MenuCommit(Level) {
	return LoggerSetLevel(Level, _LSLT_Writer, _LSLT_Notify, _LSLT_Rebuild)
}

_LSLT_DetailedRefusal() {
	global LOGGER_MIN_LEVEL, ConfigurationFile, _LSLT_WriterResult
	global _LSLT_RebuildCalls, _LSLT_SeenUpdates
	SavedLevel := LOGGER_MIN_LEVEL
	SavedPath := ConfigurationFile
	Fixture := 0
	Owned := []
	try {
		_LSLT_Reset()
		Fixture := _ScopeOwnerFixture()
		ConfigurationFile := Fixture.path
		LOGGER_MIN_LEVEL := "INFO"
		_LoggerRefreshFastFlags()
		Row := _LSLT_DetailedRow(Owned, _LSLT_MenuCommit)
		AssertFalse(Row["checked"], "INFO reads as an unticked detailed log")
		_LSLT_WriterResult := false
		AssertFalse(Row["action"].Call(), "the actual assignment owner refuses DEBUG")
		AssertEqual("DEBUG", _LSLT_SeenUpdates[1].Value, "a click on the unticked switch asks for DEBUG")
		AssertEqual("INFO", LOGGER_MIN_LEVEL, "refusal cannot publish the candidate threshold")
		AssertEqual(0, _LSLT_RebuildCalls, "refusal cannot rebuild a successful-looking tree")
		AssertFalse(_LSLT_DetailedRow(Owned)["checked"], "a refused click leaves the switch unticked")
	} finally {
		ConfigurationFile := SavedPath
		LOGGER_MIN_LEVEL := SavedLevel
		_LoggerRefreshFastFlags()
		for Built in Owned
			_CTC_ReleaseMenu(Built)
		_LSLT_Reset()
		if Fixture is Object
			_ScopeOwnerCleanup(Fixture)
	}
}
Test("logger level: the « Detailed log » click preserves the actual writer refusal", _LSLT_DetailedRefusal)
