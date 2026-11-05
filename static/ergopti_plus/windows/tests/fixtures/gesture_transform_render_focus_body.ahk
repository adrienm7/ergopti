; tests/fixtures/gesture_transform_render_focus_body.ahk

; The public gesture performs actual async Ctrl+C capture and its real context
; admission. After the real selection restore releases its OS lease, a native
; clipboard-manager publication exposes delayed rendering to the subsequent
; SendInstant snapshot. Only that WM_RENDERFORMAT changes owned-window focus.
; No cache/UIA snapshot or foreground/generation admission result is fabricated.
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
		_WRF.A := Gui(, "Ergopti original selection owner")
		_WRF.EditA := _WRF.A.AddEdit("w320 r3", "alpha")
		_WRF.B := Gui(, "Ergopti independent receiver")
		_WRF.EditB := _WRF.B.AddEdit("w320 r3")
		_WRF.A.Show()
		_WRF.B.Show()
		WinActivate("ahk_id " . _WRF.A.Hwnd)
		_WRF_Require(WinWaitActive("ahk_id " . _WRF.A.Hwnd, , 1), "The selected source window must become active before the public wrapper runs.")
		_WRF.EditA.Focus()
		DllCall("SendMessageW", "Ptr", _WRF.EditA.Hwnd, "UInt", 0xB1, "Ptr", 0, "Ptr", -1)
		Before := _WRF_OwnedFocus()
		OnMessage(0x305, _WRF_Render)
		_WRF_Require(CB_WriteTextWithReceipt(_WRF.Seed, &SeedSequence) && SeedSequence,
			"The initial native seed must supply its actual publication receipt.")
		_WRF.Mutated := true
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
		FileAppend("OBSERVATION gesture-transform-render-focus mode=" . _WRF.Mode . " render_calls=" . _WRF.RenderCalls
			. " manager_publications=" . _WRF.ManagerPublications . " copy_calls=" . _WRF.CopyCalls . " sends=" . _WRF.Sends.Length
			. " wrong_target=" . (_WRF.Sends.Length ? _WRF.Sends[1]["hwnd"] != Before["hwnd"] : false)
			. " a_wrapped=" . (_WRF.EditA.Value == _WRF.Payload) . " b_wrapped=" . (_WRF.EditB.Value == _WRF.Payload)
			. " fallbacks=" . _WRF.Fallbacks.Length . "`n", "*")
		_WRF_Require(!_WRF.RestoreFired, "The unreceipted canonical restore must not have fired before the bounded receiving observation.")
		_WRF_Require(_WRF.CopyCalls == 1 && _WRF.ManagerPublications == 1 && _WRF.RenderCalls == 1,
			"The public gesture must complete genuine copy, restore, manager publication and delayed render exactly once.")
		if _WRF.Mode == "current"
			_WRF_Require(_WRF.Sends.Length == 1 && _WRF.EditA.Value == _WRF.Payload && _WRF.EditB.Value == "",
				"The unchanged native target must receive its wrapped selection exactly once.")
		else
			_WRF_Require(_WRF.Sends.Length == 0 && _WRF.EditA.Value == "alpha" && _WRF.EditB.Value == "" && _WRF.Fallbacks.Length == 0,
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
				FileAppend("CLEANUP gesture-transform-render-focus expected_sequence=" . Expected . " observed_sequence=" . Current
					. " receipt_current=" . (Current == Expected) . " unknown_preserved=" . (Current != Expected) . "`n", "*")
			} else if _WRF.Mutated
				FileAppend("CLEANUP gesture-transform-render-focus receipt_unavailable=1 unknown_preserved=1`n", "*")
			_WRF_Settle()
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		OnMessage(0x305, _WRF_Render, 0)
		if IsObject(_WRF.A)
			_WRF.A.Destroy()
		if IsObject(_WRF.B)
			_WRF.B.Destroy()
	}
	if IsObject(Primary)
		throw Primary
}
; This observes the complete genuine native release, never a context gate.
_CB_ReleaseRestoreLock(Lock) {
	global _WRF
	Released := _GTRF_ActualReleaseRestoreLock(Lock)
	Debt := CBClipboardOwner.restore_debt
	if Released && _WRF.Armed && !_WRF.ManagerPublications && Debt is Map
			&& Debt["source"] == "selection_capture_ready" {
		_WRF_Require(DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd,
			"The clipboard manager must run only after the real restore lease is released.")
		_WRF.ManagerPublications += 1
		; A manager may replace the restored namespace while keeping its text.
		; EmptyClipboard gives this fixture full custody, not inferred adoption.
		_WRF_SeedDelayed()
	}
	return Released
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
	FileAppend("PASS gesture-transform-render-focus " . _WRF.Mode, "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
