; tests/meta/test_text_sender_clipboard_generation_recheck.ahk

; ==============================================================================
; MODULE: TextSender Clipboard Generation Re-check Meta Test
; DESCRIPTION:
; Regression guard for MED-01: fix-text-sender-clipboard-paste-reentrancy.
;
; _TextSendClipboard increments _TEXT_CLIPBOARD_GENERATION and stores a local
; snapshot before calling CB_Write and ClipWait. If a second concurrent
; TextSend call arrives while the first is inside ClipWait, the second call
; increments the counter and overwrites the clipboard with its own text.
; When the first call returns from ClipWait, it must re-check whether the
; generation still matches before issuing Ctrl+V — otherwise it pastes the
; second injection's text a second time (clobbering the output) and also
; triggers a premature clipboard restore that removes the second injection's
; text while it is still in flight.
;
; The fix adds, immediately after the ClipWait block and before
; _TextSenderSendInput("^v", "clipboard paste"), a generation re-check:
;
;   if (Generation != _TEXT_CLIPBOARD_GENERATION) {
;       CB_RestoreAll(Saved)
;       return
;   }
;
; This test asserts that the body of _TextSendClipboard contains a generation
; guard between the ClipWait block and the SendInput call.
;
; SCOPE: source introspection of adapters/text_sender.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_TSCGR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}

; Extracts the body of _TextSendClipboard from the source.
_TSCGR_ExtractBody(Src) {
	FnPos := InStr(Src, "_TextSendClipboard(Text, Saved, Callback")
	if (!FnPos)
		return ""
	depth := 0
	i := FnPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, FnPos, i - FnPos + 1)
		}
		i++
	}
	return SubStr(Src, FnPos)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_TSCGR_CheckGenerationRecheck() {
	Src := _TSCGR_ReadSource("adapters/text_sender.ahk")
	Assert(Src != "", "adapters/text_sender.ahk must be readable")

	Body := _TSCGR_ExtractBody(Src)
	Assert(Body != "", "_TextSendClipboard must be present in adapters/text_sender.ahk")

	; After ClipWait there must be a generation re-check before the paste.
	ClipWaitPos  := InStr(Body, "ClipWait(")
	RecheckPos   := InStr(Body, "Generation != _TEXT_CLIPBOARD_GENERATION", , Max(1, ClipWaitPos))
	SendInputPos := InStr(Body, '_TextSenderSendInput("^v", "clipboard paste")')

	Assert(ClipWaitPos > 0, "_TextSendClipboard must call ClipWait()")
	Assert(RecheckPos > 0,
		"_TextSendClipboard must re-check generation after ClipWait (MED-01 fix)")
	Assert(SendInputPos > 0, "_TextSendClipboard must send Ctrl+V through the guarded TextSender helper")

	; Order: ClipWait < re-check < SendInput
	Assert(ClipWaitPos < RecheckPos && RecheckPos < SendInputPos,
		"Generation re-check must appear between ClipWait and the guarded Ctrl+V send in _TextSendClipboard (MED-01)")

	; The re-check block must restore only through the ownership-checked helper.
	RecheckBlock := SubStr(Body, RecheckPos, SendInputPos - RecheckPos)
	Assert(InStr(RecheckBlock, "_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)"),
		"Generation mismatch branch must route restoration through the sequence-checked helper before returning (MED-01)")
}


Test("meta fix-text-sender-clipboard-reentrancy: post-ClipWait generation re-check present and ordered",
	_TSCGR_CheckGenerationRecheck)
