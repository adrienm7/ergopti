; tests/meta/platform/remap/keys/test_capsword_space_release_timeout.ahk

; ==============================================================================
; MODULE: CapsWord Space Release Timeout Meta Test
; DESCRIPTION:
; Keeps the CapsWord exit Space transaction bounded and cleanup-owned.
;
; A secure-desktop transition or device disconnect can lose SC039 Up. The Space
; hotkey must use the shared stuck-release timeout and a finally so CapsWord,
; its listeners and LED retire with the original activation, while an
; off/on performed during that wait keeps its replacement active.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Bounded Space release assertion =========
; =====================================================
; =====================================================

_CSRT_CapsWordSpaceExitIsBounded() {
	Body := _StripFullLineComments(_DriverFuncBody("CapsWordAutoOffNativeKey"))
	Assert(Body != "", "the actual native delimiter owner must exist")
	Src := _StripFullLineComments(_DriverDirConcat("modules/shortcuts"))
	Assert(Src != "", "the actual native hotkey source must exist")
	Assert(InStr(Src, 'SC039:: CapsWordAutoOffNativeKey("Space")')
		&& InStr(Src, 'SC01C:: CapsWordAutoOffNativeKey("Enter")'),
		"both actual native delimiter hotkeys must enter the same owner")
	Assert(InStr(Body, 'WaitFn.Call("SC039", "T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)'),
		"CapsWord Space exit must retain its shared bounded release wait (capsword-space-release-timeout)")
	Captured := InStr(Body, "Generation := CapsWordAutoOff.Generation")
	Sent := InStr(Body, "SendFn.Call(Key, [])")
	FinallyPosition := InStr(Body, "finally")
	Retired := InStr(Body, '_CapsWordAutoOffEnd(Generation, "native " . Key)')
	Assert(Captured > 0 && Sent > Captured && FinallyPosition > Sent && Retired > FinallyPosition,
		"native delimiter cleanup must retain its activation before send and retire it in finally")
}
Test("capsword: Space exit has a shared timeout and finally cleanup (capsword-space-release-timeout)", _CSRT_CapsWordSpaceExitIsBounded)
