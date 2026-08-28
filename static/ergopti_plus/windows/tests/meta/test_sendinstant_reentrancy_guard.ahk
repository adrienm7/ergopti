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
; The process-wide lease now has an immutable owner token. SendInstant claims it
; before the blocking snapshot, its deferred restore releases that exact token,
; and a contender skips the clipboard route entirely.
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
	Src := _SIRG_ReadSource("adapters/clipboard.ahk")
	Assert(InStr(Src, "CB_TryBeginPasteTransaction") > 0
		and InStr(Src, "paste_transaction") > 0,
		"the clipboard adapter must own the process-wide exact-token paste lease")
}
Test("clipboard: adapter declares an exact-owner paste lease (send-instant-sleep-clipboard-on-keyboard-thread)", _SIRG_AssertGuardDeclared)

_SIRG_AssertSendInstantChecksGuard() {
	Src := _SIRG_ReadSource("infra/hotstrings/hotstring_engine.ahk")
	Body := _DriverFuncBody("SendInstant")
	Assert(Body != "", "SendInstant(Text) declaration must exist in hotstring_engine.ahk")
	ClaimPos := InStr(Body, "CB_TryBeginPasteTransaction(")
	SnapshotPos := InStr(Body, "CB_SaveAll()")
	Assert(ClaimPos > 0 and SnapshotPos > ClaimPos,
		"SendInstant must claim the exclusive paste token before its blocking clipboard snapshot")
}
Test("hotstring_engine: SendInstant body consults the reentrancy guard (send-instant-sleep-clipboard-on-keyboard-thread)", _SIRG_AssertSendInstantChecksGuard)

_SIRG_AssertRestoreClearsGuard() {
	Src := _SIRG_ReadSource("infra/hotstrings/hotstring_engine.ahk")
	Body := _DriverFuncBody("_SendInstant_RestoreClipboard")
	Assert(Body != "", "_SendInstant_RestoreClipboard(OldClip) declaration must exist in hotstring_engine.ahk")
	Assert(InStr(Body, "CB_RestoreOwnedAllEventually") > 0
		and InStr(Body, "OwnerToken") > 0,
		"the deferred restore must transfer its exact token to retrying terminal cleanup")
}
Test("hotstring_engine: deferred restore releases the reentrancy guard (send-instant-sleep-clipboard-on-keyboard-thread)", _SIRG_AssertRestoreClearsGuard)
