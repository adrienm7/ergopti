; tests/fixtures/sendinstant_clipboard_owner_body.ahk

; Actual SendInstant runs under its real caller's Critical contract. A separate
; native process can publish after the genuine setter returns without admitting
; a same-process timer. Only the private Edit receives delegated native input.
#Requires AutoHotkey v2.0

_SICO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_SICO_Publish(Path, Text) {
	_SICO_Require(!FileExist(Path) && !FileExist(Path . ".pending"), "A private protocol receipt cannot be replaced.")
	FileAppend(Text, Path . ".pending", "UTF-8-RAW")
	FileMove(Path . ".pending", Path)
}

_SICO_Wait(Path) {
	Started := A_TickCount
	while !FileExist(Path) && TickElapsed(Started) < 3000
		Sleep(10)
	_SICO_Require(FileExist(Path), "The exact independent clipboard writer did not acknowledge its phase.")
	return FileRead(Path, "UTF-8")
}

_SICO_Identity(Text, WithSequence := false) {
	Pattern := WithSequence ? "^([0-9]+)\|([0-9]+)\|([0-9]+)$" : "^([0-9]+)\|([0-9]+)$"
	_SICO_Require(RegExMatch(Text, Pattern, &Match) > 0, "The writer must publish its actual native identity.")
	Identity := {Pid: Integer(Match[1]), Hwnd: Integer(Match[2]), Sequence: WithSequence ? Integer(Match[3]) : 0}
	Pid := 0
	DllCall("User32\GetWindowThreadProcessId", "Ptr", Identity.Hwnd, "UInt*", &Pid)
	_SICO_Require(Identity.Pid > 0 && Identity.Pid != DllCall("Kernel32\GetCurrentProcessId", "UInt")
		&& Pid == Identity.Pid, "Only the live independent writer HWND may certify its receipt.")
	return Identity
}

_SICO_RequestCopy(Phase) {
	global _SICO
	_SICO_Require(!_SICO.Copied, "The controlled external copy must occur exactly once.")
	_SICO.Armed := false
	_SICO.Boundary := Phase
	_SICO_Publish(_SICO.Root . "\copy.request", "copy")
	Identity := _SICO_Identity(_SICO_Wait(_SICO.Root . "\copy.receipt"), true)
	_SICO_Require(Identity.Pid == _SICO.Writer.Pid && Identity.Hwnd == _SICO.Writer.Hwnd,
		"The copy must come from the originally admitted independent process.")
	_SICO_Require(CB_Read() == _SICO.Foreign && Identity.Sequence > 0
		&& CB_GetSequenceNumber() == Identity.Sequence
		&& DllCall("User32\GetClipboardOwner", "Ptr") == Identity.Hwnd,
		"The independent process must actually own the exact newly copied native text.")
	_SICO.Copied := true
	_SICO.WriterSequence := Identity.Sequence
}

; Decorate only the complete genuine publisher. The native bool and every
; value remain unchanged; this exposes its unlocked return to the real copier.
CB_Write(Text) {
	global _SICO
	try {
		Published := _SICO_ActualWrite(Text)
		if Published && IsSet(_SICO) && _SICO.Armed {
			_SICO_Require(A_IsCritical == _SICO.CallerCritical && A_IsCritical > 0,
				"The setter boundary must retain the genuine caller's Critical state.")
			_SICO_Require(CB_Read() == _SICO.Payload && CB_GetSequenceNumber() > 0
				&& DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"The genuine setter must first publish its exact payload under the subject HWND.")
			_SICO_Require(DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd
				&& !DllCall("User32\IsClipboardFormatAvailable", "UInt", _SICO.Format, "Int"),
				"The setter must release its native lease and replace the original custom format.")
			_SICO.Token := CBClipboardOwner.paste_transaction
			_SICO_Require(_SICO.Token > 0 && CBClipboardOwner.active.Count == 1
				&& CBClipboardOwner.active.Has(_SICO.Token)
				&& CBClipboardOwner.active[_SICO.Token]["source"] == "hotstring_send_instant",
				"The genuine public client must own its exact admitted paste transaction.")
			_SICO.SetterCalls += 1
			if _SICO.Mode != "current"
				_SICO_RequestCopy("after-real-setter-before-receipt")
			else
				_SICO.Armed := false
		}
		return Published
	} catch Any as Failure {
		if IsSet(_SICO) && !IsObject(_SICO.Failure)
			_SICO.Failure := Failure
		throw Failure
	}
}

_SICO_Writer(Root, Mode) {
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	_SICO_Publish(Root . "\writer.ready", Pid . "|" . A_ScriptHwnd)
	Started := A_TickCount
	Copied := false
	loop {
		if FileExist(Root . "\copy.request") && !Copied {
			; This is the actual independent clipboard mutation, not an adapter port.
			A_Clipboard := Mode == "same-text-copy" ? _SICO_Payload(Root) : "sendinstant external B é😀 " . Root
			Sequence := DllCall("User32\GetClipboardSequenceNumber", "UInt")
			_SICO_Require(Sequence > 0 && DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"The writer must really own its published native clipboard.")
			_SICO_Publish(Root . "\copy.receipt", Pid . "|" . A_ScriptHwnd . "|" . Sequence)
			Copied := true
		}
		if FileExist(Root . "\subject.done")
			break
		_SICO_Require(TickElapsed(Started) < 12000, "The independent writer must retire within its private protocol deadline.")
		Sleep(10)
	}
	_SICO_Require(Copied == (Mode != "current"), "The independent writer must perform exactly the requested copy count.")
	FileAppend("PASS sendinstant-clipboard-writer " . Mode . " copies=" . (Copied ? 1 : 0) . "`n", "*", "UTF-8-RAW")
}

_SICO_Payload(Root) {
	Text := "sendinstant payload P é😀 " . Root . "|"
	loop 100
		Text .= "native paste é😀|"
	return Text
}

_SICO_OnError(Failure, *) {
	global _SICO
	if !IsObject(_SICO.Failure)
		_SICO.Failure := Failure
	return true
}

_SICO_Send(Keys) {
	global _SICO
	try {
		_SICO_Require(Keys == "^v", "Only the real paste primitive may reach the private target.")
		Focus := _TextSenderNativeFocus()
		_SICO_Require(Focus["hwnd"] == _SICO.Gui.Hwnd && Focus["control"] == _SICO.Edit.Hwnd
			&& Focus["pid"] == DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"No keyboard primitive may target a foreign window or control.")
		for Key in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
			_SICO_Require(!GetKeyState(Key, "P"), "Physical modifiers must be absent before the private paste.")
		_SICO.EmittedText := CB_Read()
		_SICO.EmittedOwner := DllCall("User32\GetClipboardOwner", "Ptr")
		; Reading the clipboard can wait: acquire a fresh native target witness
		; after that callout, immediately before the actual delegated primitive.
		Focus := _TextSenderNativeFocus()
		_SICO_Require(Focus["hwnd"] == _SICO.Gui.Hwnd && Focus["control"] == _SICO.Edit.Hwnd
			&& Focus["pid"] == DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"A clipboard read must not redirect native output to any foreign target.")
		_SICO.Emissions += 1
		Result := _SICO.SendPrimitive.Call(Keys)
		_SICO.Returned += 1
		return Result
	} catch Any as Failure {
		if !IsObject(_SICO.Failure)
			_SICO.Failure := Failure
		throw Failure
	}
}

_SICO_Settle(CheckFailure := true) {
	global _SICO
	Started := A_TickCount
	while (CBClipboardOwner.active.Count || CBClipboardOwner.restore_debt is Map
			|| CBClipboardOwner.paste_transaction) && TickElapsed(Started) < 3000 {
		if CheckFailure && IsObject(_SICO.Failure)
			throw _SICO.Failure
		if CBClipboardOwner.restore_debt is Map
			CB_RetryRestoreDebt()
		Sleep(10)
	}
	_SICO_Require(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.paste_transaction
		&& !(CBClipboardOwner.restore_debt is Map), "The actual restore callback and exact debt must settle before sampling or cleanup.")
}

_SICO_RestoreIncoming(Snapshot) {
	global _SICO
	; Never detach a live client's owner or guess its anonymous restore callback.
	; An unknown retirement retains the incoming snapshot without overwriting it.
	_SICO_Settle(false)
	Text := CB_Read(), Sequence := CB_GetSequenceNumber(), Known := false
	_SICO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "Cleanup must acquire its own actual native lease.")
	try {
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Known := (Text == _SICO.Seed || Text == _SICO.Payload || Text == _SICO.Foreign)
			&& Sequence > 0 && CB_GetSequenceNumber() == Sequence
			&& (Owner == A_ScriptHwnd || Owner == _SICO.Writer.Hwnd)
	} finally {
		_SICO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "Cleanup must release only its own read lease.")
	}
	if Known {
		CB_RestoreOwnedAllEventually(Snapshot, Sequence, 0, "sendinstant_clipboard_fixture", false)
		_SICO_Settle(false)
	}
	FileAppend("CLEANUP sendinstant-clipboard-owner known=" . (Known ? 1 : 0)
		. " unknown_preserved=" . (Known ? 0 : 1) . " debt=0 active=0`n", "*", "UTF-8-RAW")
}

; Add a genuine non-text format to the original clipboard, not to the payload.
; ClipboardAll must restore this exact image along with the Unicode text.
_SICO_AddOriginalFormat() {
	global _SICO
	_SICO.Format := DllCall("User32\RegisterClipboardFormatW", "WStr", "Ergopti.Private.SendInstant.Original", "UInt")
	_SICO_Require(_SICO.Format >= 0xC000, "The private native format must register successfully.")
	Bytes := (StrLen(_SICO.Marker) + 1) * 2
	Handle := DllCall("Kernel32\GlobalAlloc", "UInt", 0x42, "UPtr", Bytes, "Ptr")
	_SICO_Require(Handle != 0, "The private original format must allocate its actual native image.")
	Transferred := false, Opened := false
	try {
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_SICO_Require(Data != 0, "The original private format must lock.")
		try StrPut(_SICO.Marker, Data, StrLen(_SICO.Marker) + 1, "UTF-16")
		finally {
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
			_SICO_Require(Unlocked != 0 || A_LastError == 0, "The private allocation must unlock without an OS error.")
		}
		Opened := CB_OpenClipboardWithin(A_ScriptHwnd)
		_SICO_Require(Opened, "The original clipboard must admit the extra native format.")
		_SICO_Require(DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
			"The fixture may add a format only to its own original clipboard.")
		Transferred := DllCall("User32\SetClipboardData", "UInt", _SICO.Format, "Ptr", Handle, "Ptr") == Handle
		_SICO_Require(Transferred, "The extra original format must transfer to Windows.")
	} finally {
		if Opened
			_SICO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The private original-format lease must close.")
		if !Transferred
			_SICO_Require(DllCall("Kernel32\GlobalFree", "Ptr", Handle, "Ptr") == 0,
				"Only an untransferred fixture allocation may be freed.")
	}
}

_SICO_MarkerMatches() {
	global _SICO
	_SICO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The restored non-text format must admit its own native read lease.")
	try {
		Handle := DllCall("User32\GetClipboardData", "UInt", _SICO.Format, "Ptr")
		if !Handle
			return false
		Bytes := DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr")
		ExpectedBytes := (StrLen(_SICO.Marker) + 1) * 2
		if Bytes < ExpectedBytes || Bytes > 65536
			return false
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_SICO_Require(Data != 0, "The restored extra format must lock its own handle.")
		try {
			loop StrLen(_SICO.Marker)
				if NumGet(Data, (A_Index - 1) * 2, "UShort") != NumGet(StrPtr(_SICO.Marker), (A_Index - 1) * 2, "UShort")
					return false
			return NumGet(Data, StrLen(_SICO.Marker) * 2, "UShort") == 0
		} finally {
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
			_SICO_Require(Unlocked != 0 || A_LastError == 0, "The restored extra format must unlock.")
		}
	} finally {
		_SICO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The restored extra-format lease must close.")
	}
}

; Independently read the actual CF_UNICODETEXT image while the native lock
; excludes mutation. Compare exact UTF-16 code units, not a sampled sequence alone.
_SICO_Sample(Expected) {
	_SICO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The final native clipboard image must be readable under its own bounded lease.")
	try {
		Sequence := CB_GetSequenceNumber()
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Handle := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
		_SICO_Require(Handle != 0, "The private native clipboard must contain actual Unicode text.")
		Bytes := DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr")
		_SICO_Require(Bytes >= 2 && Bytes <= 65536, "The private Unicode image must fit its independent read bound.")
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_SICO_Require(Data != 0, "The exact Unicode data handle must lock successfully.")
		try {
			Units := 0
			while Units * 2 + 2 <= Bytes && NumGet(Data, Units * 2, "UShort") != 0
				Units += 1
			_SICO_Require(Units * 2 + 2 <= Bytes, "The actual bounded Unicode image must contain its own terminator.")
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
			_SICO_Require(Unlocked != 0 || A_LastError == 0, "The exact Unicode handle must unlock without an OS error.")
		}
		_SICO_Require(Sequence > 0 && CB_GetSequenceNumber() == Sequence
			&& DllCall("User32\GetClipboardOwner", "Ptr") == Owner,
			"The exact native owner and sequence must remain stable throughout the locked raw read.")
		return {Text: Text, Sequence: Sequence, Owner: Owner, RawMatches: RawMatches, RawUnits: Units}
	} finally {
		_SICO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The final native sample must release only its own clipboard lease.")
	}
}

_SICO_Subject(Root, Mode) {
	global _SICO, _SendHook
	Payload := _SICO_Payload(Root)
	_SICO := {Root: Root, Mode: Mode, Armed: false, Copied: false, Boundary: "none", WriterSequence: 0,
		Seed: "sendinstant original A é😀 " . Root, Payload: Payload,
		Foreign: Mode == "same-text-copy" ? Payload : "sendinstant external B é😀 " . Root,
		Marker: "opaque original format é😀 " . Root, Format: 0,
		Failure: 0, Ok: false, Emissions: 0, Returned: 0, SetterCalls: 0, CallerCritical: 0,
		EmittedText: "", EmittedOwner: 0, Token: 0, Gui: 0, Edit: 0, SendPrimitive: SendInput}
	Primary := 0, Snapshot := 0, HaveSnapshot := false
	OnError(_SICO_OnError)
	try {
		_SICO.Writer := _SICO_Identity(_SICO_Wait(Root . "\writer.ready"))
		_SICO_Require(_SendHook == 0 && CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.restore_debt
			&& !CBClipboardOwner.paste_transaction && !CBClipboardOwner.observer_active,
			"The genuine client must begin without a test send hook, inherited owner, observer or debt.")
		Snapshot := CB_SaveAll()
		_SICO_Require(!(Snapshot is String && Snapshot == "__CB_SAVE_ERROR__"), "The incoming opaque clipboard must be captured.")
		HaveSnapshot := true
		_SICO_Require(CB_Write(_SICO.Seed) && CB_Read() == _SICO.Seed, "Actual original clipboard A must be present.")
		_SICO_AddOriginalFormat()
		_SICO_Require(_SICO_MarkerMatches(), "The real original must contain the exact extra format before the client snapshots it.")
		_SICO.Gui := Gui("+AlwaysOnTop", "Private SendInstant clipboard owner")
		_SICO.Edit := _SICO.Gui.AddEdit("w600 h120", "")
		_SICO.Gui.Show()
		WinActivate("ahk_id " . _SICO.Gui.Hwnd)
		_SICO.Edit.Focus()
		_SICO_Require(WinWaitActive("ahk_id " . _SICO.Gui.Hwnd, , 1), "The exact private GUI must own foreground focus.")
		Focus := _TextSenderNativeFocus()
		_SICO_Require(Focus["hwnd"] == _SICO.Gui.Hwnd && Focus["control"] == _SICO.Edit.Hwnd,
			"The exact private Edit must own focus before the real public client runs.")
		_SICO.Armed := true
		; The production Notepad hotstring caller really holds Critical over this API.
		PreviousCritical := Critical("On")
		try {
			_SICO.CallerCritical := A_IsCritical
			_SICO.Ok := SendInstant(Payload)
			_SICO_Require(A_IsCritical == _SICO.CallerCritical, "The API must preserve its caller's Critical state.")
		} finally {
			Critical(PreviousCritical)
		}
		_SICO_Settle()
		if IsObject(_SICO.Failure)
			throw _SICO.Failure
		_SICO_Require(_SICO.SetterCalls == 1 && _SICO.Token > 0, "The genuine client must admit exactly one native payload write.")
		if Mode != "current"
			_SICO_Require(_SICO.Copied && _SICO.WriterSequence > 0 && _SICO.Boundary == "after-real-setter-before-receipt",
				"The independent process must actually copy at the unlocked real setter boundary.")
		Sample := _SICO_Sample(Mode == "current" ? _SICO.Seed : _SICO.Foreign)
		FinalEdit := _SICO.Edit.Value
		FileAppend("RECEIPT sendinstant-clipboard-owner mode=" . Mode . " copies=" . (_SICO.Copied ? 1 : 0)
			. " caller_critical=" . _SICO.CallerCritical . " setter_calls=" . _SICO.SetterCalls
			. " writer_pid=" . _SICO.Writer.Pid . " writer_hwnd=" . _SICO.Writer.Hwnd
			. " writer_sequence=" . _SICO.WriterSequence . " final_sequence=" . Sample.Sequence . " final_owner=" . Sample.Owner
			. " raw_match=" . (Sample.RawMatches ? 1 : 0) . " raw_units=" . Sample.RawUnits
			. " ok=" . (_SICO.Ok ? 1 : 0) . " emissions=" . _SICO.Emissions . " returned=" . _SICO.Returned
			. " edit_payload=" . (FinalEdit == Payload ? 1 : 0) . "`n", "*", "UTF-8-RAW")
		if Mode == "current" {
			_SICO_Require(_SICO.Ok && _SICO.Emissions == 1 && _SICO.Returned == 1
				&& _SICO.EmittedText == Payload && FinalEdit == Payload,
				"Current SendInstant must genuinely paste into the exact private native Edit.")
			_SICO_Require(Sample.RawMatches && Sample.Text == _SICO.Seed && _SICO_MarkerMatches(),
				"Current SendInstant must restore actual original A including its extra non-text format.")
		} else {
			_SICO_Require(Sample.RawMatches && Sample.Text == _SICO.Foreign
				&& Sample.Sequence == _SICO.WriterSequence && Sample.Owner == _SICO.Writer.Hwnd,
				"The newer independent copy must survive the actual SendInstant restore with its exact native owner and sequence.")
			_SICO_Require(!_SICO.Ok && _SICO.Emissions == 0 && _SICO.Returned == 0 && FinalEdit == "",
				"SendInstant must refuse foreign clipboard content without any native emission, even for identical text.")
		}
	} catch Any as Failure {
		Primary := Failure
	} finally {
		_SICO.Armed := false
		try {
			if HaveSnapshot
				_SICO_RestoreIncoming(Snapshot)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			try {
				if IsObject(_SICO.Gui)
					_SICO.Gui.Destroy()
			} catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			} finally {
				OnError(_SICO_OnError, 0)
				try _SICO_Publish(Root . "\subject.done", "done")
				catch Any as Failure {
					if !IsObject(Primary)
						Primary := Failure
				}
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS sendinstant-clipboard-owner " . Mode . "`n", "*", "UTF-8-RAW")
}

try {
	_SICO_Require(A_Args.Length == 4 && Integer(A_Args[4]) > 0 && Integer(A_Args[4]) <= 1000 && (A_Args[3] == "current" || A_Args[3] == "different-copy" || A_Args[3] == "same-text-copy"),
		"The private child requires its explicit role, directory and mode.")
	Critical("Off")
	Suspend(false)
	if A_Args[1] == "writer"
		_SICO_Writer(A_Args[2], A_Args[3])
	else {
		_SICO_Require(A_Args[1] == "subject", "Only the two declared private roles may execute.")
		_SICO_Subject(A_Args[2], A_Args[3])
	}
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}
