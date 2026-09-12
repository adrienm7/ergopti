; tests/unit/test_keylogger_event_id.ahk

; ==============================================================================
; MODULE: Keylogger Event-ID Recovery Tests
; DESCRIPTION:
; Exercises the production tail parser and monotonic resolver against stale
; state and multiple-device ledger fixtures.
;
; ROOT CAUSE ENCODED:
; A RegExMatch start position does not change the meaning of the subject-start
; anchor. Parsing must therefore operate on the tail substring, or a valid ID
; after the VALUES prefix is reported as zero and can be silently reissued.
; ==============================================================================

#Requires AutoHotkey v2.0+





; =======================================
; =======================================
; ======= 1/ Tail parser behavior =======
; =======================================
; =======================================

_KLEI_ReturnsLastIdForRequestedDevice() {
	sql := "INSERT INTO events_typing VALUES ('other', 91, 'a');`n"
		. "INSERT INTO events_typing VALUES ('device-a', 117, 'b');`n"
		. "INSERT INTO events_hotstring VALUES ('device-a', 203, 'c');`n"
		. "INSERT INTO events_typing VALUES ('other', 999, 'd');"

	AssertEqual(KL_ScanMaxEventId(sql, "'device-a'"), 203,
		"tail recovery must parse the final ID for the requested device")
}
Test("keylogger event id: parses the final device row (event-id-tail-anchor)",
	_KLEI_ReturnsLastIdForRequestedDevice)

_KLEI_ReturnsMaximumAcrossOutOfOrderRows() {
	sql := "INSERT INTO events_typing VALUES ('device-a', 117, 'a');`n"
		. "INSERT INTO events_typing VALUES ('device-a', 204, 'b');`n"
		. "INSERT INTO events_typing VALUES ('other', 999, 'c');`n"
		. "INSERT INTO events_hotstring VALUES ('device-a', 204, 'duplicate');`n"
		. "INSERT INTO events_typing VALUES ('device-a', 203, 'detached-flush');"

	AssertEqual(KL_ScanMaxEventId(sql, "'device-a'"), 204,
		"recovery must compute the maximum even when a detached flush appends an older id last")
	AssertEqual(KL_ResolveStartId(100, KL_ScanMaxEventId(sql, "'device-a'")), 205,
		"restart must advance beyond every durable id instead of colliding with 204")
}
Test("keylogger event id: out-of-order detached flush recovers maximum (event-id-recovery-max)",
	_KLEI_ReturnsMaximumAcrossOutOfOrderRows)

_KLEI_ReturnsZeroWhenDeviceIsAbsent() {
	sql := "INSERT INTO events_typing VALUES ('other', 91, 'a');"
	AssertEqual(KL_ScanMaxEventId(sql, "'missing'"), 0,
		"an absent device must retain the fresh-ledger zero sentinel")
}
Test("keylogger event id: absent device returns zero (event-id-tail-anchor)",
	_KLEI_ReturnsZeroWhenDeviceIsAbsent)

_KLEI_QuotedPayloadCannotReserveIds() {
	Payload := "INSERT INTO events_typing VALUES ('device-a', 999999, 'captured');"
	Sql := "INSERT INTO events_typing VALUES ('device-a', 117, " . KL_SqlStr(Payload) . ");`n"
		. "INSERT INTO events_typing VALUES ('other', 999, " . KL_SqlStr(Payload) . ");"
	AssertEqual(117, KL_ScanMaxEventId(Sql, "'device-a'"),
		"SQL-shaped captured text must not reserve an unrelated event identity")
	AssertEqual(118, KL_ResolveStartId(1, KL_ScanMaxEventId(Sql, "'device-a'")))
}
Test("keylogger event id: escaped SQL-shaped payload cannot reserve IDs (event-id-quoted-payload)",
	_KLEI_QuotedPayloadCannotReserveIds)

_KLEI_RecoveryReadRefusal(TailBytes) {
	Path := _FSWL_Path()
	Probe := Map("file", 0, "locked", false, "page_size", 1, "overlap", Buffer(32, 0))
	try {
		Source := "synthetic-recovery-source`n"
		FileAppend(Source, Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		NumPut("UInt", TailBytes ? FileGetSize(Path) - TailBytes : 0, Probe["overlap"], 16)
		Probe["file"] := FileOpen(Path, "r")
		Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
			"UInt", 3, "UInt", 0, "UInt", 1, "UInt", 0, "Ptr", Probe["overlap"], "Int")
		AssertTrue(Probe["locked"])
		AssertThrows(() => _KL_ReadRecoveryText(Path, 0, TailBytes),
			"a refused native read must not become an empty recovery source")
		if !TailBytes
			AssertThrows(() => _KL_RecoverJournalEventId(Path, 0),
				"journal identity recovery must propagate native read refusal")
		_KLRCC_ReleaseLock(Probe)
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		AssertEqual(TailBytes ? SubStr(Source, -TailBytes) : Source,
			_KL_ReadRecoveryText(Path, 0, TailBytes))
		; An exclusive reopen proves that the failed reader did not leak a handle.
		Exclusive := FileOpen(Path, "r-rwd")
		Exclusive.Close()
	} finally {
		_KLRCC_ReleaseLock(Probe)
		if FileExist(Path)
			FileDelete(Path)
	}
}
for TailBytes in [0, 8]
	Test("keylogger event id: refused recovery read tail=" . TailBytes . " (event-id-read-refusal)",
		_KLEI_RecoveryReadRefusal.Bind(TailBytes))

_KLEI_RecoveryAfterNul() {
	Path := _FSWL_Path()
	Fh := 0
	try {
		Bytes := Buffer(2, 0)
		NumPut("UChar", 10, Bytes, 1)
		Fh := FileOpen(Path, "w")
		AssertEqual(2, Fh.RawWrite(Bytes))
		Fh.Close()
		Fh := 0
		FileAppend('{"type":"typing","_event_id":204}' . "`n", Path, "UTF-8-RAW")
		AssertEqual(204, _KL_RecoverJournalEventId(Path, 0),
			"an invalid NUL record must not hide the next durable event identity")
	} finally {
		if IsObject(Fh)
			Fh.Close()
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger event id: journal recovery sees valid rows after NUL (event-id-nul-recovery)",
	_KLEI_RecoveryAfterNul)

_KLEI_SqlRecoveryAfterNul() {
	Path := _FSWL_Path()
	Fh := 0
	try {
		Fh := FileOpen(Path, "w")
		AssertEqual(4, Fh.RawWrite(Buffer(4, 0)))
		Fh.Close()
		Fh := 0
		FileAppend("INSERT INTO events_typing VALUES ('device-a', 204, 'synthetic');`n", Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		Text := _KL_ReadRecoveryText(Path, 0, KeylogConst.DATA_SQL_SCAN_TAIL_BYTES)
		AssertEqual(204, KL_ScanMaxEventId(Text, "'device-a'"),
			"a NUL hole must not hide the next durable SQL identity")
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
	} finally {
		if IsObject(Fh)
			Fh.Close()
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger event id: SQL recovery sees valid rows after NUL holes (event-id-sql-nul)",
	_KLEI_SqlRecoveryAfterNul)

_KLEI_RecoveryEmptyBoundaries(Mode) {
	Path := _FSWL_Path()
	try {
		if Mode = "empty"
			FileAppend("", Path, "UTF-8-RAW")
		else if Mode = "bom"
			FileAppend(Chr(0xFEFF), Path, "UTF-8-RAW")
		else if Mode = "eof"
			FileAppend("synthetic", Path, "UTF-8-RAW")
		Offset := Mode = "eof" ? FileGetSize(Path) : 0
		AssertEqual("", _KL_ReadRecoveryText(Path, Offset),
			"an empty recovery range is valid: " . Mode)
		if Mode != "eof"
			AssertEqual("", _KL_ReadRecoveryText(Path, 0, KeylogConst.DATA_SQL_SCAN_TAIL_BYTES))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
for Mode in ["missing", "empty", "bom", "eof"]
	Test("keylogger event id: empty recovery boundary " . Mode . " (event-id-empty-boundary)",
		_KLEI_RecoveryEmptyBoundaries.Bind(Mode))

_KLEI_RecoveryAcrossBatches() {
	Path := _FSWL_Path()
	try {
		AssertEqual(0, _KL_RecoverJournalEventId(Path, 0))
		First := '{"type":"typing","_event_id":204}' . "`n"
		Blank := ""
		loop KeylogConst.INGEST_BATCH_LINES
			Blank .= "`n"
		FileAppend(First . Blank . '{"type":"typing","_event_id":203}' . "`n"
			. '{"type":"typing","_event_id":999', Path, "UTF-8")
		Before := KLR_LedgerSnapshot(Path)
		AssertEqual(204, _KL_RecoverJournalEventId(Path, 0),
			"recovery must cross empty batches and retain earlier higher IDs")
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		FileAppend('}' . "`n", Path, "UTF-8-RAW")
		AssertEqual(999, _KL_RecoverJournalEventId(Path, 0),
			"completed tail must become visible without losing earlier records")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger event id: journal recovery crosses batches and retains incomplete tail (event-id-journal-batches)",
	_KLEI_RecoveryAcrossBatches)





; ========================================
; ========================================
; ======= 2/ Monotonic start value =======
; ========================================
; ========================================

_KLEI_AdvancesStalePersistedState() {
	AssertEqual(KL_ResolveStartId(100, 203), 204,
		"stale state must advance beyond the highest durable identifier")
	AssertEqual(KL_ResolveStartId(300, 203), 300,
		"state already ahead of the ledger must remain authoritative")
}
Test("keylogger event id: stale state advances monotonically (event-id-tail-anchor)",
	_KLEI_AdvancesStalePersistedState)


_KLEI_JournalTailAdvancesPastUncommittedIds() {
	journal := '{"type":"shortcut","_event_id":204}`n'
		. '{"type":"system_event","message":"escaped \\"_event_id\\":999","_event_id":203}`n'
	AssertEqual(204, KL_ScanMaxJournalEventId(journal),
		"restart must reserve ids beyond every uncommitted durable JSONL record")
	AssertEqual(205, KL_ResolveStartId(100, KL_ScanMaxJournalEventId(journal)),
		"a stale state counter must advance past the durable journal tail")
}
Test("keylogger event id: uncommitted journal tail advances allocator (journal-stable-event-id)",
	_KLEI_JournalTailAdvancesPastUncommittedIds)
