; tests/unit/adapters/input/test_clipboardall_external_lock.ahk

; ==============================================================================
; MODULE: ClipboardAll Native External Lock Characterization
; DESCRIPTION:
; Establishes whether the real AHK setter can reopen the same HWND's native
; clipboard lock. An independent process proves exclusion before the setter
; and reads both restored formats after its internal CloseClipboard. This does
; not change or qualify the restore-debt comparison protocol.
; ==============================================================================

#Requires AutoHotkey v2.0

_CALC_Completed(State, Code, Output, ErrorText) {
	State.Calls += 1
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_CALC_WaitFile(Path, State) {
	Started := A_TickCount
	while !FileExist(Path) && State.Calls == 0 && TickElapsed(Started) < 10000 {
		_SR_TreePoll()
		Sleep(10)
	}
	AssertTrue(FileExist(Path) != "", "the real observer handshake must arrive: " . Path
		. " / " . State.Output . State.ErrorText)
}

_CALC_AddBinaryFormat(FormatId) {
	AssertTrue(DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int"), "the fixture must open its native format publication")
	Handle := 0
	try {
		Handle := DllCall("Kernel32\GlobalAlloc", "UInt", 0x42, "UPtr", 8, "Ptr")
		AssertTrue(Handle != 0)
		Pointer := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		AssertTrue(Pointer != 0)
		try {
			for Index, Byte in [0x00, 0x07, 0x00, 0xFF, 0x01, 0x23, 0x00, 0x80]
				NumPut("UChar", Byte, Pointer, Index - 1)
		} finally DllCall("Kernel32\GlobalUnlock", "Ptr", Handle)
		AssertTrue(DllCall("User32\SetClipboardData", "UInt", FormatId, "Ptr", Handle, "Ptr") != 0)
		Handle := 0
	} finally {
		DllCall("User32\CloseClipboard", "Int")
		if Handle
			DllCall("Kernel32\GlobalFree", "Ptr", Handle, "Ptr")
	}
}

_CALC_Run(Held) {
	global DriverPid, _DriverDir
	PreviousCritical := Critical("On"), WasSuspended := A_IsSuspended
	Original := 0, SnapshotTaken := false, Saved := 0, Token := 0, Primary := 0
	Task := 0, Retired := true, RootCreated := false, RawOpened := false
	Root := A_Temp . "\ergopti_clipboard_lock_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	try {
		AssertEqual(0, CBClipboardOwner.active.Count, "the characterization refuses another clipboard owner")
		AssertEqual(0, CBClipboardOwner.paste_transaction)
		AssertFalse(CBClipboardOwner.restore_debt is Map, "the characterization refuses inherited restore debt")
		Saved := {Generation: CBClipboardOwner.generation, MutationId: CBClipboardOwner.mutation_id,
			Pending: CBClipboardOwner.pending, Observer: CBClipboardOwner.observer_active, Settle: CBClipboardOwner.settle_hook}
		CBClipboardOwner.pending := [], CBClipboardOwner.observer_active := false, CBClipboardOwner.settle_hook := 0
		Critical("Off")
		if A_IsSuspended
			Suspend(false)
		Original := CB_SaveAll()
		AssertFalse(Type(Original) == "String" && Original == "__CB_SAVE_ERROR__")
		SnapshotTaken := true
		Token := CB_TryBeginOwnedTransaction("clipboardall_lock_characterization")
		AssertTrue(Token > 0, "the real central clipboard owner admits this isolated test")
		RootCreated := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(RootCreated)
		FormatId := DllCall("User32\RegisterClipboardFormatW", "Str", "Ergopti ClipboardAll Lock Characterization", "UInt")
		AssertTrue(FormatId >= 0xC000, "the native private format must have its own registered identity")
		Text := "clipboard lock é😀`noriginal"
		AssertTrue(CB_Write(Text))
		_CALC_AddBinaryFormat(FormatId)
		Captured := CB_SaveAll()
		AssertFalse(Type(Captured) == "String" && Captured == "__CB_SAVE_ERROR__")
		AssertTrue(CB_Write("temporary clipboard lock payload"))
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", _DriverDir . "\tests\fixtures\clipboardall_lock_observer.ahk", Root, String(FormatId)],
			_CALC_Completed.Bind(State))
		Retired := false
		AssertTrue(Task.start(), "the actual separate clipboard observer must start")
		_CALC_WaitFile(Root . "\ready", State)
		AssertEqual("ready", FSReadUtf8Exact(Root . "\ready"))
		if Held {
			RawOpened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
			AssertTrue(RawOpened, "the parent must acquire its real native external lock")
		}
		AssertTrue(FSWriteCreateDurable(Root . "\before.request", "probe"))
		_CALC_WaitFile(Root . "\before.receipt", State)
		AssertEqual(Held ? "busy" : "open", FSReadUtf8Exact(Root . "\before.receipt"),
			"the separate process must distinguish the held global lock from the ordinary control")
		if Held
			AssertEqual(A_ScriptHwnd, DllCall("User32\GetOpenClipboardWindow", "Ptr"), "the same native HWND must still own the external lock")
		SetterCritical := Critical("On")
		try AssertTrue(CB_RestoreAll(Captured), "the real opaque ClipboardAll setter must accept its same-HWND native reopen")
		finally Critical(SetterCritical)
		AssertEqual(0, DllCall("User32\GetOpenClipboardWindow", "Ptr"),
			"the real setter's internal CloseClipboard releases the lock without an external close")
		RawOpened := false
		AssertTrue(FSWriteCreateDurable(Root . "\after.request", "probe"))
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the exact observer must complete once")
		AssertEqual(0, State.Code, "the native observer refused: " . State.Output . State.ErrorText)
		AssertEqual("PASS clipboardall lock observer", State.Output)
		AssertEqual("", State.ErrorText)
		AssertEqual(Text, FSReadUtf8Exact(Root . "\text.receipt"), "the independent process reads the complete restored Unicode text")
		AssertEqual("000700FF01230080", FSReadUtf8Exact(Root . "\binary.receipt"),
			"the independent process reads the restored binary format, including embedded NUL bytes")
		AssertTrue(CBClipboardOwner.active.Has(Token), "the characterization retains its exact central lease through native observation")
	} catch as Err {
		Primary := Err
	} finally {
		try {
			if RawOpened && DllCall("User32\GetOpenClipboardWindow", "Ptr") == A_ScriptHwnd
				DllCall("User32\CloseClipboard", "Int")
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
				AssertTrue(Retired, "the exact observer tree must retire before its handshake files")
			}
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if SnapshotTaken
				AssertTrue(CB_RestoreAll(Original), "the characterization must restore its incoming all-formats clipboard")
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if Token && CBClipboardOwner.active.Has(Token)
				AssertTrue(CB_EndOwnedTransaction(Token), "the exact characterization lease must retire")
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if Retired && RootCreated
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if A_IsSuspended != WasSuspended
				Suspend(WasSuspended)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if IsObject(Saved) {
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

Test("ClipboardAll lock: ordinary setter preserves both native formats (clipboardall-external-lock)", _CALC_Run.Bind(false))
Test("ClipboardAll lock: same-HWND external open excludes another process through the real setter (clipboardall-external-lock)", _CALC_Run.Bind(true))
