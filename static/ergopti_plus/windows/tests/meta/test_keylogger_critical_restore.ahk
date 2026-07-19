; tests/meta/test_keylogger_critical_restore.ahk

; ==============================================================================
; MODULE: Keylogger Critical-State Restore Meta Test
; DESCRIPTION:
; Guards every short keylogger transaction that temporarily enables Critical.
; Calling Critical("Off") at the end clobbers a caller that was already critical,
; allowing a timer to interrupt a shared-state mutation and lose input events.
; ==============================================================================

#Requires AutoHotkey v2.0


_KCR_AssertPreservesCallerCritical(FuncName, RequiredFragment) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist")
	StartIdx := InStr(Body, "previous_critical := Critical(" . Chr(34) . "On" . Chr(34) . ")")
	FinallyIdx := InStr(Body, "finally")
	RestoreIdx := InStr(Body, "Critical(previous_critical)")
	WorkIdx := InStr(Body, RequiredFragment, , StartIdx)
	Assert(StartIdx > 0 and FinallyIdx > StartIdx and RestoreIdx > FinallyIdx,
		FuncName . " must restore the caller's Critical state in finally (keylogger-critical-restore)")
	Assert(WorkIdx > StartIdx and WorkIdx < FinallyIdx,
		FuncName . " must keep its shared-state mutation inside the restore-owned transaction (keylogger-critical-restore)")
	Assert(InStr(Body, 'Critical("Off")') = 0,
		FuncName . " must not clobber a caller Critical state with Critical('Off') (keylogger-critical-restore)")
}

_KCR_FlushSnapshotPreservesCritical() {
	_KCR_AssertPreservesCallerCritical("KL_FlushBuffer", "Keylogger.buffer_events    := []")
}
Test("keylogger: flush snapshot restores caller Critical state (keylogger-critical-restore)", _KCR_FlushSnapshotPreservesCritical)


_KCR_IngestQueueTransactionsPreserveCritical() {
	_KCR_AssertPreservesCallerCritical("KL_IngestOnce", "Keylogger._pending_entries := []")
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(InStr(Body, "Keylogger._pending_entries.InsertAt") > 0,
		"KL_IngestOnce must retain its failure requeue transaction (keylogger-critical-restore)")
	Assert(InStr(Body, "Critical(previous_critical)", false, InStr(Body, "Keylogger._pending_entries.InsertAt")) > 0,
		"KL_IngestOnce requeue transaction must restore caller Critical state (keylogger-critical-restore)")
}
Test("keylogger: ingest queue transactions restore caller Critical state (keylogger-critical-restore)", _KCR_IngestQueueTransactionsPreserveCritical)

_KCR_MouseAndRoiTransactionsPreserveCritical() {
	_KCR_AssertPreservesCallerCritical("KL_Mouse_FlushScroll", "KLMouse.scroll_ticks   := 0")
	_KCR_AssertPreservesCallerCritical("KL_Roi_PruneWordCounts", "KLRoi.word_counts.Delete")
	_KCR_AssertPreservesCallerCritical("KL_Roi_HalflifeTick", "snapshot[trig] := last_tick")
}
Test("keylogger: mouse and ROI snapshots preserve caller Critical state (keylogger-critical-restore)", _KCR_MouseAndRoiTransactionsPreserveCritical)
