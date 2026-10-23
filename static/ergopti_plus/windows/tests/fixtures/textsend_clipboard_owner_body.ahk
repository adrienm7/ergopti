; tests/fixtures/textsend_clipboard_owner_body.ahk

; Public TextSend owns the real FIFO, native clipboard and restore coordinator.
; The private Edit receives the original SendInput primitive after exact focus
; checks. A second actual process copies only after the real setter returns.
#Requires AutoHotkey v2.0

_TSCO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_TSCO_Publish(Path, Text) {
	_TSCO_Require(!FileExist(Path) && !FileExist(Path . ".pending"), "A private protocol receipt cannot be replaced.")
	FileAppend(Text, Path . ".pending", "UTF-8-RAW")
	FileMove(Path . ".pending", Path)
}

_TSCO_Wait(Path) {
	Started := A_TickCount
	while !FileExist(Path) && TickElapsed(Started) < 3000
		Sleep(10)
	_TSCO_Require(FileExist(Path), "The exact independent clipboard writer did not acknowledge its phase.")
	return FileRead(Path, "UTF-8")
}

_TSCO_Identity(Text, WithSequence := false) {
	Pattern := WithSequence ? "^([0-9]+)\|([0-9]+)\|([0-9]+)$" : "^([0-9]+)\|([0-9]+)$"
	_TSCO_Require(RegExMatch(Text, Pattern, &Match) > 0, "The writer must publish its actual native identity.")
	Identity := {Pid: Integer(Match[1]), Hwnd: Integer(Match[2]), Sequence: WithSequence ? Integer(Match[3]) : 0}
	Pid := 0
	DllCall("User32\GetWindowThreadProcessId", "Ptr", Identity.Hwnd, "UInt*", &Pid)
	_TSCO_Require(Identity.Pid > 0 && Identity.Pid != DllCall("Kernel32\GetCurrentProcessId", "UInt")
		&& Pid == Identity.Pid, "Only the live independent writer HWND may certify its receipt.")
	return Identity
}

_TSCO_RequestCopy(Phase) {
	global _TSCO
	_TSCO_Require(!_TSCO.Copied, "The controlled external copy must occur exactly once.")
	_TSCO.Armed := false
	_TSCO.Boundary := Phase
	_TSCO_Publish(_TSCO.Root . "\copy.request", "copy")
	Identity := _TSCO_Identity(_TSCO_Wait(_TSCO.Root . "\copy.receipt"), true)
	_TSCO_Require(Identity.Pid == _TSCO.Writer.Pid && Identity.Hwnd == _TSCO.Writer.Hwnd,
		"The copy must come from the originally admitted independent process.")
	_TSCO_Require(CB_Read() == _TSCO.Foreign && Identity.Sequence > 0
		&& CB_GetSequenceNumber() == Identity.Sequence
		&& DllCall("User32\GetClipboardOwner", "Ptr") == Identity.Hwnd,
		"The independent process must actually own the exact newly copied native text.")
	_TSCO.Copied := true
	_TSCO.WriterSequence := Identity.Sequence
}

; Decorate only the complete genuine publisher. The native bool and every
; value remain unchanged; this exposes its unlocked return to the real copier.
CB_Write(Text) {
	global _TSCO, _TEXT_CLIPBOARD_OWNER_TOKEN
	try {
		Published := _TSCO_ActualWrite(Text)
		if Published && IsSet(_TSCO) && _TSCO.Armed {
			_TSCO_Require(CB_Read() == _TSCO.Payload && CB_GetSequenceNumber() > 0
				&& DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"The genuine setter must first publish the requested payload under the subject's native HWND.")
			_TSCO_Require(DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd,
				"The independent writer boundary must be outside the setter's real native lease.")
			_TSCO.Token := _TEXT_CLIPBOARD_OWNER_TOKEN
			_TSCO_Require(_TSCO.Token > 0 && CBClipboardOwner.active.Has(_TSCO.Token),
				"The real TextSend FIFO head must hold its exact clipboard transaction.")
			_TSCO_RequestCopy("after-real-setter-before-receipt")
		}
		return Published
	} catch Any as Failure {
		if IsSet(_TSCO) && !IsObject(_TSCO.Failure)
			_TSCO.Failure := Failure
		throw Failure
	}
}

_TSCO_Writer(Root, Mode) {
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	_TSCO_Publish(Root . "\writer.ready", Pid . "|" . A_ScriptHwnd)
	Started := A_TickCount
	Copied := false
	loop {
		if FileExist(Root . "\copy.request") && !Copied {
			; This is the actual independent clipboard mutation, not an adapter port.
			A_Clipboard := Mode == "same-text-copy" ? _TSCO_Payload(Root) : "textsend external B é😀 " . Root
			Sequence := DllCall("User32\GetClipboardSequenceNumber", "UInt")
			_TSCO_Require(Sequence > 0 && DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"The writer must really own its published native clipboard.")
			_TSCO_Publish(Root . "\copy.receipt", Pid . "|" . A_ScriptHwnd . "|" . Sequence)
			Copied := true
		}
		if FileExist(Root . "\subject.done")
			break
		_TSCO_Require(TickElapsed(Started) < 12000, "The independent writer must retire within its private protocol deadline.")
		Sleep(10)
	}
	_TSCO_Require(Copied == (Mode != "current"), "The independent writer must perform exactly the requested copy count.")
	FileAppend("PASS textsend-clipboard-writer " . Mode . " copies=" . (Copied ? 1 : 0) . "`n", "*", "UTF-8-RAW")
}

_TSCO_Payload(Root) {
	Text := "textsend payload P é😀 " . Root . "|"
	loop 100
		Text .= "native paste é😀|"
	return Text
}

_TSCO_OnError(Failure, *) {
	global _TSCO
	if !IsObject(_TSCO.Failure)
		_TSCO.Failure := Failure
	return true
}

_TSCO_Send(Keys) {
	global _TSCO
	try {
		_TSCO_Require(Keys == "^v", "Only the real paste primitive may reach the private target.")
		Focus := _TextSenderNativeFocus()
		_TSCO_Require(Focus["hwnd"] == _TSCO.Gui.Hwnd && Focus["control"] == _TSCO.Edit.Hwnd
			&& Focus["pid"] == DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"No keyboard primitive may target a foreign window or control.")
		for Key in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
			_TSCO_Require(!GetKeyState(Key, "P"), "Physical modifiers must be absent before the private paste.")
		_TSCO.EmittedText := CB_Read()
		_TSCO.EmittedOwner := DllCall("User32\GetClipboardOwner", "Ptr")
		; Reading the clipboard can wait: acquire a fresh native target witness
		; after that callout, immediately before the actual delegated primitive.
		Focus := _TextSenderNativeFocus()
		_TSCO_Require(Focus["hwnd"] == _TSCO.Gui.Hwnd && Focus["control"] == _TSCO.Edit.Hwnd
			&& Focus["pid"] == DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"A clipboard read must not redirect native output to any foreign target.")
		_TSCO.Emissions += 1
		Result := _TSCO.SendPrimitive.Call(Keys)
		_TSCO.Returned += 1
		return Result
	} catch Any as Failure {
		if !IsObject(_TSCO.Failure)
			_TSCO.Failure := Failure
		throw Failure
	}
}

_TSCO_Complete(Ok, ErrorText) {
	global _TSCO
	_TSCO.Calls += 1
	_TSCO.Ok := Ok
	_TSCO.ErrorText := ErrorText
}

_TSCO_RestoreIncoming(Snapshot) {
	global _TSCO, _TEXT_CLIPBOARD_GENERATION, _TEXT_CLIPBOARD_QUEUE
	global _TEXT_CLIPBOARD_OWNER_TOKEN, _TEXT_CLIPBOARD_BUSY
	; Revoke anonymous old restore callbacks before any fixture-owned mutation.
	_TEXT_CLIPBOARD_GENERATION += 1
	SetTimer(_TextSenderStartClipboard, 0)
	SetTimer(_TextSenderFinishClipboard, 0)
	_TEXT_CLIPBOARD_QUEUE.Length := 0
	Token := _TEXT_CLIPBOARD_OWNER_TOKEN
	Debt := CBClipboardOwner.restore_debt
	if Debt is Map {
		_TSCO_Require(Token > 0 && Debt["owner_token"] == Token,
			"Cleanup cannot detach another owner's exact restore debt.")
		_TSCO_Require(_CB_SettleRestoreDebt(Debt), "The exact old debt must retire before cleanup admission.")
	}
	if Token && CBClipboardOwner.active.Has(Token)
		_TSCO_Require(CB_EndOwnedTransaction(Token), "Cleanup must retire only the exact private FIFO head.")
	_TEXT_CLIPBOARD_OWNER_TOKEN := 0
	_TEXT_CLIPBOARD_BUSY := false
	Text := CB_Read(), Sequence := CB_GetSequenceNumber(), Known := false
	_TSCO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "Cleanup must acquire its own real native read lease.")
	try {
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Known := (Text == _TSCO.Seed || Text == _TSCO.Payload || Text == _TSCO.Foreign)
			&& Sequence > 0 && CB_GetSequenceNumber() == Sequence
			&& (Owner == A_ScriptHwnd || Owner == _TSCO.Writer.Hwnd)
	} finally {
		_TSCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "Cleanup must release its own native read lease.")
	}
	if Known {
		CB_RestoreOwnedAllEventually(Snapshot, Sequence, 0, "textsend_clipboard_fixture", false)
		Started := A_TickCount
		while CBClipboardOwner.restore_debt is Map && TickElapsed(Started) < 3000 {
			CB_RetryRestoreDebt()
			Sleep(10)
		}
		_TSCO_Require(!(CBClipboardOwner.restore_debt is Map), "The incoming opaque snapshot must settle or yield to a newer copy.")
	}
	_TSCO_Require(CBClipboardOwner.active.Count == 0 && !CB_IsPasteTransactionActive(),
		"No private clipboard transaction may survive the subject.")
	FileAppend("CLEANUP textsend-clipboard-owner known=" . (Known ? 1 : 0)
		. " unknown_preserved=" . (Known ? 0 : 1) . " debt=0 active=0`n", "*", "UTF-8-RAW")
}

; Independently read the actual CF_UNICODETEXT image while the native lock
; excludes mutation. Compare exact UTF-16 code units, not a sampled sequence alone.
_TSCO_Sample(Expected) {
	_TSCO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The final native clipboard image must be readable under its own bounded lease.")
	try {
		Sequence := CB_GetSequenceNumber()
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Handle := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
		_TSCO_Require(Handle != 0, "The private native clipboard must contain actual Unicode text.")
		Bytes := DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr")
		_TSCO_Require(Bytes >= 2 && Bytes <= 65536, "The private Unicode image must fit its independent read bound.")
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_TSCO_Require(Data != 0, "The exact Unicode data handle must lock successfully.")
		try {
			Units := 0
			while Units * 2 + 2 <= Bytes && NumGet(Data, Units * 2, "UShort") != 0
				Units += 1
			_TSCO_Require(Units * 2 + 2 <= Bytes, "The actual bounded Unicode image must contain its own terminator.")
			RawMatches := Units == StrLen(Expected)
			if RawMatches {
				loop Units
					if NumGet(Data, (A_Index - 1) * 2, "UShort") != NumGet(StrPtr(Expected), (A_Index - 1) * 2, "UShort") {
						RawMatches := false
						break
					}
			}
			Text := Units ? StrGet(Data, -Units, "UTF-16") : ""
		} finally {
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
			_TSCO_Require(Unlocked != 0 || A_LastError == 0, "The exact Unicode handle must unlock without an OS error.")
		}
		_TSCO_Require(Sequence > 0 && CB_GetSequenceNumber() == Sequence
			&& DllCall("User32\GetClipboardOwner", "Ptr") == Owner,
			"The exact native owner and sequence must remain stable throughout the locked raw read.")
		return {Text: Text, Sequence: Sequence, Owner: Owner, RawMatches: RawMatches, RawUnits: Units}
	} finally {
		_TSCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The final native sample must release only its own clipboard lease.")
	}
}

_TSCO_Subject(Root, Mode) {
	global _TSCO, _AHK_SendInput, _TEXT_CLIPBOARD_BUSY, _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_OWNER_TOKEN
	global TEXT_CLIPBOARD_THRESHOLD
	Payload := _TSCO_Payload(Root)
	_TSCO := {Root: Root, Armed: false, Copied: false, Boundary: "none", WriterSequence: 0,
		Seed: "textsend original A é😀 " . Root, Payload: Payload,
		Foreign: Mode == "same-text-copy" ? Payload : "textsend external B é😀 " . Root,
		Failure: 0, Calls: 0, Ok: false, ErrorText: "", Emissions: 0, Returned: 0,
		EmittedText: "", EmittedOwner: 0, Token: 0, Gui: 0, Edit: 0, SendPrimitive: _AHK_SendInput}
	Primary := 0, Snapshot := 0, HaveSnapshot := false
	OnError(_TSCO_OnError)
	try {
		_TSCO.Writer := _TSCO_Identity(_TSCO_Wait(Root . "\writer.ready"))
		_TSCO_Require(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.restore_debt
			&& !CBClipboardOwner.observer_active && !_TEXT_CLIPBOARD_BUSY && _TEXT_CLIPBOARD_QUEUE.Length == 0,
			"A fresh real sender and clipboard owner must have no inherited observer, queue or debt.")
		Snapshot := CB_SaveAll()
		_TSCO_Require(!(Snapshot is String && Snapshot == "__CB_SAVE_ERROR__"), "The incoming opaque clipboard must be captured.")
		HaveSnapshot := true
		_TSCO_Require(CB_Write(_TSCO.Seed) && CB_Read() == _TSCO.Seed, "Actual original clipboard A must be present.")
		_TSCO.Gui := Gui("+AlwaysOnTop", "Private TextSend clipboard owner")
		_TSCO.Edit := _TSCO.Gui.AddEdit("w600 h120", "")
		_TSCO.Gui.Show()
		WinActivate("ahk_id " . _TSCO.Gui.Hwnd)
		_TSCO.Edit.Focus()
		_TSCO_Require(WinWaitActive("ahk_id " . _TSCO.Gui.Hwnd, , 1),
			"The exact private GUI must own foreground focus before the public request.")
		Focus := _TextSenderNativeFocus()
		_TSCO_Require(Focus["hwnd"] == _TSCO.Gui.Hwnd && Focus["control"] == _TSCO.Edit.Hwnd,
			"The exact private native Edit must own keyboard focus before the public request.")
		_TSCO_Require(StrLen(Payload) > TEXT_CLIPBOARD_THRESHOLD, "The real auto-mode threshold must select the clipboard FIFO.")
		_AHK_SendInput := _TSCO_Send
		_TSCO.Armed := Mode != "current"
		TextSend(Payload, Map("mode", "auto"), _TSCO_Complete)
		Started := A_TickCount
		while (_TSCO.Calls == 0 || _TEXT_CLIPBOARD_BUSY || _TEXT_CLIPBOARD_QUEUE.Length > 0
			|| CBClipboardOwner.restore_debt is Map) && TickElapsed(Started) < 3000 {
			if IsObject(_TSCO.Failure)
				throw _TSCO.Failure
			Sleep(10)
		}
		if IsObject(_TSCO.Failure)
			throw _TSCO.Failure
		_TSCO_Require(_TSCO.Calls == 1 && !_TEXT_CLIPBOARD_BUSY && _TEXT_CLIPBOARD_QUEUE.Length == 0
			&& _TEXT_CLIPBOARD_OWNER_TOKEN == 0 && CBClipboardOwner.active.Count == 0
			&& !(CBClipboardOwner.restore_debt is Map), "The real public request and exact FIFO/debt owners must settle before sampling.")
		if Mode != "current"
			_TSCO_Require(_TSCO.Copied && _TSCO.WriterSequence > 0
				&& _TSCO.Boundary == "after-real-setter-before-receipt",
				"The independent process must actually copy at the unlocked native-setter boundary.")
		Sample := _TSCO_Sample(Mode == "current" ? _TSCO.Seed : _TSCO.Foreign)
		Observed := Sample.Text, Sequence := Sample.Sequence, Owner := Sample.Owner
		FinalEdit := _TSCO.Edit.Value
		FileAppend("RECEIPT textsend-clipboard-owner mode=" . Mode . " copies=" . (_TSCO.Copied ? 1 : 0)
			. " writer_pid=" . _TSCO.Writer.Pid . " writer_hwnd=" . _TSCO.Writer.Hwnd
			. " writer_sequence=" . _TSCO.WriterSequence . " final_sequence=" . Sequence . " final_owner=" . Owner
			. " raw_match=" . (Sample.RawMatches ? 1 : 0) . " raw_units=" . Sample.RawUnits
			. " final_external=" . (Observed == _TSCO.Foreign ? 1 : 0) . " restored_a=" . (Observed == _TSCO.Seed ? 1 : 0)
			. " callbacks=" . _TSCO.Calls . " ok=" . (_TSCO.Ok ? 1 : 0) . " emissions=" . _TSCO.Emissions
			. " returned=" . _TSCO.Returned . " edit_payload=" . (FinalEdit == Payload ? 1 : 0)
			. " emitted_foreign_owner=" . (_TSCO.EmittedOwner == _TSCO.Writer.Hwnd ? 1 : 0) . "`n", "*", "UTF-8-RAW")
		if Mode == "current" {
			_TSCO_Require(_TSCO.Ok && _TSCO.Emissions == 1 && _TSCO.Returned == 1
				&& _TSCO.EmittedText == Payload && FinalEdit == Payload,
				"Current TextSend must genuinely paste its payload into the private native Edit.")
			_TSCO_Require(Sample.RawMatches && Observed == _TSCO.Seed, "The current public paste must restore its actual original A.")
		} else {
			_TSCO_Require(Sample.RawMatches && Observed == _TSCO.Foreign && Sequence == _TSCO.WriterSequence && Owner == _TSCO.Writer.Hwnd,
				"A newer independent clipboard copy must survive real TextSend completion with its exact native owner and sequence.")
			_TSCO_Require(_TSCO.Emissions == 0 && FinalEdit == "",
				"A public paste must refuse clipboard content owned by the independent copier, including identical text.")
		}
	} catch Any as Failure {
		Primary := Failure
	} finally {
		_TSCO.Armed := false
		_AHK_SendInput := _TSCO.SendPrimitive
		try {
			if HaveSnapshot
				_TSCO_RestoreIncoming(Snapshot)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			try {
				if IsObject(_TSCO.Gui)
					_TSCO.Gui.Destroy()
			} catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			} finally {
				OnError(_TSCO_OnError, 0)
				try _TSCO_Publish(Root . "\subject.done", "done")
				catch Any as Failure {
					if !IsObject(Primary)
						Primary := Failure
				}
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS textsend-clipboard-owner " . Mode . "`n", "*", "UTF-8-RAW")
}

try {
	_TSCO_Require(A_Args.Length == 3 && (A_Args[3] == "current" || A_Args[3] == "different-copy" || A_Args[3] == "same-text-copy"),
		"The private child requires its explicit role, directory and mode.")
	Critical("Off")
	Suspend(false)
	if A_Args[1] == "writer"
		_TSCO_Writer(A_Args[2], A_Args[3])
	else {
		_TSCO_Require(A_Args[1] == "subject", "Only the two declared private roles may execute.")
		_TSCO_Subject(A_Args[2], A_Args[3])
	}
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}
