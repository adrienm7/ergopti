; tests/meta/test_sendinstant_reentrancy_guard.ahk

; ==============================================================================
; MODULE: SendInstant Reentrancy Guard Meta Test
; DESCRIPTION:
; Static source guard for finding
; "send-instant-sleep-clipboard-on-keyboard-thread".
;
; SendInstant defers its clipboard restore via SetTimer, so the user's payload
; stays in A_Clipboard for SEND_INSTANT_PASTE_DELAY_MS. Without a reentrancy
; guard a second SendInstant firing in that window (a fast follow-up wrap key)
; overwrites A_Clipboard before the first paste settles, racing the not-yet-
; restored clipboard and corrupting the user's data.
;
; The fix adds a process-wide _SEND_INSTANT_CLIP_BUSY flag: SendInstant sets it
; before touching the clipboard, the deferred restore clears it, and a second
; SendInstant observing it true skips the clipboard route entirely. This is a
; meta-static test because SendInstant's real clipboard path cannot run in the
; headless runner; it scans source text so a regression that drops the guard
; fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_SIRG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Reentrancy-guard assertions ===========
; ==================================================
; ==================================================

_SIRG_AssertGuardDeclared() {
	Src := _SIRG_ReadSource("infra/hotstrings/hotstring_engine.ahk")
	Assert(InStr(Src, "_SEND_INSTANT_CLIP_BUSY") > 0,
		"hotstring_engine.ahk must declare a _SEND_INSTANT_CLIP_BUSY reentrancy guard (send-instant-sleep-clipboard-on-keyboard-thread)")
}
Test("hotstring_engine: SendInstant declares a clipboard reentrancy guard (send-instant-sleep-clipboard-on-keyboard-thread)", _SIRG_AssertGuardDeclared)

_SIRG_AssertSendInstantChecksGuard() {
	Src := _SIRG_ReadSource("infra/hotstrings/hotstring_engine.ahk")
	Body := _DriverFuncBody("SendInstant")
	Assert(Body != "", "SendInstant(Text) declaration must exist in hotstring_engine.ahk")
	Assert(InStr(Body, "_SEND_INSTANT_CLIP_BUSY") > 0,
		"SendInstant must read/set _SEND_INSTANT_CLIP_BUSY so a second overlapping call skips the clipboard dance (send-instant-sleep-clipboard-on-keyboard-thread)")
}
Test("hotstring_engine: SendInstant body consults the reentrancy guard (send-instant-sleep-clipboard-on-keyboard-thread)", _SIRG_AssertSendInstantChecksGuard)

_SIRG_AssertRestoreClearsGuard() {
	Src := _SIRG_ReadSource("infra/hotstrings/hotstring_engine.ahk")
	Body := _DriverFuncBody("_SendInstant_RestoreClipboard")
	Assert(Body != "", "_SendInstant_RestoreClipboard(OldClip) declaration must exist in hotstring_engine.ahk")
	Assert(InStr(Body, "_SEND_INSTANT_CLIP_BUSY") > 0,
		"the deferred restore must clear _SEND_INSTANT_CLIP_BUSY so the next SendInstant can dance again (send-instant-sleep-clipboard-on-keyboard-thread)")
}
Test("hotstring_engine: deferred restore releases the reentrancy guard (send-instant-sleep-clipboard-on-keyboard-thread)", _SIRG_AssertRestoreClearsGuard)
