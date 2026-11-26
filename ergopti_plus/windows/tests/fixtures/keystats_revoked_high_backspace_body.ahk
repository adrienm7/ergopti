; tests/fixtures/keystats_revoked_high_backspace_body.ahk
; Independent native Edit oracle; no scalar-fragment field or sourcefix assumed.
_KSX_Hex(Text) {
	Result := ""
	loop StrLen(Text)
		Result .= Format("{:04X}", NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
	return Result
}
_KSX_SendBackspace(UpOnly := false) {
	global _KSX
	if !UpOnly
		_KID_Target()
	Size := A_PtrSize == 8 ? 40 : 28
	Offset := A_PtrSize == 8 ? 8 : 4
	Count := UpOnly ? 1 : 2
	Inputs := Buffer(Size * Count, 0)
	loop Count {
		Base := (A_Index - 1) * Size
		NumPut("UInt", 1, Inputs, Base)
		NumPut("UShort", 0x08, "UShort", 0x0E, "UInt", (UpOnly || A_Index == 2) ? 2 : 0, Inputs, Base + Offset)
	}
	Ack := DllCall("User32\SendInput", "UInt", Count, "Ptr", Inputs, "Int", Size, "UInt")
	if !UpOnly && Ack == 1
		_KSX.OwedUp := true
	if (UpOnly && Ack == 1) || (!UpOnly && Ack == 2)
		_KSX.OwedUp := false
	_KSD_Require(Ack == Count, "Only the exact owned native Backspace vector may be admitted.")
}
_KSX_Exercise() {
	global _KID, _KSD, _KSX
	_KID.Window := Gui(, "Ergopti owned incomplete-unit Backspace")
	_KID.Edit := _KID.Window.AddEdit("w340 r4 Multi WantReturn WantTab", "")
	Hook := 0, PreviousLevel := A_SendLevel
	Units := _KID.Mode == "two-highs" ? [0x41, 0xD83D, 0xD83D, 0xDE00] : [0x41, 0xD83D]
	BeforeHex := _KID.Mode == "two-highs" ? "0041D83DD83DDE00" : "0041D83D"
	ExpectedReceivers := _KID.Mode == "two-highs" ? ["0041D83D", "0041", ""] : ["0041", ""]
	try {
		_KID.Window.Show()
		WinActivate("ahk_id " . _KID.Window.Hwnd)
		_KSD_Require(WinWaitActive("ahk_id " . _KID.Window.Hwnd, , 2), "The child-owned receiver must become active.")
		_KID.Edit.Focus()
		_KID_Target()
		_KSD_Require(!(DllCall("GetAsyncKeyState", "Int", 0x08, "Short") & 0x8000), "No pre-existing Backspace may be held.")
		Keystats.initialized := true
		MetricsFilters.secure_field := false
		_KSD_Acquire({App: "owned-native-keystats.exe", Title: "Owned incomplete-unit receiver", Hwnd: _KID.Window.Hwnd})
		_KSD_Require(KL_Hook_RefreshContext(true) && !MF_ShouldFilter(), "The genuine privacy owner must admit this public receiver.")
		Hook := InputHook(HookDispatcherConst.INPUT_HOOK_OPTS)
		Hook.KeyOpt("{All}", "+N")
		Hook.NotifyNonText := true
		Hook.OnKeyDown := _KID_Down
		Hook.OnChar := _KID_Char
		OnMessage(0x100, _KID_KeyMessage)
		_KID.Active := true
		Hook.Start()
		_KSD_Require(Hook.InProgress, "The exact native InputHook must be active.")
		SendLevel(2)
		for Unit in Units
			_KPU_SendUnicode(Unit)
		Started := A_TickCount
		while TickElapsed64(Started) < 2000 {
			if _KID.CharCalls == Units.Length && _KID.NativeDown == Units.Length
				&& _KID.TargetDown == Units.Length && TickElapsed64(_KID.LastCallback) >= 100
				break
			Sleep(5)
		}
		Before := _KSX_Hex(_KID.Edit.Value)
		FileAppend("OBS high-bs prerequisite mode=" . _KID.Mode . " receiver_before=" . Before
			. " chars=" . _KID.CharCalls . " native=" . _KID.NativeDown . "`n", "*")
		_KSD_Require(Before == BeforeHex && _KID.CharCalls == Units.Length
			&& _KID.NativeDown == Units.Length && _KID.TargetDown == Units.Length,
			"The independent Edit must really contain the exact injected prefix and optional incomplete high unit.")
		; Both revocations are real RAM lifecycle operations with no native output.
		if _KID.Mode == "synth-revoked" {
			Owner := KL_MarkSynthetic("owned-omitted-unit-revocation")
			_KSD_Require(KL_ClearSynthetic(Owner), "The exact synthetic owner must retire without sending text.")
		} else if _KID.Mode == "focus-invalidated"
			KL_InvalidatePasswordFocus()
		_KID_Target()
		_KSD_Require(_KSX_Hex(_KID.Edit.Value) == BeforeHex,
			"The explicit revocation must leave the actual native receiver unchanged.")
		_KID.ExpectedVk := 0x08
		AllCheckpointsMatch := true
		for Step, ExpectedHex in ExpectedReceivers {
			_KSX_SendBackspace()
			Started := A_TickCount
			while TickElapsed64(Started) < 2000 {
				if _KID.NativeDown == Units.Length + Step && _KID.TargetDown == Units.Length + Step
					&& TickElapsed64(_KID.LastCallback) >= 100
					break
				Sleep(5)
			}
			_KID_Target()
			if IsObject(_KID.Failure)
				throw _KID.Failure
			_KSD_Require(_KID.NativeDown == Units.Length + Step && _KID.TargetDown == Units.Length + Step && _KSD.Errors == 0,
				"Every original Backspace must reach the actual receiver and callback without hidden errors.")
			ReceiverHex := _KSX_Hex(_KID.Edit.Value)
			LoggerHex := _KSX_Hex(Keystats.buffer_text)
			FileAppend("OBS revoked-high-bs mode=" . _KID.Mode . " step=" . Step . " receiver_after=" . ReceiverHex
				. " logger_after=" . LoggerHex . " events=" . Keystats.buffer_events.Length . "`n", "*")
			_KSD_Require(ReceiverHex == ExpectedHex,
				"Native Edit must establish the specified UTF-16 deletion trace before any logger verdict.")
			; In the two-high trace, the first remaining high is intentionally
			; malformed. Compare only once native deletion leaves complete text.
			if ExpectedHex == "0041" || ExpectedHex == ""
				AllCheckpointsMatch := AllCheckpointsMatch && LoggerHex == ExpectedHex
		}
		Backspaces := 0
		for Event in Keystats.buffer_events {
			if Event[1] == "[BS]"
				Backspaces += 1
		}
		_KSD_Require(Backspaces == ExpectedReceivers.Length, "Every real Backspace must retain its physical event count.")
		_KSD_Require(AllCheckpointsMatch, "The logger must preserve each complete native checkpoint, including the following ordinary Backspace.")
	} finally {
		try {
			if _KSX.OwedUp
				_KSX_SendBackspace(true)
			StartedUp := A_TickCount
			while (DllCall("GetAsyncKeyState", "Int", 0x08, "Short") & 0x8000) && TickElapsed64(StartedUp) < 1000
				Sleep(5)
			_KSD_Require(!(DllCall("GetAsyncKeyState", "Int", 0x08, "Short") & 0x8000), "The exact injected Backspace must be logically released before receiver retirement.")
		} finally {
			_KID.Active := false
			SendLevel(PreviousLevel)
			try {
				if IsObject(Hook) {
					Hook.Stop()
					_KSD_Require(!Hook.InProgress, "The exact InputHook must retire before its receiver.")
				}
			} finally {
				OnMessage(0x100, _KID_KeyMessage, 0)
				try _KID.Window.Destroy()
				Keystats.initialized := false
			}
		}
	}
}
if A_Args.Length != 3 || A_Args[3] != "--allow-explicit-owned-edit-unicode-input"
	throw Error("Explicit owned Unicode receiver opt-in is required.")
if !(A_Args[1] == "synth-revoked" || A_Args[1] == "focus-invalidated" || A_Args[1] == "two-highs")
	throw Error("A known Backspace scalar prerequisite is required.")
global _KSX := {OwedUp: false}
global _KSD := {Log: A_Args[2] . "\private.log", Errors: 0, Probes: 0, FlushCalls: 0, LogCalls: 0, Failure: 0}
global _KID := {Mode: A_Args[1], Window: 0, Edit: 0, Active: false, NativeDown: 0, TargetDown: 0,
	CharCalls: 0, CharUnits: "", LastCallback: 0, Failure: 0, ReceiverChars: 0, ReceiverUnits: "", DialogRequests: 0,
	ExpectedVk: 0xE7}
try {
	_KSX_Exercise()
	FileAppend("PASS native-keystats " . _KID.Mode . "`n", "*")
	ExitApp(0)
} catch as KSBEntryFailure {
	FileAppend("FAIL high-bs " . KSBEntryFailure.Message . " line=" . KSBEntryFailure.Line . "`n", "*")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*")
	ExitApp(1)
}
