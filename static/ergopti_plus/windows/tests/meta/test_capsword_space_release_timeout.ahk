; tests/meta/test_capsword_space_release_timeout.ahk

; ==============================================================================
; MODULE: CapsWord Space Release Timeout Meta Test
; DESCRIPTION:
; Keeps the CapsWord exit Space transaction bounded and cleanup-owned.
;
; A secure-desktop transition or device disconnect can lose SC039 Up. The Space
; hotkey must use the shared stuck-release timeout and a finally so CapsWord,
; its listeners, and its LED are always reset.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Bounded Space release assertion =========
; =====================================================
; =====================================================

_CSRT_CapsWordSpaceExitIsBounded() {
	Body := _DriverFuncBody("DisableCapsWord")
	Assert(Body != "", "DisableCapsWord must exist")
	Src := _DriverDirConcat("modules/shortcuts")
	Anchor := "SC039::"
	Start := InStr(Src, Anchor)
	Assert(Start > 0, "CapsWord Space hotkey must exist")
	Segment := SubStr(Src, Start, 450)
	Assert(InStr(Segment, "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC") > 0,
		"CapsWord Space exit must use the shared stuck-release timeout instead of an unbounded KeyWait (capsword-space-release-timeout)")
	Assert(InStr(Segment, "finally") > 0 and InStr(Segment, "DisableCapsWord()") > 0,
		"CapsWord Space exit must run DisableCapsWord in finally so a lost SC039 Up cannot keep state/listeners/LED active (capsword-space-release-timeout)")
}
Test("capsword: Space exit has a shared timeout and finally cleanup (capsword-space-release-timeout)", _CSRT_CapsWordSpaceExitIsBounded)
