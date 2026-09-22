; modules/keylogger/keylogger_reader_rebuild.ahk

; ==============================================================================
; MODULE: Keylogger Reader — Newest-first cold rebuild
; DESCRIPTION:
; Rebuilds a large reader image from its ledgers newest day first, so the
; dashboard can show exact statistics for the most recent days within seconds
; and refine them while older history is still being replayed.
;
; WHY IT EXISTS:
; The one-pass cold build loads the whole data.sql, then projects, aggregates
; and replays everything before anything can be shown. On a 1 GB store that is
; more than 40 minutes of blank dashboard, and a worker killed on the way (a
; driver reload) restarts from zero.
;
; HOW IT STAYS EXACT:
; 1. Ledgers are append-only batches, each one an « ingest batch » header, a
;    transaction and its COMMIT. Reading them backward from a batch boundary
;    executes whole transactions only.
; 2. Every row is keyed by (device_id, id) and inserted with OR IGNORE, so the
;    FIRST copy in file order wins. A temporary trigger keeps that rule while
;    executing backward: an earlier copy replaces the later one and records the
;    displaced row's day, whose rollups are then recomputed.
; 3. An event cannot be ingested before it happened, so once every batch
;    ingested on day D or later has been executed, every day after D is
;    complete. Completed days are rolled up with the same date-scoped rollups
;    and walker replay a warm refresh uses; a day seen again later (clock skew,
;    late import) is simply recomputed.
; 4. The rebuilt image carries warm-refresh semantics: walker n-gram chains do
;    not cross the boundary between two rollup rounds, exactly as they do not
;    cross a refreshed day (klr-reader-durable-cache).
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLRRebuildConst {
	; One backward read. Large enough that per-read overhead is negligible,
	; small enough that the newest day is on screen after a few reads.
	static CHUNK_BYTES := 4 * 1024 * 1024
	; A carry is the unexecuted prefix before the first batch header of a read.
	; A header-less compacted transaction can make it large; beyond this the
	; ledger is not in batch form and the one-pass build owns it.
	static MAX_CARRY_CHARS := 64 * 1024 * 1024
	; Below this the one-pass build finishes in seconds and stays the reference.
	static MIN_LEDGER_BYTES := 32 * 1024 * 1024
	; Rollup rounds after the first one are batched: each round rescans the
	; date-scoped sources, so rolling up after every read would dominate.
	static ROUND_INTERVAL_MS := 15000
	static BATCH_MARKER := "`n-- === ingest batch "
	; Days sort as text; this sentinel sorts after every real day.
	static NO_DAY_COMPLETE := "9999-99-99"
	; Sources whose rows feed a date-scoped rollup or the walker replay.
	static DATED_SOURCES := ["events_typing", "events_app_switch", "events_window_switch",
		"events_shortcut", "events_system", "events_hotstring", "events_llm"]
}

; Deterministic seams. Production keeps the constants above and no observer.
class KLRRebuild {
	static min_ledger_bytes := KLRRebuildConst.MIN_LEDGER_BYTES
	static chunk_bytes := KLRRebuildConst.CHUNK_BYTES
	static round_interval_ms := KLRRebuildConst.ROUND_INTERVAL_MS
	; Called after each rollup round with a progress Map; see _KLR_RebuildNotify.
	static observer := 0
}

class KLRRebuildRefusal extends Error {
}





; ==============================
; ==============================
; ======= 2/ Eligibility =======
; ==============================
; ==============================

; Only a disposable worker rebuilds newest-first: it alone publishes the image,
; and its partial rounds are observable only through the explicit observer.
; @param LedgerPaths {Array} Ledgers the rebuild would consume.
; @returns {Boolean} Whether the newest-first rebuild owns this cold build.
KLR_RebuildIsSegmented(LedgerPaths) {
	if !KLRCache.disposable || !LedgerPaths.Length
		return false
	Total := 0
	; A size that cannot be read leaves the decision to the one-pass build,
	; which owns and reports every ledger access failure.
	try {
		for Path in LedgerPaths
			Total += FileGetSize(Path)
	} catch
		return false
	return Total >= KLRRebuild.min_ledger_bytes
}

; Cold build entry for KLR_BuildDatabase: newest-first for a large store in a
; worker, the one-pass reference build otherwise.
; @param md {String} Metrics directory, trailing separator included.
; @param logPath {String} Diagnostic sink shared with the rest of the reader.
; @returns {Map} ok, db, sizes, snapshots.
KLR_BuildColdCandidateAuto(md, logPath) {
	try LedgerPaths := KLR_ListLedgerPaths(md)
	catch Error
		return KLR_BuildColdCandidate(md, logPath)
	if KLR_RebuildIsSegmented(LedgerPaths)
		return KLR_BuildColdSegmented(md, logPath, LedgerPaths)
	return KLR_BuildColdCandidate(md, logPath)
}





; ==========================================
; ==========================================
; ======= 3/ Newest-first cold build =======
; ==========================================
; ==========================================

; Materialise a cold candidate newest day first. Same contract as
; KLR_BuildColdCandidate: nothing touches KLRCache until the caller publishes.
; @param md {String} Metrics directory, trailing separator included.
; @param logPath {String} Diagnostic sink shared with the rest of the reader.
; @param LedgerPaths {Array} Every ledger of the store.
; @returns {Map} ok, db, sizes, snapshots.
KLR_BuildColdSegmented(md, logPath, LedgerPaths) {
	Failed := Map("ok", false, "db", 0, "sizes", Map())
	StartTick := A_TickCount
	db := SQLite_Open(":memory:")
	if !db {
		try LoggerError("KLReader", "Newest-first metrics rebuild could not open its memory database.")
		return Failed
	}
	Owned := true
	try {
		State := _KLR_RebuildNewState(db, LedgerPaths)
		if !KLR_LoadSchema(db)
			throw KLRRebuildRefusal("schema.sql missing or invalid")
		if !KLR_EnsureTypingProjectionTable(db) || !_KLR_RebuildInstallFirstWins(db)
			throw KLRRebuildRefusal("temporary rebuild storage could not be prepared")
		try LoggerStart("KLReader", "Newest-first metrics rebuild of {1} byte(s) in {2} ledger(s).",
			State["total_bytes"], LedgerPaths.Length)
		LastRound := 0
		loop {
			Ledger := _KLR_RebuildNextLedger(State)
			if !IsObject(Ledger)
				break
			_KLR_RebuildStep(State, Ledger)
			if !LastRound || (A_TickCount - LastRound) >= KLRRebuild.round_interval_ms {
				_KLR_RebuildRound(State, false)
				LastRound := A_TickCount
			}
		}
		_KLR_RebuildRound(State, true)
		if !SQLite_Exec(db, _KLR_RebuildDropFirstWinsSql(db))
			throw KLRRebuildRefusal("temporary first-wins triggers could not be removed")
		Sizes := Map()
		Snapshots := Map()
		for Ledger in State["ledgers"] {
			Sizes[Ledger["path"]] := Ledger["end"]
			Snapshots[Ledger["path"]] := Ledger["snapshot"]
		}
		KLW_ResetBatch()
		KLR_PrefetchDebug(logPath, "KLR newest-first rebuild in " . (A_TickCount - StartTick) . "ms")
		try LoggerSuccess("KLReader", "Newest-first metrics rebuild finished in {1} ms.", A_TickCount - StartTick)
		Owned := false
		return Map("ok", true, "db", db, "sizes", Sizes, "snapshots", Snapshots)
	} catch Error as Failure {
		; SQLite and file errors carry no typed text; refusals name their step.
		try LoggerError("KLReader", "Newest-first metrics rebuild failed: {1}. Dashboard retains its last-good data.",
			Failure is KLRRebuildRefusal ? Failure.Message : Type(Failure))
		return Failed
	} finally {
		if Owned
			try SQLite_Close(db)
	}
}

_KLR_RebuildNewState(db, LedgerPaths) {
	Ledgers := []
	Total := 0
	for Path in LedgerPaths {
		Snapshot := KLR_LedgerSnapshot(Path)
		if !Snapshot.Get("ok", false)
			throw KLRRebuildRefusal("a ledger identity could not be observed")
		Ledgers.Push(Map("path", Path, "snapshot", Snapshot, "end", Snapshot["size"],
			"cursor", Snapshot["size"], "carry", "", "trimmed", false,
			"frontier", KLRRebuildConst.NO_DAY_COMPLETE, "finished", Snapshot["size"] = 0))
		Total += Snapshot["size"]
	}
	return Map("db", db, "ledgers", Ledgers, "total_bytes", Total, "run_start", A_TickCount,
		"resumed_bytes", 0, "done_boundary", KLRRebuildConst.NO_DAY_COMPLETE,
		"oldest_complete", "", "newest_complete", "", "dirty", Map(), "nul_bytes", 0, "rounds", 0)
}

; The unfinished ledger whose frontier is newest decides which days complete,
; so it is always the one advanced next. Several devices then complete together.
_KLR_RebuildNextLedger(State) {
	Best := 0
	for Ledger in State["ledgers"] {
		if Ledger["finished"]
			continue
		if !IsObject(Best) || StrCompare(Ledger["frontier"], Best["frontier"]) > 0
			Best := Ledger
	}
	return Best
}

; Days strictly after this boundary are complete in every ledger.
_KLR_RebuildBoundary(State) {
	Boundary := ""
	for Ledger in State["ledgers"] {
		if !Ledger["finished"] && StrCompare(Ledger["frontier"], Boundary) > 0
			Boundary := Ledger["frontier"]
	}
	return Boundary
}

_KLR_RebuildTotalBytes(State) {
	Total := 0
	for Ledger in State["ledgers"]
		Total += Ledger["end"]
	return Total
}

_KLR_RebuildDoneBytes(State) {
	Done := 0
	for Ledger in State["ledgers"]
		Done += Ledger["end"] - Ledger["cursor"]
	return Done
}





; ====================================
; ====================================
; ======= 4/ One backward read =======
; ====================================
; ====================================

; Read the bytes just before the ledger cursor and execute every complete batch
; they contain. The prefix before the first batch header is carried to the next
; (older) read, so only whole transactions ever reach SQLite.
_KLR_RebuildStep(State, Ledger) {
	Cursor := Ledger["cursor"]
	Start := Max(0, Cursor - KLRRebuild.chunk_bytes)
	Count := Cursor - Start
	Buf := _KLR_RebuildReadBytes(Ledger, Start, Count)
	Skip := 0
	; A read that starts inside a multi-byte character begins at the next one;
	; the skipped bytes belong to the following read.
	if Start > 0 {
		while Skip < Count && (NumGet(Buf, Skip, "UChar") & 0xC0) = 0x80
			Skip += 1
	}
	State["nul_bytes"] += _KLR_RebuildBlankNuls(Buf, Skip, Count - Skip)
	Text := Count - Skip > 0 ? StrGet(Buf.Ptr + Skip, Count - Skip, "UTF-8") : ""
	Combined := Text . Ledger["carry"]
	NewCursor := Start + Skip
	if !Ledger["trimmed"] {
		Last := InStr(Combined, "`nCOMMIT;`n", true, -1)
		if Last {
			Combined := SubStr(Combined, 1, Last + StrLen("`nCOMMIT;`n") - 1)
			Ledger["end"] := NewCursor + StrPut(Combined, "UTF-8") - 1
			Ledger["trimmed"] := true
		} else if NewCursor > 0 {
			; No complete batch yet: keep reading backward before executing.
			Ledger["carry"] := Combined
			Ledger["cursor"] := NewCursor
			return
		} else {
			Ledger["trimmed"] := true
		}
	}
	if NewCursor = 0 {
		Executable := Combined
		Carry := ""
	} else {
		Found := InStr(Combined, KLRRebuildConst.BATCH_MARKER, true)
		if !Found {
			if StrLen(Combined) > KLRRebuildConst.MAX_CARRY_CHARS
				throw KLRRebuildRefusal("a ledger holds no batch boundary within "
					. KLRRebuildConst.MAX_CARRY_CHARS . " characters")
			Ledger["carry"] := Combined
			Ledger["cursor"] := NewCursor
			return
		}
		Executable := SubStr(Combined, Found)
		Carry := SubStr(Combined, 1, Found - 1)
	}
	_KLR_RebuildExecute(State["db"], Executable)
	Ledger["cursor"] := NewCursor
	Ledger["carry"] := Carry
	if RegExMatch(Executable, "^\n-- === ingest batch (\d{4}-\d{2}-\d{2}) ", &Header)
			&& StrCompare(Header[1], Ledger["frontier"]) < 0
		Ledger["frontier"] := Header[1]
	if NewCursor = 0
		Ledger["finished"] := true
	; A day already rolled up that reappears in older bytes must be recomputed.
	for Day in KLR_CacheAffectedDates(Map(Ledger["path"], Map("sql", Executable)))
		if StrCompare(Day, State["done_boundary"]) > 0
			State["dirty"][Day] := true
}

_KLR_RebuildReadBytes(Ledger, Start, Count) {
	Buf := Buffer(Max(Count, 1), 0)
	try File := FileOpen(Ledger["path"], "r")
	catch as Err
		throw KLRRebuildRefusal("a ledger could not be opened (" . Err.Message . ")")
	try {
		; Every read must observe the file the rebuild started from, still
		; holding at least the bytes it planned to consume.
		Current := FSHandleSnapshot(File.Handle)
		Consumed := Ledger["snapshot"]
		if !KLR_LedgerFileIsSame(Current, Consumed) || Current["size"] < Ledger["end"]
				|| (Current["size"] = Consumed["size"] && !KLR_LedgerWriteTimeIsSame(Current, Consumed))
			throw KLRRebuildRefusal("a ledger was replaced or rewritten during the rebuild")
		File.Pos := Start
		if Count > 0 && File.RawRead(Buf, Count) != Count
			throw KLRRebuildRefusal("a ledger read stopped before its observed end")
	} finally File.Close()
	return Buf
}

; An interrupted append leaves NUL bytes between two complete transactions. The
; one-pass build skips them; blanking them keeps the same bytes as whitespace.
_KLR_RebuildBlankNuls(Buf, Offset, Count) {
	Blanked := 0
	Cursor := Buf.Ptr + Offset
	Stop := Cursor + Count
	while Cursor < Stop {
		Hit := DllCall("msvcrt\memchr", "Ptr", Cursor, "Int", 0, "UPtr", Stop - Cursor, "Cdecl Ptr")
		if !Hit
			break
		NumPut("UChar", 0x20, Hit)
		Blanked += 1
		Cursor := Hit + 1
	}
	return Blanked
}

_KLR_RebuildExecute(db, Sql) {
	Result := SQLite_ExecReturnCarry(db, Sql)
	if !Result.Get("ok", false)
		throw KLRRebuildRefusal("a ledger batch was rejected by SQLite")
	; A trailing comment-only remainder (a day-rollover marker) is complete.
	Rest := Result.Get("carry", "")
	if (Rest != "") && !SQLite_Exec(db, Rest)
		throw KLRRebuildRefusal("a ledger segment ended inside a statement")
	if !SQLite_IsAutocommit(db) {
		try SQLite_Exec(db, "ROLLBACK;")
		throw KLRRebuildRefusal("a ledger segment ended inside a transaction")
	}
}





; ============================================
; ============================================
; ======= 5/ First copy wins, backward =======
; ============================================
; ============================================

_KLR_RebuildFirstWinsTables(db) {
	Tables := []
	for Row in SQLite_Query(db, "SELECT name FROM main.sqlite_schema WHERE type='table' "
			. "AND (name LIKE 'events\_%' ESCAPE '\' OR name='meta') ORDER BY name;") {
		Keys := []
		HasDate := false
		for Column in SQLite_Query(db, "PRAGMA main.table_info(" . SQLite_Q(Row["name"]) . ");") {
			if Column["pk"] > 0
				Keys.Push(Column["name"])
			if Column["name"] = "date"
				HasDate := true
		}
		if Keys.Length
			Tables.Push(Map("name", Row["name"], "keys", Keys, "dated", HasDate))
	}
	return Tables
}

; Executing an older batch after a newer one would let OR IGNORE keep the newer
; copy of a reused key. Deleting the newer copy first restores file order, and
; the displaced day (or '*' when the table has no day) is marked for recompute.
_KLR_RebuildInstallFirstWins(db) {
	Sql := "CREATE TEMP TABLE IF NOT EXISTS klr_rebuild_displaced (date TEXT PRIMARY KEY) WITHOUT ROWID;"
	for Table in _KLR_RebuildFirstWinsTables(db) {
		Match := ""
		for Key in Table["keys"]
			Match .= (Match = "" ? "" : " AND ") . Key . "=NEW." . Key
		Name := Table["name"]
		Sql .= "CREATE TEMP TRIGGER klr_rebuild_first_wins_" . Name
			. " BEFORE INSERT ON main." . Name
			. " WHEN EXISTS (SELECT 1 FROM " . Name . " WHERE " . Match . ") BEGIN "
			. "INSERT OR IGNORE INTO klr_rebuild_displaced(date) SELECT "
			. (Table["dated"] ? "date" : "'*'") . " FROM " . Name . " WHERE " . Match . ";"
			. (Name = "events_typing"
				? "DELETE FROM klr_reader_typing_counts WHERE device_id=NEW.device_id AND event_id=NEW.id;" : "")
			. "DELETE FROM " . Name . " WHERE " . Match . "; END;"
	}
	return SQLite_Exec(db, Sql)
}

_KLR_RebuildDropFirstWinsSql(db) {
	Sql := ""
	for Row in SQLite_Query(db, "SELECT name FROM temp.sqlite_schema WHERE type='trigger' "
			. "AND name LIKE 'klr\_rebuild\_first\_wins\_%' ESCAPE '\';")
		Sql .= "DROP TRIGGER temp." . Row["name"] . ";"
	return Sql . "DROP TABLE IF EXISTS temp.klr_rebuild_displaced;"
}





; ================================
; ================================
; ======= 6/ Rollup rounds =======
; ================================
; ================================

; Roll up every day that became complete since the last round, plus every
; already rolled-up day that older bytes touched again.
_KLR_RebuildRound(State, Final) {
	db := State["db"]
	Previous := State["done_boundary"]
	Boundary := Final ? "" : _KLR_RebuildBoundary(State)
	Days := State["dirty"]
	State["dirty"] := Map()
	for Row in SQLite_Query(db, "SELECT date FROM temp.klr_rebuild_displaced;")
		Days[Row["date"]] := true
	if !SQLite_Exec(db, "DELETE FROM temp.klr_rebuild_displaced;")
		throw KLRRebuildRefusal("the displaced-day journal could not be cleared")
	if Days.Has("*") {
		Days.Delete("*")
		for Day in _KLR_RebuildDaysBetween(db, Previous, KLRRebuildConst.NO_DAY_COMPLETE)
			Days[Day] := true
	}
	if StrCompare(Boundary, Previous) < 0
		for Day in _KLR_RebuildDaysBetween(db, Boundary, Previous)
			Days[Day] := true
	Scope := []
	for Day in Days
		if StrCompare(Day, Boundary) > 0
			Scope.Push(Day)
		else
			State["dirty"][Day] := true
	State["done_boundary"] := Boundary
	if Scope.Length {
		_KLR_RebuildRollUp(db, Scope)
		for Day in Scope {
			if State["oldest_complete"] = "" || StrCompare(Day, State["oldest_complete"]) < 0
				State["oldest_complete"] := Day
			if StrCompare(Day, State["newest_complete"]) > 0
				State["newest_complete"] := Day
		}
	}
	State["rounds"] += 1
	_KLR_RebuildNotify(State, Final)
}

; Days with rolled-up sources in (Low, High].
_KLR_RebuildDaysBetween(db, Low, High) {
	Union := ""
	for Source in KLRRebuildConst.DATED_SOURCES
		Union .= (Union = "" ? "" : " UNION ") . "SELECT date FROM main." . Source
			. " WHERE date>" . SQLite_Q(Low) . " AND date<=" . SQLite_Q(High)
	Days := []
	for Row in SQLite_Query(db, "SELECT DISTINCT date FROM (" . Union . ") ORDER BY date;")
		Days.Push(Row["date"])
	return Days
}

; The same date-scoped steps a warm refresh runs, followed by releasing the
; decrypted payloads those days no longer need.
_KLR_RebuildRollUp(db, Days) {
	if !KLR_PrepareTypingProjection(db, Days, true)
		throw KLRRebuildRefusal("typing projection failed")
	if !KLR_ClearAggregates(db, Days) || !KLR_RebuildAggregates(db, Days)
		throw KLRRebuildRefusal("aggregate rollup failed")
	if KLR_RebuildWalkerAggregates(db, true, Days) < 0 {
		global KLRLastReplayFailure, KLRReplayDiagnosticFn
		if KLRLastReplayFailure.Count && HasMethod(KLRReplayDiagnosticFn, "Call")
			try KLRReplayDiagnosticFn.Call(KLRLastReplayFailure.Clone())
		throw KLRRebuildRefusal("walker replay failed")
	}
	if !SQLite_Exec(db, "DELETE FROM temp.klr_reader_typing_payload WHERE (device_id,event_id) IN "
			. "(SELECT device_id,id FROM main.events_typing WHERE 1=1" . _KLR_DateScope(Days, "date") . ");")
		throw KLRRebuildRefusal("replayed typing payloads could not be released")
}

; Report one round. The observer receives the private candidate handle for the
; duration of the call only; it may read it but never keep or publish it.
_KLR_RebuildNotify(State, Final) {
	if !HasMethod(KLRRebuild.observer, "Call")
		return
	Done := _KLR_RebuildDoneBytes(State)
	KLRRebuild.observer.Call(Map(
		"db", State["db"],
		"final", Final,
		"round", State["rounds"],
		"total_bytes", _KLR_RebuildTotalBytes(State),
		"done_bytes", Done,
		"run_bytes", Done - State["resumed_bytes"],
		"elapsed_ms", A_TickCount - State["run_start"],
		"oldest_complete", State["oldest_complete"],
		"newest_complete", State["newest_complete"]))
}
