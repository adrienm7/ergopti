; tests/fixtures/known_reader_paste_body.ahk

; The receiving Edits of the native render-focus fixtures paste through a known
; reader instead of the Edit control's own single OpenClipboard. explorer.exe,
; cbdhsvc and msrdc.exe open the clipboard after every write, so the control's
; one attempt lost now and then (sends=1, Edit empty) and the fixture measured
; the desktop instead of the driver. The Ctrl+V itself stays the real native
; keystroke, routed by Windows to whichever control has the focus; only the
; reading of the clipboard on reception changes: A_Clipboard retries the open
; for #ClipboardTimeout, and a reader that still loses is reported, not hidden.
global _KRP := {Edits: Map(), Pastes: 0, Failure: 0}

; Make the given Edits receive Ctrl+V through the known reader.
; @param Edits {Gui.Edit*} The fixture's receiving controls.
_KRP_Install(Edits*) {
	global _KRP
	for Edit in Edits
		_KRP.Edits[Edit.Hwnd] := true
	OnMessage(0x102, _KRP_OnChar)
}

_KRP_Uninstall() {
	OnMessage(0x102, _KRP_OnChar, 0)
}

; WM_CHAR 0x16 is the Ctrl+V an Edit turns into its own paste; any other
; character or window keeps the default processing.
_KRP_OnChar(WParam, LParam, Msg, Hwnd) {
	global _KRP
	if WParam != 0x16 || !_KRP.Edits.Has(Hwnd)
		return
	_KRP.Pastes += 1
	try Text := A_Clipboard
	catch as Err {
		_KRP.Failure := Err
		return 0
	}
	; EM_REPLACESEL, undoable, as the control's own paste replaces its selection.
	DllCall("SendMessageW", "Ptr", Hwnd, "UInt", 0xC2, "Ptr", 1, "Str", Text)
	return 0
}

