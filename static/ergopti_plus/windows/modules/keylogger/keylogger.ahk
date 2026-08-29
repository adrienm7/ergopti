; modules/keylogger/keylogger.ahk

; ==============================================================================
; MODULE: Keylogger (AHK)
; DESCRIPTION:
; Windows port of the Hammerspoon keylogger. Mirrors the on-disk format
; specified in ../KEYLOGGER_SPEC.md byte-for-byte:
;
;   <config_dir>/metrics/by_device/<device_id>/device.json
;   <config_dir>/metrics/by_device/<device_id>/data.sql      (append-only SQL)
;   <config_dir>/metrics/by_device/<device_id>/today.log     (JSONL hot path)
;   <config_dir>/metrics/by_device/<device_id>/state.json    (small offset/counter file)
;
; FEATURES & RATIONALE:
; 1. SQLite-free hot path: this driver never opens db.sqlite. The launcher
;    (re)builds the cache from every device's data.sql on demand.
; 2. data.sql is the single source of truth on disk — Git-friendly,
;    sync-safe, identical to the Hammerspoon side so a Mac and a PC sharing
;    a cloud folder cumulate naturally.
; 3. Per-device subdirectory: each machine writes to its own folder (keyed
;    on a UUID derived from MachineGuid) so concurrent writers cannot
;    corrupt each other's files.
; 4. Crash-safe: today_log_offset is persisted in state.json on every
;    successful ingest tick. Replay is idempotent thanks to per-device
;    PRIMARY KEY (device_id, id) on every event table.
;
; SCOPE OF THIS PORT:
; The current iteration covers raw event persistence (typing, app_switch,
; window_switch, shortcut, hotstring, llm, system, session). The rich
; aggregation walker (n-grams, bursts, sessions, ergonomic streaks) is NOT
; yet ported; agg_* / ngram_* tables stay empty on Windows-only setups
; until the dedicated walker port lands. Mac users sharing a synced
; metrics folder cover this gap automatically: the HS walker on the Mac
; ingests the PC's data.sql via foreign-sync and populates the agg_*/
; ngram_* tables for every device's events.
;
; HOT PATH LATENCY (KL_AppendLog):
; Every cost on the keystroke flush path was scrutinised:
;   - Persistent FileObject handle for today.log (Section 3 KL_OpenTodayFh).
;     A FileAppend()-per-keystroke would re-open + close the file every
;     time, adding ~1 ms each on NTFS once an antivirus filter driver
;     hooks the path. Caching the handle drops that to a memcpy.
;   - Pre-encoded device_id SQL literal cached in Keylogger._device_id_lit.
;     Every INSERT used to call KL_SqlStr() on the same UUID; we now read
;     a static string instead.
;   - No fh.Flush() per call — OS-level write buffering already provides
;     sub-frame durability, and the ingest tick Flush()es before reading.
;   - JSON encoder is iterative (single string accumulator) so a flush of
;     50 events stays under one allocation per character.
;   - The only AHK-level work on the per-keystroke append is: array push
;     into Keylogger.buffer_events, two scalar increments. Real fsync
;     happens at most every 5 s in the ingest tick, never inline.
;
; PASSWORD FIELD FILTER:
; Marked TODO_UIA below. The proper Windows implementation uses UIA's
; IsPasswordPattern in combination with the focused control type and class
; name. See KEYLOGGER_SPEC §6 — to be done in a dedicated session.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KeylogConst {
    static INGEST_TICK_MS           := 5000     ; Background ingest tick.
    static INGEST_BATCH_LINES       := 5000     ; Max lines per ingest cycle.
    static THINK_PAUSE_MS           := 2000     ; Active vs thinking pause threshold.
    static WPM_MAX_DELAY_MS         := 5000     ; Outlier cap for WPM bucketing.
    static MIDNIGHT_CHECK_TICK_MS   := 60000    ; Day rollover check cadence.
    ; Min keyboard-idle window before the heavy SQL conversion and FileAppend
    ; to data.sql is allowed to run. A typing burst within this window defers
    ; the ingest to the next tick so the main thread never blocks while the
    ; user is typing.
    static INGEST_IDLE_MS           := 500
    ; Min keyboard-idle window before the heavy dashboard rebuild (KLWV_NotifyIngest
    ; "live" mode, 150-300 ms) is allowed to run on the ingest timer. A typing burst
    ; within this window defers the rebuild to the next ingest tick so the rebuild
    ; never runs while keystrokes are being dropped by LowLevelHooksTimeout.
    static INGEST_LIVE_PUSH_IDLE_MS := 500
    ; Max KL_IngestOnce passes KL_Stop is allowed to run at shutdown. Each pass
    ; drains at most INGEST_BATCH_LINES from today.log, and the RAM-only
    ; _pending_entries queue is only flushed once the reader reaches EOF, so a
    ; backlog has to be walked to the end here or the final session_end /
    ; idle_end batch dies with the process. Bounded so a pathological backlog
    ; cannot stall a Reload for minutes: 20 passes cover 100 000 lines.
    static SHUTDOWN_INGEST_MAX_PASSES := 20
    static SCHEMA_VERSION           := 1
    ; Tail size (bytes) read from data.sql at startup to scan for the max event id.
    ; data.sql is append-only and per-device, so the highest id is always near the
    ; end of the file. Reading 64 KB covers thousands of recent INSERTs while keeping
    ; startup I/O O(1) regardless of total file size (which can reach 100+ MB).
    static DATA_SQL_SCAN_TAIL_BYTES := 65536
}





; ===============================
; ===============================
; ======= 2/ Module State =======
; ===============================
; ===============================

class Keylogger {
    static initialized      := false
	static lifecycle_generation := 0
    static device_id        := ""
    static device_obj       := Map()
    static metrics_dir      := ""
    static by_device_dir    := ""
    static device_json_path := ""
    static data_sql_path    := ""
    static today_log_path   := ""
    static gitignore_path   := ""
    static state_json_path  := ""

    ; Persisted state (state.json).
    static next_event_id    := 1
    static today_log_offset := 0
    static today_log_date   := ""
    ; Ownership latch for the multi-batch midnight transaction. It prevents
    ; an ingest timer from starting a second rollover while the first one is
    ; still draining/rotating yesterday's durable JSONL file.
    static rollover_in_progress := false

    ; Per-flush typing buffer.
    static buffer_events    := []          ; Array of [char, delay_ms, meta_obj]
    static buffer_text      := ""
    static rich_chunks      := []
    static last_time        := 0
    static last_flush_time  := 0
	; Serialises detached typing snapshots without holding Critical across focus
	; classification or queue publication. A re-entrant fire must retry later;
	; otherwise two rejected snapshots can restore in reverse screen order.
	static _flush_in_progress := false
	; Lifecycle-rejected detached snapshots retain their reserved event ids here
	; instead of merging back into newer physical input. This preserves the true
	; prefix -> completion -> following-input order across Suspend/retry.
	static _retry_snapshots := []
    static session_app      := "Unknown"
    static session_title    := ""
    static session_layout   := ""
    static session_url      := ""
    static session_field_role := ""
    static session_clicks   := 0
    static session_scrolls  := 0
    static mouse_distance   := 0

    ; Synthetic keystroke tagging. When the script auto-types (hotstring
    ; expansion, LLM acceptance) the resulting keystrokes still flow through
    ; the InputHook. KL_MarkSynthetic flags the hook so it stamps s=1 and
    ; st=<source> into each captured keystroke's meta; the reader keeps that
    ; output out of the manual `chars` count and the walker attributes the
    ; n-gram source (esrc). Cleared shortly after the burst (KL_ClearSynthetic).
    static synth_active     := 0
    static synth_type       := "none"
    ; Exact owners preserve both nesting order and source attribution. A scalar
    ; depth cannot restore the outer source when an inner timer releases first.
    static synth_owners     := []
    ; True while ANY held level of the burst is expanding the user's own personal
    ; data (an IBAN, a card number, an SSN). The hook records a placeholder per
    ; character instead of the character itself — see KL_Hook_RecordedChar. It is
    ; a latch, not a per-level value: with two fires overlapping, the cheapest
    ; correct answer is the conservative one, because redacting a public
    ; character costs an n-gram and leaking a private one costs the secret. It
    ; is released with the LAST level (KL_ClearSynthetic), never before.
    static synth_private    := false
    ; Set to true by KL_Stop() before the final flush so the suspend guard in
    ; KL_AppendLog and KL_IngestOnce is bypassed during shutdown (quit-while-paused
    ; would otherwise silently discard the buffered metrics).
    static _shutting_down   := false

    ; Timers (lifecycle).
    static _ingest_timer    := unset
    static _midnight_timer  := unset
	static _initial_ingest_timer := unset

    ; In-RAM queue of entries awaiting ingest. Populated by KL_AppendLog
    ; alongside the JSONL today.log write, drained by KL_IngestOnce.
    ; This avoids the round-trip through KL_JsonDecode (COM ScriptControl
    ; is x86-only and silently returns empty Maps on 64-bit AHK) which
    ; would otherwise leave data.sql empty even when today.log fills.
    static _pending_entries := []
	; Privacy-safe session counters exposed only through KL_HealthSnapshot().
	static health_events_session := 0
	static health_privacy_hits := 0

    ; ─── Hot-path latency caches ─────────────────────────────────────────
    ; Keeping today.log open across calls eliminates the open+close cost
    ; on every keystroke flush (NTFS + antivirus filter drivers turn that
    ; into milliseconds otherwise). The handle is reopened on day rollover.
    static _today_fh        := unset
    static _today_fh_date   := ""
    ; Pre-escaped device_id literal — avoids re-running KL_SqlStr on every
    ; INSERT (the device_id never changes during a process lifetime).
    static _device_id_lit   := ""
}

#Include keylogger_health.ahk



; ============================================
; ===== 2.1) Synthetic keystroke tagging =====
; ============================================

; Flag the hook so the keystrokes the script is about to auto-type (hotstring
; expansion, LLM acceptance) are stamped synthetic in their per-keystroke meta.
; `source` is "hotstring" or "llm". Always pair with a deferred KL_ClearSynthetic
; so the flag can never leak onto subsequent manual typing.
;
; `is_private` is what stops the driver from dictating the user's IBAN to its own
; keylogger. The expansion is typed by us but OBSERVED by our InputHook like any
; other keystroke — that is the whole reason this function exists — so the
; per-character typing row carries the replacement verbatim unless the fire says
; otherwise. Linux takes the same argument through the same door
; (`append_synthetic_events(…, is_private)`).
; @param source {String} "hotstring", "llm" or "case-transform".
; @param is_private {Boolean} True when the burst about to be typed is the user's
;     personal data.
KL_MarkSynthetic(source, is_private := false) {
    Owner := Map("source", source, "private", is_private ? true : false)
    local _c := Critical("On")
    try {
        Keylogger.synth_owners.Push(Owner)
        Keylogger.synth_active := Keylogger.synth_owners.Length
        Keylogger.synth_type := source
        if is_private
            Keylogger.synth_private := true
    } finally {
        Critical(_c)
    }
    return Owner
}

; Clear the synthetic flag once the auto-typed burst has been captured. Takes a
; variadic param so it can be passed directly as a SetTimer callback.
KL_ClearSynthetic(Owner, *) {
    local _c := Critical("On")
    try {
        OwnerIndex := 0
        if Owner is Map {
            for Index, Candidate in Keylogger.synth_owners {
                if ObjPtr(Candidate) == ObjPtr(Owner) {
                    OwnerIndex := Index
                    break
                }
            }
        }
        if !OwnerIndex
            return false
        Keylogger.synth_owners.RemoveAt(OwnerIndex)
        Keylogger.synth_active := Keylogger.synth_owners.Length
        ; Only reset the type label once every held level is released. The
        ; privacy latch is released on the same condition and never earlier: an
        ; outer public fire finishing first must not un-redact the inner private
        ; one that is still typing.
        if Keylogger.synth_active {
            Keylogger.synth_type := Keylogger.synth_owners[-1]["source"]
        } else {
            Keylogger.synth_type := "none"
            Keylogger.synth_private := false
        }
        return true
    } finally {
        Critical(_c)
    }
}





; =====================================
; =====================================
; ======= 3/ Filesystem Helpers =======
; =====================================
; =====================================

KL_MkdirP(path) {
    ; AHK DirCreate is mkdir -p equivalent — no-op if directory exists.
    try DirCreate(path)
}

; Delete scratch files left next to ``path`` by a previous run that was killed
; between FileAppend and the rename. The old fixed ``.tmp`` name self-cleaned
; because every write reused it; per-invocation names do not, so debris is
; reaped here instead. Only files older than ``MaxAgeMs`` are touched, which
; makes it safe against a concurrent live writer — its scratch file is
; milliseconds old. Best-effort throughout: this runs on the save path, and a
; failure to tidy up must never take the save down with it.
; @param path {String} Final destination path whose siblings are scanned.
; @param MaxAgeMs {Integer} Minimum age, in ms, before a scratch file is reaped.
_KL_ReapStaleTemps(path, MaxAgeMs) {
    SplitPath(path, &Name, &Dir)
    if (Dir = "" or Name = "")
        return
    try {
        Loop Files, Dir . "\" . Name . ".*.tmp" {
            if (DateDiff(A_Now, A_LoopFileTimeModified, "Seconds") * 1000 >= MaxAgeMs)
                try FileDelete(A_LoopFileFullPath)
        }
    }
}

KL_WriteAtomic(path, content) {
    ; Write via .tmp + atomic rename so a crash mid-write cannot corrupt the
    ; final file. The previous implementation did FileDelete(path) + FileMove
    ; which left a window where ``path`` did not exist; an antivirus scanner
    ; or file indexer holding a transient handle on the freshly-deleted name
    ; would then make FileMove fail with "Failed", taking the whole timer
    ; tick down with it.
    ;
    ; MoveFileExW with MOVEFILE_REPLACE_EXISTING (1) | MOVEFILE_WRITE_THROUGH
    ; (8) is the documented atomic-rename primitive on NTFS — kernel-level
    ; rename that swaps the directory entry without an unlink-then-create
    ; window. We retry once on transient failure (AV briefly holds the file)
    ; before bubbling up; that is enough in practice to absorb scanner
    ; flakiness without masking real I/O errors.
    ; The scratch name must be unique per invocation. It used to be a fixed
    ; ``path . ".tmp"``, which made it a shared resource between every writer
    ; of the same target — and there are several, on threads that interrupt one
    ; another. KL_SaveState is reached from the ingest timer, from
    ; KL_DayRollover and from KL_Stop (OnExit, which pre-empts a running timer),
    ; and the ``Sleep 50`` retry below is a yield point that hands control to
    ; exactly those threads. The losing interleaving is:
    ;
    ;   A: FileAppend(tmp) → MoveFileExW fails (AV lock) → Sleep 50 …yields…
    ;   B: FileDelete(tmp) → FileAppend(tmp) → MoveFileExW succeeds, tmp gone
    ;   A: wakes, retries MoveFileExW on a tmp that no longer exists → ERROR 2
    ;
    ; which is exactly what the field logs show: ERROR_FILE_NOT_FOUND (2) and
    ; ERROR_SHARING_VIOLATION (32) from KL_SaveState, only on days with many
    ; restarts. Worse than the noise, A and B could both hold the same tmp open
    ; and interleave their FileAppend, renaming spliced JSON onto state.json.
    ; A per-invocation name removes the shared resource outright.
    static MOVEFILE_REPLACE_EXISTING := 0x1
    static MOVEFILE_WRITE_THROUGH    := 0x8
    static FLAGS := MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
    ; A scratch file older than this can only be debris from a hard kill — a
    ; live write completes in milliseconds — so it is safe to reap. Deliberately
    ; generous so a genuinely slow AV-throttled write is never targeted.
    static STALE_TEMP_MS := 60000
    static WriteSeq := 0

    WriteSeq += 1
    ; A_ScriptHwnd keeps the name unique across processes too: #SingleInstance
    ; Force replaces an instance only at the END of the successor's load, so two
    ; drivers can briefly be alive and writing the same metrics directory. It is
    ; a built-in rather than a GetCurrentProcessId DllCall on purpose — the
    ; OS-call purity ratchet (tests/meta/test_ahk_os_purity_ratchet.ahk) counts
    ; direct OS calls outside adapters/, and this needs none.
    tmp := path . "." . A_ScriptHwnd . "-" . WriteSeq . ".tmp"
    _KL_ReapStaleTemps(path, STALE_TEMP_MS)
    ; A rename only makes the stage atomic; it cannot tell whether an out-of-
    ; space write produced every byte. Publish only a flushed, byte-exact stage
    ; so state.json/device.json can never be atomically replaced with valid-
    ; prefix JSON after a short write.
    if !FSWriteDurable(tmp, content)
        throw Error("Atomic state stage write was incomplete.")
    if !FSUtf8ExactMatches(tmp, content) {
        try FileDelete(tmp)
        throw Error("Atomic state stage bytes did not verify.")
    }

    if !DllCall("Kernel32\MoveFileExW", "Str", tmp, "Str", path,
            "UInt", FLAGS, "Int") {
        ; Retry once after a brief pause to ride out a transient AV / indexer
        ; lock on ``path``. Sleep on the timer thread is acceptable here —
        ; SaveState already runs off the hot keyboard path.
        Sleep 50
        if !DllCall("Kernel32\MoveFileExW", "Str", tmp, "Str", path,
                "UInt", FLAGS, "Int") {
            err := A_LastError
            try FileDelete(tmp)
            throw OSError(err, A_ThisFunc,
                "MoveFileExW failed for '" . path . "'.")
        }
    }
}

KL_AppendLine(path, line) {
    ; Append a single JSONL line with explicit newline. UTF-8 always.
    ; Slow fallback path — AppendLog uses the cached file handle instead.
    FileAppend(line . "`n", path, "UTF-8")
}

KL_OpenTodayFh() {
    ; Open today.log for append with shared-read mode so a tail -f / git diff
    ; can inspect the file without blocking us. The handle stays open until
    ; the script exits or the day rolls over.
    today := KL_Today()
    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh)
        && Keylogger._today_fh_date = today
        return Keylogger._today_fh
    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh) {
        try Keylogger._today_fh.Close()
    }
    fh := FileOpen(Keylogger.today_log_path, "a", "UTF-8")
    Keylogger._today_fh      := fh
    Keylogger._today_fh_date := today
    return fh
}

; Push AHK's user-mode write buffer to Windows, then force the Windows cache to
; stable storage. Both boundaries must accept before RAM ownership can move.
;
; AHK v2's File object has NO Flush() method — ``HasMethod(fh, "Flush")`` is 0
; and the call raises a MethodError. Both former call sites wrapped it in a bare
; ``try``, so the error was discarded and the buffer was never flushed: measured
; here, 200 buffered writes left ``fh.Pos`` at 6695 while the file was 3 bytes on
; disk and a second reader handle saw those same 3 bytes. That matters because
; today_log_offset is persisted FROM ``fh.Pos``, so the offset routinely named
; bytes that existed only inside this process — the ingest reader could not see
; the tail it claimed to have consumed, and any exit that skips KL_CloseTodayFh
; (hard crash, power loss, taskkill, #SingleInstance replacement) dropped it for
; good. Reading the ``Handle`` property is the documented v2 idiom: AHK must
; commit its buffer before it can hand out the raw OS handle. FlushFileBuffers
; then proves the OS cache crossed the durable boundary too.
; @param fh {File} An open File object. Anything else is ignored.
KL_FlushTodayFh(fh) {
    if !IsObject(fh)
		return false
    try {
		_ := fh.Handle
		if !FSFlushFileBuffers(fh) {
			try LoggerWarn("Keylogger", "today.log stable-storage flush failed.")
			return false
		}
		return true
	}
    catch as err {
        try LoggerWarn("Keylogger", "today.log flush failed: {1}.", err.Message)
		return false
    }
}

; Appends one complete SQL batch and does not acknowledge it until both AHK's
; write buffer and the Windows cache have crossed the stable-storage boundary.
; The offset checkpoint is published only after this receipt, so a hard power
; fault can leave either a replayable old offset or a durable transaction, but
; never a durable checkpoint that skips missing SQL bytes.
KL_RollbackDataSqlAppend(Fh, OriginalLength, FlushFn := 0) {
	if !IsObject(Fh) || !IsInteger(OriginalLength) || OriginalLength < 0
		return false
	ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : FSFlushFileBuffers
	try {
		; Reading Handle first drains AHK's buffered prefix to the OS. The raw
		; handle can then be rewound and truncated at the exact pre-append byte.
		Handle := Fh.Handle
		NewPosition := 0
		if !DllCall("kernel32\SetFilePointerEx", "Ptr", Handle,
			"Int64", OriginalLength, "Int64*", &NewPosition, "UInt", 0, "Int")
			return false
		if (NewPosition != OriginalLength)
			return false
		if !DllCall("kernel32\SetEndOfFile", "Ptr", Handle, "Int")
			return false
		return ResolvedFlush.Call(Fh) == true
	} catch {
		return false
	}
}

KL_AppendDataSqlDurable(Path, Body, OpenFn := 0, FlushFn := 0) {
	ResolvedOpen := HasMethod(OpenFn, "Call") ? OpenFn : FileOpen
	ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : FSFlushFileBuffers
	Fh := 0
	try {
		Fh := ResolvedOpen.Call(Path, "a", "UTF-8")
		if !IsObject(Fh)
			throw Error("data.sql could not be opened for append")
		OriginalLength := Fh.Length
		try {
			Written := Fh.Write(Body)
			ExpectedBytes := StrPut(Body, "UTF-8") - 1
			if (Written != ExpectedBytes)
				throw Error("data.sql append was incomplete")
			if (ResolvedFlush.Call(Fh) != true)
				throw Error("data.sql stable-storage flush failed")
		} catch as Err {
			if !KL_RollbackDataSqlAppend(Fh, OriginalLength, ResolvedFlush)
				throw Error("data.sql append rollback failed after: " . Err.Message)
			throw
		}
		Fh.Close()
		Fh := 0
		return true
	} finally {
		if IsObject(Fh)
			try Fh.Close()
	}
}

KL_CloseTodayFh() {
    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh) {
		try Keylogger._today_fh.Close()
		catch as Err {
			try LoggerError("Keylogger", "Cannot close today.log: {1}.", Err.Message)
			return false
		}
        Keylogger._today_fh := unset
        Keylogger._today_fh_date := ""
    }
	return true
}





; ==================================
; ==================================
; ======= 4/ Path Resolution =======
; ==================================
; ==================================

KL_ResolveTmpdir() {
    tmp := EnvGet("TMP")
    if (tmp = "")
        tmp := EnvGet("TEMP")
    if (tmp = "")
        tmp := A_Temp
    return RTrim(tmp, "\/") . "\"
}

KL_ResolvePaths(metrics_dir, device_id) {
    md := metrics_dir
    if !RegExMatch(md, "[\\/]$")
        md .= "\"
    by_dev := md . "by_device\" . device_id . "\"

    Keylogger.metrics_dir      := md
    Keylogger.by_device_dir    := by_dev
    Keylogger.device_json_path := by_dev . "device.json"
    Keylogger.data_sql_path    := by_dev . "data.sql"
    Keylogger.today_log_path   := by_dev . "today.log"
    Keylogger.state_json_path  := by_dev . "state.json"
    Keylogger.gitignore_path   := md   . ".gitignore"
}

KL_EnsureGitignore() {
    if FileExist(Keylogger.gitignore_path)
        return
    body := "# Local hot-path log — never commit, never sync.`n"
         .  "# One writer per device; another machine appending here would`n"
         .  "# corrupt the file. Ingested into data.sql by the keylogger.`n"
         .  "today.log`n"
    FileAppend(body, Keylogger.gitignore_path, "UTF-8")
}





#Include keylogger_device.ahk





; ====================================
; ====================================
; ======= 6/ State persistence =======
; ====================================
; ====================================

KL_LoadState() {
    if !FileExist(Keylogger.state_json_path)
        return
    try {
        raw := FileRead(Keylogger.state_json_path, "UTF-8")
        s   := KL_JsonDecode(raw)
        if !(s is Map)
            return
        if s.Has("next_event_id")    && IsNumber(s["next_event_id"])
            Keylogger.next_event_id    := Integer(s["next_event_id"])
        if s.Has("today_log_offset") && IsNumber(s["today_log_offset"])
            Keylogger.today_log_offset := Integer(s["today_log_offset"])
        if s.Has("today_log_date")
            Keylogger.today_log_date   := String(s["today_log_date"])
        ; Restore the walker context if present. A missing key is fine:
        ; the walker rebuilds context on the next typing entry.
        if s.Has("ngram_ctx") {
            try KLW_RestoreCtx(s["ngram_ctx"])
        }
    }
}

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



; =========================================
; ===== 6.1) Event-id collision guard =====
; =========================================
; A Reload mid-burst can lose the final flush window, leaving the persisted
; next_event_id in state.json LAGGING the true max id already written to
; data.sql. On the next launch KL_AllocEventId would then re-mint ids that
; already exist, and the schema's `INSERT OR IGNORE INTO events_* (device_id,
; id, ...)` SILENTLY DROPS the colliding rows — permanent, invisible data
; loss. The defence does not trust state.json alone: at startup it scans the
; existing data.sql and the uncommitted today.log tail for the highest id
; already published for THIS device, then starts after it. Parsing and resolve
; helpers remain pure so the recovery arithmetic stays unit-testable.

#Include keylogger_event_id.ahk





#Include keylogger_json.ahk

#Include keylogger_journal.ahk
#Include keylogger_shutdown.ahk





; ========================================
; ========================================
; ======= 8/ Hot path — append_log =======
; ========================================
; ========================================

KL_AppendLog(entry, &RejectedBySuspend := false, PublishGuard := unset,
	PublishCommit := unset) {
	RejectedBySuspend := false
    ; Hot path. Optimisations applied (see Section 2 latency caches):
    ;  - persistent FileObject handle: avoids open/close ≈ 0.5-2 ms each
    ;    that NTFS + AV filter drivers tax on every keystroke flush;
    ;  - direct fh.Write() instead of FileAppend(): bypasses the PATH
    ;    re-resolution and locale-encoding negotiation that FileAppend
    ;    redoes on every call;
    ;  - no FormatTime when timestamp is already set by the caller.
    if !Keylogger.initialized
        return false
    if !(entry is Map) || !entry.Has("type")
        return false
    ; Pause must silence everything. Native Suspend only disarms hotkeys/hotstrings,
    ; but the keylogger feeds on an InputHook + ~10 SetTimer / OnClipboardChange
    ; sources that bypass it. KL_AppendLog is the single chokepoint every telemetry
    ; source funnels through, so one guard here silences ALL keystroke / sensor /
    ; clipboard capture while the driver is paused (nothing reaches today.log or the
    ; _pending_entries data.sql queue). system_event lifecycle markers (e.g. the
    ; "paused" marker itself) are exempt so the pause transition stays diagnosable.
    ; See project_suspend_pause_invariant.
	if A_IsSuspended && entry["type"] != "system_event" && !Keylogger._shutting_down {
		; Callers that detached mutable state need to distinguish a lifecycle
		; refusal (safe to retry) from a privacy/validation drop (must never be
		; replayed in a later foreground context).
		RejectedBySuspend := true
		return false
	}
    ; Privacy filters — drop anything captured while the focused window is
    ; on the user's exclusion list, in private browsing, or in a system-
    ; auth dialog. The check is cached for ~250 ms so the per-keystroke
    ; cost is negligible. Wrapped in try so an unloaded module degrades
    ; gracefully (filters stay off rather than crashing the hot path).
    filtered := false
    try {
        filtered := MF_ShouldFilter()
    } catch {
        ; Module not loaded or error — fail closed (treat as filtered) so sensitive
        ; data is never logged when the privacy module is unavailable.
        filtered := true
        try LoggerWarn("Keylogger", "MF_ShouldFilter unavailable — defaulting to filtered.")
    }
    if filtered {
		KL_RecordPrivacyHit()
        return false
	}
    ; MF_ShouldFilter() above evaluated MetricsFocusCache, which MF_RefreshFocus
    ; repoints within MF_FOCUS_TTL_MS (50 ms). The PAYLOAD, however, describes
    ; whatever window its producer saw, and every producer lags that cache:
    ; app_switch / window_switch carry the OUTGOING prev_app / prev_title by
    ; design, while every other type carries Keylogger.session_app /
    ; session_title, which only KL_Hook_RefreshContext writes and only under its
    ; own 1000 ms TTL on a 250 ms timer. So for up to ~1.25 s after switching
    ; away from an excluded or private-browsing window the live check passed
    ; while the row still stamped that window's process name and verbatim title
    ; — precisely the identifiers the filter exists to suppress. Scoping the
    ; re-check to the two switch types (F9) left the typing / shortcut /
    ; hotstring / mouse / ergo siblings leaking the same stale pair, so it now
    ; runs for every entry against whatever context that entry actually carries:
    ; the verdict and the payload can no longer describe two different windows.
    ctx_app   := ""
    ctx_title := ""
    if (entry["type"] = "app_switch") {
        ctx_app := entry.Has("prev_app") ? entry["prev_app"] : ""
    } else if (entry["type"] = "window_switch") {
        ctx_app   := entry.Has("app") ? entry["app"] : ""
        ctx_title := entry.Has("prev_title") ? entry["prev_title"] : ""
    } else {
        ctx_app   := entry.Has("app") ? entry["app"] : ""
        ctx_title := entry.Has("title") ? entry["title"] : ""
    }
    if (ctx_app != "" || ctx_title != "") {
        outgoing_filtered := false
        try {
            outgoing_filtered := MF_ShouldFilterFor(ctx_app, ctx_title)
        } catch {
            ; Module not loaded or error — fail closed, same contract as the
            ; live-focus check above.
            outgoing_filtered := true
            try LoggerWarn("Keylogger", "MF_ShouldFilterFor unavailable — defaulting to filtered.")
        }
        if outgoing_filtered {
			KL_RecordPrivacyHit()
            return false
		}
    }
	if !entry.Has("timestamp")
		entry["timestamp"] := KL_NowTimestamp()
	; Queue the live Map for the ingest tick — no JSON round-trip needed
	; for entries originating in this process. The JSON stringification and disk
	; append are deferred to KL_IngestOnce so we never block the keystroke thread.
	; Privacy checks and timestamp formatting above can yield. Pair the final
	; lifecycle recheck with the shared-queue mutation so Suspend cannot land in
	; the one-statement gap and publish a row after the pause boundary.
	AppendCritical := Critical("On")
	try {
		if A_IsSuspended && entry["type"] != "system_event" && !Keylogger._shutting_down {
			RejectedBySuspend := true
			return false
		}
		; Async producers may do privacy/context preparation above, then discover
		; that their immutable UI owner was replaced. Recheck at the exact queue
		; mutation; the optional commit is memory-only and shares that transaction.
		if IsSet(PublishGuard) && !PublishGuard.Call()
			return false
		KL_AssignStableEventId(entry)
		Keylogger._pending_entries.Push(entry)
		Keylogger.health_events_session += 1
		if IsSet(PublishCommit)
			PublishCommit.Call()
	} finally {
		Critical(AppendCritical)
	}
	return true
}





; ========================================
; ========================================
; ======= 9/ flush_buffer (typing) =======
; ========================================
; ========================================

; Queue a detached typing snapshot when its lifecycle owner was invalidated.
; It must stay separate from newer live input: merging would replay characters
; typed after an accepted completion under the older snapshot's reserved id.
_KL_RestoreBufferSnapshot(Snapshot, AttemptFlushTick) {
    PreviousCritical := Critical("On")
    try {
		InsertAt := Keylogger._retry_snapshots.Length + 1
		for Index, Queued in Keylogger._retry_snapshots {
			if (Queued.EventId > Snapshot.EventId) {
				InsertAt := Index
				break
			}
		}
		Keylogger._retry_snapshots.InsertAt(InsertAt, Snapshot)
		if (Keylogger.last_flush_time == AttemptFlushTick)
			Keylogger.last_flush_time := Snapshot.LastFlushTime
    } finally {
        Critical(PreviousCritical)
    }
}

KL_FlushBuffer(PublishGuard := unset, &DeferredByActiveFlush := false) {
	DeferredByActiveFlush := false
	if !Keylogger.initialized
		return false

	; Claim one detached-snapshot owner in the same short transaction as the
	; generation check and reference swap. The expensive classification below is
	; deliberately outside Critical, but a sibling flush then leaves the live
	; buffer untouched and tells its fire-log owner to retry.
	previous_critical := Critical("On")
	try {
		if IsSet(PublishGuard) && !PublishGuard.Call()
			return false
		if Keylogger._flush_in_progress {
			DeferredByActiveFlush := true
			return false
		}
		RetryingSnapshot := Keylogger._retry_snapshots.Length > 0
		if RetryingSnapshot {
			Snapshot := Keylogger._retry_snapshots.RemoveAt(1)
			AttemptFlushTick := A_TickCount
			Keylogger._flush_in_progress := true
		} else {
		if (Keylogger.buffer_events.Length = 0
			&& Keylogger.session_clicks = 0
			&& Keylogger.session_scrolls = 0)
			return true

		Keylogger._flush_in_progress := true
		AttemptFlushTick := A_TickCount
		snap_events := Keylogger.buffer_events
		snap_text := Keylogger.buffer_text
		snap_rich := Keylogger.rich_chunks
		snap_clicks := Keylogger.session_clicks
		snap_scrolls := Keylogger.session_scrolls
		snap_dist := Keylogger.mouse_distance
		snap_last_time := Keylogger.last_time
		snap_last_flush_time := Keylogger.last_flush_time
		Snapshot := {
			EventId: KL_AllocEventId(),
			Events: snap_events,
			Text: snap_text,
			RichChunks: snap_rich,
			Clicks: snap_clicks,
			Scrolls: snap_scrolls,
			Distance: snap_dist,
			LastTime: snap_last_time,
			LastFlushTime: snap_last_flush_time,
			Pause: (snap_events.Length > 0) ? snap_events[1][2] : 0,
			App: Keylogger.session_app,
			Title: Keylogger.session_title,
			Url: Keylogger.session_url,
			FieldRole: Keylogger.session_field_role,
			Layout: Keylogger.session_layout
		}
		Keylogger.buffer_events    := []
		Keylogger.buffer_text := ""
		Keylogger.rich_chunks := []
		Keylogger.last_time := 0
		Keylogger.session_clicks := 0
		Keylogger.session_scrolls := 0
		Keylogger.mouse_distance := 0
		Keylogger.last_flush_time := AttemptFlushTick
		}
	} finally {
		Critical(previous_critical)
	}

	Published := false
	try {
		Published := _KL_PublishBufferSnapshot(
			Snapshot, AttemptFlushTick, PublishGuard?)
	} finally {
		ReleaseCritical := Critical("On")
		try Keylogger._flush_in_progress := false
		finally Critical(ReleaseCritical)
	}
	; A successful retry precedes the live buffer in screen order. Drain the
	; latter now so a caller asking for a flush (notably output preparation and
	; shutdown) still gets the historical all-buffer contract.
	if (Published && RetryingSnapshot)
		return KL_FlushBuffer(PublishGuard?)
	return Published
}

; Builds and publishes one already-detached typing snapshot. The lifecycle
; owner is checked after classification and immediately before publication; a
; rejected owner restores the snapshot while the outer serialisation latch is
; still held.
_KL_PublishBufferSnapshot(Snapshot, AttemptFlushTick, PublishGuard := unset) {
	if (Snapshot.Events.Length = 0 && Snapshot.Clicks = 0 && Snapshot.Scrolls = 0)
		return true
	total_time_ms := 0
	total_chars := 0
	for _, ev in Snapshot.Events {
		meta := ev[3]
		if !(meta is Map) || !meta.Has("s") || !meta["s"] {
			d := ev[2]
			if (d > KeylogConst.WPM_MAX_DELAY_MS)
				d := KeylogConst.WPM_MAX_DELAY_MS
			total_time_ms += d
			total_chars += 1
		}
	}
	wpm := (total_time_ms > 0)
		? ((total_chars / 5) / (total_time_ms / 60000)) : 0
	app_cat := "unknown"
	try app_cat := KL_AppCat_Get(Snapshot.App)
	entry := Map(
		"_event_id", Snapshot.EventId,
		"type", "typing",
		"text", Snapshot.Text,
		"rich_text", "",
		"app", Snapshot.App,
		"app_category", app_cat,
		"title", Snapshot.Title,
		"url", Snapshot.Url,
		"field_role", Snapshot.FieldRole,
		"layout", Snapshot.Layout,
		"is_fullscreen", 0,
		"in_meeting", 0,
		"mouse_clicks", Snapshot.Clicks,
		"mouse_scrolls", Snapshot.Scrolls,
		"mouse_distance_px", Snapshot.Distance,
		"pause_before_ms", Snapshot.Pause,
		"wpm", Round(wpm, 1),
		"events", Snapshot.Events
	)
	if IsSet(PublishGuard) && !PublishGuard.Call() {
		_KL_RestoreBufferSnapshot(Snapshot, AttemptFlushTick)
		return false
	}
	Accepted := KL_AppendLog(entry, &RejectedBySuspend)
	; Only an explicit lifecycle refusal restores the buffer. A false return can
	; also mean a privacy/validation drop; replaying that text after resume under a
	; different foreground window would defeat the filter that rejected it.
	if RejectedBySuspend {
		_KL_RestoreBufferSnapshot(Snapshot, AttemptFlushTick)
		return false
	}
	return Accepted
}





; ===================================================
; ===================================================
; ======= 10/ Public log_* event entry points =======
; ===================================================
; ===================================================

KL_LogAppSwitch(prev_app, next_app, duration_ms := 0) {
    KL_AppendLog(Map(
        "type",        "app_switch",
        "prev_app",    prev_app,
        "next_app",    next_app,
        "duration_ms", duration_ms
    ))
}

KL_LogWindowSwitch(app_name, prev_title, next_title, duration_ms := 0) {
    KL_AppendLog(Map(
        "type",        "window_switch",
        "app",         app_name,
        "prev_title",  prev_title,
        "next_title",  next_title,
        "duration_ms", duration_ms
    ))
}

KL_LogShortcut(shortcut_key, app_name := "Unknown") {
    if (shortcut_key = "")
        return
    KL_AppendLog(Map(
        "type", "shortcut",
        "key",  shortcut_key,
        "app",  app_name
    ))
}

KL_LogSystemEvent(action, metadata := unset) {
    e := Map("type", "system_event", "action", action)
    if IsSet(metadata) && (metadata is Map) {
        for k, v in metadata
            e[k] := v
    }
    KL_AppendLog(e)
}

; KL_LogHotstring — the FIRED-hotstring row — lives in
; modules/keylogger/keylogger_hotstring_log.ahk. It was split out so the
; headless test suite can drive it against a recording KL_AppendLog: it is the
; one row that can carry the user's personal data, and this file installs OS
; hooks at load, so nothing here is includable from a test.

; Logs that a hotstring tooltip was shown to the user. Mirrors HS init.lua:1196.
; The call site (prefix watcher) drives suggested/dismissed pairing — there
; is at most one suggestion live at any time per device.
KL_LogHotstringSuggested(trigger, replacement, h_type := "unknown", app_name := "") {
    if !Keylogger.initialized
        return
    app := (app_name != "") ? app_name : Keylogger.session_app
    KL_AppendLog(Map(
        "type",        "hotstring_suggested",
        "app",         app,
        "trigger",     trigger,
        "replacement", replacement,
        "h_type",      h_type
    ))
}

; Token-aware sibling for a tooltip post-present callback. All privacy/context
; work in KL_AppendLog stays outside Critical; only the final owner guard,
; in-memory queue push and state commit are atomic.
KL_LogHotstringSuggestedGuarded(trigger, replacement, h_type, PublishGuard,
	PublishCommit, app_name := "") {
    if !Keylogger.initialized
        return false
    app := (app_name != "") ? app_name : Keylogger.session_app
    RejectedBySuspend := false
    return KL_AppendLog(Map(
        "type",        "hotstring_suggested",
        "app",         app,
        "trigger",     trigger,
        "replacement", replacement,
        "h_type",      h_type
    ), &RejectedBySuspend, PublishGuard, PublishCommit)
}

; Logs that a previously-suggested hotstring tooltip was dismissed without
; firing. Mirrors HS init.lua:1214.
KL_LogHotstringDismissed(trigger, replacement, h_type := "unknown", app_name := "") {
    if !Keylogger.initialized
        return
    app := (app_name != "") ? app_name : Keylogger.session_app
    KL_AppendLog(Map(
        "type",        "hotstring_dismissed",
        "app",         app,
        "trigger",     trigger,
        "replacement", replacement,
        "h_type",      h_type
    ))
}

KL_LogLlm(kind, payload) {
    e := Map("type", "llm_" . kind)
    if (payload is Map) {
        for k, v in payload
            e[k] := v
    }
    KL_AppendLog(e)
}

/**
 * Logs a FAILED LLM prediction attempt — same envelope as KL_LogLlm but the
 * predictions array is empty and ``failure_reason`` captures what went
 * wrong. Without this event a tail of the log shows only successes and
 * "are predictions silently dropping?" becomes impossible to answer.
 *
 * Mirrors keylogger.log_llm_failed on the HS side (modules/keylogger/init.lua).
 *
 * @param {Map} payload - Fields: app, context, backend, model, system_prompt,
 *     user_prompt, failure_reason, elapsed_ms.
 */
KL_LogLlmFailed(payload) {
    e := Map("type", "llm_generation_failed", "predictions", [])
    if (payload is Map) {
        for k, v in payload
            e[k] := v
    }
    KL_AppendLog(e)
}

; ─── Acceptance-rate events ─────────────────────────────────────────────
; Three matched events that let a tail of the log compute "what fraction
; of suggestions did the user accept?". Mirrors keylogger.log_llm_suggested
; / log_llm_dismissed / log_llm_accepted on the HS side.

KL_LogLlmSuggested(app_name, count) {
    KL_AppendLog(Map(
        "type", "llm_suggested",
        "app",  app_name,
        "count", count
    ))
}

KL_LogLlmDismissed(app_name, all_predictions) {
    KL_AppendLog(Map(
        "type", "llm_dismissed",
        "app",  app_name,
        "all_predictions", all_predictions
    ))
}

KL_LogLlmAccepted(prediction_text, app_name, all_predictions, chosen_index) {
    KL_AppendLog(Map(
        "type", "llm_accepted",
        "app",  app_name,
        "prediction", prediction_text,
        "all_predictions", all_predictions,
        "chosen_index", chosen_index,
        ; ``net_saved_chars`` matches the HS field — same accounting,
        ; AHK side doesn't track backspaces, so ``deletes`` is 0 by
        ; construction here.
        "net_saved_chars", StrLen(prediction_text)
    ))
}

#Include keylogger_llm_journal.ahk

KL_LogSession(kind, duration_ms := unset, PublishCommit := 0) {
    e := Map("type", kind)
    if IsSet(duration_ms)
        e["duration_ms"] := duration_ms
	if HasMethod(PublishCommit, "Call") {
		RejectedBySuspend := false
		return KL_AppendLog(e, &RejectedBySuspend, , PublishCommit)
	}
	return KL_AppendLog(e)
}





#Include keylogger_text_cipher.ahk
#Include keylogger_text_migration.ahk
#Include keylogger_sql.ahk





; ===============================
; ===============================
; ======= 12/ Ingest Tick =======
; ===============================
; ===============================

KL_ReadNewTodayLog() {
    ; Flush the writer's pending buffer so the reader sees every line that
    ; the hot path appended since the last tick — without this, in-flight
    ; events stay invisible until OS buffer pressure forces a flush. The
    ; reader below opens its own handle and can only ever see what the OS
    ; actually holds, so this has to be a real flush (see KL_FlushTodayFh).
    if Keylogger.HasOwnProp("_today_fh")
        KL_FlushTodayFh(Keylogger._today_fh)
	return _KL_JournalReadLines(Keylogger.today_log_path,
		Keylogger.today_log_offset, KeylogConst.INGEST_BATCH_LINES, KL_JsonDecode)
}

KL_IngestOnce(force := false, rollover_owned := false) {
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
        return KL_DayRollover()
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
		JournalResult := _KL_JournalPendingEntries()
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
    read_result := KL_ReadNewTodayLog()
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
			fh := KL_OpenTodayFh()
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
			batch_start := fh.Pos
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
				prefix_flushed := false
				try prefix_flushed := KL_FlushTodayFh(fh) == true
				if prefix_flushed
					_KL_JournalRestoreSnapshot(pending_snapshot,
						pending_logged_count + 1)
				else {
					_KL_JournalRollbackAppend(fh, batch_start)
					_KL_JournalRestoreSnapshot(pending_snapshot)
				}
				return Map("ok", false, "eof", false,
					"reason", "today_log_append_failed")
			}
			; Advance the success path past the JSONL lines just written. On an SQL
			; failure the old offset is deliberately retained, so those same lines
			; are read once from disk on the following tick. The flush is what makes
			; fh.Pos trustworthy here: without it the position counts bytes still
			; sitting in AHK's write buffer, so the committed offset named a byte
			; that did not exist in the file yet. Reaching this line at all implies
			; source_eof, so the writer's position and the reader's bookmark agree.
			if !KL_FlushTodayFh(fh) {
				rollback_ok := _KL_JournalRollbackAppend(fh, batch_start)
				_KL_JournalRestoreSnapshot(pending_snapshot)
				try LoggerError("Keylogger",
					"Cannot durably flush today.log; batch retained in RAM (rollback={1}).",
					rollback_ok)
				return Map("ok", false, "eof", false,
					"reason", "today_log_flush_failed")
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
    for _, entry in entries {
        for _, sql in KL_BuildInserts(entry)
            statements.Push(sql)
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
        pending_requeue_count := pending_snapshot.Length - pending_logged_count
        if (pending_requeue_count > 0) {
            previous_critical := Critical("On")
            try {
                loop pending_requeue_count {
                    snapshot_index := pending_logged_count + A_Index
                    Keylogger._pending_entries.InsertAt(A_Index, pending_snapshot[snapshot_index])
                }
            } finally {
                Critical(previous_critical)
            }
        }
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
    ; Guard with a keyboard-idle check: the full "live" rebuild takes
    ; 150-300 ms; running it during a typing burst exceeds
    ; LowLevelHooksTimeout (~300 ms) and silently drops keystrokes.
    ; Deferred to the next ingest tick if the user typed recently.
    if (KLHook.last_tick = 0 || (A_TickCount - KLHook.last_tick) & 0xFFFFFFFF >= KeylogConst.INGEST_LIVE_PUSH_IDLE_MS)
        try KLWV_NotifyIngest()

    return Map("ok", true, "eof", source_eof,
        "committed_offset", Keylogger.today_log_offset)
}

KL_DayRollover() {
    if !Keylogger.initialized
        return Map("ok", false, "reason", "not_initialized")
    if Keylogger.rollover_in_progress
        return Map("ok", false, "reason", "already_running")
    if A_IsSuspended && !Keylogger._shutting_down
        return Map("ok", false, "reason", "suspended")

    Keylogger.rollover_in_progress := true
    try {
        old_date := Keylogger.today_log_date
        new_date := KL_Today()
        if (old_date = "") {
            Keylogger.today_log_date := new_date
            if !KL_SaveState()
                return Map("ok", false, "reason", "state_failed")
            return Map("ok", true, "reason", "initialised")
        }
        if (old_date = new_date)
            return Map("ok", true, "reason", "already_current")

        ; Force every bounded batch through the durable SQL + state commit.
        ; The delete is unreachable until the reader reports EOF from a
        ; successful ingest; a failed append/read/save leaves today.log intact.
        loop {
            ingest_result := KL_IngestOnce(true, true)
            if !ingest_result["ok"]
                return Map("ok", false, "reason", ingest_result["reason"])
            if ingest_result["eof"]
                break
        }

        try FileAppend(
            "`n-- === day rollover " . old_date . " -> " . new_date . " ===`n",
            Keylogger.data_sql_path, "UTF-8")
        catch as err {
            try LoggerError("Keylogger", "Cannot write day rollover marker: {1}.",
				err.Message)
            return Map("ok", false, "reason", "marker_failed")
        }

        KL_CloseTodayFh()  ; release the handle before deleting.
        if FileExist(Keylogger.today_log_path) {
            try FileDelete(Keylogger.today_log_path)
            catch as err {
                try LoggerError("Keylogger", "Cannot delete rolled today.log: {1}.",
					err.Message)
                return Map("ok", false, "reason", "delete_failed")
            }
        }
        if FileExist(Keylogger.today_log_path)
            return Map("ok", false, "reason", "delete_failed")

        ; Publish the new date only after durable data and deletion succeeded.
        old_offset := Keylogger.today_log_offset
        Keylogger.today_log_offset := 0
        Keylogger.today_log_date   := new_date
        if !KL_SaveState() {
            ; The file is already rotated. Keep the old persisted epoch so a
            ; later retry is conservative (no data loss), rather than claiming
            ; a new day whose state was never durable.
            Keylogger.today_log_offset := old_offset
            Keylogger.today_log_date   := old_date
            return Map("ok", false, "reason", "state_failed")
        }
        ; A new day starts every walker context fresh. Yesterday's partial
        ; word / streak / current_burst is meaningless at midnight.
        try KLW_DayRolloverReset()
        return Map("ok", true, "reason", "rotated")
    } finally {
        Keylogger.rollover_in_progress := false
    }
}

KL_MidnightCheck() {
    if A_IsSuspended
        return
    if (Keylogger.today_log_date != "" && Keylogger.today_log_date != KL_Today())
        KL_DayRollover()
}





#Include keylogger_password.ahk





; ======================================
; ======================================
; ======= 14/ Bootstrap data.sql =======
; ======================================
; ======================================

KL_BootstrapDataSql() {
    if FileExist(Keylogger.data_sql_path) {
		try {
			Probe := FileOpen(Keylogger.data_sql_path, "a", "UTF-8")
			if !IsObject(Probe)
				throw Error("append handle unavailable")
			Probe.Close()
			return true
		} catch as Err {
			try LoggerError("Keylogger", "data.sql is not writable: {1}.", Err.Message)
			return false
		}
	}
    header := "-- ergopti metrics — device " . Keylogger.device_id
        .  " — schema_version " . KeylogConst.SCHEMA_VERSION . "`n"
        .  "-- This file is APPEND-ONLY. Do not edit by hand.`n"
        .  "-- The launcher rebuilds db.sqlite from this file on demand.`n"
        .  "PRAGMA foreign_keys = OFF;`n"
    try FileAppend(header, Keylogger.data_sql_path, "UTF-8")
    catch as err {
        try LoggerError("Keylogger", "Could not create data.sql: {1}", err.Message)
        return false
    }

    ; A brand-new ledger contains no legacy/mixed rows: every later local row is
    ; emitted under the cipher posture already in force. Commit that trustworthy
    ; O(1) fact now so the deferred boot sync never proof-scans an empty ledger.
    return KL_Mig_RecordNewLedgerPosture()
}





; =============================
; =============================
; ======= 15/ Lifecycle =======
; =============================
; =============================

KL_Init(metrics_dir) {
    if Keylogger.initialized
		return true

    KL_MkdirP(metrics_dir)

    obj := KL_ResolveDevice(metrics_dir)
    Keylogger.device_obj := obj
    Keylogger.device_id  := obj["device_id"]

    Keylogger._device_id_lit := KL_SqlStr(Keylogger.device_id)
    KL_ResolvePaths(metrics_dir, Keylogger.device_id)
    KL_MkdirP(Keylogger.by_device_dir)
    KL_MkdirP(KL_ResolveTmpdir() . "ergopti_metrics\" . Keylogger.device_id)
    KL_EnsureGitignore()
    KL_WriteDeviceJson(obj)
    KL_LoadState()

    ; Harden next_event_id against id reuse: never trust state.json alone. A
    ; Reload mid-burst can leave the persisted counter lagging the true max id
    ; already in data.sql; re-minting those ids would be silently dropped by
    ; the schema's INSERT OR IGNORE. Resolve to one past the highest persisted
    ; id so a new event can never collide with an existing one.
    ; Read only the TAIL of data.sql — it is append-only and per-device, so the
    ; highest id is always near the end. 64 KB covers thousands of recent INSERTs
    ; and keeps startup I/O O(1) on 100+ MB files (keylogger-scan-max-id-performance).
    sql_text := ""
    try {
        if FileExist(Keylogger.data_sql_path) {
            fh := FileOpen(Keylogger.data_sql_path, "r", "UTF-8")
            if IsObject(fh) {
                fh.Seek(Max(0, fh.Length - KeylogConst.DATA_SQL_SCAN_TAIL_BYTES), 0)
                sql_text := fh.Read()
                fh.Close()
            }
        }
    }
    ; Entries receive their id before JSONL publication. If the process died
    ; before advancing the journal offset, reserve past those durable ids too;
    ; otherwise a producer firing early in the next boot could collide with an
    ; uncommitted line before the ingest timer replays it.
    journal_text := ""
    try {
        if FileExist(Keylogger.today_log_path) {
            journal_fh := FileOpen(Keylogger.today_log_path, "r", "UTF-8")
            if IsObject(journal_fh) {
                journal_fh.Seek(Min(Max(0, Keylogger.today_log_offset),
                    journal_fh.Length), 0)
                journal_text := journal_fh.Read()
                journal_fh.Close()
            }
        }
    }
    max_id := Max(
        KL_ScanMaxEventId(sql_text, Keylogger._device_id_lit),
        KL_ScanMaxJournalEventId(journal_text))
    Keylogger.next_event_id := KL_ResolveStartId(Keylogger.next_event_id, max_id)

    if (Keylogger.today_log_date = "")
        Keylogger.today_log_date := KL_Today()
	if !KL_BootstrapDataSql() {
		try LoggerError("Keylogger",
			"Initialization refused because the durable ledger is unavailable.")
		return false
	}

	InitCritical := Critical("On")
	try {
		Keylogger._shutting_down := false
		Keylogger.health_events_session := 0
		Keylogger.health_privacy_hits := 0
		Keylogger.lifecycle_generation += 1
		Keylogger.initialized := true
	} finally {
		Critical(InitCritical)
	}
	try {
		if !KL_AppCat_Init(metrics_dir)
			throw Error("application category initialization failed")

		; Initialise the walker batch dicts. KL_LoadState() above already
		; restored the per-app n-gram context (KLW.ctx) if state.json had one.
		try KLW_ResetBatch()

		; Publish every exact timer identity before native admission. This includes
		; the initial one-shot so a later initialization failure can cancel it too.
		if !KL_TimerGroupStart(Keylogger, [
			Map("property", "_ingest_timer", "callback", KL_IngestOnce.Bind(),
				"period", KeylogConst.INGEST_TICK_MS),
			Map("property", "_midnight_timer", "callback", KL_MidnightCheck.Bind(),
				"period", KeylogConst.MIDNIGHT_CHECK_TICK_MS),
			Map("property", "_initial_ingest_timer",
				"callback", KL_IngestOnce.Bind(), "period", -250)
		], SetTimer, "core")
			throw Error("keylogger timer cleanup debt blocks initialization")

		; Bring data.sql in line with the at-rest posture the config just restored.
		; A no-op unless they disagree, and deferred either way: the comparison is
		; cheap but the rewrite it may start is not, and neither belongs on the boot
		; critical path.
		if !KL_Mig_RequestPostureSync(KL_MIG_BOOT_DELAY_MS)
			throw Error("at-rest posture sync could not be scheduled")
	} catch as Err {
		try KL_TimerGroupStop(Keylogger,
			["_initial_ingest_timer", "_ingest_timer", "_midnight_timer"],
			SetTimer, "core")
		RollbackCritical := Critical("On")
		try Keylogger.initialized := false
		finally Critical(RollbackCritical)
		try LoggerError("Keylogger", "Initialization rolled back: {1}.", Err.Message)
		return false
	}
	return true
}

; Publish the terminal ownership lease before any other subsystem drains into
; the keylogger. The global shutdown handler calls this before the deferred
; hotstring fire queue, and KL_Stop repeats it for direct callers.
KL_BeginShutdown() {
	ShutdownCritical := Critical("On")
	try {
		if !Keylogger.initialized
			return false
		if !Keylogger._shutting_down {
			Keylogger._shutting_down := true
			Keylogger.lifecycle_generation += 1
		}
		return true
	} finally {
		Critical(ShutdownCritical)
	}
}

; Rolls back the reversible shutdown lease when an OnExit gate refuses before
; any producer is stopped. Durable rows already drained remain consumed, while
; future keylogger callbacks receive a fresh lifecycle generation.
KL_CancelShutdown() {
	ShutdownCritical := Critical("On")
	try {
		if !Keylogger.initialized
			return false
		if Keylogger._shutting_down {
			Keylogger._shutting_down := false
			Keylogger.lifecycle_generation += 1
		}
		return true
	} finally {
		Critical(ShutdownCritical)
	}
}

KL_Stop() {
    if !Keylogger.initialized
		return true
    ; Raise the shutdown bypass BEFORE any teardown. Every *_Stop() below drains a
    ; CLOSING lifecycle event (session_end, idle_end, vpn_disconnected,
    ; screen_recording_end, the final roi_snapshot) through KL_AppendLog, whose
    ; pause guard would otherwise discard them on a quit or reload issued while the
    ; driver is paused — leaving events_session with a session_start and no
    ; session_end, which poisons every active-time aggregate downstream. Reload is
    ; the driver's standard apply-settings path, so this fired routinely. Setting
    ; the flag only just before the trailing KL_FlushBuffer() protected the two
    ; explicit flushes but none of the six module drains that carry most of the
    ; shutdown write traffic.
	if !KL_BeginShutdown()
		return false
    ; Drop any in-flight ledger rewrite before the shutdown drain: its staging
    ; file describes a data.sql that the flush below is about to extend, and the
    ; ingest guard bypasses on _shutting_down, so leaving it armed would publish a
    ; ledger missing the closing batch.
    try KL_Mig_Cancel()
	PrefetchStopped := KLPF_CancelAll()
    ; Release the keystroke hook FIRST so no late event lands in a
    ; buffer we are about to flush + serialise.
    try KL_Hook_Stop()
    ; Drain idle / session state and unhook OnMessage handlers so the
    ; JSONL never ends with a dangling session_start / idle_start.
	WatchersStopped := false
	try WatchersStopped := KL_Watchers_Stop()
    try KL_Mouse_Stop()
	SensorsStopped := false
	try SensorsStopped := KL_Sensors_Stop()
	TopologyStopped := false
	try TopologyStopped := KL_Topo_Stop()
	AvStateStopped := false
	try AvStateStopped := KL_AV_Stop()
	NetworkStopped := false
	try NetworkStopped := KL_Net_Stop()
    try KL_Clip_Stop()
	RoiStopped := false
	try RoiStopped := KL_Roi_Stop()
	TimersStopped := KL_TimerGroupStop(Keylogger,
		["_initial_ingest_timer", "_ingest_timer", "_midnight_timer"],
		SetTimer, "core")
    ; _shutting_down was raised at the top of this function (see the comment
    ; there) so the module drains above could emit their closing events too.
	FlushComplete := KL_FlushBuffer()
	JournalResult := _KL_JournalPendingEntries()
	if !FlushComplete or !JournalResult["ok"] {
		try LoggerError("Keylogger",
			"Shutdown retained durable debt (flush={1}, journal={2}).",
			FlushComplete, JournalResult["ok"])
		return false
	}
	if !KL_AppCat_PrepareShutdown() {
		try LoggerError("Keylogger",
			"Shutdown retained pending app-category persistence debt.")
		return false
	}
    ; force := true — the typing-idle guard would otherwise return before the
    ; pending drain, and there is no next tick left to defer to. Looped because
    ; each pass drains at most INGEST_BATCH_LINES and the RAM-only queue is only
    ; flushed once the reader reaches EOF, so a backlog has to be walked out.
	IngestComplete := false
    loop KeylogConst.SHUTDOWN_INGEST_MAX_PASSES {
        ingest_result := KL_IngestOnce(true)
        ; A rollover result carries no "eof" key — nothing left to walk either way.
		if !ingest_result["ok"] {
			try LoggerError("Keylogger", "Shutdown ingest failed ({1}).",
				KL_GetMap(ingest_result, "reason", "unknown"))
			break
		}
		if KL_GetMap(ingest_result, "eof", true) {
			IngestComplete := true
            break
		}
    }
	StateSaved := KL_SaveState()
	HandleClosed := KL_CloseTodayFh()
	if !TimersStopped or !SensorsStopped or !TopologyStopped or !AvStateStopped
		or !NetworkStopped or !RoiStopped or !PrefetchStopped or !WatchersStopped
		or !IngestComplete or !StateSaved or !HandleClosed {
		try LoggerError("Keylogger",
			"Shutdown incomplete (core_timers={1}, sensors={2}, topology={3}, av={4}, network={5}, roi={6}, prefetch={7}, watchers={8}, ingest={9}, state={10}, close={11}).",
			TimersStopped, SensorsStopped, TopologyStopped, AvStateStopped,
			NetworkStopped, RoiStopped, PrefetchStopped, WatchersStopped,
			IngestComplete, StateSaved, HandleClosed)
		return false
	}
    Keylogger.initialized := false
	return true
}





; ============================================
; ============================================
; ======= 16/ Convenience / Public API =======
; ============================================
; ============================================

KL_GetSqlitePath() {
    ; The launcher uses this path to (re)build db.sqlite from data.sql on
    ; demand. The keylogger itself never opens the SQLite file.
    return KL_ResolveTmpdir() . "ergopti_metrics\" . Keylogger.device_id . "\db.sqlite"
}

KL_GetDeviceShortId() {
    if (Keylogger.device_id = "")
        return ""
    return SubStr(Keylogger.device_id, 1, 8) . "…"
}

; Setters mirroring HS CoreState — wire them from your event handlers.
KL_SetSessionApp(name) {
    Keylogger.session_app := name
}
KL_SetSessionTitle(title) {
    Keylogger.session_title := title
}
KL_SetSessionLayout(layout) {
    Keylogger.session_layout := layout
}
KL_SetSessionUrl(url) {
    Keylogger.session_url := url
}
KL_SetSessionFieldRole(role) {
    Keylogger.session_field_role := role
}
KL_BumpMouseClick() {
    Keylogger.session_clicks += 1
}
KL_BumpMouseScroll() {
    Keylogger.session_scrolls += 1
}
KL_BumpMouseDistance(px) {
    Keylogger.mouse_distance += px
}
