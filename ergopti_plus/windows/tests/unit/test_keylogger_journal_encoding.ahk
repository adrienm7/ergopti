; tests/unit/test_keylogger_journal_encoding.ahk

; ==============================================================================
; MODULE: Keylogger Journal Encoding Admission Tests
; DESCRIPTION:
; A native UTF-8 append must not publish or mutate an existing UTF-16 journal.
; The failed candidate must leave the previous singleton properties recoverable.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJE_RejectUtf16() {
	Saved := Map()
	for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	}
	Path := _FSWL_Path()
	Writer := 0
	try {
		FileAppend("user-owned é😀", Path, "UTF-16")
		Before := FileRead(Path, "RAW")
		Keylogger.today_log_path := Path
		Keylogger._today_fh := unset
		Keylogger._today_fh_date := ""
		Failure := 0
		try Writer := KL_OpenTodayFh()
		catch Any as Err
			Failure := Err
		AssertTrue(Failure is ValueError, "UTF-16 journal must be refused at encoding admission")
		AssertFalse(Keylogger.HasOwnProp("_today_fh"), "invalid handle must not be published")
		AssertEqual("", Keylogger._today_fh_date)
		After := FileRead(Path, "RAW")
		AssertEqual(Before.Size, After.Size)
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory",
			"Ptr", Before, "Ptr", After, "UPtr", Before.Size, "UPtr"))
	} finally {
		if IsObject(Writer)
			Writer.Close()
		for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
			if Saved.Has(Name)
				Keylogger.%Name% := Saved[Name]
			else
				Keylogger.%Name% := unset
		}
		if FileExist(Path)
			FileDelete(Path)
	}
}

Test("keylogger: UTF-16 journal is refused before handle publication (keylogger-journal-encoding)", _KJE_RejectUtf16)

_KJE_ReadFirstRow(Encoding) {
	Path := _FSWL_Path()
	First := '{"type":"typing","_event_id":1}' . "`n"
	Second := '{"type":"typing","_event_id":2}' . "`n"
	try {
		FileAppend(First . Second, Path, Encoding)
		Read := _KL_JournalReadLines(Path, 0, 1, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertEqual(1, Read["entries"].Length, "the first JSON row must survive the encoding header")
		AssertEqual(1, Read["entries"][1]["_event_id"])
		AssertFalse(Read["eof"])
		Next := _KL_JournalReadLines(Path, Read["offset"], 1, KL_JsonDecode)
		AssertEqual(1, Next["entries"].Length)
		AssertEqual(2, Next["entries"][1]["_event_id"])
		AssertTrue(Next["eof"])
		AssertEqual(FileGetSize(Path), Next["offset"], "the checkpoint remains a byte offset")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Encoding in ["UTF-8", "UTF-8-RAW"]
	Test("keylogger: first journal row survives " . Encoding . " (journal-bom-replay)",
		_KJE_ReadFirstRow.Bind(Encoding))

_KJE_RejectCheckpointPastEnd(Mode) {
	Path := _FSWL_Path()
	Line := '{"type":"typing","_event_id":1}' . "`n"
	Offset := StrPut(Line, "UTF-8")
	try {
		if Mode != "missing"
			FileAppend(Mode = "empty" ? "" : Line, Path, "UTF-8-RAW")
		Read := _KL_JournalReadLines(Path, Offset, 1, KL_JsonDecode)
		AssertFalse(Read["ok"], "a stale checkpoint must not certify that the journal is drained")
		AssertFalse(Read["eof"], "rollover must not discard a journal whose checkpoint is invalid")
		AssertEqual(Offset, Read["offset"], "refusal must retain the caller's checkpoint")
		AssertEqual(0, Read["entries"].Length)
		if Mode != "missing"
			AssertEqual(Mode = "empty" ? "" : Line, FileRead(Path, "UTF-8"))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Mode in ["present", "empty", "missing"]
	Test("keylogger: stale journal checkpoint refuses " . Mode . " (journal-checkpoint-past-end)",
		_KJE_RejectCheckpointPastEnd.Bind(Mode))

_KJE_AcceptCheckpointAtEnd(Mode) {
	Path := _FSWL_Path()
	try {
		if Mode != "missing"
			FileAppend(Mode = "empty" ? "" : '{"type":"typing"}' . "`n", Path, "UTF-8-RAW")
		Offset := Mode = "present" ? FileGetSize(Path) : 0
		Read := _KL_JournalReadLines(Path, Offset, 1, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertTrue(Read["eof"], "an exact checkpoint remains eligible for rollover")
		AssertEqual(Offset, Read["offset"])
		AssertEqual(0, Read["entries"].Length)
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Mode in ["present", "empty", "missing"]
	Test("keylogger: exact journal checkpoint accepts " . Mode . " (journal-checkpoint-past-end)",
		_KJE_AcceptCheckpointAtEnd.Bind(Mode))

_KJE_RejectUnalignedCheckpoint(Encoding, Offset) {
	Path := _FSWL_Path()
	Text := '{"type":"typing","text":"é😀"}' . "`n"
	try {
		FileAppend(Text, Path, Encoding)
		Read := _KL_JournalReadLines(Path, Offset, 1, KL_JsonDecode)
		AssertFalse(Read["ok"], "an invalid byte position must not acknowledge or replay a record")
		AssertFalse(Read["eof"])
		AssertEqual(Offset, Read["offset"])
		AssertEqual(0, Read["entries"].Length)
		AssertEqual(Text, FileRead(Path, "UTF-8"))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Scenario in [["UTF-8-RAW", -1], ["UTF-8-RAW", 1], ["UTF-8", 1], ["UTF-8", 2]]
	Test("keylogger: invalid journal position " . Scenario[1] . " / " . Scenario[2] . " (journal-checkpoint-alignment)",
		_KJE_RejectUnalignedCheckpoint.Bind(Scenario[1], Scenario[2]))

_KJE_AlignedUnicodeContinuation(Encoding) {
	Path := _FSWL_Path()
	First := '{"type":"typing","text":"é😀"}' . "`r`n"
	Second := '{"type":"typing","text":"à"}' . "`n"
	InitialOffset := Encoding = "UTF-8" ? 3 : 0
	try {
		FileAppend(First . Second, Path, Encoding)
		Read := _KL_JournalReadLines(Path, InitialOffset, 1, KL_JsonDecode)
		AssertTrue(Read["ok"], "the position after a BOM is a valid initial checkpoint")
		AssertEqual("é😀", Read["entries"][1]["text"])
		AssertEqual(InitialOffset + StrPut(First, "UTF-8") - 1, Read["offset"])
		Next := _KL_JournalReadLines(Path, Read["offset"], 1, KL_JsonDecode)
		AssertTrue(Next["ok"], "byte checkpoints must survive Unicode and CRLF delimiters")
		AssertEqual("à", Next["entries"][1]["text"])
		AssertTrue(Next["eof"])
		AssertEqual(FileGetSize(Path), Next["offset"])
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Encoding in ["UTF-8", "UTF-8-RAW"]
	Test("keylogger: aligned Unicode continuation " . Encoding . " (journal-checkpoint-alignment)",
		_KJE_AlignedUnicodeContinuation.Bind(Encoding))
