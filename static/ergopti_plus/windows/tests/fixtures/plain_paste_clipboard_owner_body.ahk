; tests/fixtures/plain_paste_clipboard_owner_body.ahk

; Both real plain-paste clients share the native clipboard contract. A separate
; process publishes after the genuine setter returns. Only the private Edit
; receives the unchanged native injection; no clipboard operation is faked.
#Requires AutoHotkey v2.0

_PPCO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_PPCO_Publish(Path, Text) {
	_PPCO_Require(!FileExist(Path) && !FileExist(Path . ".pending"), "A private protocol receipt cannot be replaced.")
	FileAppend(Text, Path . ".pending", "UTF-8-RAW")
	FileMove(Path . ".pending", Path)
}

_PPCO_Wait(Path) {
	Started := A_TickCount
	while !FileExist(Path) && TickElapsed(Started) < 3000
		Sleep(10)
	_PPCO_Require(FileExist(Path), "The exact independent clipboard writer did not acknowledge its phase.")
	return FileRead(Path, "UTF-8")
}

_PPCO_Identity(Text, WithSequence := false) {
	Pattern := WithSequence ? "^([0-9]+)\|([0-9]+)\|([0-9]+)$" : "^([0-9]+)\|([0-9]+)$"
	_PPCO_Require(RegExMatch(Text, Pattern, &Match) > 0, "The writer must publish its actual native identity.")
	Identity := {Pid: Integer(Match[1]), Hwnd: Integer(Match[2]), Sequence: WithSequence ? Integer(Match[3]) : 0}
	Pid := 0
	DllCall("User32\GetWindowThreadProcessId", "Ptr", Identity.Hwnd, "UInt*", &Pid)
	_PPCO_Require(Identity.Pid > 0 && Identity.Pid != DllCall("Kernel32\GetCurrentProcessId", "UInt")
		&& Pid == Identity.Pid, "Only the live independent writer HWND may certify its receipt.")
	return Identity
}

_PPCO_RequestCopy(Phase) {
	global _PPCO
	_PPCO_Require(!_PPCO.Copied, "The controlled external copy must occur exactly once.")
	_PPCO.Armed := false
	_PPCO.Boundary := Phase
	_PPCO_Publish(_PPCO.Root . "\copy.request", "copy")
	Identity := _PPCO_Identity(_PPCO_Wait(_PPCO.Root . "\copy.receipt"), true)
	_PPCO_Require(Identity.Pid == _PPCO.Writer.Pid && Identity.Hwnd == _PPCO.Writer.Hwnd,
		"The copy must come from the originally admitted independent process.")
	_PPCO_Require(CB_Read() == _PPCO.Foreign && Identity.Sequence > 0
		&& CB_GetSequenceNumber() == Identity.Sequence
		&& DllCall("User32\GetClipboardOwner", "Ptr") == Identity.Hwnd,
		"The independent process must actually own the exact newly copied native text.")
	_PPCO.Copied := true
	_PPCO.WriterSequence := Identity.Sequence
}

; Decorate the real unlocked publisher selected by source shape. The same
; assertions and independent writer run before the genuine receipt acquisition.
_PPCO_ObservePublished() {
	global _PPCO
	_PPCO_Require(A_IsCritical == _PPCO.CallerCritical,
		"The genuine setter boundary must preserve the calling frame's Critical state.")
	_PPCO_Require(CB_Read() == _PPCO.Payload && CB_GetSequenceNumber() > 0
		&& DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
		"The genuine setter must first publish its exact payload under the subject HWND.")
	_PPCO_Require(DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd
		&& !DllCall("User32\IsClipboardFormatAvailable", "UInt", _PPCO.Format, "Int"),
		"The setter must release its native lease and replace the original custom format.")
	_PPCO.Token := CBClipboardOwner.paste_transaction
	_PPCO_Require(_PPCO.Token > 0 && CBClipboardOwner.active.Count == 1
		&& CBClipboardOwner.active.Has(_PPCO.Token)
		&& CBClipboardOwner.active[_PPCO.Token]["source"] == _PPCO.Source,
		"The genuine public client must own its exact admitted paste transaction.")
	_PPCO.SetterCalls += 1
	if _PPCO.Mode != "current"
		_PPCO_RequestCopy("after-real-setter-before-receipt")
	else
		_PPCO.Armed := false
	FileAppend("PUBLISHER_FIRED native=" . (_PPCO_UsesNativeMutation ? 1 : 0) . " calls=" . _PPCO.SetterCalls . "`n", "*", "UTF-8-RAW")
}

_CB_PlainNativeMutationCAS(Record, Text) {
	global _PPCO
	try {
		Result := _PPCO_ActualNativeMutationCAS(Record, Text)
		if IsSet(_PPCO) && _PPCO.Armed && Record["published"] && !Record["lease_unknown"]
			_PPCO_ObservePublished()
		return Result
	} catch Any as Failure {
		if IsSet(_PPCO) && !IsObject(_PPCO.Failure)
			_PPCO.Failure := Failure
		throw Failure
	}
}

CB_Write(Text) {
	global _PPCO
	try {
		Published := _PPCO_ActualWrite(Text)
		if Published && !_PPCO_UsesNativeMutation && IsSet(_PPCO) && _PPCO.Armed
			_PPCO_ObservePublished()
		return Published
	} catch Any as Failure {
		if IsSet(_PPCO) && !IsObject(_PPCO.Failure)
			_PPCO.Failure := Failure
		throw Failure
	}
}

_PPCO_Writer(Root, Mode) {
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	_PPCO_Publish(Root . "\writer.ready", Pid . "|" . A_ScriptHwnd)
	Started := A_TickCount
	Copied := false
	loop {
		if FileExist(Root . "\copy.request") && !Copied {
			; This is the actual independent clipboard mutation, not an adapter port.
			A_Clipboard := Mode == "same-text-copy" ? _PPCO_Payload(Root) : "plain-paste external B é😀 " . Root
			Sequence := DllCall("User32\GetClipboardSequenceNumber", "UInt")
			_PPCO_Require(Sequence > 0 && DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"The writer must really own its published native clipboard.")
			_PPCO_Publish(Root . "\copy.receipt", Pid . "|" . A_ScriptHwnd . "|" . Sequence)
			Copied := true
		}
		if FileExist(Root . "\subject.done")
			break
		_PPCO_Require(TickElapsed(Started) < 12000, "The independent writer must retire within its private protocol deadline.")
		Sleep(10)
	}
	_PPCO_Require(Copied == (Mode != "current"), "The independent writer must perform exactly the requested copy count.")
	FileAppend("PASS plain-paste-clipboard-writer " . Mode . " copies=" . (Copied ? 1 : 0) . "`n", "*", "UTF-8-RAW")
}

_PPCO_Payload(Root) {
	Text := "plain-paste payload P é😀 " . Root . "|"
	loop 100
		Text .= "native paste é😀|"
	return Text
}

_PPCO_OnError(Failure, *) {
	global _PPCO
	if !IsObject(_PPCO.Failure)
		_PPCO.Failure := Failure
	return true
}

_PPCO_Send(Keys) {
	global _PPCO
	try {
		_PPCO_Require(Keys == "^v", "Only the real paste primitive may reach the private target.")
		Focus := _TextSenderNativeFocus()
		_PPCO_Require(Focus["hwnd"] == _PPCO.Gui.Hwnd && Focus["control"] == _PPCO.Edit.Hwnd
			&& Focus["pid"] == DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"No keyboard primitive may target a foreign window or control.")
		for Key in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
			_PPCO_Require(!GetKeyState(Key, "P"), "Physical modifiers must be absent before the private paste.")
		_PPCO.EmittedText := CB_Read()
		_PPCO.EmittedOwner := DllCall("User32\GetClipboardOwner", "Ptr")
		; Reading the clipboard can wait: acquire a fresh native target witness
		; after that callout, immediately before the actual delegated primitive.
		Focus := _TextSenderNativeFocus()
		_PPCO_Require(Focus["hwnd"] == _PPCO.Gui.Hwnd && Focus["control"] == _PPCO.Edit.Hwnd
			&& Focus["pid"] == DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"A clipboard read must not redirect native output to any foreign target.")
		_PPCO.Emissions += 1
		Result := _PPCO.SendPrimitive.Call(Keys)
		_PPCO.Returned += 1
		return Result
	} catch Any as Failure {
		if !IsObject(_PPCO.Failure)
			_PPCO.Failure := Failure
		throw Failure
	}
}

_PPCO_Settle(CheckFailure := true) {
	global _PPCO
	Started := A_TickCount
	while (CBClipboardOwner.active.Count || CBClipboardOwner.restore_debt is Map
			|| CBClipboardOwner.paste_transaction) && TickElapsed(Started) < 3000 {
		if CheckFailure && IsObject(_PPCO.Failure)
			throw _PPCO.Failure
		if CBClipboardOwner.restore_debt is Map
			CB_RetryRestoreDebt()
		Sleep(10)
	}
	_PPCO_Require(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.paste_transaction
		&& !(CBClipboardOwner.restore_debt is Map), "The actual restore callback and exact debt must settle before sampling or cleanup.")
}

_PPCO_RestoreIncoming(Snapshot) {
	global _PPCO
	; Never detach a live client's owner or guess its anonymous restore callback.
	; An unknown retirement retains the incoming snapshot without overwriting it.
	_PPCO_Settle(false)
	Text := CB_Read(), Sequence := CB_GetSequenceNumber(), Known := false
	_PPCO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "Cleanup must acquire its own actual native lease.")
	try {
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Known := (Text == _PPCO.Seed || Text == _PPCO.Payload || Text == _PPCO.Foreign)
			&& Sequence > 0 && CB_GetSequenceNumber() == Sequence
			&& (Owner == A_ScriptHwnd || Owner == _PPCO.Writer.Hwnd)
	} finally {
		_PPCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "Cleanup must release only its own read lease.")
	}
	if Known {
		CB_RestoreOwnedAllEventually(Snapshot, Sequence, 0, "plain-paste_clipboard_fixture", false)
		_PPCO_Settle(false)
	}
	FileAppend("CLEANUP plain-paste-clipboard-owner known=" . (Known ? 1 : 0)
		. " unknown_preserved=" . (Known ? 0 : 1) . " debt=0 active=0`n", "*", "UTF-8-RAW")
}

; Add a genuine non-text format to the original clipboard, not to the payload.
; ClipboardAll must restore this exact image along with the Unicode text.
_PPCO_AddOriginalFormat() {
	global _PPCO
	_PPCO.Format := DllCall("User32\RegisterClipboardFormatW", "WStr", "Ergopti.Private.PlainPaste.Original", "UInt")
	_PPCO_Require(_PPCO.Format >= 0xC000, "The private native format must register successfully.")
	Bytes := (StrLen(_PPCO.Marker) + 1) * 2
	Handle := DllCall("Kernel32\GlobalAlloc", "UInt", 0x42, "UPtr", Bytes, "Ptr")
	_PPCO_Require(Handle != 0, "The private original format must allocate its actual native image.")
	Transferred := false, Opened := false
	try {
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_PPCO_Require(Data != 0, "The original private format must lock.")
		try StrPut(_PPCO.Marker, Data, StrLen(_PPCO.Marker) + 1, "UTF-16")
		finally {
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
			_PPCO_Require(Unlocked != 0 || A_LastError == 0, "The private allocation must unlock without an OS error.")
		}
		Opened := CB_OpenClipboardWithin(A_ScriptHwnd)
		_PPCO_Require(Opened, "The original clipboard must admit the extra native format.")
		_PPCO_Require(DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
			"The fixture may add a format only to its own original clipboard.")
		Transferred := DllCall("User32\SetClipboardData", "UInt", _PPCO.Format, "Ptr", Handle, "Ptr") == Handle
		_PPCO_Require(Transferred, "The extra original format must transfer to Windows.")
	} finally {
		if Opened
			_PPCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The private original-format lease must close.")
		if !Transferred
			_PPCO_Require(DllCall("Kernel32\GlobalFree", "Ptr", Handle, "Ptr") == 0,
				"Only an untransferred fixture allocation may be freed.")
	}
}

_PPCO_MarkerMatches() {
	global _PPCO
	_PPCO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The restored non-text format must admit its own native read lease.")
	try {
		Handle := DllCall("User32\GetClipboardData", "UInt", _PPCO.Format, "Ptr")
		if !Handle
			return false
		Bytes := DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr")
		ExpectedBytes := (StrLen(_PPCO.Marker) + 1) * 2
		if Bytes < ExpectedBytes || Bytes > 65536
			return false
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_PPCO_Require(Data != 0, "The restored extra format must lock its own handle.")
		try {
			loop StrLen(_PPCO.Marker)
				if NumGet(Data, (A_Index - 1) * 2, "UShort") != NumGet(StrPtr(_PPCO.Marker), (A_Index - 1) * 2, "UShort")
					return false
			return NumGet(Data, StrLen(_PPCO.Marker) * 2, "UShort") == 0
		} finally {
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
			_PPCO_Require(Unlocked != 0 || A_LastError == 0, "The restored extra format must unlock.")
		}
	} finally {
		_PPCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The restored extra-format lease must close.")
	}
}

; Independently read the actual CF_UNICODETEXT image while the native lock
; excludes mutation. Compare exact UTF-16 code units, not a sampled sequence alone.
_PPCO_Sample(Expected) {
	_PPCO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The final native clipboard image must be readable under its own bounded lease.")
	try {
		Sequence := CB_GetSequenceNumber()
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Handle := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
		_PPCO_Require(Handle != 0, "The private native clipboard must contain actual Unicode text.")
		Bytes := DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr")
		_PPCO_Require(Bytes >= 2 && Bytes <= 65536, "The private Unicode image must fit its independent read bound.")
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_PPCO_Require(Data != 0, "The exact Unicode data handle must lock successfully.")
		try {
			Units := 0
			while Units * 2 + 2 <= Bytes && NumGet(Data, Units * 2, "UShort") != 0
				Units += 1
			_PPCO_Require(Units * 2 + 2 <= Bytes, "The actual bounded Unicode image must contain its own terminator.")
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
			_PPCO_Require(Unlocked != 0 || A_LastError == 0, "The exact Unicode handle must unlock without an OS error.")
		}
		_PPCO_Require(Sequence > 0 && CB_GetSequenceNumber() == Sequence
			&& DllCall("User32\GetClipboardOwner", "Ptr") == Owner,
			"The exact native owner and sequence must remain stable throughout the locked raw read.")
		return {Text: Text, Sequence: Sequence, Owner: Owner, RawMatches: RawMatches, RawUnits: Units}
	} finally {
		_PPCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The final native sample must release only its own clipboard lease.")
	}
}

_PPCO_Subject(Root, Mode) {
	global _PPCO, _SendHook
	Payload := _PPCO_Payload(Root)
	_PPCO := {Root: Root, Mode: Mode, Armed: false, Copied: false, Boundary: "none", WriterSequence: 0,
		Seed: Payload, Payload: Payload,
		Foreign: Mode == "same-text-copy" ? Payload : "plain-paste external B é😀 " . Root,
		Marker: "opaque original format é😀 " . Root, Format: 0,
		Source: A_Args[5] == "gesture" ? "gesture_paste_plain" : "paste_without_formatting",
		Failure: 0, Completed: false, Emissions: 0, Returned: 0, SetterCalls: 0, CallerCritical: 0,
		EmittedText: "", EmittedOwner: 0, Token: 0, Gui: 0, Edit: 0, SendPrimitive: SendInput}
	Primary := 0, Snapshot := 0, HaveSnapshot := false
	OnError(_PPCO_OnError)
	try {
		_PPCO.Writer := _PPCO_Identity(_PPCO_Wait(Root . "\writer.ready"))
		_PPCO_Require(_SendHook == 0 && CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.restore_debt
			&& !CBClipboardOwner.paste_transaction && !CBClipboardOwner.observer_active,
			"The genuine client must begin without a test send hook, inherited owner, observer or debt.")
		Snapshot := CB_SaveAll()
		_PPCO_Require(!(Snapshot is String && Snapshot == "__CB_SAVE_ERROR__"), "The incoming opaque clipboard must be captured.")
		HaveSnapshot := true
		_PPCO_Require(CB_Write(_PPCO.Seed) && CB_Read() == _PPCO.Seed, "Actual original clipboard A must be present.")
		_PPCO_AddOriginalFormat()
		_PPCO_Require(_PPCO_MarkerMatches(), "The real original must contain the exact extra format before the client snapshots it.")
		_PPCO.Gui := Gui("+AlwaysOnTop", "Private Plain paste clipboard owner")
		_PPCO.Edit := _PPCO.Gui.AddEdit("w600 h120", "")
		_PPCO.Gui.Show()
		WinActivate("ahk_id " . _PPCO.Gui.Hwnd)
		_PPCO.Edit.Focus()
		_PPCO_Require(WinWaitActive("ahk_id " . _PPCO.Gui.Hwnd, , 1), "The exact private GUI must own foreground focus.")
		Focus := _TextSenderNativeFocus()
		_PPCO_Require(Focus["hwnd"] == _PPCO.Gui.Hwnd && Focus["control"] == _PPCO.Edit.Hwnd,
			"The exact private Edit must own focus before the real public client runs.")
		_PPCO.Armed := true
		_PPCO_Require(CB_Read() == Payload && !WinActive("ahk_exe EXCEL.EXE"),
			"The actual text clipboard and exact private non-Excel target must select the coercing client path.")
		_PPCO.CallerCritical := A_IsCritical
		_PPCO_Invoke()
		_PPCO.Completed := true
		_PPCO_Require(A_IsCritical == _PPCO.CallerCritical, "The API must preserve the calling frame's Critical state.")
		_PPCO_Settle()
		if IsObject(_PPCO.Failure)
			throw _PPCO.Failure
		_PPCO_Require(_PPCO.SetterCalls == 1 && _PPCO.Token > 0, "The genuine client must admit exactly one native payload write.")
		if Mode != "current"
			_PPCO_Require(_PPCO.Copied && _PPCO.WriterSequence > 0 && _PPCO.Boundary == "after-real-setter-before-receipt",
				"The independent process must actually copy at the unlocked real setter boundary.")
		Sample := _PPCO_Sample(Mode == "current" ? _PPCO.Seed : _PPCO.Foreign)
		FinalEdit := _PPCO.Edit.Value
		FileAppend("RECEIPT plain-paste-clipboard-owner mode=" . Mode . " copies=" . (_PPCO.Copied ? 1 : 0)
			. " caller_critical=" . _PPCO.CallerCritical . " setter_calls=" . _PPCO.SetterCalls
			. " writer_pid=" . _PPCO.Writer.Pid . " writer_hwnd=" . _PPCO.Writer.Hwnd
			. " writer_sequence=" . _PPCO.WriterSequence . " final_sequence=" . Sample.Sequence . " final_owner=" . Sample.Owner
			. " raw_match=" . (Sample.RawMatches ? 1 : 0) . " raw_units=" . Sample.RawUnits
			. " completed=" . (_PPCO.Completed ? 1 : 0) . " emissions=" . _PPCO.Emissions . " returned=" . _PPCO.Returned
			. " edit_payload=" . (FinalEdit == Payload ? 1 : 0) . "`n", "*", "UTF-8-RAW")
		if Mode == "current" {
			_PPCO_Require(_PPCO.Completed && _PPCO.Emissions == 1 && _PPCO.Returned == 1
				&& _PPCO.EmittedText == Payload && FinalEdit == Payload,
				"Current Plain paste must genuinely paste into the exact private native Edit.")
			_PPCO_Require(Sample.RawMatches && Sample.Text == _PPCO.Seed && _PPCO_MarkerMatches(),
				"Current Plain paste must restore actual original A including its extra non-text format.")
		} else {
			_PPCO_Require(Sample.RawMatches && Sample.Text == _PPCO.Foreign
				&& Sample.Sequence == _PPCO.WriterSequence && Sample.Owner == _PPCO.Writer.Hwnd,
				"The newer independent copy must survive the actual Plain paste restore with its exact native owner and sequence.")
			_PPCO_Require(_PPCO.Completed && _PPCO.Emissions == 0 && _PPCO.Returned == 0 && FinalEdit == "",
				"Plain paste must refuse foreign clipboard content without any native emission, even for identical text.")
		}
	} catch Any as Failure {
		Primary := Failure
	} finally {
		_PPCO.Armed := false
		try {
			if HaveSnapshot
				_PPCO_RestoreIncoming(Snapshot)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			try {
				if IsObject(_PPCO.Gui)
					_PPCO.Gui.Destroy()
			} catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			} finally {
				OnError(_PPCO_OnError, 0)
				try _PPCO_Publish(Root . "\subject.done", "done")
				catch Any as Failure {
					if !IsObject(Primary)
						Primary := Failure
				}
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS plain-paste-clipboard-owner " . Mode . "`n", "*", "UTF-8-RAW")
}

try {
	_PPCO_Require(A_Args.Length == 5 && (A_Args[5] == "gesture" || A_Args[5] == "shortcut") && Integer(A_Args[4]) > 0 && Integer(A_Args[4]) <= 1000 && (A_Args[3] == "current" || A_Args[3] == "different-copy" || A_Args[3] == "same-text-copy"),
		"The private child requires its explicit role, directory and mode.")
	Critical("Off")
	Suspend(false)
	if A_Args[1] == "writer"
		_PPCO_Writer(A_Args[2], A_Args[3])
	else {
		_PPCO_Require(A_Args[1] == "subject", "Only the two declared private roles may execute.")
		_PPCO_Subject(A_Args[2], A_Args[3])
	}
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}
