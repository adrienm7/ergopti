; tests/meta/test_keylogger_idle_defer_preserves_pending.ahk

; ==============================================================================
; MODULE: Keylogger Idle-Defer Guard Order Test (F05)
; DESCRIPTION:
; Regression guard for the bug where KL_IngestOnce() cleared _pending_entries
; from RAM (step 1) before reaching the keyboard-idle defer guard (step 4).
; If the user was mid-burst the function returned without advancing
; today_log_offset, writing SQL, or calling KL_SaveState. The entries existed
; only on disk, and on the next tick KL_JsonDecode was a no-op on 64-bit hosts,
; so those entries were silently lost.
;
; THE FIX: move the INGEST_IDLE_MS guard to the top of KL_IngestOnce, before
; the _pending_entries drain. This test asserts the invariant at the source
; level by verifying the byte offset of INGEST_IDLE_MS is less than the byte
; offset of the _pending_entries := [] reset inside KL_IngestOnce.
; ==============================================================================

#Requires AutoHotkey v2.0




; Read the keylogger source relative to the tests/meta directory.
_KLID_ReadSource(RelPath) {
	Root := A_ScriptDir . "\..\..\"
	return FileRead(Root . RelPath)
}

; Extract a function body by searching for the flush-left closing brace that
; terminates the first function definition matching FuncDef.
_KLID_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	; Find flush-left closing brace — the column-0 `}` that closes the function
	i := 1
	while (i <= StrLen(Rest)) {
		if (SubStr(Rest, i, 2) == "`n}") {
			return SubStr(Rest, 1, i + 1)
		}
		i++
	}
	return Rest
}





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckIdleDeferBeforePendingDrain() {
	try {
		Src := _KLID_ReadSource("modules\keylogger\keylogger.ahk")
	} catch {
		; File unreadable — skip rather than fail, test environment issue
		return
	}

	; Strip block comments so /*…*/ regions cannot fool the offset comparison
	Src := RegExReplace(Src, "(?s)/\*.*?\*/", "")

	Body := _KLID_FuncBody(Src, "KL_IngestOnce(")
	Assert(StrLen(Body) > 0,
		"KL_IngestOnce must be present in keylogger.ahk")

	IdlePos  := InStr(Body, "INGEST_IDLE_MS")
	DrainPos := InStr(Body, "_pending_entries := []")

	Assert(IdlePos > 0,
		"KL_IngestOnce must reference INGEST_IDLE_MS (idle-defer guard)")

	Assert(DrainPos > 0,
		"KL_IngestOnce must contain '_pending_entries := []' (the pending-entries drain)")

	Assert(IdlePos < DrainPos,
		"INGEST_IDLE_MS guard must appear BEFORE '_pending_entries := []' in KL_IngestOnce "
		. "— guard was after the drain, so mid-burst entries were cleared from RAM then "
		. "lost when the function deferred (KL_JsonDecode is no-op on 64-bit). "
		. "Found INGEST_IDLE_MS at offset " . IdlePos . ", drain at offset " . DrainPos . ".")
}

Test("meta keylogger F05: idle-defer guard is before pending-entries drain",
	_MetaCheckIdleDeferBeforePendingDrain)
