; tests/meta/test_text_sender_clipboard_sequence_ownership.ahk

; A queued clipboard injection must never paste a user copy made while it was
; waiting, nor restore an older snapshot over that copy after its own paste.

#Requires AutoHotkey v2.0

_TSCSO_ClipboardTransactionOwnsSequence() {
	Body := _DriverFuncBody("_TextSendClipboard")
	Assert(Body != "", "_TextSendClipboard must exist")
	OwnedPos := InStr(Body, "OwnedSequence := CB_GetSequenceNumber()")
	PastePos := InStr(Body, '_TextSenderSendInput("^v", "clipboard paste")')
	Assert(OwnedPos > 0 and PastePos > OwnedPos,
		"clipboard injection must capture an ownership sequence before Ctrl+V")
	RecheckPos := InStr(Body, "CB_GetSequenceNumber() != OwnedSequence")
	Assert(RecheckPos > OwnedPos and RecheckPos < PastePos,
		"clipboard injection must reject a changed sequence before Ctrl+V so it never pastes a user copy")
	Restore := _DriverFuncBody("_TextSendRestoreClipboard")
	Assert(InStr(Restore, "CB_GetSequenceNumber() != OwnedSequence") > 0,
		"deferred clipboard restore must preserve a newer user clipboard sequence")
	Start := _DriverFuncBody("_TextSenderStartClipboard")
	Assert(InStr(Start, "Saved := CB_SaveAll()") > 0,
		"each FIFO head must snapshot at ownership time, not reuse a stale session snapshot")
	SenderBody := _DriverFuncBody("TextSend")
	Assert(InStr(SenderBody, "CB_SaveAll()") == 0,
		"TextSend must not snapshot on the keyboard caller before FIFO ownership")
}
Test("text sender: clipboard transactions preserve intervening user copies (text-sender-clipboard-sequence-ownership)", _TSCSO_ClipboardTransactionOwnsSequence)
