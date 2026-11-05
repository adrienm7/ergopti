; tests/fixtures/selection_capture_control_focus_body.ahk

; The first real GetSelectionAsync clipboard snapshot renders a native delayed
; format. Rendering may move focus between two private controls in ONE HWND,
; without changing physical input or the foreground-window identity. No context
; result is fabricated. Copy, transform, clipboard publication and paste are real.
if A_Args.Length != 4 || A_Args[1] != "--allow-explicit-owned-clipboard-render-focus"
	throw Error("Explicit owned-window/clipboard render focus opt-in is required.")
if !(A_Args[2] == "current" || A_Args[2] == "redirect")
	throw Error("Unknown render-focus case.")
global SEND_INSTANT_PASTE_DELAY_MS := Integer(A_Args[3]), _SendHook := 0
global Features := Map("shortcuts", Map(ConfigLeaf.WRAP_TEXT_IF_SELECTED, true)), _WS_Disabled := Map()
global UIA_SELECTION_MAX_AGE_MS := Integer(A_Args[4]), _UIA_SelectionCache := 0
global _WRF := {Mode: A_Args[2], A: 0, B: 0, EditA: 0, EditB: 0, Armed: false, RenderCalls: 0,
	Mutated: false, OwnSequence: 0, OwnToken: 0, RestoreCallback: 0, RestoreFired: false, Sends: [], Fallbacks: [], Rings: [], ManagerPublications: 0, CopyCalls: 0, Seed: "owned renderer seed", Payload: "[alpha]", Failure: 0}
LoggerWarn(*) => 0
LoggerError(*) => 0
LoggerDebug(*) => 0
LoggerInfo(*) => 0

; Delegate the actual publisher and retain only its authenticated receipt.
CB_WriteTextWithReceipt(Text, &OwnedSequence := 0) {
	global _WRF
	Published := _WRF_ActualWriteTextWithReceipt(Text, &OwnedSequence)
	_WRF.OwnSequence := Published && OwnedSequence ? OwnedSequence : 0
	_WRF.OwnToken := CBClipboardOwner.paste_transaction
	return Published
}
CB_WritePlainSnapshot(Capture, Text, &OwnedSequence) {
	global _WRF
	Published := _WRF_ActualWritePlainSnapshot(Capture, Text, &OwnedSequence)
	_WRF.OwnSequence := Published && OwnedSequence ? OwnedSequence : 0
	_WRF.OwnToken := CBClipboardOwner.paste_transaction
	return Published
}

_WRF_ObserveRestoreTimer(Callback, Delay) {
	global _WRF
	_WRF.RestoreCallback := Callback
	return SetTimer(Callback, Delay)
}
_SendInstant_RestoreClipboard(OldClip, OwnedSequence, OwnerToken) {
	global _WRF
	; The canonical all-formats setter closes internally. It supplies no exact
	; post-close receipt, so never adopt its observable resulting sequence.
	_WRF.RestoreFired := true
	_WRF.OwnSequence := 0
	return _WRF_ActualRestoreClipboard(OldClip, OwnedSequence, OwnerToken)
}
_WRF_DisarmOwnedRestore() {
	global _WRF
	if IsObject(_WRF.RestoreCallback) && !_WRF.RestoreFired {
		SetTimer(_WRF.RestoreCallback, 0)
	}
}
_WRF_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
SendNewResult(Text, Args*) {
	global _WRF
	_WRF.Fallbacks.Push({Text: Text, Focus: _TextSenderNativeFocus()})
	return true
}
UpdateLastSentCharacter(Text) {
	global _WRF
	_WRF.Rings.Push(Text)
}
_WRF_OwnedFocus() {
	global _WRF
	Focus := _TextSenderNativeFocus()
	_WRF_Require(Focus["pid"] == DllCall("GetCurrentProcessId", "UInt")
		&& ((Focus["hwnd"] == _WRF.A.Hwnd && Focus["control"] == _WRF.EditA.Hwnd)
			|| (Focus["hwnd"] == _WRF.B.Hwnd && Focus["control"] == _WRF.EditB.Hwnd)),
		"Native effects may only reach the two child-owned foreground Edits.")
	return Focus
}
_WRF_NativeSend(Keys) {
	global _WRF
	_WRF_Require(Keys == "^v", "Only the actual paste primitive may reach these private Edits.")
	Focus := _WRF_OwnedFocus()
	for Key in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
		_WRF_Require(!GetKeyState(Key, "P") && !GetKeyState(Key), "Release modifiers before the owned native paste.")
	Observed := CB_Read()
	_WRF_Require(Observed == "[alpha]" || Observed == "[bravo]",
		"Only a transformation of one of the two private fixture selections may reach native paste.")
	Focus := _WRF_OwnedFocus()
	_WRF.Sends.Push(Focus)
	return SendInput(Keys)
}
_WRF_Render(Format, LParam, Message, Hwnd) {
	global _WRF
	if Hwnd != _WRF.A.Hwnd || Format != 13
		return
	Handle := 0, Transferred := false
	try {
		_WRF.RenderCalls += 1
		_WRF_Require(_WRF.RenderCalls == 1, "The delayed Unicode data must render only once.")
		if _WRF.Armed && _WRF.Mode == "redirect" {
			WinActivate("ahk_id " . _WRF.B.Hwnd)
			_WRF_Require(WinWaitActive("ahk_id " . _WRF.B.Hwnd, , 1), "The native clipboard renderer must activate its second owned window.")
			_WRF.EditB.Focus()
		}
		Handle := DllCall("Kernel32\GlobalAlloc", "UInt", 0x42, "UPtr", (StrLen(_WRF.Seed) + 1) * 2, "Ptr")
		_WRF_Require(Handle != 0, "The delayed native format must allocate its own memory.")
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_WRF_Require(Data != 0, "The delayed native allocation must lock.")
		try StrPut(_WRF.Seed, Data, StrLen(_WRF.Seed) + 1, "UTF-16")
		finally DllCall("Kernel32\GlobalUnlock", "Ptr", Handle)
		; WM_RENDERFORMAT is delivered under the requester's native clipboard
		; lock. Opening the clipboard here would violate the platform contract.
		Transferred := DllCall("User32\SetClipboardData", "UInt", 13, "Ptr", Handle, "Ptr") == Handle
		_WRF_Require(Transferred, "The renderer must transfer its real CF_UNICODETEXT image to Windows.")
		_WRF.OwnSequence := CB_GetSequenceNumber()
	} catch as Err {
		_WRF.Failure := Err
	} finally {
		if Handle && !Transferred
			DllCall("Kernel32\GlobalFree", "Ptr", Handle)
	}
	return 0
}
_WRF_SeedDelayed() {
	global _WRF
	_WRF_Require(CB_OpenClipboardWithin(_WRF.A.Hwnd), "The fixture must acquire its own native clipboard lease.")
	try {
		_WRF_Require(DllCall("User32\EmptyClipboard", "Int") != 0, "The owned native clipboard lease must accept the delayed-format seed.")
		_WRF.Mutated := true
		DllCall("Kernel32\SetLastError", "UInt", 0)
		DllCall("User32\SetClipboardData", "UInt", 13, "Ptr", 0, "Ptr")
		_WRF_Require(A_LastError == 0 && DllCall("User32\IsClipboardFormatAvailable", "UInt", 13, "Int")
			&& DllCall("User32\GetClipboardOwner", "Ptr") == _WRF.A.Hwnd,
			"The native clipboard must advertise the real delayed Unicode owner without materializing it.")
		_WRF.OwnSequence := CB_GetSequenceNumber()
	} finally DllCall("User32\CloseClipboard")
}
_WRF_Settle() {
	Started := A_TickCount
	while (CBClipboardOwner.active.Count || CBClipboardOwner.paste_transaction || CBClipboardOwner.restore_debt is Map)
			&& TickElapsed(Started) < 3000 {
		if CBClipboardOwner.restore_debt is Map
			CB_RetryRestoreDebt()
		Sleep(5)
	}
	_WRF_Require(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.paste_transaction
		&& !(CBClipboardOwner.restore_debt is Map), "The actual clipboard owner and restore debt must retire before fixture cleanup.")
}
_WRF_Main() {
	global _WRF, _UIA_SelectionCache
	Incoming := CB_SaveAll(), Primary := 0
	_WRF_Require(Type(Incoming) != "String", "The incoming all-formats clipboard snapshot must be available before any mutation.")
	try {
		_WRF.A := Gui(, "Ergopti original selection owner")
		_WRF.EditA := _WRF.A.AddEdit("w320 r3", "alpha")
		_WRF.B := _WRF.A
		_WRF.EditB := _WRF.A.AddEdit("w320 r3", "bravo")
		_WRF.A.Show()
		WinActivate("ahk_id " . _WRF.A.Hwnd)
		_WRF_Require(WinWaitActive("ahk_id " . _WRF.A.Hwnd, , 1), "The selected source window must become active before the public wrapper runs.")
		_WRF.EditA.Focus()
		DllCall("SendMessageW", "Ptr", _WRF.EditB.Hwnd, "UInt", 0xB1, "Ptr", 0, "Ptr", -1)
		DllCall("SendMessageW", "Ptr", _WRF.EditA.Hwnd, "UInt", 0xB1, "Ptr", 0, "Ptr", -1)
		Before := _WRF_OwnedFocus()
		OnMessage(0x305, _WRF_Render)
		_WRF_SeedDelayed()
		_WRF.Armed := true
		GestureTransformSelection((Text) => "[" . Text . "]")
		Started := A_TickCount
		while (!_WRF.RenderCalls || IsObject(_SelectionCaptureJob)) && TickElapsed(Started) < 3000
			Sleep(5)
		_WRF_DisarmOwnedRestore()
		_WRF.Armed := false
		Started := A_TickCount
		while _WRF.EditA.Value != _WRF.Payload && _WRF.EditB.Value != _WRF.Payload && TickElapsed(Started) < 500
			Sleep(5)
		if IsObject(_WRF.Failure)
			throw _WRF.Failure
		FileAppend("OBSERVATION selection-capture-control-focus mode=" . _WRF.Mode . " render_calls=" . _WRF.RenderCalls
			. " manager_publications=" . _WRF.ManagerPublications . " copy_calls=" . _WRF.CopyCalls . " sends=" . _WRF.Sends.Length
			. " wrong_control=" . (_WRF.Sends.Length ? _WRF.Sends[1]["control"] != Before["control"] : false)
			. " a_wrapped=" . (_WRF.EditA.Value == _WRF.Payload) . " b_transformed=" . (_WRF.EditB.Value == "[bravo]")
			. " fallbacks=" . _WRF.Fallbacks.Length . "`n", "*")
		_WRF_Require(!_WRF.RestoreFired, "The unreceipted canonical restore must not have fired before the bounded receiving observation.")
		_WRF_Require((_WRF.Mode == "current" ? _WRF.CopyCalls == 1 : _WRF.CopyCalls <= 1) && _WRF.ManagerPublications == 0 && _WRF.RenderCalls == 1,
			"The initial snapshot must really render once; a redirected control may be rejected before native copy without inventing another publication.")
		if _WRF.Mode == "current"
			_WRF_Require(_WRF.Sends.Length == 1 && _WRF.EditA.Value == _WRF.Payload && _WRF.EditB.Value == "bravo",
				"The unchanged native target must receive its wrapped selection exactly once.")
		else
			_WRF_Require(_WRF.Sends.Length == 0 && _WRF.EditA.Value == "alpha" && _WRF.EditB.Value == "bravo" && _WRF.Fallbacks.Length == 0,
				"A clipboard renderer changing focus must not redirect the old selected text or a fallback symbol into another target.")
	} catch as Err {
		Primary := Err
	} finally {
		Critical("Off")
		_WRF.Armed := false
		try {
			_WRF_DisarmOwnedRestore()
			GetSelectionCancel()
			if IsObject(_WRF.RestoreCallback) && !_WRF.RestoreFired {
				Callback := _WRF.RestoreCallback
				_WRF.RestoreCallback := 0
				Callback.Call()
			}
			if _WRF.Mutated && _WRF.OwnSequence {
				Expected := _WRF.OwnSequence
				; Current is a diagnostic comparison only, never cleanup authority.
				Current := CB_GetSequenceNumber()
				CB_RestoreOwnedAllEventually(Incoming, Expected, _WRF.OwnToken, "wrap_render_focus_fixture", true, false)
				FileAppend("CLEANUP selection-capture-control-focus expected_sequence=" . Expected . " observed_sequence=" . Current
					. " receipt_current=" . (Current == Expected) . " unknown_preserved=" . (Current != Expected) . "`n", "*")
			} else if _WRF.Mutated
				FileAppend("CLEANUP selection-capture-control-focus receipt_unavailable=1 unknown_preserved=1`n", "*")
			_WRF_Settle()
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		OnMessage(0x305, _WRF_Render, 0)
		if IsObject(_WRF.A)
			_WRF.A.Destroy()
		if IsObject(_WRF.B) && ObjPtr(_WRF.B) != ObjPtr(_WRF.A)
			_WRF.B.Destroy()
	}
	if IsObject(Primary)
		throw Primary
}
_CB_ReleaseRestoreLock(Lock) => _GTRF_ActualReleaseRestoreLock(Lock)
_GTRF_NativeCopy() {
	global _WRF
	Focus := _WRF_OwnedFocus()
	_WRF_Require(Focus["hwnd"] == _WRF.A.Hwnd,
		"The genuine capture copy may only target one of the private same-window source controls.")
	_WRF.CopyCalls += 1
	return SendEvent("^c")
}
try {
	_WRF_Main()
	FileAppend("PASS selection-capture-control-focus " . _WRF.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
