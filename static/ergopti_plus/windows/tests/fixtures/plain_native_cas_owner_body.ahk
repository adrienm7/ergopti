; tests/fixtures/plain_native_cas_owner_body.ahk

; ==============================================================================
; MODULE: Native Plain Clipboard CAS Component Child
; DESCRIPTION:
; Real clipboard contents and two owned native processes exercise the publisher.
; Close-ACK loss and retry refusal are labelled protocol injections. SetData NULL
; is a real API result after deliberately closing the fixture's exact opener.
; No application paste acknowledgement or healthy-opener Close failure is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_PNCO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_PNCO_Publish(Name, Value := "ack") {
	global _PNCO
	Path := _PNCO.Root . "\" . Name
	_PNCO_Require(!FileExist(Path) && !FileExist(Path . ".pending"), "Each exact role handshake is single-use: " . Name)
	FileAppend(String(Value), Path . ".pending", "UTF-8-RAW")
	FileMove(Path . ".pending", Path)
}

_PNCO_Wait(Name) {
	global _PNCO
	Started := A_TickCount
	while !FileExist(_PNCO.Root . "\" . Name) && TickElapsed(Started) < 3000
		Sleep(10)
	_PNCO_Require(FileExist(_PNCO.Root . "\" . Name), "The actual owned role must acknowledge: " . Name)
	return FileRead(_PNCO.Root . "\" . Name, "UTF-8")
}

_PNCO_OnError(Failure, *) {
	global _PNCO
	if !IsObject(_PNCO.Failure)
		_PNCO.Failure := Failure
	return true
}

_PNCO_Close() {
	global _PNCO
	Result := DllCall("User32\CloseClipboard", "Int")
	NativeError := A_LastError
	if _PNCO.Armed && _PNCO.Mode == "close-lost" && !_PNCO.CloseFired {
		_PNCO.CloseFired += 1
		_PNCO_Require(Result != 0, "The injected lost ACK follows a genuinely successful native Close.")
		_PNCO.CloseResult := Result, _PNCO.CloseError := NativeError
		throw _PNCO.Injected
	}
	_PNCO.CloseResult := Result, _PNCO.CloseError := NativeError
	return Result
}

_PNCO_SetData(Arguments*) {
	global _PNCO
	if _PNCO.Armed && _PNCO.Mode == "set-null" {
		_PNCO.SetFired += 1
		_PNCO_Require(_PNCO.SetFired == 1 && DllCall("User32\GetOpenClipboardWindow", "Ptr") == A_ScriptHwnd,
			"Only the genuine prepared publisher's own opener may be aborted.")
		_PNCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The deliberately aborted opener must receive its own Close ACK.")
	}
	DllCall("Kernel32\SetLastError", "UInt", 0)
	Result := DllCall("User32\SetClipboardData", Arguments*)
	NativeError := A_LastError
	_PNCO.SetResult := Result, _PNCO.SetError := NativeError
	return Result
}

_PNCO_ArmRetry() {
	global _PNCO
	if _PNCO.Mode == "arm-refused" && !_PNCO.ArmFired {
		_PNCO.ArmFired += 1
		throw _PNCO.Injected
	}
	return SetTimer(CB_RetryRestoreDebt, -CB_RESTORE_RETRY_MS)
}

_CB_PlainNativeMutationCAS(Record, Text) {
	global _PNCO
	Result := _PNCO_ActualMutation(Record, Text)
	_PNCO.Record := Record
	if _PNCO.Armed && Record["changed"] {
		_PNCO.Armed := false
		_PNCO_Require(A_IsCritical == _PNCO.CallerCritical, "The true native publisher must restore its caller's Critical before authentication.")
		if _PNCO.Mode == "close-lost" {
			_PNCO_Require(Record["lease_unknown"] && Record["failure"] == _PNCO.Injected,
				"The missing Close ACK must remain a typed unknown, with its original failure.")
			_PNCO.NullHeld := DllCall("User32\OpenClipboard", "Ptr", 0, "Int") != 0
			_PNCO_Require(_PNCO.NullHeld, "A real later NULL borrower must acquire its own lease after the original Close.")
		} else if _PNCO.Mode == "foreign-wins" {
			_PNCO_Publish("copy.request")
			_PNCO.ForeignSequence := Integer(_PNCO_Wait("copy.receipt"))
			_PNCO_Require(_PNCO.ForeignSequence > 0 && DllCall("User32\GetClipboardOwner", "Ptr") == _PNCO.WriterHwnd,
				"The independent newer native writer must own the clipboard before authentication.")
			CBClipboardOwner.settle_hook := _PNCO_AdmitSuccessor
		} else if _PNCO.Mode == "auth-busy" || _PNCO.Mode == "set-null" || _PNCO.Mode == "arm-refused" {
			_PNCO_Publish("hold.request")
			_PNCO_Wait("held.receipt")
			_PNCO_Require(DllCall("User32\GetOpenClipboardWindow", "Ptr") == _PNCO.WriterHwnd,
				"The independent native reader must hold its exact lease before authentication.")
		}
	}
	return Result
}

_PNCO_AdmitSuccessor() {
	global _PNCO
	_PNCO.HookCalls += 1
	_PNCO_Require(_PNCO.HookCalls == 1 && DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd,
		"The old read lease must have its Close ACK before terminal settlement admits B.")
	CBClipboardOwner.settle_hook := 0
	_PNCO.Next := CB_TryBeginPasteTransaction("plain_native_successor")
	_PNCO_Require(_PNCO.Next > _PNCO.Token, "The real central owner must admit a distinct successor after old settlement.")
}

_PNCO_Writer() {
	global _PNCO
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	_PNCO_Publish("writer.ready", Pid . "|" . A_ScriptHwnd)
	Held := false, Copied := false, Probed := false, ProbedAfter := false, Primary := 0
	Started := A_TickCount
	try {
		loop {
			if FileExist(_PNCO.Root . "\hold.request") && !Held && !FileExist(_PNCO.Root . "\released.receipt") {
				Held := CB_OpenClipboardWithin(A_ScriptHwnd)
				_PNCO_Require(Held, "The independent holder must really acquire its native lock.")
				_PNCO_Publish("held.receipt")
			}
			if Held && FileExist(_PNCO.Root . "\release.request") {
				_PNCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The exact independent holder must receive Close ACK.")
				Held := false
				_PNCO_Publish("released.receipt")
			}
			if FileExist(_PNCO.Root . "\copy.request") && !Copied {
				A_Clipboard := _PNCO.Foreign
				Sequence := DllCall("User32\GetClipboardSequenceNumber", "UInt")
				_PNCO_Require(Sequence > 0 && DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
					"The independent process must genuinely publish its own newer clipboard.")
				_PNCO_Publish("copy.receipt", Sequence)
				Copied := true
			}
			if FileExist(_PNCO.Root . "\probe.request") && !Probed {
				DllCall("Kernel32\SetLastError", "UInt", 0)
				Opened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int")
				OpenError := A_LastError
				if Opened
					_PNCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "An unexpectedly admitted independent probe must close itself.")
				_PNCO_Publish("probe.receipt", Opened . "|" . OpenError)
				Probed := true
				_PNCO_Require(!Opened, "The candidate must leave the original native borrower's lock intact.")
			}
			if FileExist(_PNCO.Root . "\probe-after.request") && !ProbedAfter {
				Held := CB_OpenClipboardWithin(A_ScriptHwnd)
				_PNCO_Require(Held, "The independent probe must open after the original caller's own Close.")
				_PNCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The final probe must close only its own lease.")
				Held := false, ProbedAfter := true
				_PNCO_Publish("probe-after.receipt")
			}
			if FileExist(_PNCO.Root . "\subject.done")
				break
			_PNCO_Require(TickElapsed(Started) < 12000, "The independent native role must retire within its private deadline.")
			Sleep(10)
		}
	} catch Any as Failure {
		Primary := Failure
	} finally {
		if Held {
			try _PNCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "The independent role must release its exact live lease on failure.")
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS plain-native-cas-writer " . _PNCO.Mode . "`n", "*", "UTF-8-RAW")
}

_PNCO_Drain() {
	Started := A_TickCount
	while CBClipboardOwner.restore_debt is Map && TickElapsed(Started) < 3000 {
		CB_RetryRestoreDebt()
		Sleep(10)
	}
	_PNCO_Require(!(CBClipboardOwner.restore_debt is Map), "The exact retained debt must finish before cleanup.")
}

_PNCO_ReleaseBorrower() {
	global _PNCO
	if _PNCO.NullHeld || _PNCO.Held {
		_PNCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "Only the original fixture borrower may close its own native lease.")
		_PNCO.NullHeld := false, _PNCO.Held := false
	}
}

_PNCO_ReleaseWriter() {
	global _PNCO
	if FileExist(_PNCO.Root . "\held.receipt") && !FileExist(_PNCO.Root . "\release.request") {
		_PNCO_Publish("release.request")
		_PNCO_Wait("released.receipt")
	}
}

_PNCO_Subject() {
	global _PNCO
	Snapshot := 0, Captured := 0, HaveSnapshot := false, Primary := 0, Token := 0
	OnError(_PNCO_OnError)
	try {
		Identity := StrSplit(_PNCO_Wait("writer.ready"), "|")
		_PNCO_Require(Identity.Length == 2, "The independent role must publish its own actual native identity.")
		Pid := 0, _PNCO.WriterHwnd := Integer(Identity[2])
		DllCall("User32\GetWindowThreadProcessId", "Ptr", _PNCO.WriterHwnd, "UInt*", &Pid)
		_PNCO_Require(Pid == Integer(Identity[1]) && Pid != DllCall("Kernel32\GetCurrentProcessId", "UInt"),
			"The writer HWND must belong to the exact different live process.")
		Snapshot := CB_SaveAll()
		_PNCO_Require(IsObject(Snapshot), "The real incoming opaque snapshot must be acquired before fixture publication.")
		HaveSnapshot := true
		_PNCO_Require(CB_Write(_PNCO.Seed) && CB_Read() == _PNCO.Seed, "The real original A must precede the exact owner claim.")
		Token := CB_TryBeginPasteTransaction("plain_native_cas_fixture"), _PNCO.Token := Token
		_PNCO_Require(Token > 0 && CB_SavePlainSnapshot(Token, &Captured), "The real owner and stable opaque snapshot must be admitted.")
		Before := DllCall("User32\GetClipboardSequenceNumber", "UInt")
		if _PNCO.Mode == "borrow-null" || _PNCO.Mode == "borrow-own" {
			_PNCO.Held := DllCall("User32\OpenClipboard", "Ptr", _PNCO.Mode == "borrow-null" ? 0 : A_ScriptHwnd, "Int") != 0
			_PNCO_Require(_PNCO.Held, "The original caller must first acquire its real native lease.")
		}
		_PNCO.CallerCritical := A_IsCritical, _PNCO.Armed := true
		Caught := 0, OwnedSequence := 0, Published := false
		try Published := CB_WritePlainSnapshot(Captured, "0", &OwnedSequence)
		catch Any as Failure
			Caught := Failure
		_PNCO_Require(A_IsCritical == _PNCO.CallerCritical, "All publisher paths must restore inherited Critical.")
		Record := _PNCO.Record
		_PNCO_Require(Record is Map && Record["saved"] == Captured["saved"] && Record["owner_token"] == Token,
			"The genuine publisher must retain the same opaque snapshot and exact token, not a fabricated receipt.")
		if _PNCO.Mode == "zero" {
			_PNCO_Require(!IsObject(Caught) && Published && OwnedSequence > 0 && CB_Read() == "0"
				&& CB_HasRestoreDebtForOwner(Token) && Record["phase"] == "ready",
				"String zero must be a genuine published text with a retained ready snapshot.")
			_PNCO_Require(CB_RestorePlainSnapshotEventually(Captured["saved"], OwnedSequence, Token, "plain_native_cas_fixture"),
				"The real callback must restore exactly its authenticated generation.")
		} else if _PNCO.Mode == "borrow-null" || _PNCO.Mode == "borrow-own" {
			_PNCO_Require(!IsObject(Caught) && !Published && !OwnedSequence && !Record["changed"]
				&& DllCall("User32\GetClipboardSequenceNumber", "UInt") == Before,
				"A borrowed native lease must prevent every mutation and positive receipt.")
			_PNCO_Publish("probe.request")
			_PNCO_Require(StrSplit(_PNCO_Wait("probe.receipt"), "|")[1] == "0", "The different process must still be excluded before original Close.")
			_PNCO_ReleaseBorrower()
			_PNCO_Publish("probe-after.request")
			_PNCO_Wait("probe-after.receipt")
		} else if _PNCO.Mode == "foreign-wins" {
			_PNCO_Require(!IsObject(Caught) && !Published && !OwnedSequence && !Record["restoration_right"]
				&& _PNCO.Next > Token && _PNCO.HookCalls == 1 && CBClipboardOwner.paste_transaction == _PNCO.Next
				&& CBClipboardOwner.active.Count == 1 && CBClipboardOwner.active.Has(_PNCO.Next),
				"Retiring the old restore right must preserve the real successor admitted at settlement.")
			_PNCO_Require(CB_Read() == _PNCO.Foreign && DllCall("User32\GetClipboardSequenceNumber", "UInt") == _PNCO.ForeignSequence
				&& DllCall("User32\GetClipboardOwner", "Ptr") == _PNCO.WriterHwnd,
				"The actual newer native copy must win without old rollback or late cleanup.")
			_PNCO_Require(CB_EndOwnedTransaction(_PNCO.Next), "Only the fixture's exact successor may be released.")
			_PNCO.Next := 0
		} else {
			_PNCO_Require(!Published && !OwnedSequence && CB_HasRestoreDebtForOwner(Token)
				&& CBClipboardOwner.restore_debt == Record && Record["saved"] == Captured["saved"]
				&& CBClipboardOwner.paste_transaction == Token && CBClipboardOwner.active.Has(Token)
				&& Record["kind"] == "plain_native" && Record["expected_sequence"] == 0 && !Record["force"]
				&& !CB_PrepareShutdown(), "An unresolved native capability must retain the same SavedAll and token, including shutdown refusal.")
			if _PNCO.Mode == "close-lost" {
				_PNCO_Require(Caught == _PNCO.Injected && _PNCO.CloseFired == 1 && _PNCO.CloseResult == 1
					&& Record["lease_unknown"] && _PNCO.NullHeld, "Actual successful Close followed by lost ACK must remain unknown while a later NULL borrower holds.")
				_PNCO_Publish("probe.request")
				_PNCO_Require(StrSplit(_PNCO_Wait("probe.receipt"), "|")[1] == "0", "Recovery may not close the later NULL borrower's lease.")
				_PNCO_ReleaseBorrower()
				_PNCO_Publish("probe-after.request")
				_PNCO_Wait("probe-after.receipt")
			} else if _PNCO.Mode == "set-null" {
				_PNCO_Require(!IsObject(Caught) && _PNCO.SetFired == 1 && !_PNCO.SetResult && _PNCO.SetError
					&& !_PNCO.CloseResult && Record["lease_unknown"] && !Record["published"],
					"Real SetClipboardData NULL after deliberate opener abort cannot become an ordinary zero-sequence restore.")
			} else if _PNCO.Mode == "arm-refused" {
				_PNCO_Require(Caught == _PNCO.Injected && _PNCO.ArmFired == 1 && Record["retry_failure"] == _PNCO.Injected,
					"A protocol retry-arm refusal must preserve its original Error and exact published debt.")
			} else
				_PNCO_Require(!IsObject(Caught), "Actual native contention is a retained refusal, not an injected exception.")
			_PNCO_ReleaseWriter()
		}
		_PNCO_Drain()
		_PNCO_Require(!CB_HasRestoreDebtForOwner(Token) && !CBClipboardOwner.active.Count && !CBClipboardOwner.paste_transaction,
			"Real retry or terminal refusal must retire only the original owner and all its debt.")
		if _PNCO.Mode != "foreign-wins"
			_PNCO_Require(CB_Read() == _PNCO.Seed, "Every known owned generation must finish with the real original A.")
		if IsObject(_PNCO.Failure)
			throw _PNCO.Failure
		FileAppend("RECEIPT plain-native-cas mode=" . _PNCO.Mode . " published=" . (Published ? 1 : 0)
			. " close_fired=" . _PNCO.CloseFired . " set_fired=" . _PNCO.SetFired . " arm_fired=" . _PNCO.ArmFired
			. " changed=" . (Record["changed"] ? 1 : 0) . " lease_unknown=" . (Record["lease_unknown"] ? 1 : 0)
			. " right=" . (Record["restoration_right"] ? 1 : 0) . " active=0 debt=0`n", "*", "UTF-8-RAW")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		_PNCO.Armed := false
		for Cleanup in [_PNCO_ReleaseBorrower, _PNCO_ReleaseWriter, _PNCO_Drain] {
			try Cleanup.Call()
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			if _PNCO.Next && CBClipboardOwner.active.Has(_PNCO.Next)
				CB_EndOwnedTransaction(_PNCO.Next)
			if Token && !CB_HasRestoreDebtForOwner(Token) && CBClipboardOwner.active.Has(Token)
				CB_EndOwnedTransaction(Token)
			_PNCO_Require(!CBClipboardOwner.active.Count && !(CBClipboardOwner.restore_debt is Map), "Cleanup cannot discard an unknown SavedAll or owner.")
			if HaveSnapshot {
				Text := CB_Read(), Sequence := CB_GetSequenceNumber()
				Known := Sequence > 0 && (Text == _PNCO.Seed || Text == "0" || Text == _PNCO.Foreign)
					&& (DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd
						|| DllCall("User32\GetClipboardOwner", "Ptr") == _PNCO.WriterHwnd)
				if Known
					_PNCO_Require(CB_RestoreOwnedAllEventually(Snapshot, Sequence, 0, "plain_native_cas_cleanup", false), "Only a known fixture generation may restore the incoming snapshot.")
				_PNCO_Drain()
				FileAppend("CLEANUP plain-native-cas-owner known=" . (Known ? 1 : 0) . " unknown_preserved=" . (Known ? 0 : 1) . " debt=0 active=0`n", "*", "UTF-8-RAW")
			}
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			CBClipboardOwner.settle_hook := 0
			OnError(_PNCO_OnError, 0)
			try _PNCO_Publish("subject.done")
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS plain-native-cas-owner " . _PNCO.Mode . "`n", "*", "UTF-8-RAW")
}

try {
	_PNCO_Require(A_Args.Length == 5, "The child requires its exact two roles, private directory and declared mode.")
	global _PNCO := {Root: A_Args[2], Mode: A_Args[3], Record: 0, Armed: false, Held: false, NullHeld: false,
		Seed: "native CAS original A é😀 " . A_Args[2], Foreign: "native CAS foreign C é😀 " . A_Args[2],
		Failure: 0, Injected: Error("Controlled protocol acknowledgement refusal."), Token: 0, Next: 0, HookCalls: 0,
		CloseFired: 0, CloseResult: 0, CloseError: 0, SetFired: 0, SetResult: 0, SetError: 0, ArmFired: 0,
		CallerCritical: 0, WriterHwnd: 0, ForeignSequence: 0}
	Critical("Off")
	if A_Args[1] == "writer"
		_PNCO_Writer()
	else {
		_PNCO_Require(A_Args[1] == "subject", "Only the owned subject or writer may execute.")
		_PNCO_Subject()
	}
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}
