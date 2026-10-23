; tests/unit/modules/keystats/reader/test_klr_trusted_frames.ahk

; ==============================================================================
; MODULE: Trusted Reader Frame Tests
; DESCRIPTION: Captured SQL text cannot forge ledger replay boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0

; Build through the real capture serializer, including apostrophe escaping and
; hotstring-unit metadata. A multiline SQL hotstring is legitimate stored data.
_KLRFI_Batch(Payload, Id := 1) {
	SavedDevice := Keystats.device_id
	SavedLiteral := Keystats._device_id_lit
	try {
		Keystats.device_id := "dev-one"
		Keystats._device_id_lit := KL_SqlStr(Keystats.device_id)
		Entry := Map("timestamp", "2026-03-04 11:00:00.000", "app", "fixture.exe",
			"trigger", "fixture", "replacement", Payload, "net_saved_chars", StrLen(Payload) - 7)
		return KLRRebuildConst.BATCH_MARKER . "2026-03-04 11:00:00.000 (offset 0 -> 0, 1 entry(ies)) ===`n"
			. "BEGIN TRANSACTION;`n" . KL_BuildInsertHotstring(Entry, Id, "fired") . "`nCOMMIT;`n"
	} finally {
		Keystats.device_id := SavedDevice
		Keystats._device_id_lit := SavedLiteral
	}
}

_KLRFI_Payload(Kind) {
	Prefix := ""
	loop 257
		Prefix .= "é漢😀'"
	FakeHeader := KLRRebuildConst.BATCH_MARKER . "2026-03-04 11:00:05.000 (offset 0 -> 0, 1 entry(ies)) ===`n"
	if Kind == "valid-suffix"
		; Starting at this fake header is syntactically valid SQL: -- hides
		; the actual closing quote, and the real COMMIT closes the fake BEGIN.
		return Prefix . FakeHeader . "BEGIN TRANSACTION;`nSELECT 1;`n-- swallowed closing quote "
	return Prefix . "`nCOMMIT;`n" . FakeHeader
		. "CREATE TRIGGER quoted BEGIN SELECT 'doubled'; END;`n/* -- odd ' " . Chr(34) . " */`ntrailing é😀"
}

_KLRFI_CapturedMarkers(Kind, ChunkBytes) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Payload := _KLRFI_Payload(Kind)
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger() . _KLRFI_Batch(Payload))
		Reference := _KLRNF_Build(false)
		Rows := SQLite_Query(Reference, "SELECT replacement FROM events_hotstring;")
		AssertEqual(1, Rows.Length, "the real writer fixture must be accepted by the one-pass oracle")
		AssertEqual(Payload, Rows[1]["replacement"], "the independent oracle must preserve the complete literal")
		Fingerprint := _KLRDC_DerivedFingerprint(Reference)
		Rebuilt := _KLRNF_Build(true, 0, 0, ChunkBytes)
		AssertTrue(Rebuilt != 0, "captured SQL sentinels must not reject a valid ledger")
		Rows := SQLite_Query(Rebuilt, "SELECT replacement FROM events_hotstring;")
		AssertEqual(1, Rows.Length, "even a parseable fake suffix must not silently skip the real captured row")
		AssertEqual(Payload, Rows[1]["replacement"], "UTF-8 splits and doubled quotes must remain exact")
		AssertEqual(Fingerprint, _KLRDC_DerivedFingerprint(Rebuilt), "framed and one-pass rollups must agree")
	} finally {
		_KLRDC_Cleanup()
	}
}
for _KLRFIKind in ["quoted-markers", "valid-suffix"]
	for _KLRFIChunk in [7, 31, 700, 4096]
		Test("KLR trusted framing: " . _KLRFIKind . " in " . _KLRFIChunk . " byte reads (klr-trusted-frame-capture)",
			_KLRDC_CheckTeardown.Bind(_KLRFI_CapturedMarkers.Bind(_KLRFIKind, _KLRFIChunk)))

; The last COMMIT-looking line in a torn literal is not a durable frontier.
; Completing the same append later must insert the captured row exactly once.
_KLRFI_TornLiteral(ChunkBytes, PartialUtf8 := false) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Base := _KLRNF_ThreeDayLedger()
		Payload := _KLRFI_Payload("quoted-markers") . "`nCOMMIT;`nnot closed é😀"
		Batch := _KLRFI_Batch(Payload)
		Cut := InStr(Batch, "not closed") + StrLen("not closed")
		if PartialUtf8 {
			Full := Base . Batch
			Size := StrPut(Full, "UTF-8") - 1
			Bytes := Buffer(Size + 1)
			StrPut(Full, Bytes, "UTF-8")
			CutBytes := StrPut(Base . SubStr(Batch, 1, Cut), "UTF-8")
			; Include only the first byte of é, inside the unfinished literal.
			File := FileOpen(_KLRDC_LedgerPath(), "w", "UTF-8-RAW")
			try File.RawWrite(Bytes, CutBytes)
			finally File.Close()
		} else
			_KLRDC_WriteLedger(Base . SubStr(Batch, 1, Cut))
		Rebuilt := _KLRNF_Build(true, 0, 0, ChunkBytes)
		AssertTrue(Rebuilt != 0, "a fake COMMIT in the torn literal cannot poison the last complete batch")
		AssertEqual(0, SQLite_Query(Rebuilt, "SELECT COUNT(*) AS n FROM events_hotstring;")[1]["n"])
		AssertEqual(StrPut(Base, "UTF-8") - 1, KLRCache.last_sizes[_KLRDC_LedgerPath()],
			"consumption must stop at the real COMMIT certified from BOF")
		if PartialUtf8 {
			File := FileOpen(_KLRDC_LedgerPath(), "a", "UTF-8-RAW")
			try File.RawWrite(Bytes.Ptr + CutBytes, Size - CutBytes)
			finally File.Close()
		} else
			_KLRDC_AppendLedger(SubStr(Batch, Cut + 1))
		Warm := _KLRDC_BuildAsWorker()
		Rows := SQLite_Query(Warm, "SELECT replacement FROM events_hotstring;")
		AssertEqual(1, Rows.Length, "the now-complete tail must be consumed exactly once")
		AssertEqual(Payload, Rows[1]["replacement"])
		AssertEqual(FileGetSize(_KLRDC_LedgerPath()), KLRCache.last_sizes[_KLRDC_LedgerPath()])
	} finally {
		_KLRDC_Cleanup()
	}
}
for _KLRFITornChunk in [7, 700]
	Test("KLR trusted framing: torn literal in " . _KLRFITornChunk . " byte reads (klr-trusted-frame-tail)",
		_KLRDC_CheckTeardown.Bind(_KLRFI_TornLiteral.Bind(_KLRFITornChunk)))

Test("KLR trusted framing: EOF splits a captured UTF-8 character (klr-trusted-frame-tail)",
	_KLRDC_CheckTeardown.Bind(_KLRFI_TornLiteral.Bind(31, true)))

; These are SQLite's own quote/comment states, observed only after full lines.
; Odd quote characters in comments and doubled string delimiters are adversaries
; to a parity counter, while CREATE TRIGGER tokens inside a literal are data.
_KLRFI_NativeState(Text, Before, After) {
	SQLite_EnsureModule()
	Index := Map("lexical", Before, "probe_calls", 0, "probe_bytes", 0)
	Bytes := _KLR_RebuildFrameState(Text, Index)
	AssertEqual(StrPut(Text, "UTF-8") - 1, Bytes, "native state prefixes cannot leak into source byte offsets")
	AssertEqual(After, Index["lexical"], "SQLite must own the lexical decision")
	AssertTrue(Index["probe_calls"] >= 1 && Index["probe_calls"] <= 6, "native scans must stay bounded per segment")
}
_KLRFIStates := [
	["SELECT 'é😀`n", 1, 2],
	["doubled '' and CREATE TRIGGER t BEGIN`n", 2, 2],
	["closing'; -- odd quote '`n", 2, 1],
	['SELECT "quoted`n', 1, 3],
	["SELECT " . Chr(96) . "quoted`n", 1, 4],
	["SELECT [quoted`n", 1, 5],
	["SELECT /* odd quote '`n", 1, 6],
	["comment -- ' */ SELECT 1;`n", 6, 1],
	["-- odd quote ' and /* ignored`n", 1, 1]]
for _KLRFIStateNo, _KLRFIStateCase in _KLRFIStates
	Test("KLR trusted framing: native lexical state " . _KLRFIStateNo . " (klr-trusted-frame-lexer)",
		_KLRFI_NativeState.Bind(_KLRFIStateCase[1], _KLRFIStateCase[2], _KLRFIStateCase[3]))

; Resume offsets can fall inside an indexed frame. Its first header is eligible
; only when strictly before the cursor; replay must not execute it twice.
_KLRFI_ResumeFrame(ChunkBytes) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Payload := "é😀" . KLRRebuildConst.BATCH_MARKER . "2026-03-04 12:00:00.000 ===`nBEGIN;`n-- closing quote "
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger() . _KLRFI_Batch(Payload))
		Reference := _KLRDC_DerivedFingerprint(_KLRNF_Build(false))
		AssertEqual(0, _KLRNF_Build(true, 0, 3, ChunkBytes))
		AssertTrue(FSExists(KLR_RebuildCheckpointPath(_KLRDC_Root())), "the interrupted owner must leave a real checkpoint")
		First := 0
		Observe(Info) {
			if !IsObject(First)
				First := Info.Clone()
		}
		Rebuilt := _KLRNF_Build(true, Observe, 0, ChunkBytes)
		AssertTrue(IsObject(First) && First["done_bytes"] > First["run_bytes"], "the checkpoint must actually be adopted")
		AssertEqual(Reference, _KLRDC_DerivedFingerprint(Rebuilt))
		Rows := SQLite_Query(Rebuilt, "SELECT replacement FROM events_hotstring;")
		AssertEqual(1, Rows.Length)
		AssertEqual(Payload, Rows[1]["replacement"])
	} finally {
		_KLRDC_Cleanup()
	}
}
for _KLRFIResumeChunk in [700, 1400]
	Test("KLR trusted framing: checkpoint in " . _KLRFIResumeChunk . " byte frames (klr-trusted-frame-resume)",
		_KLRDC_CheckTeardown.Bind(_KLRFI_ResumeFrame.Bind(_KLRFIResumeChunk)))

; A real index uses the same immutable source receipt owner as replay. Mutating
; after its final read specifically exercises the final receipt check.
_KLRFI_IndexSource(Change) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.chunk_bytes, KLRRebuild.index_observer]
	Db := 0
	try {
		Source := _KLRNF_ThreeDayLedger()
		_KLRDC_WriteLedger(Source)
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		State := _KLR_RebuildNewState(Db, [_KLRDC_LedgerPath()])
		Ledger := State["ledgers"][1]
		KLRRebuild.chunk_bytes := 700
		Observed := []
		Observe(Info) {
			AssertFalse(Info.Has("db"), "index progress never publishes an unrolled database")
			Observed.Push(Info.Clone())
			if Info["indexed_bytes"] != Info["index_total_bytes"]
				return
			if Change == "append"
				_KLRDC_AppendLedger(_KLRDC_TypingBatch(8, "2026-03-04 12:00:00.000", "2026-03-04", "four.exe", ["z"]))
			else if Change == "replace"
				_KLRDC_WriteLedger(Source)
			else if Change == "shrink" {
				File := FileOpen(_KLRDC_LedgerPath(), "rw")
				try File.Length := 1
				finally File.Close()
			} else {
				File := FileOpen(_KLRDC_LedgerPath(), "rw")
				try File.RawWrite(Buffer(1, 0x20))
				finally File.Close()
				; Guarantee a different durable receipt without relying on clock
				; granularity or sleeping in the test process.
				FileSetTime("20260101000000", _KLRDC_LedgerPath(), "M")
			}
		}
		KLRRebuild.index_observer := Observe
		Rejected := false
		try _KLR_RebuildIndex(State, Ledger)
		catch KLRRebuildRefusal
			Rejected := true
		AssertTrue(Observed.Length > 1, "the real fixture must exercise several paced reads")
		AssertEqual(Change != "append", Rejected, "source mutation must refuse the index while append preserves its pinned prefix")
		if Change == "append" {
			Bytes := StrPut(Source, "UTF-8") - 1
			AssertEqual(Bytes, Ledger["end"], "a concurrent append must remain outside the planned source image")
			AssertTrue(FileGetSize(_KLRDC_LedgerPath()) > Ledger["end"])
			Last := Observed[Observed.Length]
			AssertEqual(Bytes, Last["indexed_bytes"], "forward reads consume each planned byte exactly once")
			AssertTrue(Last["frame_count"] <= Ceil(Bytes / 700), "frame memory is bounded by read chunks")
		} else
			AssertFalse(Ledger.Has("frames"), "a rejected index cannot publish trusted frames")
	} finally {
		if Db
			SQLite_Close(Db)
		KLRRebuild.chunk_bytes := Saved[1]
		KLRRebuild.index_observer := Saved[2]
		_KLRDC_Cleanup()
	}
}
for _KLRFIChange in ["append", "replace", "shrink", "rewrite"]
	Test("KLR trusted framing: pinned source " . _KLRFIChange . " (klr-trusted-frame-source)",
		_KLRDC_CheckTeardown.Bind(_KLRFI_IndexSource.Bind(_KLRFIChange)))

; Native SQL accepts these comments; their unbalanced quote characters and
; embedded fake sentinels must not turn captured/comment bytes into frames.
_KLRFI_CommentBoundaries() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Comment := "`n/* comment with odd apostrophe '`n"
			. KLRRebuildConst.BATCH_MARKER . "2026-03-09 01:00:00.000 ===`nCOMMIT;`n"
			. "still comment */`n-- quote ' and /* are line-comment data`n"
		Source := _KLRNF_ThreeDayLedger() . Comment
			. _KLRDC_TypingBatch(9, "2026-03-04 09:00:00.000", "2026-03-04", "four.exe", ["z"])
		_KLRDC_WriteLedger(Source)
		Reference := _KLRDC_DerivedFingerprint(_KLRNF_Build(false))
		Rebuilt := _KLRNF_Build(true, 0, 0, 31)
		AssertTrue(Rebuilt != 0, "native comments remain valid across tiny indexing reads")
		AssertEqual(Reference, _KLRDC_DerivedFingerprint(Rebuilt))
		AssertEqual("2026-03-01,2026-03-02,2026-03-03,2026-03-04", _KLRNF_Days(Rebuilt),
			"a comment-shaped date must never become a completeness frontier")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR trusted framing: comments cannot forge a boundary (klr-trusted-frame-comments)",
	_KLRDC_CheckTeardown.Bind(_KLRFI_CommentBoundaries))

; Measure the real AHK/native path without a brittle wall-clock limit. A 32 MiB
; ledger must use one read per byte, O(chunks) frames and bounded native probes.
; The numeric diagnostic lets Windows qualification record its actual cost.
_KLRFI_IndexCost() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.chunk_bytes, KLRRebuild.index_observer]
	Db := 0
	try {
		Payload := ""
		loop 280
			Payload .= "quoted '' é😀 "
		Block := _KLRFI_Batch(Payload)
		Path := _KLRDC_LedgerPath()
		File := FileOpen(Path, "w", "UTF-8-RAW")
		AssertTrue(IsObject(File))
		try {
			File.Write(_KLRDC_Header())
			while File.Pos < KLRRebuildConst.MIN_LEDGER_BYTES
				File.Write(Block)
		} finally File.Close()
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		State := _KLR_RebuildNewState(Db, [Path])
		Ledger := State["ledgers"][1]
		KLRRebuild.chunk_bytes := KLRRebuildConst.CHUNK_BYTES
		Last := 0
		Observe(Info) {
			Last := Info.Clone()
		}
		KLRRebuild.index_observer := Observe
		Started := A_TickCount
		_KLR_RebuildIndex(State, Ledger)
		Elapsed := TickElapsed64(Started, A_TickCount)
		AssertTrue(IsObject(Last))
		Bytes := FileGetSize(Path)
		AssertEqual(Bytes, Last["indexed_bytes"], "indexing cannot reread partial lines or inflate work")
		AssertEqual(Bytes, Ledger["end"], "the last real COMMIT remains exact")
		AssertTrue(Last["frame_count"] <= Ceil(Bytes / KLRRebuildConst.CHUNK_BYTES), "index memory stays O(chunks)")
		AssertTrue(Last["probe_bytes"] <= 6 * Bytes + Last["probe_calls"] * 4,
			"native lexer work must stay linear even with many quoted rows")
		_TestAppendProgress("# trusted-frame-index bytes=" . Bytes . " elapsed_ms=" . Elapsed
			. " frames=" . Last["frame_count"] . " native_probe_bytes=" . Last["probe_bytes"])
	} finally {
		if Db
			SQLite_Close(Db)
		KLRRebuild.chunk_bytes := Saved[1]
		KLRRebuild.index_observer := Saved[2]
		_KLRDC_Cleanup()
	}
}
Test("KLR trusted framing: native forward index has bounded cost (klr-trusted-frame-cost)",
	_KLRDC_CheckTeardown.Bind(_KLRFI_IndexCost))

; Carry memory excludes the next read chunk: a near-bound line may close at
; its first LF. The bound applies to the incomplete suffix left after it.
_KLRFI_CarryBound(Closes) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.chunk_bytes, KLRRebuildConst.MAX_FRAME_BYTES]
	Db := 0
	try {
		Line := "--"
		loop Closes ? 16 : 64
			Line .= "A"
		Source := Line . "`nCOMMIT;`n"
		_KLRDC_WriteLedger(Source)
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		State := _KLR_RebuildNewState(Db, [_KLRDC_LedgerPath()])
		Ledger := State["ledgers"][1]
		KLRRebuild.chunk_bytes := 16
		KLRRebuildConst.MAX_FRAME_BYTES := 20
		Rejected := false
		try _KLR_RebuildIndex(State, Ledger)
		catch KLRRebuildRefusal
			Rejected := true
		AssertEqual(!Closes, Rejected, "only the remaining incomplete physical line consumes the carry bound")
		if Closes
			AssertEqual(StrPut(Source, "UTF-8") - 1, Ledger["end"], "the closing LF cannot cause a false refusal")
		else
			AssertFalse(Ledger.Has("frames"), "over-bound input cannot publish a partial trusted index")
	} finally {
		if Db
			SQLite_Close(Db)
		KLRRebuild.chunk_bytes := Saved[1]
		KLRRebuildConst.MAX_FRAME_BYTES := Saved[2]
		_KLRDC_Cleanup()
	}
}
for _KLRFICloses in [false, true]
	Test("KLR trusted framing: carry closes=" . _KLRFICloses . " (klr-trusted-frame-bound)",
		_KLRDC_CheckTeardown.Bind(_KLRFI_CarryBound.Bind(_KLRFICloses)))

; Format 14 could persist a successfully parsed fake suffix with missing raw
; rows. Unchanged ledgers and matching old seeds cannot authorize its reuse.
_KLRFI_LegacyProjection() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Payload := "complete capture é😀"
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRFI_Batch(Payload))
		_KLRDC_BuildAsWorker()
		Root := _KLRDC_Root()
		Seed := KLPF_CaptureHistorySeed(Root, "2026-03-04")
		AssertTrue(KLPF_HistorySeedAllowsDelta(Seed, Seed), "current format remains a positive seed control")
		Legacy := Seed.Clone()
		Legacy["projection_format"] := "14"
		AssertFalse(KLPF_HistorySeedAllowsDelta(Legacy, Seed), "an old delivered projection requires complete history")
		AssertFalse(KLPF_HistorySeedAllowsDelta(Legacy, Legacy), "two matching legacy receipts still cannot prove the corrected semantics")
		KLR_ResetCache()
		KLRCache.disposable := true
		Path := KLR_CachePath(Root)
		AssertEqual(1, KLR_CacheAttach(Root, ""), "a current durable image must remain attachable")
		KLR_ResetCache()
		Stored := SQLite_Open(Path)
		AssertTrue(Stored != 0)
		try AssertTrue(SQLite_Exec(Stored, "UPDATE klr_cache_meta SET value='14' WHERE key='format_version';"
			. "DELETE FROM events_hotstring;"))
		finally SQLite_Close(Stored)
		KLRCache.disposable := true
		AssertEqual(0, KLR_CacheAttach(Root, ""), "a format-14 image must be rejected before its missing rows are trusted")
		AssertFalse(FSExists(Path), "the owned legacy cache must be retired through normal rejection")
		Rebuilt := _KLRDC_BuildAsWorker()
		Rows := SQLite_Query(Rebuilt, "SELECT replacement FROM events_hotstring;")
		AssertEqual(1, Rows.Length, "the authoritative ledger restores the missing captured row")
		AssertEqual(Payload, Rows[1]["replacement"])
	} finally _KLRDC_Cleanup()
}
Test("KLR trusted framing: legacy cache and seeds require rebuild (klr-trusted-frame-format)",
	_KLRDC_CheckTeardown.Bind(_KLRFI_LegacyProjection))

; The worker publishes an alive heartbeat while indexing, never an unrolled
; partial snapshot or a throughput estimate made from unreplayed bytes.
_KLRFI_IndexHeartbeat() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLRRebuild.chunk_bytes, KLRRebuild.index_observer]
	Db := 0
	Root := _KLRDC_Root()
	Publisher := KLPFRebuildPublisher(Root, () => 1000)
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger())
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		State := _KLR_RebuildNewState(Db, [_KLRDC_LedgerPath()])
		KLRRebuild.chunk_bytes := 700
		KLRRebuild.index_observer := Publisher
		_KLR_RebuildIndex(State, State["ledgers"][1])
		Path := KLPF_RebuildProgressPath(Root)
		AssertTrue(FSExists(Path), "indexing must keep the worker's progress document alive")
		Progress := JsonParse(FileRead(Path, "UTF-8"))
		AssertEqual("running", Progress["state"])
		AssertEqual(0, Progress["percent"], "indexed source bytes are not replayed metric bytes")
		AssertEqual(-1, Progress["eta_s"], "index throughput cannot predict replay work")
		for Which in ["typing", "apps"]
			AssertFalse(FSExists(KLPF_PartialSnapshotPath(Which, Root)), "indexing must not publish unrolled rows")
		AssertTrue(Publisher.Retire())
		AssertFalse(FSExists(Path), "the heartbeat is retired by its owning publisher")
	} finally {
		if Db
			SQLite_Close(Db)
		KLRRebuild.chunk_bytes := Saved[1]
		KLRRebuild.index_observer := Saved[2]
		for Which in ["typing", "apps"]
			try FileDelete(KLPF_PartialSnapshotPath(Which, Root))
		try FileDelete(KLPF_RebuildProgressPath(Root))
		_KLRDC_Cleanup()
	}
}
Test("KLR trusted framing: worker heartbeat during indexing (klr-trusted-frame-progress)",
	_KLRDC_CheckTeardown.Bind(_KLRFI_IndexHeartbeat))
