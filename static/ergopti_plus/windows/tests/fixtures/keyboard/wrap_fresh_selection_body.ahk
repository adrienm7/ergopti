; tests/fixtures/keyboard/wrap_fresh_selection_body.ahk

; A genuine RegisterHotKey trigger first advances the native no-hook epoch.
; The callback then installs the real keyboard hook before default selection
; capture, so the driver's own Ctrl+C does not masquerade as later physical
; input. This qualifies composition, never physical hardware provenance.
; Every receiver and every injected edge belongs to this private child.
if A_Args.Length != 4 || A_Args[1] != "--allow-explicit-owned-wrap-fresh-selection"
	throw Error("Explicit private native selection opt-in is required")
if A_PtrSize != 8 || !(A_Args[2] == "fresh" || A_Args[2] == "empty" || A_Args[2] == "timeout" || A_Args[2] == "supersession")
	throw Error("The exact INPUT40 ABI and a known fresh-selection mode are required")
global SEND_INSTANT_PASTE_DELAY_MS := Integer(A_Args[3]), UIA_SELECTION_MAX_AGE_MS := Integer(A_Args[4]), _SendHook := 0
global Features := Map("shortcuts", Map(ConfigLeaf.WRAP_TEXT_IF_SELECTED, true)), _WS_Disabled := Map(), _UIA_SelectionCache := 0
global _WFC := {Mode: A_Args[2], Window: 0, Edit: 0, Snapshot: 0, Incoming: 0,
	BeforeEpoch: 0, TriggerEpoch: 0, CurrentEpoch: 0, Calls: 0, Injected: 0, Copies: 0, Sends: [], Bare: [], Rings: [],
	OwnSequence: 0, OwnToken: 0, RestoreCallback: 0, RestoreFired: false, Failure: 0, Registered: false, CallbackReturned: false}
LoggerWarn(*) => 0
LoggerError(*) => 0
LoggerDebug(*) => 0
LoggerInfo(*) => 0
_WFC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_WFC_Target() {
	global _WFC
	_WFC_Require(WIGetForegroundHwnd() == _WFC.Window.Hwnd && WIGetFocusedControlToken() == _WFC.Edit.Hwnd
		&& WinGetPID("ahk_id " . _WFC.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Every native input edge must remain confined to the exact private foreground Edit")
}
CB_WriteTextWithReceipt(Text, &OwnedSequence := 0) {
	global _WFC
	Published := _WRF_ActualWriteTextWithReceipt(Text, &OwnedSequence)
	if Published && OwnedSequence {
		_WFC.OwnSequence := OwnedSequence
		_WFC.OwnToken := CBClipboardOwner.paste_transaction
	}
	return Published
}
CB_WritePlainSnapshot(Capture, Text, &OwnedSequence) {
	global _WFC
	Published := _WRF_ActualWritePlainSnapshot(Capture, Text, &OwnedSequence)
	_WFC.OwnSequence := Published && OwnedSequence ? OwnedSequence : 0
	_WFC.OwnToken := CBClipboardOwner.paste_transaction
	return Published
}

_WRF_ObserveRestoreTimer(Callback, Delay) {
	global _WFC
	_WFC.RestoreCallback := Callback
	return SetTimer(Callback, Delay)
}
_SendInstant_RestoreClipboard(OldClip, OwnedSequence, OwnerToken) {
	global _WFC
	_WFC.RestoreFired := true
	_WFC.OwnSequence := 0
	return _WRF_ActualRestoreClipboard(OldClip, OwnedSequence, OwnerToken)
}
_CB_ReleaseRestoreLock(Lock) => _GTRF_ActualReleaseRestoreLock(Lock)
_WRF_NativeSend(Keys) {
	global _WFC
	_WFC_Target()
	_WFC_Require(Keys == "^v" && CB_Read() == "[bravo]", "Only the actual newly copied selection may be pasted")
	_WFC.Sends.Push(Keys)
	return SendInput(Keys)
}
SendNewResult(Text, Args*) {
	global _WFC
	_WFC_Target()
	_WFC.Bare.Push(Text)
	; Isolated native transport for the bare-symbol boundary, not a fake success.
	SendText(Text)
	return true
}
UpdateLastSentCharacter(Text) {
	global _WFC
	_WFC.Rings.Push(Text)
}
_GTRF_NativeCopy() {
	global _WFC, Features
	_WFC_Target()
	_WFC.Copies += 1
	Result := SendEvent("^c")
	if _WFC.Mode == "supersession" {
		; A newer real public invocation supersedes A even without fabricating a
		; physical generation. Its disabled-feature path types only its own key.
		Features["shortcuts"][ConfigLeaf.WRAP_TEXT_IF_SELECTED] := false
		WrapTextIfSelected("#", "#", "#")
	}
	return Result
}
_WFC_Run(*) {
	global _WFC
	try {
		_WFC_Target()
		_WFC.Calls += 1
		_WFC.TriggerEpoch := _UIA_CurrentInputEpoch()
		_WFC_Require(_WFC.TriggerEpoch != _WFC.BeforeEpoch, "The genuine RegisterHotKey trigger must advance the native fallback epoch")
		InstallKeybdHook()
		_WFC.CurrentEpoch := _UIA_CurrentInputEpoch()
		_WFC_Require(_WFC.CurrentEpoch != _WFC.Snapshot.InputEpoch, "The actual installed-hook consumer must still observe the stale snapshot epoch")
		Action := ErgoptiLayout_Action(Map("wrap", "[", "left", "[", "right", "]"), Map())
		Action.Call()
	} catch as Failure {
		_WFC.Failure := Failure
	} finally _WFC.CallbackReturned := true
}
_WFC_Inject() {
	global _WFC
	try {
		_WFC_Target()
		Packets := Buffer(80, 0)
		for Index, Flags in [0, 2] {
			Offset := (Index - 1) * 40
			NumPut("UInt", 1, Packets, Offset)
			NumPut("UShort", 0x75, "UShort", 0x40, "UInt", Flags, Packets, Offset + 8)
			NumPut("UPtr", 0x57464301, Packets, Offset + 24)
		}
		_WFC.Injected := DllCall("SendInput", "UInt", 2, "Ptr", Packets, "Int", 40, "UInt")
		_WFC_Require(_WFC.Injected == 2, "The complete private F6 down/up vector must be accepted")
	} catch as Failure {
		_WFC.Failure := Failure
	}
}
_WFC_Settle() {
	Started := A_TickCount
	while (CBClipboardOwner.active.Count || CBClipboardOwner.restore_debt is Map || CBClipboardOwner.paste_transaction)
			&& TickElapsed(Started) < 3000 {
		if CBClipboardOwner.restore_debt is Map
			CB_RetryRestoreDebt()
		Sleep(5)
	}
	_WFC_Require(!CBClipboardOwner.active.Count && !(CBClipboardOwner.restore_debt is Map)
		&& !CBClipboardOwner.paste_transaction, "Exact clipboard owners and restore debt must settle")
}
_WFC_Main() {
	global _WFC, _UIA_SelectionCache, _SelectionCaptureJob
	_WFC.Incoming := CB_SaveAll()
	_WFC_Require(!(Type(_WFC.Incoming) == "String" && _WFC.Incoming == "__CB_SAVE_ERROR__"), "The incoming native clipboard must snapshot successfully")
	_WFC.Window := Gui(, "Ergopti private fresh wrapping receiver")
	_WFC.Edit := _WFC.Window.AddEdit("w320 r3", "bravo")
	Primary := 0
	try {
		_WFC.Window.Show()
		WinActivate("ahk_id " . _WFC.Window.Hwnd)
		_WFC_Require(WinWaitActive("ahk_id " . _WFC.Window.Hwnd, , 2), "The owned fresh-selection receiver must become active")
		_WFC.Edit.Focus()
		_WFC_Target()
		for Key in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			_WFC_Require(!GetKeyState(Key, "P") && !GetKeyState(Key), "Release modifiers before private native trigger injection")
		_WFC_Require(CB_WriteTextWithReceipt("private wrapping seed", &SeedSequence) && SeedSequence, "The fixture must retain its genuine initial clipboard publication receipt")
		if _WFC.Mode == "timeout" || _WFC.Mode == "empty"
			SendMessage(0xB1, 5, 5, _WFC.Edit.Hwnd)
		else
			SendMessage(0xB1, 0, -1, _WFC.Edit.Hwnd)
		_WFC.BeforeEpoch := _UIA_CurrentInputEpoch()
		; Wrong cached text is deliberate: fallback must reread the actual bravo.
		_WFC.Snapshot := {Text: "obsolete", Hwnd: _WFC.Window.Hwnd, Control: _WFC.Edit.Hwnd,
			InputEpoch: _WFC.BeforeEpoch, CapturedAt: A_TickCount, Consumed: false}
		if _WFC.Mode != "empty"
			_UIA_SelectionCache := _WFC.Snapshot
		Hotkey("F6", _WFC_Run, "I0")
		_WFC.Registered := true
		SetTimer(_WFC_Inject, -50)
		Started := A_TickCount
		while (!(_WFC.CallbackReturned && !IsObject(_SelectionCaptureJob)) || (!_WFC.Sends.Length && !_WFC.Bare.Length))
				&& !IsObject(_WFC.Failure) && TickElapsed(Started) < 4000
			Sleep(5)
		; Retain the exact already-owned restore until the native receiver has
		; processed Ctrl+V; do not restore the payload before that receipt.
		if IsObject(_WFC.RestoreCallback) && !_WFC.RestoreFired
			SetTimer(_WFC.RestoreCallback, 0)
		Started := A_TickCount
		Expected := _WFC.Mode == "fresh" ? "[bravo]" : _WFC.Mode == "supersession" ? "#" : "bravo["
		while _WFC.Edit.Value != Expected && TickElapsed(Started) < 750
			Sleep(5)
		if IsObject(_WFC.Failure)
			throw _WFC.Failure
		FileAppend("OBSERVATION wrap-fresh-selection mode=" . _WFC.Mode . " calls=" . _WFC.Calls . " injected=" . _WFC.Injected
			. " before_epoch=" . _WFC.BeforeEpoch . " trigger_epoch=" . _WFC.TriggerEpoch . " consumer_epoch=" . _WFC.CurrentEpoch
			. " old_consumed=" . _WFC.Snapshot.Consumed . " copies=" . _WFC.Copies . " sends=" . _WFC.Sends.Length
			. " bare=" . _WFC.Bare.Length . " text=" . _WFC.Edit.Value . " job_active=" . IsObject(_SelectionCaptureJob) . "`n", "*")
		_WFC_Require(_WFC.CallbackReturned && _WFC.Calls == 1 && !_WFC.Snapshot.Consumed, "The real producer must never promote or consume its stale snapshot")
		_WFC_Require(_WFC.Edit.Value == Expected, "The actual native receiver must obtain only fresh wrapped text or its one admitted bare symbol")
		_WFC_Require(_WFC.Copies == (_WFC.Mode == "empty" ? 0 : 1), "Only an otherwise-valid epoch mismatch may start the real default selection copy")
		_WFC_Require(_WFC.Sends.Length == (_WFC.Mode == "fresh" ? 1 : 0)
			&& _WFC.Bare.Length == (_WFC.Mode == "fresh" ? 0 : 1), "Superseded or empty copies must never emit a stale wrap")
		_WFC_Require(!IsObject(_SelectionCaptureJob), "The exact selection request must retire")
	} catch as Failure {
		Primary := Failure
	} finally {
		SetTimer(_WFC_Inject, 0)
		if _WFC.Registered
			Hotkey("F6", "Off")
		GetSelectionCancel()
		if IsObject(_WFC.RestoreCallback) && !_WFC.RestoreFired
			SetTimer(_WFC.RestoreCallback, 0)
		try {
			if IsObject(_WFC.RestoreCallback) && !_WFC.RestoreFired {
				Callback := _WFC.RestoreCallback
				_WFC.RestoreCallback := 0
				Callback.Call()
			}
			ExpectedSequence := _WFC.OwnSequence
			ObservedSequence := CB_GetSequenceNumber()
			if ExpectedSequence
				CB_RestoreOwnedAllEventually(_WFC.Incoming, ExpectedSequence, _WFC.OwnToken, "wrap_fresh_selection_fixture", true, false)
			_WFC_Settle()
			FileAppend("CLEANUP wrap-fresh-selection expected_sequence=" . ExpectedSequence . " observed_sequence=" . ObservedSequence
				. " receipt_current=" . (ExpectedSequence && ExpectedSequence == ObservedSequence)
				. " unknown_preserved=" . (!ExpectedSequence || ExpectedSequence != ObservedSequence) . " active=0 debt=0`n", "*")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		_WFC.Window.Destroy()
	}
	if IsObject(Primary)
		throw Primary
}
try {
	_WFC_Main()
	FileAppend("PASS wrap-fresh-selection " . _WFC.Mode, "*")
	ExitApp(0)
} catch as Failure {
	FileAppend(Failure.Message . "`n" . Failure.Stack, "**")
	ExitApp(1)
}
