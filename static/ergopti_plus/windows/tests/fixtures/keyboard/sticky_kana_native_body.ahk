; tests/fixtures/keyboard/sticky_kana_native_body.ahk

; Both original and replay are native injection into this child's owned Edit.
; Original injection uses User32, not SendEvent's persistent modifier ownership.
; This is injected input, not a physical-key witness.
if A_Args.Length != 2 || A_Args[1] != "--allow-owned-native-kana-sticky"
	throw Error("Explicit native modifier injection opt-in is required.")
if A_PtrSize != 8 || !(A_Args[2] == "plain" || A_Args[2] == "kana-held" || A_Args[2] == "kana-released" || A_Args[2] == "kana-up-before-key" || A_Args[2] == "kana-preheld-released")
	throw Error("The exact 64-bit INPUT40 probe and known case are required.")
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2, TEXT_SENDER_SEND_LEVEL := 0
; A valid production policy keeps shortcut words open. Its actual complete-scalar
; predicate and policy reader run below; no transaction/commit function is stubbed.
global HSE_ArrowResetsWord := false, HSE_ShortcutResetsWord := false, HSE_TapHoldResetsWord := false
global HSE_Buffer := "seed", _PrefixBuffer := "seed"
global _TH_OwnedModifiers := Map(), LayerEnabled := false, _TapHoldTapInDispatch := ""
global _SKN := {Mode: A_Args[2], Window: 0, Edit: 0, Hook: 0, Received: [], Payloads: [], Errors: [],
	Injected: 0, OemOwed: false, F6Owed: false, Observer: 0, NativeEvents: [], ReleasedAtReplay: false, Failure: 0, TransactionCritical: false, Finishes: [], InitialOEM: 0, PreheldBeforeCapture: false}
global _ALTGR_KANA_FIXUP := _SKN.Mode != "plain"
global _ALTGR_LAYOUT_PROBE := Map("altgr_vk", 0xDF)
global _TextSenderKeyIsDown := (Name) => GetKeyState(Name)
global _AHK_SendInput := _SKN_Replay

_SKN_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerError(Args*) {
	global _SKN
	_SKN.Errors.Push(Args)
}
LoggerWarn(Args*) {
	global _SKN
	_SKN.Errors.Push(Args)
}
LoggerDebug(Tag, Message, Args*) {
	global _SKN
	if Tag == "HotstringBuffers"
		_SKN.Finishes.Push(A_IsCritical)
}
_SKN_Target() {
	global _SKN
	_SKN_Require(DllCall("GetForegroundWindow", "Ptr") == _SKN.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == _SKN.Edit.Hwnd
		&& WinGetPID("ahk_id " . _SKN.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Every native send must target the child-owned foreground Edit.")
}
_SKN_Receiver(WParam, LParam, Message, Hwnd) {
	global _SKN
	if Hwnd != _SKN.Edit.Hwnd || !(WParam == 0x75 || WParam == 0xDF)
		return
	; Win32 GetKeyState here reflects the receiver's dequeued key message,
	; rather than the final asynchronous state after the whole input batch.
	_SKN.Received.Push({Vk: WParam, Extra: DllCall("GetMessageExtraInfo", "UPtr"),
		Oem: !!(DllCall("GetKeyState", "Int", 0xDF, "Short") & 0x8000), Ctrl: !!(DllCall("GetKeyState", "Int", 0x11, "Short") & 0x8000),
		Shift: !!(DllCall("GetKeyState", "Int", 0x10, "Short") & 0x8000)})
	return 0
}
_SKN_Replay(Keys) {
	global _SKN
	_SKN_Target()
	_SKN.ReleasedAtReplay := !GetKeyState("vkDF") && !(DllCall("GetAsyncKeyState", "Int", 0xDF, "Short") & 0x8000)
	_SKN.Payloads.Push(Keys)
	_SKN.TransactionCritical := !!A_IsCritical
	_SKN_Require(_SKN.TransactionCritical, "Native replay must be admitted inside the actual HS transaction.")
	SendInput(Keys)
}
_SKN_Packets(Rows) {
	Packets := Buffer(Rows.Length * 40, 0)
	for Index, Row in Rows {
		Offset := (Index - 1) * 40
		NumPut("UInt", 1, Packets, Offset)
		NumPut("UShort", Row[1], "UShort", Row[2], "UInt", Row[3], Packets, Offset + 8)
		NumPut("UPtr", 0x53534D01, Packets, Offset + 24)
	}
	return Packets
}
_SKN_OriginalDown(Hook, Vk, Sc) {
	global _SKN
	if _SKN.Observer == Hook
		_SKN.NativeEvents.Push({Vk: Vk, Sc: Sc})
}
_SKN_Inject() {
	global _SKN
	try {
		_SKN_Target()
		for Token, Record in _SIHO_Owners
			if Record["owner"] == "sticky-modifier"
				_SKN.Hook := Record["hook"]
		_SKN_Require(_SKN.Hook is InputHook && _SKN.Hook.InProgress,
			"Original injection must reach the actual admitted sticky InputHook.")
		; A newest, fully visible I1 observer independently receives native
		; VK/SC pairs before the suppressive hook sees them. Sender-level0 replay
		; stays below this observer, so a constructed packet is never its proof.
		if !IsObject(_SKN.Observer) {
			_SKN.Observer := InputHook("V L0 I1")
			_SKN.Observer.KeyOpt("{All}", "N")
			_SKN.Observer.OnKeyDown := _SKN_OriginalDown
		} else {
			; The preheld Down was observed before Sticky existed. Rearm the
			; exact passive observer newest so the SUT cannot hide its F6 witness.
			_SKN.Observer.Stop()
			_SKN_Require(!_SKN.Observer.InProgress, "The original passive observer must stop before its exact rearm")
		}
		_SKN.Observer.Start()
		_SKN_Require(_SKN.Observer.InProgress, "The passive native ABI observer must be admitted before injection.")
		; The native OEM8/extended-SC138 pair matches Kana AltGr's event ABI.
		; Family identity is explicitly simulated; no installed Kana HKL is claimed.
		; Held mode isolates capture admission; released mode adds the exact OEM8
		; Up in the original native batch before Wait can unwind and replay.
		Rows := _SKN.Mode == "kana-held" ? [[0xDF, 0x38, 1], [0x75, 0x40, 0], [0x75, 0x40, 2]]
			: [[0x75, 0x40, 0], [0x75, 0x40, 2]]
		if _SKN.Mode == "kana-released"
			Rows := [[0xDF, 0x38, 1], [0x75, 0x40, 0], [0x75, 0x40, 2], [0xDF, 0x38, 3]]
		if _SKN.Mode == "kana-up-before-key"
			Rows := [[0xDF, 0x38, 1], [0xDF, 0x38, 3], [0x75, 0x40, 0], [0x75, 0x40, 2]]
		if _SKN.Mode == "kana-preheld-released"
			Rows := [[0x75, 0x40, 0], [0x75, 0x40, 2], [0xDF, 0x38, 3]]
		Packets := _SKN_Packets(Rows)
		_SKN.Injected := DllCall("SendInput", "UInt", Rows.Length, "Ptr", Packets, "Int", 40, "UInt")
		for Index, Row in Rows {
			if Index > _SKN.Injected
				break
			if Row[1] == 0xDF
				_SKN.OemOwed := !(Row[3] & 2)
			else if Row[1] == 0x75
				_SKN.F6Owed := !(Row[3] & 2)
		}
		_SKN_Require(_SKN.Injected == Rows.Length, "The complete exact native INPUT40 vector must be admitted.")
	} catch as Err {
		_SKN.Failure := Err
		SIHO_StopAll()
	}
}
_SKN_HasF6() {
	global _SKN
	for Event in _SKN.Received
		if Event.Vk == 0x75
			return true
	return false
}
_SKN_Main() {
	global _SKN
	_SKN.Window := Gui(, "Ergopti native sticky flag probe")
	_SKN.Edit := _SKN.Window.AddEdit("w320 r3")
	try {
		_SKN.Window.Show()
		WinActivate("ahk_id " . _SKN.Window.Hwnd)
		_SKN_Require(WinWaitActive("ahk_id " . _SKN.Window.Hwnd, , 2), "The native target must acquire focus.")
		_SKN.Edit.Focus()
		_SKN_Target()
		for Modifier in ["Ctrl", "Alt", "Shift", "LWin", "RWin", "vkDF", "F6"]
			_SKN_Require(!GetKeyState(Modifier, "P") && !GetKeyState(Modifier), "Native probe requires released modifiers.")
		OnMessage(0x100, _SKN_Receiver)
		if _SKN.Mode == "kana-preheld-released" {
			_SKN_Require(SIHO_Count() == 0, "Initial native hold precedes every suppressive capture")
			_SKN.Observer := InputHook("V L0 I1")
			_SKN.Observer.KeyOpt("{All}", "N")
			_SKN.Observer.OnKeyDown := _SKN_OriginalDown
			_SKN.Observer.Start()
			_SKN_Require(_SKN.Observer.InProgress, "The initial native OEM witness must be armed")
			_SKN_Target()
			Initial := _SKN_Packets([[0xDF, 0x38, 1]])
			_SKN.InitialOEM := DllCall("SendInput", "UInt", 1, "Ptr", Initial, "Int", 40, "UInt")
			_SKN.OemOwed := _SKN.InitialOEM == 1
			_SKN_Require(_SKN.InitialOEM == 1, "The initial actual OEM Down must be acknowledged before capture")
			Started := A_TickCount
			while (_SKN.NativeEvents.Length != 1 || _SKN.Received.Length != 1 || !GetKeyState("vkDF"))
				&& A_TickCount - Started < 1000
				Sleep(5)
			_SKN.PreheldBeforeCapture := _SKN.NativeEvents.Length == 1 && _SKN.Received.Length == 1
				&& _SKN.NativeEvents[1].Vk == 0xDF && _SKN.NativeEvents[1].Sc == 0x138
				&& _SKN.Received[1].Vk == 0xDF && _SKN.Received[1].Extra == 0x53534D01
				&& GetKeyState("vkDF") && !!(DllCall("GetAsyncKeyState", "Int", 0xDF, "Short") & 0x8000)
				&& SIHO_Count() == 0
			_SKN_Require(_SKN.PreheldBeforeCapture, "The native receiver and independent observer must witness OEM held before Sticky is called")
		}
		SetTimer(_SKN_Inject, -1)
		Accepted := StickyModifier("sticky_ctrl")
		if IsObject(_SKN.Failure)
			throw _SKN.Failure
		Started := A_TickCount
		while (!_SKN_HasF6() || _SKN.NativeEvents.Length < (_SKN.Mode != "plain" ? 2 : 1))
			&& A_TickCount - Started < 1500
			Sleep(5)
		_SKN_Require(_SKN_HasF6(), "The actual original or replayed F6 must reach the owned receiver before sampling.")
		_SKN.Observer.Stop()
		_SKN_Require(!_SKN.Observer.InProgress, "The exact passive native observer must stop before the ABI receipt is sampled.")
		ExpectedEvents := _SKN.Mode != "plain" ? 2 : 1
		NativeOem := _SKN.Mode != "plain" && _SKN.NativeEvents.Length >= 1
			&& _SKN.NativeEvents[1].Vk == 0xDF && _SKN.NativeEvents[1].Sc == 0x138
		NativeF6 := _SKN.NativeEvents.Length == ExpectedEvents
			&& _SKN.NativeEvents[ExpectedEvents].Vk == 0x75 && _SKN.NativeEvents[ExpectedEvents].Sc == 0x40
		FileAppend("OBSERVATION sticky-kana-native-abi mode=" . _SKN.Mode . " keydowns=" . _SKN.NativeEvents.Length
			. " oem_df_sc138=" . NativeOem . " f6_75_sc40=" . NativeF6
			. " observer_level=" . _SKN.Observer.MinSendLevel . "`n", "*")
		_SKN_Require(NativeF6 && (_SKN.Mode == "plain" || NativeOem),
			"The native original VK/SC ABI must be observed independently before any business verdict.")
		F6 := [], OriginalOem := 0, OriginalF6 := 0
		for Event in _SKN.Received {
			if Event.Vk == 0x75 {
				F6.Push(Event)
				OriginalF6 += Event.Extra == 0x53534D01
			} else if Event.Vk == 0xDF && Event.Extra == 0x53534D01
				OriginalOem += 1
		}
		CapturedMods := IsObject(_SKN.Hook) ? _SKN.Hook.EndMods : ""
		FileAppend("OBSERVATION sticky-kana mode=" . _SKN.Mode . " inserted=" . _SKN.Injected
			. " end_key=" . _SKN.Hook.EndKey . " end_mods=" . CapturedMods
			. " f6_received=" . F6.Length . " original_f6=" . OriginalF6 . " original_oem=" . OriginalOem
			. " f6_ctrl=" . (F6.Length ? F6[1].Ctrl : -1) . " f6_oem=" . (F6.Length ? F6[1].Oem : -1)
			. " released_before_replay=" . _SKN.ReleasedAtReplay
			. " payload=" . (_SKN.Payloads.Length ? _SKN.Payloads[1] : "") . "`n", "*")
		if _SKN.Mode == "kana-preheld-released" {
			FileAppend("OBSERVATION sticky-kana-preheld initial_ack=" . _SKN.InitialOEM
				. " held_before_capture=" . _SKN.PreheldBeforeCapture . "`n", "*")
			_SKN_Require(_SKN.PreheldBeforeCapture && _SKN.InitialOEM == 1, "The initial native hold receipt must precede the real capture")
		}
		if _SKN.Mode == "kana-released" || _SKN.Mode == "kana-up-before-key" || _SKN.Mode == "kana-preheld-released"
			_SKN_Require(_SKN.ReleasedAtReplay, "The actual OEM8 logical and asynchronous states must be released before the genuine replay port is called.")
		_SKN_Require(Accepted && _SKN.Errors.Length == 0 && _SKN.Payloads.Length == 1,
			"The real sticky capture and real TextPressKey must emit one native replay without errors.")
		_SKN_Require(F6.Length == 1 && F6[1].Ctrl && OriginalF6 == 0,
			"Kana AltGr must remain an intervening modifier so the following F6, not OEM8, consumes the requested sticky Ctrl.")
		_SKN_Require(OriginalOem == (_SKN.Mode != "plain")
			&& F6[1].Oem == (_SKN.Mode == "kana-held" || _SKN.Mode == "kana-released" || _SKN.Mode == "kana-preheld-released"),
			"The receiver must retain the original native Kana modifier through the actual modified F6.")
		if _SKN.Mode == "kana-held"
			_SKN_Require(!!(DllCall("GetAsyncKeyState", "Int", 0xDF, "Short") & 0x8000),
				"Replay must never release the user's original custom-modifier hold")
		_SKN_Require(_SKN.Hook.OnKeyDown == "" && _SKN.Hook.OnKeyUp == "" && _SKN.Hook.OnEnd == "",
			"The exact completed capture must release all private callback references")
		_SKN_Require(_SKN.TransactionCritical && _SKN.Finishes.Length == 1 && !_SKN.Finishes[1]
			&& HSE_Buffer == "seed" && _PrefixBuffer == "seed" && SIHO_Count() == 0,
			"The genuine synthetic transaction and exact suppressive owner must compose and settle unchanged.")
	} finally {
		SetTimer(_SKN_Inject, 0)
		try SIHO_StopAll()
		finally {
			if IsObject(_SKN.Observer) {
				_SKN.Observer.Stop()
				_SKN_Require(!_SKN.Observer.InProgress, "The exact visible native observer must retire before exit.")
			}
			if _SKN.F6Owed {
				Packets := _SKN_Packets([[0x75, 0x40, 2]])
				_SKN_Require(DllCall("SendInput", "UInt", 1, "Ptr", Packets, "Int", 40, "UInt") == 1,
					"A partially admitted original F6 Down requires its exact acknowledged Up.")
				_SKN.F6Owed := false
			}
			if _SKN.OemOwed {
				Packets := _SKN_Packets([[0xDF, 0x38, 3]])
				_SKN_Require(DllCall("SendInput", "UInt", 1, "Ptr", Packets, "Int", 40, "UInt") == 1,
					"The fixture must acknowledge its exact original OEM8 Up.")
				Started := A_TickCount
				while GetKeyState("vkDF") && A_TickCount - Started < 1000
					Sleep(5)
				_SKN_Require(!GetKeyState("vkDF"), "The acknowledged OEM8 Up must settle logically before retirement.")
				_SKN.OemOwed := false
			}
			if (_SKN.Mode == "kana-released" && _SKN.Injected == 4)
				|| (_SKN.Mode == "kana-up-before-key" && _SKN.Injected >= 2)
				|| (_SKN.Mode == "kana-preheld-released" && _SKN.Injected == 3) {
				Started := A_TickCount
				while GetKeyState("vkDF") && A_TickCount - Started < 1000
					Sleep(5)
				_SKN_Require(!GetKeyState("vkDF"), "The acknowledged original OEM8 Up must settle logically before the receiver retires.")
			}
			OnMessage(0x100, _SKN_Receiver, 0)
			_SKN.Window.Destroy()
		}
	}
}
try {
	_SKN_Main()
	FileAppend("PASS sticky-kana-native " . _SKN.Mode, "*")
	ExitApp(0)
} catch as SKNEntryFailure {
	FileAppend(SKNEntryFailure.Message . "`n" . SKNEntryFailure.Stack, "**")
	ExitApp(1)
}
