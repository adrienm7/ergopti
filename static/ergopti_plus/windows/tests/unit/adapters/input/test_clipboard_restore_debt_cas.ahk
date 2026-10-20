; tests/unit/adapters/input/test_clipboard_restore_debt_cas.ahk

#Requires AutoHotkey v2.0

; Real clipboard mutations from an independent process challenge the native
; lease across the actual coordinator's sequence probe and opaque restore.
_CRDC_Sequence(State) {
	State.SequenceReads += 1
	Sequence := CB_GetSequenceNumber()
	if State.Mode == "boundary" {
		AssertTrue(FSWriteCreateDurable(State.Root . "\before.request", "copy"))
		_CALC_WaitFile(State.Root . "\before.receipt", State)
		State.Before := FSReadUtf8Exact(State.Root . "\before.receipt")
	}
	return Sequence
}

_CRDC_Restore(State, Snapshot) {
	State.Restores += 1
	AssertTrue(Snapshot == State.Captured, "the setter must receive the exact retained opaque snapshot")
	return CB_RestoreAll(Snapshot)
}

_CRDC_Binary(FormatId) {
	AssertTrue(DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int"))
	try {
		Handle := DllCall("User32\GetClipboardData", "UInt", FormatId, "Ptr")
		AssertTrue(Handle != 0, "the restored native binary format must exist")
		AssertTrue(DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr") >= 8)
		Pointer := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		AssertTrue(Pointer != 0)
		try {
			Hex := ""
			loop 8
				Hex .= Format("{:02X}", NumGet(Pointer, A_Index - 1, "UChar"))
			return Hex
		} finally DllCall("Kernel32\GlobalUnlock", "Ptr", Handle)
	} finally DllCall("User32\CloseClipboard", "Int")
}

_CRDC_Run(Mode) {
	global DriverPid, _DriverDir
	PreviousCritical := Critical("On"), WasSuspended := A_IsSuspended
	Root := A_Temp . "\ergopti_restore_cas_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Original := 0, SnapshotTaken := false, Saved := 0, Token := 0, Primary := 0
	Task := 0, Retired := true, RootCreated := false, RawOpened := false
	State := {Calls: 0, Code: -1, Output: "", ErrorText: "", Root: Root, Mode: Mode,
		SequenceReads: 0, Restores: 0, Before: "", Captured: 0}
	try {
		AssertEqual(0, CBClipboardOwner.active.Count, "the native test refuses another clipboard owner")
		AssertEqual(0, CBClipboardOwner.paste_transaction)
		AssertFalse(CBClipboardOwner.restore_debt is Map, "the native test refuses inherited restore debt")
		Saved := {Generation: CBClipboardOwner.generation, MutationId: CBClipboardOwner.mutation_id,
			Pending: CBClipboardOwner.pending, Observer: CBClipboardOwner.observer_active, Settle: CBClipboardOwner.settle_hook}
		CBClipboardOwner.pending := [], CBClipboardOwner.observer_active := false, CBClipboardOwner.settle_hook := 0
		Critical("Off")
		if A_IsSuspended
			Suspend(false)
		Original := CB_SaveAll()
		AssertFalse(Type(Original) == "String" && Original == "__CB_SAVE_ERROR__")
		SnapshotTaken := true
		Token := CB_TryBeginPasteTransaction("clipboard_restore_native_cas_fixture")
		AssertTrue(Token > 0)
		RootCreated := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(RootCreated)
		FormatId := DllCall("User32\RegisterClipboardFormatW", "Str", "Ergopti Restore Debt Native CAS", "UInt")
		AssertTrue(FormatId >= 0xC000)
		Text := "opaque original é😀`nrestore debt"
		AssertTrue(CB_Write(Text))
		_CALC_AddBinaryFormat(FormatId)
		State.Captured := CB_SaveAll()
		AssertFalse(Type(State.Captured) == "String" && State.Captured == "__CB_SAVE_ERROR__")
		AssertTrue(CB_Write("temporary restore debt payload"))
		Expected := CB_GetSequenceNumber()
		AssertTrue(Expected > 0)
		BeforeMutation := CBClipboardOwner.mutation_id
		Foreign := "independent foreign copy é😀"
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", _DriverDir . "\tests\fixtures\clipboard_restore_debt_writer.ahk", Root, Mode, Foreign],
			_CALC_Completed.Bind(State))
		Retired := false
		AssertTrue(Task.start(), "the exact independent clipboard writer must start")
		_CALC_WaitFile(Root . "\ready", State)
		AssertEqual("ready", FSReadUtf8Exact(Root . "\ready"))
		if Mode == "foreign" {
			AssertTrue(FSWriteCreateDurable(Root . "\before.request", "copy"))
			_CALC_WaitFile(Root . "\before.receipt", State)
			AssertEqual("copied", FSReadUtf8Exact(Root . "\before.receipt"))
			AssertTrue(CB_GetSequenceNumber() != Expected, "the external copy must precede the actual comparison")
		}
		if Mode == "borrowed" {
			AssertTrue(CB_Write(Foreign))
			AssertTrue(CB_GetSequenceNumber() != Expected, "the borrowed-lock control must take the skip path")
			BeforeMutation := CBClipboardOwner.mutation_id
			RawOpened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
			AssertTrue(RawOpened, "the real caller must retain its own native lease")
		}
		Result := CB_RestoreOwnedAllEventually(State.Captured, Expected, Token,
			"clipboard_restore_native_cas_fixture", true, false,
			_CRDC_Restore.Bind(State), _CRDC_Sequence.Bind(State))
		if Mode == "borrowed"
			AssertEqual(A_ScriptHwnd, DllCall("User32\GetOpenClipboardWindow", "Ptr"),
				"even a skipped debt must preserve the caller's exact borrowed native lease")
		if Mode == "busy" || Mode == "borrowed" {
			AssertFalse(Result, "an incumbent lock must retain the exact restore debt")
			AssertEqual(0, State.SequenceReads, "ownership cannot be sampled outside the unavailable native lock")
			AssertEqual(0, State.Restores)
			AssertTrue(CB_HasRestoreDebtForOwner(Token))
			AssertTrue(CBClipboardOwner.active.Has(Token))
			if Mode == "borrowed" {
				AssertTrue(DllCall("User32\CloseClipboard", "Int"), "only the borrowing caller may close its lease")
				RawOpened := false
			}
			AssertTrue(FSWriteCreateDurable(Root . "\before.request", "release"))
			_CALC_WaitFile(Root . "\before.receipt", State)
			AssertEqual("released", FSReadUtf8Exact(Root . "\before.receipt"))
			AssertTrue(CB_RetryRestoreDebt(), "the admitted retry must settle its retained debt")
		} else
			AssertTrue(Result, "the actual coordinator must settle its exact admitted request")
		AssertEqual(1, State.SequenceReads)
		ExpectedRestores := Mode == "foreign" || Mode == "borrowed" ? 0 : 1
		AssertEqual(ExpectedRestores, State.Restores, "only the still-owned payload may be restored")
		if Mode == "boundary"
			AssertEqual("busy", State.Before, "the independent copy must be excluded between comparison and setter")
		if Mode == "foreign" || Mode == "borrowed" {
			AssertEqual(Foreign, CB_Read(), "a copy already foreign at comparison must win unchanged")
			AssertEqual(BeforeMutation, CBClipboardOwner.mutation_id, "foreign content must not reserve a restore mutation")
		} else {
			AssertEqual(Text, CB_Read(), "the real setter must restore the entire Unicode format")
			AssertEqual("000700FF01230080", _CRDC_Binary(FormatId), "the opaque custom format including NUL must survive")
			AssertEqual(BeforeMutation + 1, CBClipboardOwner.mutation_id, "exactly one native restore is published")
		}
		AssertFalse(CBClipboardOwner.restore_debt is Map)
		AssertFalse(CBClipboardOwner.active.Has(Token))
		AssertFalse(CB_IsPasteTransactionActive())
		AssertEqual(0, CBClipboardOwner.pending.Length, "the isolated observer cannot acquire foreign FIFO records")
		AssertTrue(DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd,
			"no native restore lock may escape settlement")
		AssertTrue(FSWriteCreateDurable(Root . "\after.request", "copy"))
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, State.Output . State.ErrorText)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("PASS clipboard restore debt writer", State.Output)
		AssertEqual("", State.ErrorText)
		AssertEqual("copied", FSReadUtf8Exact(Root . "\after.receipt"))
		AfterSequence := CB_GetSequenceNumber()
		AssertTrue(AfterSequence > 0)
		AssertTrue(CB_RetryRestoreDebt(), "a completed debt has no further clipboard mutation")
		AssertEqual(AfterSequence, CB_GetSequenceNumber(), "a copy after the setter's close must win normally")
		AssertEqual(Foreign . " after", CB_Read())
		AssertEqual(ExpectedRestores, State.Restores)
	} catch as Err {
		Primary := Err
	} finally {
		Critical("On")
		try {
			if RawOpened && DllCall("User32\GetOpenClipboardWindow", "Ptr") == A_ScriptHwnd
				AssertTrue(DllCall("User32\CloseClipboard", "Int"))
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if IsObject(Task) {
				Started := A_TickCount
				loop {
					Result := Task.requestTerminate()
					Retired := Result is Integer && Result == 1
					if Retired || TickElapsed(Started) >= 5000
						break
					_SR_TreePoll()
					Sleep(10)
				}
				AssertTrue(Retired, "the exact writer must retire before its private files")
			}
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			Debt := CBClipboardOwner.restore_debt
			if Retired && Token && Debt is Map && Debt["owner_token"] == Token
				AssertTrue(_CB_SettleRestoreDebt(Debt), "cleanup must detach only its exact retained debt")
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if Retired && SnapshotTaken
				AssertTrue(CB_RestoreAll(Original), "the test must restore its incoming opaque clipboard")
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if Retired && Token && CBClipboardOwner.active.Has(Token)
				AssertTrue(CB_EndOwnedTransaction(Token))
			if Retired && RootCreated
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if A_IsSuspended != WasSuspended
				Suspend(WasSuspended)
			if Retired && IsObject(Saved) {
				CBClipboardOwner.generation := Saved.Generation, CBClipboardOwner.mutation_id := Saved.MutationId
				CBClipboardOwner.pending := Saved.Pending, CBClipboardOwner.observer_active := Saved.Observer
				CBClipboardOwner.settle_hook := Saved.Settle
			}
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _CRDC_Mode in ["boundary", "busy", "foreign", "borrowed"]
	Test("clipboard restore debt: native " . _CRDC_Mode . " preserves comparison custody (clipboard-restore-debt-native-cas)",
		_CRDC_Run.Bind(_CRDC_Mode))
