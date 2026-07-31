; tests/meta/test_remapped_list_unconditional.ahk

; ==============================================================================
; MODULE: RemappedList Unconditional Assignment Meta-Test
; DESCRIPTION:
; Structural regression for the RemappedList population fix in modules/keymap/layout.ahk.
;
; Before the fix, RemapKey() only inserted the Character → ScanCode entry into
; RemappedList when AlternativeCharacter was empty (i.e. when no alternative
; character was provided). Keys called with a non-empty AlternativeCharacter —
; which includes accented letters (e.g. é, à, ç) and the magic key (★) — were
; silently omitted from RemappedList. This caused any lookup against RemappedList
; for those characters to fail, breaking features that rely on knowing which scan
; codes are under Ergopti control.
;
; The fix moves the RemappedList assignment BEFORE the if/else so it always runs
; regardless of whether AlternativeCharacter is present.
;
; This test inspects layout.ahk source and asserts:
;   1. RemappedList[Character] := ScanCode appears BEFORE the if AlternativeCharacter
;      check in RemapKey().
;   2. The assignment is NOT inside the if == "" branch (it is unconditional).
; ==============================================================================

#Requires AutoHotkey v2.0




; =============================================================
; =============================================================
; ======= 1/ Assertions =======================================
; =============================================================
; =============================================================

_RLUA_AssignmentPresent() {
	; Move-resilient: extract the RemapKey body via the bare-name helper instead of
	; a pinned layout.ahk read + 800-char window. The exact body is strictly better
	; for the positional checks below.
	block := _DriverFuncBody("RemapKey")
	Assert(InStr(block, "RemappedList[Character] := ScanCode") > 0,
		"layout.ahk: RemapKey() must assign RemappedList[Character] := ScanCode for all remapped keys")
}
Test("RemapKey: RemappedList[Character] := ScanCode assignment present (remapped-list-unconditional)", _RLUA_AssignmentPresent)


_RLUA_AssignmentBeforeAlternativeCheck() {
	block := _DriverFuncBody("RemapKey")
	posAssign := InStr(block, "RemappedList[Character] := ScanCode")
	; The guarded hotkey for AlternativeCharacter must come AFTER the assignment.
	posAlt    := InStr(block, 'AlternativeCharacter != ""')
	posAlt2   := InStr(block, "{Text}")
	Assert(posAssign > 0,
		"layout.ahk: RemappedList assignment must be present in RemapKey()")
	; posAlt or posAlt2 must exist and be after posAssign.
	posCheck := (posAlt > 0) ? posAlt : posAlt2
	Assert(posCheck > 0,
		"layout.ahk: AlternativeCharacter branch must still be present in RemapKey()")
	Assert(posAssign < posCheck,
		"layout.ahk: RemappedList[Character] := ScanCode must precede the AlternativeCharacter guard — it must be unconditional")
}
Test("RemapKey: RemappedList assignment precedes AlternativeCharacter branch (remapped-list-unconditional)", _RLUA_AssignmentBeforeAlternativeCheck)


_RLUA_AssignmentNotInsideEmptyStringBranch() {
	block := _DriverFuncBody("RemapKey")
	; The old conditional was: if AlternativeCharacter == "" { RemappedList[...] }
	; After the fix, the == "" check must no longer gate the assignment.
	posAssign := InStr(block, "RemappedList[Character] := ScanCode")
	posEmptyGuard := InStr(block, 'AlternativeCharacter == ""')
	if (posEmptyGuard = 0) {
		; The guard is gone entirely, which is the strongest form of the fix. Say so
		; by asserting what remains true — that the assignment is still THERE. An
		; Assert(true, "") here also passed when the assignment had been deleted
		; along with the guard, and RemapKey stopped recording remaps at all.
		Assert(posAssign > 0,
			"the RemappedList assignment must still exist — with the empty-string guard gone, "
			. "nothing else in this test would notice its removal")
		return
	}
	; If the == "" guard still exists, the assignment must come BEFORE it.
	Assert(posAssign < posEmptyGuard,
		'layout.ahk: RemappedList assignment must not be inside the AlternativeCharacter == empty string branch')
}
Test("RemapKey: RemappedList assignment not guarded by AlternativeCharacter == empty (remapped-list-unconditional)", _RLUA_AssignmentNotInsideEmptyStringBranch)
