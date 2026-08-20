; tests/meta/test_text_sender_clipboard_restore.ahk

; ==============================================================================
; MODULE: Clipboard Restore On Every Post-Write Bail-Out
; DESCRIPTION:
; _TextSendClipboard writes the payload into the user's real clipboard before it
; can paste it. From that moment on, EVERY exit path owns a cleanup obligation:
; whatever else goes wrong, the user's own clipboard content has to come back.
;
; The obligation was met on four of the five post-write bail-outs. The fifth —
; the one taken when CB_GetSequenceNumber() cannot produce an ownership proof —
; returned without restoring, because the shared restore helper deliberately
; refuses to act without that very proof. The two guards composed into a hole:
; the helper's refusal was correct in isolation, and so was calling it, but on
; this path calling it was the same as doing nothing. The injected text then sat
; in the clipboard until the user next copied something, so the next Ctrl+V in
; any application pasted an expansion — or a password the driver had just typed.
;
; The guards below pin the repaired branch, its sibling that always did the right
; thing, and the property that makes the new helper worth having — that it does
; NOT ask for the proof it exists to replace.
;
; There is deliberately no sweep demanding a restore on every post-write exit:
; the branch taken when the sequence CHANGED must not restore, because another
; owner holds the clipboard by then. A blanket rule would fail on that correct
; answer, and a guard that punishes the right behaviour gets deleted rather than
; obeyed.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; The write after which the cleanup obligation exists. Everything before it can
; return freely — the user's clipboard is still untouched at that point.
global _TSCR_WRITE_CALL := "CB_Write("

; Any of these discharges the obligation on a bail-out path.
global _TSCR_RESTORE_CALLS := ["_TextSendRestoreClipboard(", "_TextSendForceRestoreClipboard(", "CB_RestoreAll("]





; ===============================
; ===============================
; ======= 2/ Test Helpers =======
; ===============================
; ===============================

; True when any recognised restore call appears in Segment.
; @param Segment {String} Source slice to search.
; @returns {Integer} 1 when a restore call is present, 0 otherwise.
_TSCR_HasRestore(Segment) {
	global _TSCR_RESTORE_CALLS
	for Call in _TSCR_RESTORE_CALLS {
		if InStr(Segment, Call)
			return 1
	}
	return 0
}





; =========================
; =========================
; ======= 3/ Guards =======
; =========================
; =========================

; The specific branch the fix is about, named so a regression reads clearly.
_TSCR_OwnershipBailOutRestores() {
	Body := _DriverFuncBody("_TextSendClipboard")
	Assert(Body != "", "_TextSendClipboard() must exist in the driver source")

	WriteAt := InStr(Body, _TSCR_WRITE_CALL)
	Assert(WriteAt > 0, "_TextSendClipboard must still write the payload through CB_Write()")

	BailAt := InStr(Body, "if !OwnedSequence")
	Assert(BailAt > WriteAt,
		"the ownership-unavailable bail-out must still sit AFTER the clipboard write — if it moved above the write there is no obligation to discharge and this guard is measuring the wrong thing")

	; From the bail-out to the return that closes it.
	ReturnAt := InStr(Body, "return", false, BailAt)
	Assert(ReturnAt > BailAt, "the ownership-unavailable bail-out must return")
	Segment := SubStr(Body, BailAt, ReturnAt - BailAt)

	Assert(_TSCR_HasRestore(Segment),
		"the bail-out taken when clipboard ownership cannot be proven must restore the user's clipboard before returning. CB_Write has already succeeded at that point, so returning without a restore leaves the injected payload — an expansion, or a password the driver just typed — in the clipboard for the next Ctrl+V in any application")
}

; The force variant only earns its existence by NOT requiring the proof its
; sibling requires; gating it on a sequence number restores the original hole.
_TSCR_ForceRestoreDoesNotRequireTheProof() {
	Body := _DriverFuncBody("_TextSendForceRestoreClipboard")
	Assert(Body != "", "_TextSendForceRestoreClipboard() must exist in the driver source")

	Assert(InStr(Body, "OwnedSequence") == 0 and InStr(Body, "CB_GetSequenceNumber(") == 0,
		"_TextSendForceRestoreClipboard must not consult the clipboard sequence. It exists precisely for the path where that sequence is unavailable, so re-introducing the check would make it a no-op there and silently restore the original defect")

	Assert(InStr(Body, "_TEXT_CLIPBOARD_GENERATION") > 0,
		"_TextSendForceRestoreClipboard must still honour the generation counter — a newer injection that owns the clipboard slot has to win over a late restore")

	Assert(InStr(Body, "CB_RestoreAll(") > 0,
		"_TextSendForceRestoreClipboard must actually restore the snapshot")
}

; The ClipWait timeout is the sibling bail-out that owns the same obligation and
; already met it. Pinning it stops a future edit from "simplifying" the two paths
; into one that drops the restore.
;
; Deliberately NOT a sweep over every post-write bail-out: the branch taken when
; the sequence CHANGED must not restore, because a different owner holds the
; clipboard by then and restoring would clobber the user's newer content. A guard
; that demanded a restore everywhere would fail on that correct answer.
_TSCR_ClipWaitTimeoutRestores() {
	Body := _DriverFuncBody("_TextSendClipboard")
	Assert(Body != "", "_TextSendClipboard() must exist in the driver source")

	At := InStr(Body, "if !ClipWait(")
	Assert(At > 0, "_TextSendClipboard must still bail out when ClipWait times out")

	ReturnAt := InStr(Body, "return", false, At)
	Assert(ReturnAt > At, "the ClipWait bail-out must return")

	Assert(_TSCR_HasRestore(SubStr(Body, At, ReturnAt - At)),
		"the ClipWait-timeout bail-out must restore the user's clipboard before returning — the payload is already written at that point and this transaction still owns it")
}





; ===============================
; ===============================
; ======= 4/ Registration =======
; ===============================
; ===============================

Test("meta text-sender-clipboard: the ownership-unavailable bail-out restores the clipboard",
	_TSCR_OwnershipBailOutRestores)
Test("meta text-sender-clipboard: the force restore does not require the proof it exists to replace",
	_TSCR_ForceRestoreDoesNotRequireTheProof)
Test("meta text-sender-clipboard: the ClipWait-timeout bail-out restores the clipboard",
	_TSCR_ClipWaitTimeoutRestores)
