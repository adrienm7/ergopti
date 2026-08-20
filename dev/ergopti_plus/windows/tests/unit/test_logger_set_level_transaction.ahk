; tests/unit/test_logger_set_level_transaction.ahk

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
	SavedLevel := LOGGER_MIN_LEVEL
	Bundle := false
	try {
		_LSLT_Reset()
		ConfigurationFile := A_Temp . "\ergopti_logger_level.toml"
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
	SavedLevel := LOGGER_MIN_LEVEL
	SavedCritical := A_IsCritical
	try {
		ConfigurationFile := A_Temp . "\ergopti_logger_level_critical.toml"
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
		Critical(SavedCritical)
	}
}
Test("logger level: action defuses inherited Critical through post-commit menu "
	. "rebuild (logger-level-postcommit-inherited-critical)",
	_LSLT_InheritedCriticalStopsAtLoggerAction)
