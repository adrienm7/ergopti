; tests/meta/test_text_sender_clipboard_failure.ahk
#Requires AutoHotkey v2.0

Test_TextSenderDoesNotPasteAfterClipboardFailure() {
	Body := _DriverFuncBody("_TextSendClipboard")
	WriteCheck := InStr(Body, "if !CB_Write(Text)")
	Paste := InStr(Body, '_AHK_SendInput.Call("^v")')
	Assert(WriteCheck > 0 and Paste > WriteCheck,
		"clipboard injection must check CB_Write before issuing Ctrl+V")
	Assert(InStr(Body, "skipping paste to avoid injecting stale content") > 0,
		"failed clipboard writes must be diagnosable rather than silently pasting stale data")
	StartBody := _DriverFuncBody("_TextSenderStartClipboard")
	Assert(InStr(StartBody, 'Saved == "__CB_SAVE_ERROR__"') > 0,
		"the FIFO owner must reject a failed clipboard snapshot before scheduling injection")
}

Test("text sender: clipboard failures cannot paste stale content", Test_TextSenderDoesNotPasteAfterClipboardFailure)
