; tests/meta/test_sendinstant_clip_contention_guard.ahk

; ==============================================================================
; MODULE: SendInstant Clipboard-Contention Guard Meta Test
; DESCRIPTION:
; Guard for the unbounded clipboard transaction found by the 2026-07-21
; performance audit. The Notepad expansion path takes Critical and holds it
; across the whole SendInstant call, so anything slow in there starves the
; keyboard hook rather than merely delaying one expansion.
;
; CB_SaveAll snapshots EVERY clipboard format, and A_Clipboard retries for
; #ClipboardTimeout -- a full second by default, never overridden in this driver
; -- when another process holds the clipboard open. A remote-desktop client, a
; clipboard manager or a freshly captured full-screen bitmap can therefore
; freeze the keyboard thread for one to two seconds.
;
; The fix probes for contention BEFORE entering the transaction and falls back
; to the clipboard-free {Text} route, which is the same trade the pre-existing
; reentrancy branch already accepts.
;
; ROOT CAUSE ENCODED, three parts:
;   1. the probe must run BEFORE CB_SaveAll -- a check afterwards saves nothing;
;   2. the probe must be CB_IsBusy (an OpenClipboard attempt), never
;      CB_GetSequenceNumber, which is a monotonic counter of past changes and
;      cannot report the current owner;
;   3. every branch that INJECTS the text must report success. A bare return is
;      falsy, and WrapTextIfSelected reads falsy as "emitted nothing" and re-sends
;      the bare symbol on top of the text that just landed.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================================
; ===============================================================
; ======= 1/ The probe precedes the clipboard transaction =======
; ===============================================================
; ===============================================================

_SICG_ProbeRunsBeforeTheSnapshot() {
	Body := _DriverFuncBody("SendInstant")
	Assert(Body != "", "SendInstant() must exist in the driver source")

	ProbePos := InStr(Body, "CB_IsBusy(")
	SnapPos := InStr(Body, "CB_SaveAll(")
	Assert(ProbePos > 0,
		"SendInstant must probe for clipboard contention via CB_IsBusy - the Notepad caller holds Critical across this call, so a contended clipboard starves the keyboard hook for as long as A_Clipboard keeps retrying")
	Assert(SnapPos > 0, "SendInstant must still snapshot the clipboard on its normal path")
	Assert(ProbePos < SnapPos,
		"the contention probe must run BEFORE CB_SaveAll - a probe placed after the snapshot has already paid the stall it exists to avoid")

	Assert(InStr(Body, "CB_HasImage(") > 0,
		"SendInstant must also skip the transaction when the clipboard holds a bitmap - snapshotting every format of a full-screen capture is the other way this path blocks")

	Assert(InStr(SubStr(Body, 1, SnapPos), "CB_GetSequenceNumber") == 0,
		"the contention probe must not be CB_GetSequenceNumber - it is a monotonic counter of past changes and says nothing about who owns the clipboard now")
}
Test("hotstrings: SendInstant probes for clipboard contention before snapshotting (sendinstant-clip-contention)",
	_SICG_ProbeRunsBeforeTheSnapshot)





; ===============================================================
; ===============================================================
; ======= 2/ The probe must not become the blocker itself =======
; ===============================================================
; ===============================================================

_SICG_ProbeClosesWhatItOpens() {
	Body := _DriverFuncBody("CB_IsBusy")
	Assert(Body != "", "CB_IsBusy() must exist in the Clipboard adapter")

	OpenPos := InStr(Body, "OpenClipboard")
	ClosePos := InStr(Body, "CloseClipboard")
	Assert(OpenPos > 0,
		"CB_IsBusy must test ownership with OpenClipboard - it is the only call that answers immediately instead of waiting")
	Assert(ClosePos > 0 and ClosePos > OpenPos,
		"CB_IsBusy must close the clipboard again after a successful open - leaving it open would make the driver itself the process that blocks everyone else, which is the exact failure the probe exists to prevent")
}
Test("clipboard: the contention probe releases the clipboard it opened (sendinstant-clip-contention)",
	_SICG_ProbeClosesWhatItOpens)





; ========================================================
; ========================================================
; ======= 3/ A branch that injects reports success =======
; ========================================================
; ========================================================

; layout.ahk does `if !SendInstant(...) SendNewResult(Symbol)`, so a falsy return
; from a branch that DID inject means the symbol is emitted a second time, on top
; of the text already on screen. The bare `return` in the pre-existing reentrancy
; branch had exactly that defect; both fallback branches now return true.
_SICG_InjectingBranchesReportSuccess() {
	Body := _DriverFuncBody("SendInstant")
	Assert(Body != "", "SendInstant() must exist in the driver source")

	; Count the clipboard-free injections and the successful returns that follow
	; them. Comparing counts avoids a lookahead regex, which can match empty and
	; make the whole assertion pass vacuously.
	Injections := 0
	Pos := 1
	while (Pos := InStr(Body, 'SendInput(Prefix . "{Text}" . Text)', , Pos)) {
		Injections += 1
		Tail := SubStr(Body, Pos, 200)
		Assert(InStr(Tail, "return true") > 0,
			"every clipboard-free injection in SendInstant must be followed by a true return - a falsy return makes WrapTextIfSelected re-emit the bare symbol on top of the text this branch just injected")
		Pos += 1
	}
	Assert(Injections >= 2,
		"SendInstant must keep both clipboard-free fallbacks: the in-flight-restore branch and the contention branch")
}
Test("hotstrings: every clipboard-free SendInstant branch reports that it injected (sendinstant-clip-contention)",
	_SICG_InjectingBranchesReportSuccess)
