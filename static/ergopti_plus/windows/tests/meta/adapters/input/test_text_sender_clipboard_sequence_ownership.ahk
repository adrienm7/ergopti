; tests/meta/adapters/input/test_text_sender_clipboard_sequence_ownership.ahk

; A queued clipboard injection must never paste a user copy made while it was
; waiting, nor restore an older snapshot over that copy after its own paste.

#Requires AutoHotkey v2.0

_TSCSO_ClipboardTransactionOwnsSequence() {
	Body := _DriverFuncBody("_TextSendClipboard")
	Assert(Body != "", "_TextSendClipboard must exist")
	OwnedPos := InStr(Body, "CB_WriteTextWithReceipt(Text, &OwnedSequence)")
	Receipt := _DriverFuncBody("CB_WriteTextWithReceipt")
	Assert(Receipt != "", "the actual receipt owner must be present")
	BeforePos := InStr(Receipt, "BeforeMutation := CBClipboardOwner.mutation_id")
	SetterPos := InStr(Receipt, "Published := CB_Write(Text)")
	Assert(BeforePos > 0 and SetterPos > BeforePos,
		"the actual setter must follow the captured mutation origin")
	Assert(InStr(Receipt, "CBClipboardOwner.mutation_id == BeforeMutation + 1") > SetterPos
		and InStr(Receipt, 'DllCall("User32\GetClipboardOwner", "Ptr") != A_ScriptHwnd') > SetterPos
		and InStr(Receipt, 'StrGet(Pointer, -Length, "UTF-16") == Text') > SetterPos,
		"receipt ownership requires the exact mutation, native owner and complete UTF-16 payload")
	PastePos := InStr(Body, '_TextSenderSendInput("^v", "clipboard paste")')
	Assert(OwnedPos > 0 and PastePos > OwnedPos,
		"clipboard injection must capture an ownership sequence before Ctrl+V")
	RecheckPos := InStr(Body, "CB_GetSequenceNumber() != OwnedSequence")
	Assert(RecheckPos > OwnedPos and RecheckPos < PastePos,
		"clipboard injection must reject a changed sequence before Ctrl+V so it never pastes a user copy")
	Restore := _DriverFuncBody("_TextSendRestoreClipboard")
	Debt := _DriverFuncBody("CB_RestoreOwnedAllEventually")
	Retry := _DriverFuncBody("CB_RetryRestoreDebt")
	Assert(InStr(Restore, "CB_RestoreOwnedAllEventually(Saved, OwnedSequence,") > 0
		and InStr(Restore, "_TEXT_CLIPBOARD_OWNER_TOKEN") > 0,
		"deferred clipboard restore must transfer its exact snapshot, sequence and owner")
	Assert(InStr(Debt, '"expected_sequence", ExpectedSequence') > 0
		and InStr(Retry, 'CurrentSequence != Debt["expected_sequence"]') > 0
		and InStr(Retry, 'Debt["expected_sequence"] and !CurrentSequence') > 0,
		"the real restore coordinator must distinguish a newer clipboard from an unavailable probe")
	Start := _DriverFuncBody("_TextSenderStartClipboard")
	Assert(InStr(Start, "Saved := CB_SaveAll()") > 0,
		"each FIFO head must snapshot at ownership time, not reuse a stale session snapshot")
	SenderBody := _DriverFuncBody("TextSend")
	Assert(InStr(SenderBody, "CB_SaveAll()") == 0,
		"TextSend must not snapshot on the keyboard caller before FIFO ownership")
}
Test("text sender: clipboard transactions preserve intervening user copies (text-sender-clipboard-sequence-ownership)", _TSCSO_ClipboardTransactionOwnsSequence)
