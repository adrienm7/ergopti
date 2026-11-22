; tests/unit/platform/input/test_clipboard_reader_wait.ahk

; ==============================================================================
; MODULE: Paste Publication Against A Known Clipboard Reader
; DESCRIPTION:
; Windows wakes clipboard readers (explorer.exe, clipboard history) after every
; change. A second owned process holds the real lock the same way, so the
; SendInstant publication and its contention probe meet a reader on demand
; instead of depending on the desktop's. No sequence or holder is forged.
; ==============================================================================

#Requires AutoHotkey v2.0

_CRWT_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

; Starts the known reader and returns once it holds the lock for HoldMs.
_CRWT_StartReader(HoldMs) {
	global _DriverDir
	static Serial := 0
	Root := A_Temp . "\ergopti_clipboard_reader_" . A_ScriptHwnd . "_" . ++Serial . "_" . A_TickCount
	FSCreateDirectoryExclusiveStrict(Root)
	Reader := {Root: Root, Calls: 0, Code: -1, Output: "", ErrorText: "", Handle: 0, Hwnd: 0}
	Reader.Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8",
		_DriverDir . "\tests\fixtures\clipboard_reader_hold.ahk", Root, String(HoldMs)], _CRWT_Done.Bind(Reader))
	AssertTrue(Reader.Handle.start(), "the known reader process must start")
	Started := A_TickCount
	while !FileExist(Root . "\held") && Reader.Calls == 0 && TickElapsed(Started) < 10000 {
		_SR_TreePoll()
		Sleep(1)
	}
	AssertTrue(FileExist(Root . "\held") != "", "the known reader must hold the lock: " . Reader.Output . Reader.ErrorText)
	Reader.Hwnd := Integer(FileRead(Root . "\held", "UTF-8"))
	return Reader
}

_CRWT_FinishReader(Reader) {
	if !IsObject(Reader)
		return
	Started := A_TickCount
	while Reader.Calls == 0 && TickElapsed(Started) < 10000 {
		_SR_TreePoll()
		Sleep(10)
	}
	if Reader.Calls == 0
		Reader.Handle.requestTerminate()
	AssertEqual(1, Reader.Handle.terminate(), "the known reader process must retire")
	AssertEqual(0, Reader.Code, "the known reader failed: " . Reader.Output . Reader.ErrorText)
	AssertContains(Reader.Output, "PASS clipboard reader hold")
	DirDelete(Reader.Root, true)
}

_CRWT_RequireIdleOwner() {
	AssertEqual(0, CBClipboardOwner.active.Count, "no other in-process clipboard transaction may run")
	AssertEqual(0, CBClipboardOwner.paste_transaction)
	AssertFalse(CBClipboardOwner.restore_debt is Map)
}

; Waits for the real restore service to put the user's clipboard back.
_CRWT_Settle() {
	Started := A_TickCount
	while (CBClipboardOwner.active.Count || CBClipboardOwner.paste_transaction
			|| CBClipboardOwner.restore_debt is Map) && TickElapsed(Started) < 3000 {
		if CBClipboardOwner.restore_debt is Map
			CB_RetryRestoreDebt()
		Sleep(10)
	}
	_CRWT_RequireIdleOwner()
}

; Reads the published text and the DWORD of each transient marker.
_CRWT_ReadPublication() {
	global CB_TRANSIENT_FORMAT_NAMES
	AssertTrue(CB_OpenClipboardWithin(A_ScriptHwnd), "the test must read the publication under its own lock")
	try {
		Handle := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
		AssertTrue(Handle != 0, "the publication must hold Unicode text")
		Pointer := DllCall("Kernel32\GlobalLock", "Ptr", Handle, "Ptr")
		try Text := StrGet(Pointer, "UTF-16")
		finally DllCall("Kernel32\GlobalUnlock", "Ptr", Handle)
		Markers := Map()
		for Name in CB_TRANSIENT_FORMAT_NAMES {
			MarkerFormat := DllCall("User32\RegisterClipboardFormatW", "Str", Name, "UInt")
			Data := DllCall("User32\GetClipboardData", "UInt", MarkerFormat, "Ptr")
			Markers[Name] := Data && DllCall("Kernel32\GlobalSize", "Ptr", Data, "UPtr") >= 4
				? NumGet(DllCall("Kernel32\GlobalLock", "Ptr", Data, "Ptr"), "UInt") : -1
			if Data
				DllCall("Kernel32\GlobalUnlock", "Ptr", Data)
		}
	} finally DllCall("User32\CloseClipboard", "Int")
	return {Text: Text, Markers: Markers}
}

/** The paste publication outwaits a reader shorter than its bound and marks itself transient. */
_CRWT_PublicationOutwaitsReader() {
	global CB_PASTE_READER_WAIT_MS, CB_TRANSIENT_FORMAT_NAMES
	_CRWT_RequireIdleOwner()
	Payload := "ergopti reader wait " . A_TickCount
	Token := CB_TryBeginPasteTransaction("clipboard_reader_wait_test")
	AssertTrue(Token > 0, "the test must own the real paste transaction")
	Reader := 0, Sequence := 0, Published := false, Captured := 0
	try {
		AssertTrue(CB_SavePlainSnapshot(Token, &Captured), "the real snapshot must bind the current generation")
		HoldMs := CB_PASTE_READER_WAIT_MS * 7 // 10
		Reader := _CRWT_StartReader(HoldMs)
		AssertEqual(Reader.Hwnd, DllCall("User32\GetOpenClipboardWindow", "Ptr"),
			"the known reader must still hold the lock when the publication starts")
		Published := CB_WritePlainSnapshot(Captured, Payload, &Sequence)
		AssertTrue(Published, "a reader shorter than CB_PASTE_READER_WAIT_MS must not refuse the paste publication")
		AssertTrue(Sequence > 0, "the outwaited publication must still authenticate its own sequence")
		Publication := _CRWT_ReadPublication()
		AssertEqual(Payload, Publication.Text)
		for Name in CB_TRANSIENT_FORMAT_NAMES
			AssertEqual(0, Publication.Markers[Name], "the transient payload must carry " . Name . " = 0")
	} finally {
		if Published && Sequence
			CB_RestorePlainSnapshotEventually(Captured["saved"], Sequence, Token, "clipboard_reader_wait_test")
		else if !CB_HasRestoreDebtForOwner(Token)
			CB_EndOwnedTransaction(Token)
		_CRWT_Settle()
		_CRWT_FinishReader(Reader)
	}
}
Test("Clipboard reader wait: the paste publication outwaits a passing reader (clipboard-reader-wait)",
	_CRWT_PublicationOutwaitsReader)

/** A reader holding past the bound still refuses the publication, within the bound. */
_CRWT_PublicationRefusesLongReader() {
	global CB_PASTE_READER_WAIT_MS
	_CRWT_RequireIdleOwner()
	HoldMs := CB_PASTE_READER_WAIT_MS * 5
	Token := CB_TryBeginPasteTransaction("clipboard_reader_wait_test")
	AssertTrue(Token > 0, "the test must own the real paste transaction")
	Reader := 0, Sequence := 0, Published := false, Captured := 0
	try {
		AssertTrue(CB_SavePlainSnapshot(Token, &Captured), "the real snapshot must bind the current generation")
		Reader := _CRWT_StartReader(HoldMs)
		Started := A_TickCount
		Published := CB_WritePlainSnapshot(Captured, "ergopti long reader", &Sequence)
		Elapsed := TickElapsed(Started)
		AssertFalse(Published, "a reader holding past the bound must refuse the publication")
		AssertEqual(0, Sequence)
		AssertTrue(Elapsed >= CB_PASTE_READER_WAIT_MS && Elapsed < HoldMs - CB_PASTE_READER_WAIT_MS,
			"the refusal must come after the bound and before the reader lets go (" . Elapsed . " ms)")
	} finally {
		if Published && Sequence
			CB_RestorePlainSnapshotEventually(Captured["saved"], Sequence, Token, "clipboard_reader_wait_test")
		else if !CB_HasRestoreDebtForOwner(Token)
			CB_EndOwnedTransaction(Token)
		_CRWT_FinishReader(Reader)
		_CRWT_Settle()
	}
}
Test("Clipboard reader wait: a reader past the bound refuses the publication in time (clipboard-reader-wait)",
	_CRWT_PublicationRefusesLongReader)

/** The contention probe answers idle once a passing reader closes, busy for a long one. */
_CRWT_BusyProbeOutwaitsReader() {
	global CB_PASTE_READER_WAIT_MS
	_CRWT_RequireIdleOwner()
	Reader := _CRWT_StartReader(CB_PASTE_READER_WAIT_MS * 7 // 10)
	try {
		AssertEqual(Reader.Hwnd, DllCall("User32\GetOpenClipboardWindow", "Ptr"),
			"the known reader must still hold the lock when the probe starts")
		AssertFalse(CB_IsBusy(), "a reader shorter than CB_PASTE_READER_WAIT_MS must not send SendInstant down the clipboard-free path")
	} finally _CRWT_FinishReader(Reader)
	HoldMs := CB_PASTE_READER_WAIT_MS * 5
	Reader := _CRWT_StartReader(HoldMs)
	try {
		Started := A_TickCount
		AssertTrue(CB_IsBusy(), "a reader holding past the bound keeps the clipboard busy")
		AssertTrue(TickElapsed(Started) < HoldMs - CB_PASTE_READER_WAIT_MS, "the probe must answer within its bound")
	} finally _CRWT_FinishReader(Reader)
}
Test("Clipboard reader wait: the contention probe outwaits a passing reader (clipboard-reader-wait)",
	_CRWT_BusyProbeOutwaitsReader)
