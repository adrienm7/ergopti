; modules/keylogger/keylogger_ingest.ahk

; ==============================================================================
; MODULE: Keylogger Journal Ingestion
; DESCRIPTION:
; Converts durable journal batches into SQL and publishes the consumed offset.
; Definitions remain hook-free for native failure and retry integration tests.
; ==============================================================================

#Include keylogger_constants.ahk

KL_SaveState() {
    ngram_ctx := Map()
    try ngram_ctx := KLW_SerializeCtx()
    s := Map(
        "next_event_id",    Keylogger.next_event_id,
        "today_log_offset", Keylogger.today_log_offset,
        "today_log_date",   Keylogger.today_log_date,
        "ngram_ctx",        ngram_ctx
    )
    ; Best-effort: a transient antivirus / indexer lock on state.json must
    ; not propagate up the timer stack and kill the ingest tick. The next
    ; KL_SaveState a few seconds later will retry on a fresh write.
    try {
        KL_WriteAtomic(Keylogger.state_json_path, KL_JsonEncode(s))
        return true
    } catch as e {
        try LoggerWarn("Keylogger",
            "KL_SaveState: KL_WriteAtomic failed ('{1}') — will retry next tick.",
            e.Message)
        return false
    }
}

; Restore only entries without a complete journal record. Logged entries are
; recovered from the unchanged offset, and requeuing them would duplicate them.
_KL_IngestRequeueUnwritten(Snapshot, LoggedCount) {
	if !(LoggedCount is Integer) || LoggedCount < 0 || LoggedCount > Snapshot.Length
		throw ValueError("Invalid journaled entry count during ingestion recovery.")
	Count := Snapshot.Length - LoggedCount
	if Count {
		PreviousCritical := Critical("On")
		try {
			Loop Count
				Keylogger._pending_entries.InsertAt(A_Index, Snapshot[LoggedCount + A_Index])
		} finally Critical(PreviousCritical)
	}
	return Count
}

KL_ReadNewTodayLog(Token := 0) {
	Scope := _KL_JournalEnter(Token)
	if !IsObject(Scope)
		return Map("ok", false, "offset", Keylogger.today_log_offset, "entries", [], "eof", false)
	try {
	    ; Flush the writer's pending buffer so the reader sees every line that
	    ; the hot path appended since the last tick — without this, in-flight
	    ; events stay invisible until OS buffer pressure forces a flush. The
	    ; reader below opens its own handle and can only ever see what the OS
	    ; actually holds, so this has to be a real flush (see KL_FlushTodayFh).
	    if Keylogger.HasOwnProp("_today_fh") && !KL_FlushTodayFh(Keylogger._today_fh)
	        return Map("ok", false, "offset", Keylogger.today_log_offset, "entries", [], "eof", false)
		return _KL_JournalReadLines(Keylogger.today_log_path,
			Keylogger.today_log_offset, KeylogConst.INGEST_BATCH_LINES, KL_JsonDecode)
	} finally {
		_KL_JournalLeave(Scope)
	}
}

KL_IngestOnce(force := false, rollover_owned := false, Token := 0) {
	; Admission can repair disk state, so paused or inactive timers refuse first.
	; Recheck inside the scope because repair itself is interruptible.
	if !Keylogger.initialized
		return Map("ok", false, "eof", false, "reason", "not_initialized")
	if A_IsSuspended && !Keylogger._shutting_down
		return Map("ok", false, "eof", false, "reason", "suspended")
	if (IsSet(KL_Mig_IsActive) && KL_Mig_IsActive() && !Keylogger._shutting_down)
		return Map("ok", false, "eof", false, "reason", "migrating")
	Scope := _KL_JournalEnter(Token)
	if !IsObject(Scope)
		return Map("ok", false, "eof", false, "reason", "journal_unavailable")
	try {
	    if !Keylogger.initialized
	        return Map("ok", false, "eof", false, "reason", "not_initialized")
	    ; Never run the ingest tick while the driver is paused. No new events
	    ; are written during suspension (KL_AppendLog is guarded), so the tick
	    ; would do redundant I/O; more importantly, running the heavy FileAppend
	    ; + live-push while suspended violates the pause invariant.
	    if A_IsSuspended && !Keylogger._shutting_down
	        return Map("ok", false, "eof", false, "reason", "suspended")
	    ; Hold off while the at-rest migration is rewriting data.sql. It publishes the
	    ; converted ledger with a single move, and an append landing between its last
	    ; read and that move would be overwritten and lost for good. Deferring is
	    ; free: today.log is the durable buffer and keeps accepting events, exactly as
	    ; during the typing-burst deferral below.
	    if (IsSet(KL_Mig_IsActive) && KL_Mig_IsActive() && !Keylogger._shutting_down)
	        return Map("ok", false, "eof", false, "reason", "migrating")
	    ; The ingest timer can beat the midnight timer. Only the rollover
	    ; transaction owns a date change: never publish a new-day journal row into
	    ; yesterday's file merely because SQL is deferred during active typing.
	    if (!rollover_owned && Keylogger.today_log_date != "" && Keylogger.today_log_date != KL_Today())
	        return KL_DayRollover(Scope.Token)
	    if (Keylogger.today_log_date = "")
	        Keylogger.today_log_date := KL_Today()

	    ; Guard against running the heavy SQL/I/O path during a typing burst.
	    ; Moved BEFORE the pending-entries drain so we never clear _pending_entries
	    ; from RAM and then defer — that would leave entries on disk only, where
	    ; KL_JsonDecode is a no-op on 64-bit and entries are silently lost.
	    ; Bypasses on _shutting_down for the same reason the suspend guard above
	    ; does: deferring only works while a next tick still exists. At shutdown
	    ; there is none, so "defer" means "discard" — and _pending_entries lives in
	    ; RAM only, so quitting or reloading within INGEST_IDLE_MS of a keystroke
	    ; used to throw away the whole closing batch (session_end, idle_end, the
	    ; final roi_snapshot), leaving events_session with an unpaired session_start.
	    if (!force and !Keylogger._shutting_down and IsSet(KLHook) and KLHook.last_tick != 0 and (A_TickCount - KLHook.last_tick) & 0xFFFFFFFF < KeylogConst.INGEST_IDLE_MS) {
			JournalResult := _KL_JournalPendingEntries(0, Scope.Token)
			if !JournalResult["ok"]
				return Map("ok", false, "eof", false,
					"reason", JournalResult["reason"])
			return Map("ok", true, "eof", false, "reason", "typing",
				"journaled", JournalResult["journaled"])
		}
	    ; Prefer the in-RAM queue when available — it sidesteps KL_JsonDecode
	    ; entirely (COM ScriptControl is x86-only and silently empties Maps
	    ; on 64-bit hosts). The JSONL pass is still used to drain anything
	    ; that landed on disk while this process was not running.
	    read_result := KL_ReadNewTodayLog(Scope.Token)
	    if !read_result["ok"]
	        return Map("ok", false, "eof", false, "reason", "read_failed")
	    new_offset := read_result["offset"]
	    entries    := read_result["entries"]
	    source_eof := read_result["eof"]
		; Only drain the RAM queue once the reader has caught up with today.log.
		; KL_ReadNewTodayLog caps every pass at INGEST_BATCH_LINES, so while a
		; backlog remains the append handle sits far past the reader's bookmark.
		; Draining anyway forced a choice between two silent corruptions: publish
		; the writer's position and every unread line is skipped for good (worse,
		; KL_DayRollover then deletes today.log), or publish the reader's bookmark
		; and the lines just appended are read back on a later tick and inserted a
		; second time under a freshly allocated event id. Holding the queue in RAM
		; for the few ticks the backlog needs avoids both; it is bounded because
		; each pass advances the bookmark by up to INGEST_BATCH_LINES.
		;
		; Atomically snapshot and clear _pending_entries under Critical so the
		; keystroke hook cannot Push a new entry between our Length check and
		; the := [] reset — without this, entries pushed after the Length check
		; but before the clear are silently dropped, never reaching data.sql.
		pending_snapshot := []
		if source_eof {
			previous_critical := Critical("On")
			try {
				pending_snapshot := Keylogger._pending_entries
				Keylogger._pending_entries := []
			} finally {
				Critical(previous_critical)
			}
		}

		; Write pending events to disk now, off the hot path. Track the completed
		; JSONL lines precisely: on a later data.sql failure, completed lines are
		; already recoverable from the old offset and must NOT also be re-queued.
		pending_logged_count := 0
		if (pending_snapshot.Length > 0) {
			; Opening today.log must honour the same failure transaction as the
			; data.sql append below. FileOpen THROWS OSError in v2 — it never returns
			; a falsy handle — so a bare call aborted the timer thread right here,
			; after _pending_entries had already been snapshot-and-cleared above.
			; pending_snapshot is a local, so those keystrokes were simply gone: no
			; requeue, no offset rollback, and the global error net only logs and
			; returns, it does not resume the aborted callback. Unlike the data.sql
			; path there is no disk copy to recover from — KL_AppendLog pushes to
			; _pending_entries only — so the snapshot is the sole copy.
			fh := 0
			try {
				fh := KL_OpenTodayFh(Scope.Token)
				batch_start := fh.Pos
				if Type(batch_start) != "Integer" || batch_start < 0
					throw ValueError("Journal position must be a nonnegative byte boundary.")
			} catch as err {
				; Nothing reached today.log, so the ENTIRE snapshot returns to RAM.
				previous_critical := Critical("On")
				try {
					loop pending_snapshot.Length
						Keylogger._pending_entries.InsertAt(A_Index, pending_snapshot[A_Index])
				} finally {
					Critical(previous_critical)
				}
				; Leave today_log_offset alone so the next tick retries the same chunk.
				try LoggerError("Keylogger",
					"Cannot open today.log: {1}; {2} pending entry(ies) re-queued.",
					err.Message, pending_snapshot.Length)
				return Map("ok", false, "eof", false, "reason", "today_log_open_failed")
			}
			if IsObject(fh) {
				append_failed := false
				for _, e in pending_snapshot {
					try {
						line := KL_JsonEncode(e)
						line := StrReplace(line, "`n", "\n")
						line := StrReplace(line, "`r", "")
						if !_KL_JournalAppendDefault(fh, line)
							throw Error("today.log append was incomplete")
						pending_logged_count += 1
					} catch as err {
						append_failed := true
						try LoggerError("Keylogger",
							"Cannot append pending keylogger event to today.log: {1}.",
							err.Message)
						break
					}
				}
				if append_failed {
					rollback_ok := Scope.Owner.Rollback(Scope.Token, fh, batch_start,
						_KL_JournalRollbackAppend)
					_KL_JournalRestoreSnapshot(pending_snapshot)
					try LoggerError("Keylogger",
						"Journal append failed; batch retained (rollback={1}, queued_lines={2}).",
						rollback_ok, pending_snapshot.Length)
					return Map("ok", false, "eof", false,
						"reason", rollback_ok ? "today_log_append_failed" : "journal_repair_pending")
				}

				; Advance the success path past the JSONL lines just written. On an SQL
				; failure the old offset is deliberately retained, so those same lines
				; are read once from disk on the following tick. The flush is what makes
				; fh.Pos trustworthy here: without it the position counts bytes still
				; sitting in AHK's write buffer, so the committed offset named a byte
				; that did not exist in the file yet. Reaching this line at all implies
				; source_eof, so the writer's position and the reader's bookmark agree.
				if !KL_FlushTodayFh(fh) {
					rollback_ok := Scope.Owner.Rollback(Scope.Token, fh, batch_start,
						_KL_JournalRollbackAppend)
					_KL_JournalRestoreSnapshot(pending_snapshot)
					try LoggerError("Keylogger",
						"Cannot durably flush today.log; batch retained in RAM (rollback={1}).",
						rollback_ok)
					return Map("ok", false, "eof", false,
						"reason", rollback_ok ? "today_log_flush_failed" : "journal_repair_pending")
				}
				new_offset := fh.Pos
			}
		}

		for _, e in pending_snapshot
			entries.Push(e)

		if (entries.Length = 0) {
			; Still advance today_log_offset so the cold-replay window keeps
			; shrinking even when no entries were decodable on disk.
			if (new_offset != Keylogger.today_log_offset) {
				old_offset := Keylogger.today_log_offset
				Keylogger.today_log_offset := new_offset
				if !KL_SaveState() {
					Keylogger.today_log_offset := old_offset
					return Map("ok", false, "eof", false, "reason", "state_failed")
				}
			}
			return Map("ok", true, "eof", source_eof,
				"committed_offset", Keylogger.today_log_offset)
		}

	    ; Heavy part: SQL conversion and data.sql FileAppend.
	    ; The keyboard-idle guard that defers this work during typing bursts is now
	    ; at the very top of this function (before the pending-entries drain) so that
	    ; we never clear _pending_entries from RAM and then return without persisting
	    ; to SQL — which would silently lose events on 64-bit hosts where KL_JsonDecode
	    ; is a no-op.
	    statements := []
		try {
			for _, entry in entries {
				for _, sql in KL_BuildInserts(entry)
					statements.Push(sql)
			}
		} catch as Err {
			Requeued := _KL_IngestRequeueUnwritten(pending_snapshot, pending_logged_count)
			; Builder errors can contain external values. Report the failure class
			; and ownership counts without copying the event or exception text.
			try LoggerError("Keylogger",
				"SQL conversion failed ({1}); journal offset unchanged, {2} unwritten pending entry(ies) re-queued.",
				Type(Err), Requeued)
			return Map("ok", false, "eof", false, "reason", "sql_conversion_failed")
		}
	    ; Only raw events reach data.sql — never the walker's aggregate UPSERTs,
	    ; which used to make the file grow ~140 MB/day. Every derived aggregate is
	    ; projected out-of-process instead (see the walk note further down), so
	    ; there is deliberately no KLW.batch flush on this path.
	    if (statements.Length = 0) {
	        old_offset := Keylogger.today_log_offset
	        Keylogger.today_log_offset := new_offset
	        if !KL_SaveState() {
	            Keylogger.today_log_offset := old_offset
	            return Map("ok", false, "eof", false, "reason", "state_failed")
	        }
	        return Map("ok", true, "eof", source_eof,
	            "committed_offset", Keylogger.today_log_offset)
	    }

	    body := "`n-- === ingest batch " . KL_NowTimestamp()
	        .  " (offset " . Keylogger.today_log_offset
	        .  " -> " . new_offset
	        .  ", " . entries.Length . " entry(ies)) ===`nBEGIN TRANSACTION;`n"
	    for _, sql in statements
	        body .= sql . "`n"
	    body .= "COMMIT;`n"

	    try KL_AppendDataSqlDurable(Keylogger.data_sql_path, body)
	    catch as err {
	        ; Only the tail that did NOT reach today.log needs to return to RAM.
	        ; Completed JSONL lines will be re-read from the unchanged old offset;
	        ; re-queueing them too used to make the next retry insert them twice.
	        pending_requeue_count := _KL_IngestRequeueUnwritten(pending_snapshot, pending_logged_count)
	        ; Leave today_log_offset alone so the next tick retries the same chunk.
	        try LoggerError("Keylogger",
				"Cannot append to data.sql: {1}; {2} unwritten pending entry(ies) re-queued.",
				err.Message, pending_requeue_count)
	        return Map("ok", false, "eof", false, "reason", "sql_failed")
	    }
	    old_offset := Keylogger.today_log_offset
	    Keylogger.today_log_offset := new_offset
	    if !KL_SaveState() {
	        Keylogger.today_log_offset := old_offset
	        return Map("ok", false, "eof", false, "reason", "state_failed")
	    }

	    ; This process deliberately does NOT walk the entries it just committed.
	    ; KLW.batch has exactly one consumer, KLW_BuildBatchSql, and it is reachable
	    ; only from KLR_ReplayFlush / KLR_InjectKlwBatch inside KLR_BuildDatabase —
	    ; which runs in the detached `--keylogger-prefetch-worker` instance spawned
	    ; by KLPF_RequestBuild, never here. A foreground walk therefore had no
	    ; reader at all: it pushed seven n-gram maps per keystroke (quadgrams and
	    ; longer are near-unique, so ~4 new Map entries per keystroke) into an
	    ; accumulator that only KLW_ResetBatch at init and KLW_DayRolloverReset at
	    ; midnight ever touched again — tens of MB retained for a whole day and then
	    ; discarded unread, plus that work paid under Critical on the ingest tick.
	    ;
	    ; The worker rebuilds every walker-owned aggregate from the durable
	    ; events_* rows with a fresh context (KLR_RebuildWalkerAggregates), so the
	    ; dashboard is already correct without an in-process copy. The rule this
	    ; encodes: an accumulator must have a consumer in the same process.
	    ;
	    ; B niveau 2 hook: when the dashboard is hosted via WebView2, push
	    ; the freshly-projected prefetch blob to the page so the user sees
	    ; the new data without reloading. No-op when no WebView2 dashboards
	    ; are open (KLWV.windows is empty) or the module is not loaded.
	    ; Keep process launch out of typing bursts: worker setup still enters
	    ; filesystem and native process APIs. Busy commits retain their revision
	    ; and dirty mode in memory, so a later manifest/drain can recover without
	    ; requiring another SQL append.
	    if (KLHook.last_tick = 0 || (A_TickCount - KLHook.last_tick) & 0xFFFFFFFF >= KeylogConst.INGEST_LIVE_PUSH_IDLE_MS) {
	        try KLWV_NotifyIngest()
	    } else {
	        try KLWV_RecordCommittedIngest()
	    }

	    return Map("ok", true, "eof", source_eof,
	        "committed_offset", Keylogger.today_log_offset)
	} finally {
		_KL_JournalLeave(Scope)
	}
}
