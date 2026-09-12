; tests/unit/test_keylogger_journal_read_progress.ahk

; ==============================================================================
; MODULE: Journal Read Progress Tests
; DESCRIPTION: A refused ReadLine must fail before spinning until a lock disappears.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJRP_RefusedReadDoesNotSpin(LockedOffset) {
	Path := _FSWL_Path()
	Probe := Map("file", 0, "locked", false, "page_size", 1, "overlap", Buffer(32, 0))
	Release := _KLRCC_ReleaseLock.Bind(Probe)
	PreviousCritical := Critical("Off")
	try {
		Padding := ""
		if LockedOffset {
			Loop 8192
				Padding .= "x"
			NumPut("UInt", LockedOffset, Probe["overlap"], 16)
		}
		FileAppend('{"type":"typing","_event_id":1,"text":"' . Padding . '"}' . "`n", Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		Probe["file"] := FileOpen(Path, "r")
		Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
			"UInt", 3, "UInt", 0, "UInt", 1, "UInt", 0, "Ptr", Probe["overlap"], "Int")
		AssertTrue(Probe["locked"])
		; Bound the broken implementation: it spins until this native lock ends.
		SetTimer(Release, -500)
		Read := _KL_JournalReadLines(Path, 0, 1, KL_JsonDecode)
		AssertFalse(Read["ok"], "a refused read must fail rather than spin until it can return success")
		AssertEqual(0, Read["offset"])
		AssertEqual(0, Read["entries"].Length)
		AssertFalse(Read["eof"], "read refusal must not authorize journal retirement")
		SetTimer(Release, 0)
		Release.Call()
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		Read := _KL_JournalReadLines(Path, 0, 10, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertTrue(Read["eof"])
		AssertEqual(1, Read["entries"].Length)
		AssertEqual(1, Read["entries"][1]["_event_id"])
	} finally {
		SetTimer(Release, 0)
		Release.Call()
		Critical(PreviousCritical)
		if FileExist(Path)
			FileDelete(Path)
	}
}
for LockedOffset in [0, 4096]
	Test("keylogger: native journal read refusal offset=" . LockedOffset . " preserves progress (journal-read-progress)",
		_KJRP_RefusedReadDoesNotSpin.Bind(LockedOffset))

_KJRP_LongRecord(Limit) {
	Path := _FSWL_Path()
	try {
		Payload := Format("{:131072}", "x")
		Line := '{"type":"typing","_event_id":1,"text":"' . Payload . '"}'
		AssertEqual(Payload, KL_JsonDecode(Line)["text"], "the complete record must decode")
		FileAppend(Line . "`n", Path, "UTF-8-RAW")
		Read := _KL_JournalReadLines(Path, 0, Limit, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(1, Read["entries"].Length, "a long record must not be acknowledged as malformed fragments")
		AssertEqual(Payload, Read["entries"][1]["text"])
		AssertEqual(FileGetSize(Path), Read["offset"])
		AssertTrue(Read["eof"])
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Limit in [1, 10]
	Test("keylogger: long journal record limit=" . Limit . " stays intact (journal-long-record)",
		_KJRP_LongRecord.Bind(Limit))

_KJRP_LongRecordBoundaries() {
	Path := _FSWL_Path()
	try {
		; The multibyte character crosses the raw read boundary after the prefix.
		Prefix := '{"type":"typing","text":"'
		Payload := Format("{:" . (65535 - StrLen(Prefix)) . "}", "x") . Chr(0x1F642)
		First := Prefix . Payload . '"}' . "`r`n"
		Second := '{"type":"typing","text":"second"}'
		FileAppend(First . Second, Path, "UTF-8-RAW")
		Read := _KL_JournalReadLines(Path, 0, 1, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(1, Read["entries"].Length)
		AssertEqual(Payload, Read["entries"][1]["text"])
		AssertEqual(StrPut(First, "UTF-8") - 1, Read["offset"])
		AssertFalse(Read["eof"])
		Checkpoint := Read["offset"]
		Read := _KL_JournalReadLines(Path, Checkpoint, 10, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(Checkpoint, Read["offset"])
		AssertEqual(0, Read["entries"].Length)
		AssertFalse(Read["eof"])
		FileAppend("`n", Path, "UTF-8-RAW")
		Read := _KL_JournalReadLines(Path, Checkpoint, 10, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(1, Read["entries"].Length)
		AssertEqual("second", Read["entries"][1]["text"])
		AssertEqual(FileGetSize(Path), Read["offset"])
		AssertTrue(Read["eof"])
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger: UTF-8 framing preserves batch and incomplete tail boundaries (journal-long-record)",
	_KJRP_LongRecordBoundaries)

_KJRP_NulRecord() {
	Path := _FSWL_Path()
	Fh := 0
	try {
		Prefix := '{"type":"typing","text":"invalid-prefix"}'
		Bytes := Buffer(StrPut(Prefix, "UTF-8") + 2, 0)
		StrPut(Prefix, Bytes, "UTF-8")
		NumPut("UChar", 120, Bytes, Bytes.Size - 2)
		NumPut("UChar", 10, Bytes, Bytes.Size - 1)
		Fh := FileOpen(Path, "w")
		AssertEqual(Bytes.Size, Fh.RawWrite(Bytes))
		Fh.Close()
		Fh := 0
		FileAppend('{"type":"typing","text":"valid"}' . "`n", Path, "UTF-8-RAW")
		Read := _KL_JournalReadLines(Path, 0, 1, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(0, Read["entries"].Length)
		AssertEqual(Bytes.Size, Read["offset"])
		AssertFalse(Read["eof"])
		Read := _KL_JournalReadLines(Path, 0, 10, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(1, Read["entries"].Length, "a NUL must not hide an invalid record suffix")
		AssertEqual("valid", Read["entries"][1]["text"])
		AssertTrue(Read["eof"])
		AssertEqual(FileGetSize(Path), Read["offset"])
	} finally {
		if IsObject(Fh)
			Fh.Close()
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger: embedded NUL cannot turn malformed JSON into an event (journal-nul-record)", _KJRP_NulRecord)

_KJRP_BlankLineBudget(Newline) {
	Path := _FSWL_Path()
	try {
		FileAppend(Newline . Newline . '{"type":"typing","text":"next"}' . "`n", Path, "UTF-8-RAW")
		Offset := 0
		loop 2 {
			Read := _KL_JournalReadLines(Path, Offset, 1, KL_JsonDecode)
			AssertTrue(Read["ok"])
			AssertEqual(0, Read["entries"].Length, "blank records must consume the batch budget")
			AssertEqual(Offset + StrLen(Newline), Read["offset"])
			AssertFalse(Read["eof"])
			Offset := Read["offset"]
		}
		Read := _KL_JournalReadLines(Path, Offset, 1, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(1, Read["entries"].Length)
		AssertEqual("next", Read["entries"][1]["text"])
		AssertEqual(FileGetSize(Path), Read["offset"])
		AssertTrue(Read["eof"])
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Newline in ["`n", "`r`n"]
	Test("keylogger: blank records consume batch budget width=" . StrLen(Newline) . " (journal-blank-budget)",
		_KJRP_BlankLineBudget.Bind(Newline))
