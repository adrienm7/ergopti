; tests/fixtures/plain_paste_foreign_text_owner_body.ahk

; The canonical snapshot fixture supplies the genuine A setup, public clients,
; observers, deferred restore settlement, exact native focus and primary cleanup.
; Only B's scenario differs: one independent native lease publishes Unicode and
; a private format. Final loss is business data, never a missing-B prerequisite.
#Requires AutoHotkey v2.0

global _PPSFT_BSnapshots := [], _PPSFT_BRestore := 0

; A legitimate client may retain a newer genuine B snapshot and restore all B
; formats. Observe that exact object and native image, rather than requiring a
; fixed owner or generation after a legitimate all-formats restoration.
CB_SaveAll() {
	global _PPSN, _PPSFT_BSnapshots
	if !IsSet(_PPSN) || !_PPSN.Invoking || !_PPSN.SnapshotReturned
		return _PPSFT_FirstSaveAll()
	try {
		Before := _PPSFT_SampleB(_PPSN.Root)
		_PPSN_Require(Before.RawMatches && Before.TextMatches && Before.Unicode
			&& Before.Owner == _PPSN.Writer.Hwnd,
			"A second genuine snapshot must actually capture the independent Unicode and private-format B.")
		Saved := _PPSN_ActualSaveAll()
		After := _PPSFT_SampleB(_PPSN.Root)
		_PPSN_Require(IsObject(Saved) && Saved.Size > 0 && After.RawMatches && After.TextMatches
			&& After.Unicode && After.Owner == Before.Owner,
			"The exact opaque B snapshot must return while both real B images remain present.")
		_PPSFT_BSnapshots.Push({Saved: Saved, Sequence: After.Sequence, Owner: After.Owner})
		return Saved
	} catch Any as Failure {
		if !IsObject(_PPSN.Failure)
			_PPSN.Failure := Failure
		throw Failure
	}
}

CB_RestoreAll(Saved) {
	global _PPSN, _PPSFT_BSnapshots, _PPSFT_BRestore
	Observed := false
	for Capture in _PPSFT_BSnapshots
		if IsObject(Saved) && Saved == Capture.Saved
			Observed := true
	Result := _PPSFT_ActualRestoreAll(Saved)
	if Observed && Result {
		try {
			After := _PPSFT_SampleB(_PPSN.Root)
			if After.RawMatches && After.TextMatches && After.Unicode && After.Owner == A_ScriptHwnd
				_PPSFT_BRestore := {Sequence: After.Sequence, Owner: After.Owner}
		} catch Any as Failure {
			if !IsObject(_PPSN.Failure)
				_PPSN.Failure := Failure
			throw Failure
		}
	}
	return Result
}

_PPSFT_PreservedB(Sample) {
	global _PPSN, _PPSFT_BSnapshots, _PPSFT_BRestore
	if Sample.Sequence == _PPSN.WriterSequence && Sample.Owner == _PPSN.Writer.Hwnd
		return true
	for Capture in _PPSFT_BSnapshots
		if Sample.Sequence == Capture.Sequence && Sample.Owner == Capture.Owner
			return true
	return IsObject(_PPSFT_BRestore) && Sample.Sequence == _PPSFT_BRestore.Sequence
		&& Sample.Owner == _PPSFT_BRestore.Owner
}

_PPSFT_Text(Root) {
	return "independent Unicode B é😀 " . Root
}

_PPSFT_Allocation(Text) {
	Handle := DllCall("Kernel32\GlobalAlloc", "UInt", 0x42, "UPtr", (StrLen(Text) + 1) * 2, "Ptr")
	_PPSN_Require(Handle != 0, "The real Unicode image must allocate a movable native handle.")
	try {
		Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		_PPSN_Require(Data != 0, "The actual allocation must lock before UTF-16 is written.")
		try StrPut(Text, Data, StrLen(Text) + 1, "UTF-16")
		finally {
			DllCall("Kernel32\SetLastError", "UInt", 0)
			Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
			_PPSN_Require(Unlocked != 0 || A_LastError == 0, "The actual Unicode allocation must unlock without an OS error.")
		}
		return {Handle: Handle, Transferred: false}
	} catch Any as Failure {
		if DllCall("Kernel32\GlobalFree", "Ptr", Handle, "Ptr") != 0
			Failure.Message .= " The failed native allocation could not be released either."
		throw Failure
	}
}

_PPSFT_WritePair(Root) {
	Allocations := [], Opened := false, Primary := 0
	try {
		Allocations.Push(_PPSFT_Allocation(_PPSFT_Text(Root)))
		Allocations.Push(_PPSFT_Allocation(_PPSN_Marker(Root)))
		Opened := CB_OpenClipboardWithin(A_ScriptHwnd)
		_PPSN_Require(Opened, "The independent process must acquire one real native write lease.")
		_PPSN_Require(DllCall("User32\EmptyClipboard", "Int") != 0, "The independent writer must actually replace A.")
		Formats := [13, _PPSN_Format()]
		for Index, Allocation in Allocations {
			Allocation.Transferred := DllCall("User32\SetClipboardData", "UInt", Formats[Index], "Ptr", Allocation.Handle, "Ptr") == Allocation.Handle
			_PPSN_Require(Allocation.Transferred, "Each native Unicode/private allocation must transfer to Windows under the same lease.")
		}
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if Opened
				_PPSN_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The writer must release its own exact native lease.")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		for Allocation in Allocations {
			try {
				if !Allocation.Transferred
					_PPSN_Require(DllCall("Kernel32\GlobalFree", "Ptr", Allocation.Handle, "Ptr") == 0,
						"Only allocations not transferred to Windows may be freed.")
			} catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
}

_PPSFT_UnicodeMatches(Expected) {
	Handle := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
	_PPSN_Require(Handle != 0, "An available real Unicode format must provide its actual native data handle.")
	Bytes := DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr")
	if Bytes < (StrLen(Expected) + 1) * 2 || Bytes > 65536
		return false
	Data := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
	_PPSN_Require(Data != 0, "The actual available Unicode image must lock for its raw comparison.")
	try {
		loop StrLen(Expected)
			if NumGet(Data, (A_Index - 1) * 2, "UShort") != NumGet(StrPtr(Expected), (A_Index - 1) * 2, "UShort")
				return false
		return NumGet(Data, StrLen(Expected) * 2, "UShort") == 0
	} finally {
		DllCall("Kernel32\SetLastError", "UInt", 0)
		Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
		_PPSN_Require(Unlocked != 0 || A_LastError == 0, "The native Unicode read must unlock without an OS error.")
	}
}

_PPSFT_SampleB(Root) {
	Sample := _PPSN_Sample(_PPSN_Marker(Root))
	_PPSN_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "The native Unicode sample must acquire its actual read lease.")
	try {
		_PPSN_Require(CB_GetSequenceNumber() == Sample.Sequence && DllCall("User32\GetClipboardOwner", "Ptr") == Sample.Owner,
			"The two native B format samples must refer to the same actual owner and generation.")
		Sample.TextMatches := Sample.Unicode && _PPSFT_UnicodeMatches(_PPSFT_Text(Root))
		_PPSN_Require(CB_GetSequenceNumber() == Sample.Sequence && DllCall("User32\GetClipboardOwner", "Ptr") == Sample.Owner,
			"The exact native generation must remain stable while Unicode B is compared.")
		return Sample
	} finally {
		_PPSN_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The Unicode sample must release only its own native lease.")
	}
}

_PPSN_RequestCopy() {
	global _PPSN
	_PPSN_Require(!_PPSN.Copied, "Exactly one independent post-snapshot text copy may be admitted.")
	_PPSN_Publish(_PPSN.Root . "\copy.request", "copy")
	Identity := _PPSN_Identity(_PPSN_Wait(_PPSN.Root . "\copy.receipt"), true)
	_PPSN_Require(Identity.Pid == _PPSN.Writer.Pid && Identity.Hwnd == _PPSN.Writer.Hwnd,
		"The originally admitted independent writer must own the real text-copy receipt.")
	Sample := _PPSFT_SampleB(_PPSN.Root)
	_PPSN_Require(Sample.Present && Sample.RawMatches && Sample.TextMatches && Sample.Unicode && Sample.Formats >= 2
		&& Sample.Sequence > 0 && Sample.Sequence != _PPSN.SnapshotSequence
		&& Sample.Sequence == Identity.Sequence && Sample.Owner == Identity.Hwnd,
		"Before the real post-snapshot read, B must actually contain Unicode and its exact private format under the independent HWND and a fresh sequence.")
	_PPSN.Copied := true
	_PPSN.WriterSequence := Sample.Sequence
	_PPSN.BoundaryMatches := Sample.RawMatches && Sample.TextMatches
}

_PPSN_Writer(Root, Client) {
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	_PPSN_Publish(Root . "\writer.ready", Pid . "|" . A_ScriptHwnd)
	Started := A_TickCount, Copied := false
	loop {
		if FileExist(Root . "\copy.request") && !Copied {
			_PPSFT_WritePair(Root)
			Sample := _PPSFT_SampleB(Root)
			_PPSN_Require(Sample.RawMatches && Sample.TextMatches && Sample.Unicode && Sample.Formats >= 2
				&& Sample.Owner == A_ScriptHwnd && Sample.Sequence > 0,
				"The independent writer must actually own both exact native B formats before acknowledging its copy.")
			_PPSN_Publish(Root . "\copy.receipt", Pid . "|" . A_ScriptHwnd . "|" . Sample.Sequence)
			Copied := true
		}
		if FileExist(Root . "\subject.done")
			break
		_PPSN_Require(TickElapsed(Started) < 12000, "The independent writer must retire within its existing private deadline.")
		Sleep(10)
	}
	_PPSN_Require(Copied, "The independent writer must actually perform its requested native mutation.")
	FileAppend("PASS plain-paste-foreign-text-writer " . Client . " copies=1`n", "*", "UTF-8-RAW")
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
