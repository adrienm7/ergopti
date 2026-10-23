; tests/fixtures/plain_paste_snapshot_owner_body.ahk

; A real all-formats snapshot precedes an independent native non-text copy.
; Every adapter observation delegates unchanged. Final absence is data for the
; business oracle: a broken coercion must not become a missing-format premise.
#Requires AutoHotkey v2.0

_PPSN_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_PPSN_Publish(Path, Text) {
	_PPSN_Require(!FileExist(Path) && !FileExist(Path . ".pending"), "The private protocol cannot replace an existing receipt.")
	FileAppend(Text, Path . ".pending", "UTF-8-RAW")
	FileMove(Path . ".pending", Path)
}

_PPSN_Wait(Path) {
	Started := A_TickCount
	while !FileExist(Path) && TickElapsed(Started) < 3000
		Sleep(10)
	_PPSN_Require(FileExist(Path), "The independent process must actually acknowledge its bounded native phase.")
	return FileRead(Path, "UTF-8")
}

_PPSN_Identity(Text, WithSequence := false) {
	Pattern := WithSequence ? "^([0-9]+)\|([0-9]+)\|([0-9]+)$" : "^([0-9]+)\|([0-9]+)$"
	_PPSN_Require(RegExMatch(Text, Pattern, &Found) > 0, "The writer must export its actual native identity.")
	Identity := {Pid: Integer(Found[1]), Hwnd: Integer(Found[2]), Sequence: WithSequence ? Integer(Found[3]) : 0}
	Pid := 0
	DllCall("User32\GetWindowThreadProcessId", "Ptr", Identity.Hwnd, "UInt*", &Pid)
	_PPSN_Require(Identity.Pid > 0 && Identity.Pid != DllCall("Kernel32\GetCurrentProcessId", "UInt")
		&& Pid == Identity.Pid, "The receipt must identify the live independent process and its genuine window.")
	return Identity
}

_PPSN_Format() {
	Id := DllCall("User32\RegisterClipboardFormatW", "WStr", "Ergopti.Private.PlainSnapshot", "UInt")
	_PPSN_Require(Id >= 0xC000, "The real private native format must register successfully.")
	return Id
}

_PPSN_Marker(Root, Original := false) {
	return (Original ? "snapshot original A é😀 " : "independent custom-only B é😀 ") . Root
}

; The subject adds a format to its own original A. The actual writer clears
; all formats and publishes only its native B. No adapter write is simulated.
_PPSN_WriteFormat(Text, Clear) {
	FormatId := _PPSN_Format()
	Handle := DllCall("Kernel32\GlobalAlloc", "UInt", 0x42, "UPtr", (StrLen(Text) + 1) * 2, "Ptr")
	_PPSN_Require(Handle != 0, "The private clipboard image must allocate a real native handle.")
	Transferred := false, Opened := false
	try {
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_PPSN_Require(Data != 0, "The native private image must lock.")
		try StrPut(Text, Data, StrLen(Text) + 1, "UTF-16")
		finally {
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
			_PPSN_Require(Unlocked != 0 || A_LastError == 0, "The native allocation must unlock without an OS error.")
		}
		Opened := CB_OpenClipboardWithin(A_ScriptHwnd)
		_PPSN_Require(Opened, "The process must acquire its own actual native write lease.")
		if Clear
			_PPSN_Require(DllCall("User32\EmptyClipboard", "Int") != 0, "The independent writer must actually replace all clipboard formats.")
		else
			_PPSN_Require(DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"The subject may add a format only to its own original text clipboard.")
		Transferred := DllCall("User32\SetClipboardData", "UInt", FormatId, "Ptr", Handle, "Ptr") == Handle
		_PPSN_Require(Transferred, "The actual native image must transfer to Windows.")
	} finally {
		try {
			if Opened
				_PPSN_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The writer must release only its own native lease.")
		} finally {
			if !Transferred
				_PPSN_Require(DllCall("Kernel32\GlobalFree", "Ptr", Handle, "Ptr") == 0,
					"Only an untransferred fixture allocation may be freed.")
		}
	}
}

; A missing or cleared B yields Present=false/RawMatches=false, not a failed
; prerequisite. The same real read serves the earlier positive boundary proof.
_PPSN_Sample(Expected) {
	_PPSN_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The actual clipboard must admit its bounded native sample lease.")
	try {
		Sequence := CB_GetSequenceNumber()
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Unicode := DllCall("User32\IsClipboardFormatAvailable", "UInt", 13, "Int") != 0
		DllCall("Kernel32\SetLastError", "UInt", 0)
		Formats := DllCall("User32\CountClipboardFormats", "Int")
		_PPSN_Require(Formats != 0 || A_LastError == 0, "An empty native format list must be an actual empty clipboard, not an OS read error.")
		Available := DllCall("User32\IsClipboardFormatAvailable", "UInt", _PPSN_Format(), "Int") != 0
		Handle := Available ? DllCall("User32\GetClipboardData", "UInt", _PPSN_Format(), "Ptr") : 0
		_PPSN_Require(!Available || Handle != 0, "An available native format must expose its own real data handle.")
		Bytes := Handle ? DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr") : 0
		Matches := false, Units := 0, Readable := false
		if Bytes >= 2 && Bytes <= 65536 {
			Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
			_PPSN_Require(Data != 0, "The available native image must lock successfully before its bytes are read.")
			if Data {
				try {
					while Units * 2 + 2 <= Bytes && NumGet(Data, Units * 2, "UShort") != 0
						Units += 1
					Readable := Units * 2 + 2 <= Bytes
					Matches := Readable && Units == StrLen(Expected)
					if Matches {
						loop Units
							if NumGet(Data, (A_Index - 1) * 2, "UShort") != NumGet(StrPtr(Expected), (A_Index - 1) * 2, "UShort") {
								Matches := false
								break
							}
					}
				} finally {
					DllCall("Kernel32\SetLastError", "UInt", 0)
					Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
					_PPSN_Require(Unlocked != 0 || A_LastError == 0, "The sampled native image must unlock successfully.")
				}
			}
		}
		_PPSN_Require(CB_GetSequenceNumber() == Sequence && DllCall("User32\GetClipboardOwner", "Ptr") == Owner,
			"The actual clipboard owner and sequence must stay stable during this exact locked sample.")
		return {Sequence: Sequence, Owner: Owner, Unicode: Unicode, Formats: Formats,
			Present: Available && Handle != 0, RawMatches: Matches, Readable: Readable, Units: Units, Bytes: Bytes}
	} finally {
		_PPSN_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The sample must release only its own native read lease.")
	}
}

_PPSN_RequestCopy() {
	global _PPSN
	_PPSN_Require(!_PPSN.Copied, "Exactly one independent post-snapshot copy may be admitted.")
	_PPSN_Publish(_PPSN.Root . "\copy.request", "copy")
	Identity := _PPSN_Identity(_PPSN_Wait(_PPSN.Root . "\copy.receipt"), true)
	_PPSN_Require(Identity.Pid == _PPSN.Writer.Pid && Identity.Hwnd == _PPSN.Writer.Hwnd,
		"The original admitted independent writer must own the native copy receipt.")
	Sample := _PPSN_Sample(_PPSN_Marker(_PPSN.Root))
	_PPSN_Require(Sample.Present && Sample.Readable && Sample.RawMatches && !Sample.Unicode && Sample.Formats == 1
		&& Sample.Sequence > 0 && Sample.Sequence != _PPSN.SnapshotSequence
		&& Sample.Sequence == Identity.Sequence && Sample.Owner == Identity.Hwnd,
		"Before the second real read, B must actually be custom-only native data under the independent HWND and a fresh exact sequence.")
	_PPSN.Copied := true
	_PPSN.WriterSequence := Sample.Sequence
	_PPSN.BoundaryMatches := Sample.RawMatches
}

CB_SaveAll() {
	global _PPSN
	try {
		Observing := IsSet(_PPSN) && _PPSN.Invoking
		if Observing {
			TextBefore := _PPSN_ActualRead()
			Before := _PPSN_Sample(_PPSN_Marker(_PPSN.Root, true))
			_PPSN_Require(TextBefore == _PPSN.Seed && Before.RawMatches && Before.Unicode
				&& Before.Owner == A_ScriptHwnd && Before.Sequence > 0,
				"The actual original A must still be present immediately before the real snapshot acquisition.")
		}
		Snapshot := _PPSN_ActualSaveAll()
		if Observing {
			_PPSN.SnapshotCalls += 1
			_PPSN_Require(_PPSN.SnapshotCalls == 1 && IsObject(Snapshot) && Snapshot.Size > 0,
				"The public client must receive one genuine nonempty opaque ClipboardAll snapshot.")
			_PPSN_Require(A_IsCritical == _PPSN.CallerCritical
				&& DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd,
				"The genuine snapshot must return with its caller state and without retaining its native lease.")
			_PPSN.Token := CBClipboardOwner.paste_transaction
			_PPSN_Require(_PPSN.Token > 0 && CBClipboardOwner.active.Count == 1
				&& CBClipboardOwner.active.Has(_PPSN.Token)
				&& CBClipboardOwner.active[_PPSN.Token]["source"] == _PPSN.Source,
				"The actual public client must hold its exact admitted paste owner before snapshot acquisition.")
			TextAfter := _PPSN_ActualRead()
			After := _PPSN_Sample(_PPSN_Marker(_PPSN.Root, true))
			_PPSN_Require(TextAfter == _PPSN.Seed && After.RawMatches && After.Unicode
				&& After.Owner == A_ScriptHwnd && After.Sequence > 0,
				"The real opaque snapshot must complete while actual A remains present before the independent copy.")
			; Native rendering may materialize formats during ClipboardAll. Record
			; both actual generations without assuming that conversion is a copy.
			_PPSN.BeforeSnapshotSequence := Before.Sequence
			_PPSN.SnapshotSequence := After.Sequence
			_PPSN.SnapshotBytes := Snapshot.Size
			_PPSN_RequestCopy()
			_PPSN.SnapshotReturned := true
			FileAppend("BOUNDARY plain-paste-snapshot-owner before_sequence=" . Before.Sequence
				. " after_sequence=" . After.Sequence . " snapshot_bytes=" . Snapshot.Size
				. " original_a_match=1 writer_sequence=" . _PPSN.WriterSequence
				. " boundary_b=" . (_PPSN.BoundaryMatches ? 1 : 0) . " no_unicode=1`n", "*", "UTF-8-RAW")
		}
		return Snapshot
	} catch Any as Failure {
		if IsSet(_PPSN) && !IsObject(_PPSN.Failure)
			_PPSN.Failure := Failure
		throw Failure
	}
}

CB_Read() {
	global _PPSN
	try {
		Text := _PPSN_ActualRead()
		if IsSet(_PPSN) && _PPSN.Invoking && _PPSN.SnapshotReturned {
			_PPSN.ReadsAfterSnapshot += 1
			if _PPSN.ReadsAfterSnapshot == 1
				_PPSN.FirstReadEmpty := Text == ""
		}
		return Text
	} catch Any as Failure {
		if IsSet(_PPSN) && !IsObject(_PPSN.Failure)
			_PPSN.Failure := Failure
		throw Failure
	}
}

CB_Write(Text) {
	global _PPSN
	try {
		if IsSet(_PPSN) && _PPSN.Invoking && _PPSN.SnapshotReturned
			_PPSN.WritesAfterSnapshot += 1
		Published := _PPSN_ActualWrite(Text)
		if Published && IsSet(_PPSN) && _PPSN.Invoking && _PPSN.SnapshotReturned {
			_PPSN.LastWriteSequence := CB_GetSequenceNumber()
			_PPSN.LastWriteOwner := DllCall("User32\GetClipboardOwner", "Ptr")
		}
		return Published
	} catch Any as Failure {
		if IsSet(_PPSN) && !IsObject(_PPSN.Failure)
			_PPSN.Failure := Failure
		throw Failure
	}
}

_PPSN_Writer(Root, Client) {
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	_PPSN_Publish(Root . "\writer.ready", Pid . "|" . A_ScriptHwnd)
	Started := A_TickCount, Copied := false
	loop {
		if FileExist(Root . "\copy.request") && !Copied {
			_PPSN_WriteFormat(_PPSN_Marker(Root), true)
			Sample := _PPSN_Sample(_PPSN_Marker(Root))
			_PPSN_Require(Sample.RawMatches && Sample.Present && !Sample.Unicode && Sample.Formats == 1
				&& Sample.Owner == A_ScriptHwnd && Sample.Sequence > 0, "The writer must actually own only the exact new native B format.")
			_PPSN_Publish(Root . "\copy.receipt", Pid . "|" . A_ScriptHwnd . "|" . Sample.Sequence)
			Copied := true
		}
		if FileExist(Root . "\subject.done")
			break
		_PPSN_Require(TickElapsed(Started) < 12000, "The independent writer must retire within its private deadline.")
		Sleep(10)
	}
	_PPSN_Require(Copied, "The independent writer must actually perform its requested native mutation.")
	FileAppend("PASS plain-paste-snapshot-writer " . Client . " copies=1`n", "*", "UTF-8-RAW")
}

_PPSN_OnError(Failure, *) {
	global _PPSN
	if !IsObject(_PPSN.Failure)
		_PPSN.Failure := Failure
	return true
}

_PPSN_Send(Keys) {
	global _PPSN
	try {
		_PPSN_Require(Keys == "^v", "Only the exact real native paste may reach the private Edit.")
		for Key in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
			_PPSN_Require(!GetKeyState(Key, "P"), "Physical modifiers must be absent before the private native primitive.")
		Focus := _TextSenderNativeFocus()
		_PPSN_Require(Focus["hwnd"] == _PPSN.Gui.Hwnd && Focus["control"] == _PPSN.Edit.Hwnd
			&& Focus["pid"] == DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"Only the exact private native Edit and process may receive the delegated primitive.")
		_PPSN.Emissions += 1
		Result := _PPSN.SendPrimitive.Call(Keys)
		_PPSN.Returned += 1
		return Result
	} catch Any as Failure {
		if !IsObject(_PPSN.Failure)
			_PPSN.Failure := Failure
		throw Failure
	}
}

_PPSN_Settle(CheckFailure := true) {
	global _PPSN
	Started := A_TickCount
	while (CBClipboardOwner.active.Count || CBClipboardOwner.restore_debt is Map
			|| CBClipboardOwner.paste_transaction) && TickElapsed(Started) < 3000 {
		if CheckFailure && IsObject(_PPSN.Failure)
			throw _PPSN.Failure
		if CBClipboardOwner.restore_debt is Map
			CB_RetryRestoreDebt()
		Sleep(10)
	}
	_PPSN_Require(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.paste_transaction
		&& !(CBClipboardOwner.restore_debt is Map), "Actual owners and restore debt must retire before the final sample or cleanup.")
}

_PPSN_RestoreIncoming(Incoming) {
	global _PPSN
	_PPSN_Settle(false)
	Text := _PPSN_ActualRead()
	Before := CB_GetSequenceNumber()
	A := _PPSN_Sample(_PPSN_Marker(_PPSN.Root, true))
	B := _PPSN_Sample(_PPSN_Marker(_PPSN.Root))
	Same := Before > 0 && A.Sequence == Before && B.Sequence == Before && A.Owner == B.Owner
	KnownA := Same && Text == _PPSN.Seed && A.RawMatches && A.Unicode && A.Owner == A_ScriptHwnd
	KnownB := Same && B.RawMatches && !B.Unicode && B.Formats == 1 && B.Sequence == _PPSN.WriterSequence
		&& B.Owner == _PPSN.Writer.Hwnd
	KnownEmpty := Same && B.Formats == 0 && !B.Unicode && B.Owner == A_ScriptHwnd
		&& B.Sequence == _PPSN.LastWriteSequence && _PPSN.LastWriteOwner == A_ScriptHwnd
	Known := KnownA || KnownB || KnownEmpty
	if Known {
		CB_RestoreOwnedAllEventually(Incoming, Before, 0, "plain_paste_snapshot_fixture", false)
		_PPSN_Settle(false)
	}
	FileAppend("CLEANUP plain-paste-snapshot-owner known=" . (Known ? 1 : 0)
		. " unknown_preserved=" . (Known ? 0 : 1) . " active=0 debt=0`n", "*", "UTF-8-RAW")
}

_PPSN_Subject(Root, Client) {
	global _PPSN, _SendHook
	_PPSN := {Root: Root, Client: Client, Seed: "plain snapshot text A é😀 " . Root,
		Source: Client == "gesture" ? "gesture_paste_plain" : "paste_without_formatting",
		Invoking: false, SnapshotReturned: false, SnapshotCalls: 0, ReadsAfterSnapshot: 0, FirstReadEmpty: false,
		WritesAfterSnapshot: 0, LastWriteSequence: 0, LastWriteOwner: 0, Copied: false, BoundaryMatches: false,
		WriterSequence: 0, OriginalSequence: 0, BeforeSnapshotSequence: 0, SnapshotSequence: 0, SnapshotBytes: 0,
		Token: 0, CallerCritical: 0, Completed: false,
		Failure: 0, Emissions: 0, Returned: 0, SendPrimitive: SendInput, Gui: 0, Edit: 0}
	Primary := 0, HaveIncoming := false, Incoming := 0
	OnError(_PPSN_OnError)
	try {
		_PPSN.Writer := _PPSN_Identity(_PPSN_Wait(Root . "\writer.ready"))
		_PPSN_Require(_SendHook == 0 && CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.restore_debt
			&& !CBClipboardOwner.paste_transaction && !CBClipboardOwner.observer_active, "The real clipboard owner must begin fresh without test send hooks or debt.")
		Incoming := CB_SaveAll()
		_PPSN_Require(IsObject(Incoming), "The actual incoming opaque clipboard must be captured before private mutations.")
		HaveIncoming := true
		_PPSN_Require(CB_Write(_PPSN.Seed) && CB_Read() == _PPSN.Seed, "The original native text A must be present.")
		_PPSN_WriteFormat(_PPSN_Marker(Root, true), false)
		Original := _PPSN_Sample(_PPSN_Marker(Root, true))
		_PPSN_Require(Original.RawMatches && Original.Unicode && Original.Owner == A_ScriptHwnd
			&& Original.Sequence > 0, "Actual original A must contain Unicode and the exact extra native format before its snapshot.")
		_PPSN.OriginalSequence := Original.Sequence
		_PPSN.Gui := Gui("+AlwaysOnTop", "Private plain paste snapshot")
		_PPSN.Edit := _PPSN.Gui.AddEdit("w600 h120", "")
		_PPSN.Gui.Show()
		WinActivate("ahk_id " . _PPSN.Gui.Hwnd)
		_PPSN.Edit.Focus()
		_PPSN_Require(WinWaitActive("ahk_id " . _PPSN.Gui.Hwnd, , 1) && !WinActive("ahk_exe EXCEL.EXE"),
			"The actual private non-Excel GUI must own foreground focus before the public call.")
		_PPSN.CallerCritical := A_IsCritical
		_PPSN.Invoking := true
		_PPSN_Invoke()
		_PPSN.Invoking := false
		_PPSN.Completed := true
		_PPSN_Require(A_IsCritical == _PPSN.CallerCritical, "The genuine void public client must preserve its caller state.")
		_PPSN_Settle()
		if IsObject(_PPSN.Failure)
			throw _PPSN.Failure
		_PPSN_Require(_PPSN.SnapshotCalls == 1 && _PPSN.SnapshotReturned && _PPSN.Token > 0
			&& _PPSN.Copied && _PPSN.BoundaryMatches && _PPSN.WriterSequence > 0,
			"The real public client must cross the authenticated A snapshot and independent custom-only B before its business oracle.")
		if _PPSN.ReadsAfterSnapshot > 0
			_PPSN_Require(_PPSN.FirstReadEmpty,
				"When the client actually reads after the snapshot, its real first read must observe the authenticated non-text B as empty.")
		Final := _PPSN_Sample(_PPSN_Marker(Root))
		FileAppend("RECEIPT plain-paste-snapshot-owner client=" . Client . " snapshots=" . _PPSN.SnapshotCalls
			. " boundary_b=" . (_PPSN.BoundaryMatches ? 1 : 0) . " copied=" . (_PPSN.Copied ? 1 : 0)
			. " reads_after_snapshot=" . _PPSN.ReadsAfterSnapshot
			. " second_read_empty=" . (_PPSN.FirstReadEmpty ? 1 : 0) . " writes=" . _PPSN.WritesAfterSnapshot
			. " before_snapshot_sequence=" . _PPSN.BeforeSnapshotSequence . " snapshot_sequence=" . _PPSN.SnapshotSequence
			. " snapshot_bytes=" . _PPSN.SnapshotBytes
			. " final_b_present=" . (Final.Present ? 1 : 0) . " final_b_match=" . (Final.RawMatches ? 1 : 0)
			. " final_unicode=" . (Final.Unicode ? 1 : 0) . " final_formats=" . Final.Formats
			. " final_owner=" . Final.Owner . " final_sequence=" . Final.Sequence
			. " writer_pid=" . _PPSN.Writer.Pid . " writer_hwnd=" . _PPSN.Writer.Hwnd . " writer_sequence=" . _PPSN.WriterSequence
			. " completed=" . (_PPSN.Completed ? 1 : 0) . " emissions=" . _PPSN.Emissions . " returned=" . _PPSN.Returned . "`n", "*", "UTF-8-RAW")
		_PPSN_Require(Final.RawMatches && Final.Present && !Final.Unicode && Final.Formats == 1
			&& Final.Owner == _PPSN.Writer.Hwnd && Final.Sequence == _PPSN.WriterSequence,
			"A newer independent non-text copy must survive the real plain-paste client and its restore with its exact native image, owner and sequence.")
		_PPSN_Require(_PPSN.Completed && _PPSN.WritesAfterSnapshot == 0,
			"An empty second read must not request a destructive text setter after a real newer non-text copy.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		_PPSN.Invoking := false
		try {
			if HaveIncoming
				_PPSN_RestoreIncoming(Incoming)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			try {
				if IsObject(_PPSN.Gui)
					_PPSN.Gui.Destroy()
			} catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			} finally {
				OnError(_PPSN_OnError, 0)
				try _PPSN_Publish(Root . "\subject.done", "done")
				catch Any as Failure {
					if !IsObject(Primary)
						Primary := Failure
				}
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS plain-paste-snapshot-owner " . Client . "`n", "*", "UTF-8-RAW")
}

try {
	_PPSN_Require(A_Args.Length == 4 && (A_Args[3] == "gesture" || A_Args[3] == "shortcut")
		&& Integer(A_Args[4]) > 0 && Integer(A_Args[4]) <= 1000, "Only the declared private role, directory, client and actual bounded timing may execute.")
	Critical("Off")
	Suspend(false)
	if A_Args[1] == "writer"
		_PPSN_Writer(A_Args[2], A_Args[3])
	else {
		_PPSN_Require(A_Args[1] == "subject", "Only the two owned process roles are admitted.")
		_PPSN_Subject(A_Args[2], A_Args[3])
	}
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}
