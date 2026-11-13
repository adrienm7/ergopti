; tests/fixtures/gestures/title_transform_target_body.ahk

; Actual public selection title-case action with its real long pure transform.
; A passive synthetic-owner observer arms a native timer after genuine capture
; admission. The timer must run INSIDE the actual interpreted TextCaseTitle loop,
; not inside an artificial wait. Only two private owned windows can receive I/O.
if A_Args.Length != 4 || A_Args[1] != "--allow-explicit-owned-clipboard-render-focus"
	throw Error("Explicit owned-window/clipboard render focus opt-in is required.")
if !(A_Args[2] == "current" || A_Args[2] == "redirect")
	throw Error("Unknown render-focus case.")
global SEND_INSTANT_PASTE_DELAY_MS := Integer(A_Args[3]), _SendHook := 0
global Features := Map("shortcuts", Map(ConfigLeaf.WRAP_TEXT_IF_SELECTED, true)), _WS_Disabled := Map()
global UIA_SELECTION_MAX_AGE_MS := Integer(A_Args[4]), _UIA_SelectionCache := 0
global _WRF := {Mode: A_Args[2], A: 0, B: 0, EditA: 0, EditB: 0, Armed: false, RenderCalls: 0,
	Mutated: false, OwnSequence: 0, OwnToken: 0, RestoreCallback: 0, RestoreFired: false, Sends: [], Fallbacks: [], Rings: [], ManagerPublications: 0, CopyCalls: 0, Transforming: false, TransformDone: false, TransformElapsed: -1, TransformCritical: -1, MoveCalls: 0, MovedInsideTransform: false, Initial: "", Seed: "owned renderer seed", Payload: "[alpha]", Failure: 0}
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
	_WRF_Require(CB_Read() == _WRF.Payload, "The real clipboard setter must publish the exact wrapped selection before paste.")
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
		; A larger valid selection measures the real transform's scheduling
		; behavior. No extra wait or artificial callout enters its production loop.
		_WRF.Payload := ""
		loop 30000 {
			_WRF.Initial .= "alpha beta "
			_WRF.Payload .= "Alpha Beta "
		}
		_WRF.A := Gui(, "Ergopti original selection owner")
		; AHK applies EM_LIMITTEXT only after CreateWindowEx. Install the long
		; real selection after creating the control, not as its window caption.
		_WRF.EditA := _WRF.A.AddEdit("w320 r3 Limit1000000")
		_WRF.EditA.Value := _WRF.Initial
		_WRF.B := Gui(, "Ergopti independent receiver")
		_WRF.EditB := _WRF.B.AddEdit("w320 r3")
		_WRF.A.Show()
		_WRF.B.Show()
		WinActivate("ahk_id " . _WRF.A.Hwnd)
		_WRF_Require(WinWaitActive("ahk_id " . _WRF.A.Hwnd, , 1), "The selected source window must become active before the public wrapper runs.")
		_WRF.EditA.Focus()
		DllCall("SendMessageW", "Ptr", _WRF.EditA.Hwnd, "UInt", 0xB1, "Ptr", 0, "Ptr", -1)
		Before := _WRF_OwnedFocus()
		_WRF_Require(_WRF.EditA.Value == _WRF.Initial,
			"The actual native Edit must retain the complete private larger selection before copy.")
		_WRF_Require(CB_WriteTextWithReceipt(_WRF.Seed, &SeedSequence) && SeedSequence,
			"The initial native seed must supply its actual publication receipt.")
		_WRF.Mutated := true
		_WRF.Armed := true
		GestureTransformSelection(TextCaseTitle)
		Started := A_TickCount
		while (!_WRF.TransformDone || IsObject(_SelectionCaptureJob)) && TickElapsed(Started) < 3000
			Sleep(5)
		_WRF_DisarmOwnedRestore()
		_WRF.Armed := false
		Started := A_TickCount
		while _WRF.EditA.Value != _WRF.Payload && _WRF.EditB.Value != _WRF.Payload && TickElapsed(Started) < 500
			Sleep(5)
		if IsObject(_WRF.Failure)
			throw _WRF.Failure
		FileAppend("OBSERVATION gesture-title-transform-target mode=" . _WRF.Mode . " moved_inside_transform=" . _WRF.MovedInsideTransform . " move_calls=" . _WRF.MoveCalls
			. " input_units=" . StrLen(_WRF.Initial) . " transform_ms=" . _WRF.TransformElapsed
			. " transform_critical=" . _WRF.TransformCritical . " manager_publications=" . _WRF.ManagerPublications . " copy_calls=" . _WRF.CopyCalls . " sends=" . _WRF.Sends.Length
			. " wrong_target=" . (_WRF.Sends.Length ? _WRF.Sends[1]["hwnd"] != Before["hwnd"] : false)
			. " a_wrapped=" . (_WRF.EditA.Value == _WRF.Payload) . " b_wrapped=" . (_WRF.EditB.Value == _WRF.Payload)
			. " fallbacks=" . _WRF.Fallbacks.Length . "`n", "*")
		; The real one-shot restore may run while this large native paste renders.
		; Its observer retires OwnSequence rather than adopting the new contents;
		; cleanup below preserves that unknown sequence if it already fired.
		_WRF_Require(_WRF.CopyCalls == 1 && _WRF.TransformDone && _WRF.ManagerPublications == 0 && _WRF.RenderCalls == 0,
			"The actual public capture and genuine title-case transform must complete without a delayed clipboard renderer.")
		_WRF_Require(_WRF.Mode == "current" ? _WRF.MoveCalls == 0 : _WRF.MoveCalls == 1 && _WRF.MovedInsideTransform,
			"The redirected case must change its owned native focus during the actual production transform, never after an artificial wait.")
		if _WRF.Mode == "current"
			_WRF_Require(_WRF.Sends.Length == 1 && _WRF.EditA.Value == _WRF.Payload && _WRF.EditB.Value == "",
				"The unchanged native target must receive its wrapped selection exactly once.")
		else
			_WRF_Require(_WRF.Sends.Length == 0 && _WRF.EditA.Value == _WRF.Initial && _WRF.EditB.Value == "" && _WRF.Fallbacks.Length == 0,
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
				FileAppend("CLEANUP gesture-title-transform-target expected_sequence=" . Expected . " observed_sequence=" . Current
					. " receipt_current=" . (Current == Expected) . " unknown_preserved=" . (Current != Expected) . "`n", "*")
			} else if _WRF.Mutated
				FileAppend("CLEANUP gesture-title-transform-target receipt_unavailable=1 unknown_preserved=1`n", "*")
			_WRF_Settle()
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		SetTimer(_GTTL_MoveFocus, 0)
		if IsObject(_WRF.A)
			_WRF.A.Destroy()
		if IsObject(_WRF.B)
			_WRF.B.Destroy()
	}
	if IsObject(Primary)
		throw Primary
}
_CB_ReleaseRestoreLock(Lock) => _GTRF_ActualReleaseRestoreLock(Lock)
KL_MarkSynthetic(Source, IsPrivate := false) {
	global _WRF
	Owner := _GTTL_ActualMarkSynthetic(Source, IsPrivate)
	if _WRF.Armed && _WRF.Mode == "redirect"
		SetTimer(_GTTL_MoveFocus, -1)
	return Owner
}
TextCaseTitle(Text) {
	global _WRF
	_WRF_Require(Text == _WRF.Initial, "The genuine async capture must deliver the complete private source to the actual title-case transform.")
	Started := A_TickCount
	_WRF.TransformCritical := A_IsCritical
	_WRF.Transforming := true
	try return _GTTL_ActualTextCaseTitle(Text)
	finally {
		_WRF.TransformElapsed := A_TickCount - Started
		_WRF.Transforming := false
		_WRF.TransformDone := true
	}
}
_GTTL_MoveFocus() {
	global _WRF
	try {
		_WRF_OwnedFocus()
		_WRF.MoveCalls += 1
		_WRF.MovedInsideTransform := _WRF.Transforming
		WinActivate("ahk_id " . _WRF.B.Hwnd)
		_WRF_Require(WinWaitActive("ahk_id " . _WRF.B.Hwnd, , 1), "The timer must activate its second private receiver.")
		_WRF.EditB.Focus()
	} catch as Failure {
		_WRF.Failure := Failure
	}
}
_GTRF_NativeCopy() {
	global _WRF
	Focus := _WRF_OwnedFocus()
	_WRF_Require(Focus["hwnd"] == _WRF.A.Hwnd && Focus["control"] == _WRF.EditA.Hwnd,
		"The genuine capture copy may only target its original owned source.")
	_WRF.CopyCalls += 1
	return SendEvent("^c")
}
try {
	_WRF_Main()
	FileAppend("PASS gesture-title-transform-target " . _WRF.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
