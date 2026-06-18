; tests/meta/test_keylogger_rollover_force_ingest.ahk

; ==============================================================================
; MODULE: Keylogger Day-Rollover Force-Ingest Test (F21)
; DESCRIPTION:
; Regression guard for the bug where KL_DayRollover() called KL_IngestOnce()
; (no arguments) and then deleted today.log. If the user was typing at midnight
; the idle-defer guard inside KL_IngestOnce would return early, leaving
; un-ingested lines on disk. The subsequent FileDelete then permanently discarded
; those lines.
;
; THE FIX: KL_IngestOnce gains a `force` parameter (default false). KL_DayRollover
; calls KL_IngestOnce(true) to bypass the idle guard and guarantee that every
; line in today.log reaches data.sql before the file is deleted.
;
; This test asserts two source-level invariants:
;   1. KL_IngestOnce signature declares the `force` parameter.
;   2. KL_DayRollover calls KL_IngestOnce(true), not KL_IngestOnce().
; ==============================================================================

#Requires AutoHotkey v2.0




; Read the keylogger source relative to the tests/meta directory.
_KLRD_ReadSource(RelPath) {
	Root := A_ScriptDir . "\..\..\"
	return FileRead(Root . RelPath)
}

; Extract a function body by searching for the flush-left closing brace that
; terminates the first function definition matching FuncDef.
_KLRD_FuncBody(Src, FuncDef) {
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

_MetaCheckRolloverForceIngest() {
	try {
		Src := _KLRD_ReadSource("modules\keylogger\keylogger.ahk")
	} catch {
		; File unreadable — skip rather than fail, test environment issue
		return
	}

	; Strip block comments so /*…*/ regions cannot fool string searches
	Src := RegExReplace(Src, "(?s)/\*.*?\*/", "")


	; --- Assert 1: KL_IngestOnce signature declares the `force` parameter ---
	; The signature must be KL_IngestOnce(force ...) so the caller can bypass
	; the idle-defer guard at day rollover.
	SigLine := _KLRD_FuncBody(Src, "KL_IngestOnce(")
	Assert(StrLen(SigLine) > 0,
		"KL_IngestOnce must be present in keylogger.ahk")

	; Check the declaration line (up to first `{`) for the `force` keyword
	DeclEnd := InStr(SigLine, "{")
	if (DeclEnd = 0)
		DeclEnd := StrLen(SigLine) + 1
	Decl := SubStr(SigLine, 1, DeclEnd)

	Assert(InStr(Decl, "force") > 0,
		"KL_IngestOnce must declare a 'force' parameter in its signature — "
		. "without it KL_DayRollover cannot bypass the idle-defer guard to "
		. "guarantee today.log is fully ingested before deletion")


	; --- Assert 2: KL_DayRollover calls KL_IngestOnce(true) ---
	RolloverBody := _KLRD_FuncBody(Src, "KL_DayRollover(")
	Assert(StrLen(RolloverBody) > 0,
		"KL_DayRollover must be present in keylogger.ahk")

	Assert(InStr(RolloverBody, "KL_IngestOnce(true)") > 0,
		"KL_DayRollover must call KL_IngestOnce(true) (not KL_IngestOnce()) — "
		. "the force flag is mandatory to ensure all pending entries are written "
		. "to data.sql before today.log is deleted at midnight rollover")
}

Test("meta keylogger F21: KL_IngestOnce has force parameter and rollover passes true",
	_MetaCheckRolloverForceIngest)

_MetaCheckRolloverNoBareCall() {
	try {
		Src := _KLRD_ReadSource("modules\keylogger\keylogger.ahk")
	} catch {
		return
	}

	Src := RegExReplace(Src, "(?s)/\*.*?\*/", "")
	RolloverBody := _KLRD_FuncBody(Src, "KL_DayRollover(")
	Assert(StrLen(RolloverBody) > 0,
		"KL_DayRollover must be present in keylogger.ahk")

	; Confirm the bare KL_IngestOnce() call (no argument) is gone from the
	; rollover body — only the forced call KL_IngestOnce(true) must remain.
	BareCallPos := InStr(RolloverBody, "KL_IngestOnce()")
	Assert(BareCallPos = 0,
		"KL_DayRollover must NOT call KL_IngestOnce() (no args) — it must always "
		. "pass true so the idle-defer guard is bypassed before today.log is deleted "
		. "(bare call found at offset " . BareCallPos . " in rollover body)")
}

Test("meta keylogger F21: KL_DayRollover does not contain bare KL_IngestOnce() call",
	_MetaCheckRolloverNoBareCall)
