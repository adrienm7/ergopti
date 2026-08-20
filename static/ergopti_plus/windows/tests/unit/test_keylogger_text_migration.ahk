; static/ergopti_plus/windows/tests/unit/test_keylogger_text_migration.ahk

; ==============================================================================
; MODULE: At-Rest Bulk Migration Tests (Windows)
; DESCRIPTION:
; Regression coverage for the half of at-rest encryption that was missing:
; ticking the box encrypted only the rows written from that moment on, so a
; machine with a year of logs enabled a setting that left every earlier row in
; clear. Unticking it had the mirror defect.
;
; This driver stores its rows in data.sql, an append-only ledger of INSERT
; statements — db.sqlite is a disposable cache rebuilt from it — so the ledger
; is what a migration has to convert, and these tests run against a real one.
;
; WHAT THIS ENCODES:
; 1. The rewrite is byte-exact. The ledger is not line-oriented: typed text can
;    contain a newline, a semicolon, a comma, a double-dash and an escaped
;    quote, all of which a naive split would cut a statement on and corrupt.
; 2. It is idempotent. A pass over an already-converted ledger converts nothing
;    and changes nothing, which is what makes a restarted migration converge.
; 3. It fails CLOSED, and leaves data.sql untouched when it does. The converted
;    ledger is built beside the original and published with a single move, so a
;    failure at any point before that move loses nothing at all.
; 4. It never rewrites an aggregate column, and never touches another device's
;    rows — those belong to that device's key domain.
; ==============================================================================

; ==============================================================================
; ==============================================================================
; ======= 1/ Fixture Helpers ===================================================
; ==============================================================================
; ==============================================================================

global _KLMigDir := A_Temp . "\ergopti_migration_test"
global _KLMigMachineId := "00000000-0000-0000-0000-0000000000AA"
global _KLMigTimers := []
global _KLMigSuccesses := []

; Points the migration at a throwaway ledger and returns its path.
_KLMig_Reset() {
    try KL_Mig_Cancel()
    KLMigration.timer_fn := 0
    KLMigration.marker_commit_fn := 0
    KLMigration.success_fn := 0
    if !DirExist(_KLMigDir)
        DirCreate(_KLMigDir)
    Keylogger.by_device_dir := _KLMigDir . "\"
    Keylogger.data_sql_path := _KLMigDir . "\data.sql"
    Keylogger.device_id := "test-device"
    Keylogger._device_id_lit := KL_SqlStr("test-device")
    Keylogger.next_event_id := 1
    Keylogger.initialized := true
    try FileDelete(Keylogger.data_sql_path)
    try FileDelete(Keylogger.data_sql_path . KL_MIG_STAGING_SUFFIX)
    try FileDelete(Keylogger.by_device_dir . KL_MIG_MARKER_FILE)
    KL_Enc_SetMachineIdOverride(_KLMigMachineId)
    KL_Enc_SetEnabled(false)
    return Keylogger.data_sql_path
}

_KLMig_RecordTimer(callback, period) {
    global _KLMigTimers
    _KLMigTimers.Push(Map("callback", callback, "period", period))
    return true
}

_KLMig_FailMarkerCommit(*) {
    return false
}

_KLMig_RecordSuccess(converted, scanned) {
    global _KLMigSuccesses
    _KLMigSuccesses.Push(Map("converted", converted, "scanned", scanned))
    return true
}

; Builds one events_typing statement through the PRODUCTION builder, so the
; fixture cannot drift from the format the driver actually writes.
_KLMig_TypingSql(text) {
    entry := Map("type", "typing", "timestamp", "2026-07-30 10:00:00.000",
        "app", "TestApp", "text", text, "wpm", 42)
    rows := KL_BuildInserts(entry)
    return rows.Length ? rows[1] : ""
}

; Writes a ledger shaped like a real one: header comments, a transaction, the
; typing rows, a foreign-device row and a non-typing INSERT.
_KLMig_WriteLedger(texts, foreignText := "") {
    body := "-- ergopti metrics - device test-device`n"
        .  "-- This file is APPEND-ONLY. Do not edit by hand.`n"
        .  "PRAGMA foreign_keys = OFF;`n"
        .  "`n-- === ingest batch 2026-07-30 10:00:00 (3 entry(ies)) ===`nBEGIN TRANSACTION;`n"
    for _, text in texts
        body .= _KLMig_TypingSql(text) . "`n"
    if (foreignText != "") {
        ; A row that arrived from another machine. Built with the same builder
        ; under a different device id, then restored.
        localLit := Keylogger._device_id_lit
        Keylogger._device_id_lit := KL_SqlStr("other-device")
        body .= _KLMig_TypingSql(foreignText) . "`n"
        Keylogger._device_id_lit := localLit
    }
    body .= "INSERT OR IGNORE INTO events_shortcut (device_id, id, ts, date, app, key) "
        .  "VALUES ('test-device', 900, '2026-07-30 10:00:00.000', '2026-07-30', 'TestApp', 'ctrl+s');`n"
    body .= "COMMIT;`n"
    FileAppend(body, Keylogger.data_sql_path, "UTF-8")
    return body
}

; Runs a pass to completion without the timer, with a bound so a pass that never
; terminates fails loudly instead of hanging the suite.
_KLMig_Drain() {
    guard := 0
    while (KL_Mig_Slice() && guard < 1000)
        guard += 1
    return guard
}

; Returns the VALUES field named `column` of the Nth events_typing statement,
; unquoted. Uses the migration's own tokeniser, which is the point: a reader
; that split on commas would disagree with it exactly where the bugs live.
_KLMig_FieldOf(ledger, occurrence, column) {
    pos := 0
    loop occurrence {
        pos := InStr(ledger, KL_MIG_INSERT_MARKER, , pos + 1)
        if (!pos)
            return ""
    }
    columnsOpen := InStr(ledger, "(", , pos)
    columnsClose := _KL_Mig_MatchingParen(ledger, columnsOpen)
    columns := StrSplit(SubStr(ledger, columnsOpen + 1, columnsClose - columnsOpen - 1), ",", " `t`r`n")
    valuesOpen := InStr(ledger, "(", , InStr(ledger, "VALUES", , columnsClose))
    valuesClose := _KL_Mig_MatchingParen(ledger, valuesOpen)
    fields := _KL_Mig_SplitTuple(SubStr(ledger, valuesOpen + 1, valuesClose - valuesOpen - 1))
    index := _KL_Mig_IndexOf(columns, column)
    if (!index || index > fields.Length)
        return ""
    raw := Trim(fields[index])
    if (StrLen(raw) >= 2 && SubStr(raw, 1, 1) = "'" && SubStr(raw, -1) = "'")
        return _KL_Mig_Unquote(raw)
    return raw
}




; ==============================================================================
; ==============================================================================
; ======= 2/ The Statement Tokeniser ===========================================
; ==============================================================================
; ==============================================================================

; Text the user could genuinely type, every character of which breaks a naive
; split: a semicolon ends a statement, a comma separates fields, a quote ends a
; literal, a double-dash starts a comment and a newline ends a line.
_KLMig_TokeniserSurvivesTypedText() {
    sql := "INSERT OR IGNORE INTO events_typing (device_id, id, text) "
        .  "VALUES ('dev', 1, 'a; b, c -- d ''quoted'' e');"
    AssertEqual(StrLen(sql), _KL_Mig_StatementEnd(sql),
        "a semicolon inside the typed text must not be taken for the end of the statement")
}

Test("KL_Mig: the tokeniser ends a statement on the real terminator", _KLMig_TokeniserSurvivesTypedText)

_KLMig_TokeniserSkipsComments() {
    ; A comment holding an odd number of quotes would flip the literal state for
    ; the whole rest of the ledger if it were parsed rather than skipped.
    sql := "-- don't parse this`nPRAGMA foreign_keys = OFF;"
    AssertEqual(StrLen(sql), _KL_Mig_StatementEnd(sql),
        "an apostrophe in a comment must not open a string literal")
}

Test("KL_Mig: the tokeniser skips comment text rather than parsing it", _KLMig_TokeniserSkipsComments)

_KLMig_TokeniserWaitsForMore() {
    AssertEqual(0, _KL_Mig_StatementEnd("INSERT OR IGNORE INTO events_typing (a) VALUES ('unter"),
        "an incomplete statement must report 0 so the reader fetches more input")
}

Test("KL_Mig: the tokeniser reports an incomplete statement", _KLMig_TokeniserWaitsForMore)

_KLMig_SplitsOnTopLevelCommasOnly() {
    fields := _KL_Mig_SplitTuple("'dev', 1, 'a, b', 'c''d', 0")
    AssertEqual(5, fields.Length, "a comma inside a literal is typed text, not a separator")
    AssertEqual("'a, b'", Trim(fields[3]))
    AssertEqual("'c''d'", Trim(fields[4]))
}

Test("KL_Mig: the tuple splitter respects quoted literals", _KLMig_SplitsOnTopLevelCommasOnly)




; ==============================================================================
; ==============================================================================
; ======= 3/ Enabling Converts The Ledger ======================================
; ==============================================================================
; ==============================================================================

_KLMig_EncryptsStoredRows() {
    _KLMig_Reset()
    ; Multi-byte UTF-8, an embedded newline, an escaped quote and a semicolon:
    ; the ledger is not line-oriented, and every one of these has broken a naive
    ; rewrite at some point.
    texts := ["hello world", "h" . Chr(0xE9) . "llo " . Chr(0x20AC) . " monde",
        "line one`nline two", "it's a; test -- really"]
    _KLMig_WriteLedger(texts)
    before := FileRead(Keylogger.data_sql_path, "UTF-8")

    KL_Enc_SetEnabled(true)
    AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false), "the pass must start")
    _KLMig_Drain()

    after := FileRead(Keylogger.data_sql_path, "UTF-8")
    loop texts.Length {
        stored := _KLMig_FieldOf(after, A_Index, "text")
        AssertTrue(KL_Enc_IsEncrypted(stored),
            "row " . A_Index . " must be stored as an envelope")
        AssertEqual(texts[A_Index], KL_Enc_Decrypt(stored),
            "the envelope must decrypt back to the exact bytes it replaced")
    }
    ; The plaintext must be gone from the file, not merely from the column.
    for _, text in texts
        AssertTrue(!InStr(after, text), "the typed text must not survive anywhere in the ledger")
    AssertTrue(before != after, "the ledger must actually have been rewritten")
    KL_Enc_SetEnabled(false)
}

Test("KL_Mig: enabling encrypts the rows already in data.sql", _KLMig_EncryptsStoredRows)

_KLMig_LeavesAggregatesAlone() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["measured text"])
    KL_Enc_SetEnabled(true)
    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()

    after := FileRead(Keylogger.data_sql_path, "UTF-8")
    ; The dashboard computes over these. An envelope in one would break every
    ; query while protecting nothing.
    AssertEqual("TestApp", _KLMig_FieldOf(after, 1, "app"), "app must be left in clear")
    AssertEqual("2026-07-30", _KLMig_FieldOf(after, 1, "date"), "date must be left in clear")
    AssertEqual("42", _KLMig_FieldOf(after, 1, "wpm"), "wpm must be left in clear")
    AssertContains(after, "INSERT OR IGNORE INTO events_shortcut",
        "a non-typing statement must pass through untouched")
    AssertContains(after, "'ctrl+s'", "another table's text must not be encrypted")
    AssertContains(after, "PRAGMA foreign_keys = OFF;", "the ledger header must survive")
    AssertContains(after, "COMMIT;", "the transaction framing must survive")
    KL_Enc_SetEnabled(false)
}

Test("KL_Mig: only the two typed-text columns are rewritten", _KLMig_LeavesAggregatesAlone)

_KLMig_LeavesForeignRowsAlone() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["mine"], "theirs")
    KL_Enc_SetEnabled(true)
    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()

    after := FileRead(Keylogger.data_sql_path, "UTF-8")
    AssertTrue(KL_Enc_IsEncrypted(_KLMig_FieldOf(after, 1, "text")), "the local row must be converted")
    ; The key derives from the machine id, so this machine could not decrypt a
    ; foreign row — and encrypting it would lock its owner out of its own data.
    AssertEqual("theirs", _KLMig_FieldOf(after, 2, "text"),
        "a row imported from another device must be left exactly as it arrived")
    KL_Enc_SetEnabled(false)
}

Test("KL_Mig: another device's rows are never touched", _KLMig_LeavesForeignRowsAlone)




; ==============================================================================
; ==============================================================================
; ======= 4/ Disabling Reverts The Ledger ======================================
; ==============================================================================
; ==============================================================================

_KLMig_DecryptsBackToTheOriginal() {
    _KLMig_Reset()
    texts := ["secret sentence", "accentu" . Chr(0xE9) . " text", "multi`nline"]
    _KLMig_WriteLedger(texts)

    KL_Enc_SetEnabled(true)
    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()

    ; The user unticks the box. Decryption does not consult the toggle.
    KL_Enc_SetEnabled(false)
    AssertTrue(KL_Mig_Start(KL_MIG_MODE_DECRYPT, false), "the reverse pass must start")
    _KLMig_Drain()

    after := FileRead(Keylogger.data_sql_path, "UTF-8")
    loop texts.Length {
        AssertEqual(texts[A_Index], _KLMig_FieldOf(after, A_Index, "text"),
            "row " . A_Index . " must come back byte for byte")
    }
    AssertTrue(!InStr(after, KL_ENC_MARKER), "no envelope may be left behind")
}

Test("KL_Mig: disabling decrypts the stored rows in place", _KLMig_DecryptsBackToTheOriginal)




; ==============================================================================
; ==============================================================================
; ======= 5/ Restart And Idempotence ===========================================
; ==============================================================================
; ==============================================================================

_KLMig_SecondPassChangesNothing() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["one", "two", "three"])
    KL_Enc_SetEnabled(true)
    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()
    once := FileRead(Keylogger.data_sql_path, "UTF-8")

    ; Exactly what an interrupted-then-restarted pass does: run it again over a
    ; ledger that is already in the target state.
    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()
    twice := FileRead(Keylogger.data_sql_path, "UTF-8")

    AssertEqual(once, twice,
        "re-wrapping an envelope would make it undecryptable in one pass")
    AssertEqual("one", KL_Enc_Decrypt(_KLMig_FieldOf(twice, 1, "text")),
        "a doubly-wrapped value would not decrypt in one step")
    ; The bytes matching is not enough on its own: it would also hold if every
    ; row were re-encrypted and happened to land on the same ciphertext. What
    ; makes a restart cheap AND safe is that an already-converted row is SKIPPED,
    ; so the second pass must report no conversions at all.
    AssertEqual(0, KLMigration.converted,
        "an already-converted row must be skipped, not converted again")
    KL_Enc_SetEnabled(false)
}

Test("KL_Mig: a second pass over a converted ledger is a no-op", _KLMig_SecondPassChangesNothing)

_KLMig_ConvergesFromAHalfConvertedLedger() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["alpha", "beta"])
    KL_Enc_SetEnabled(true)

    ; Convert both rows, then put the SECOND one back in clear. That is exactly
    ; the state an interruption leaves behind: a prefix of the ledger converted,
    ; the rest untouched. Both of row 1's columns stay converted, so the count
    ; below can be sharp about what the resumed pass is allowed to touch.
    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()
    converted := FileRead(Keylogger.data_sql_path, "UTF-8")
    firstEnvelope := _KLMig_FieldOf(converted, 1, "text")

    mixed := StrReplace(converted, KL_SqlStr(_KLMig_FieldOf(converted, 2, "text")), KL_SqlStr("beta"))
    mixed := StrReplace(mixed, KL_SqlStr(_KLMig_FieldOf(converted, 2, "events_json")), KL_SqlStr("{}"))
    try FileDelete(Keylogger.data_sql_path)
    FileAppend(mixed, Keylogger.data_sql_path, "UTF-8")

    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()

    after := FileRead(Keylogger.data_sql_path, "UTF-8")
    AssertEqual(firstEnvelope, _KLMig_FieldOf(after, 1, "text"),
        "an already-converted row must be left exactly as it was")
    AssertEqual("alpha", KL_Enc_Decrypt(_KLMig_FieldOf(after, 1, "text")))
    AssertEqual("beta", KL_Enc_Decrypt(_KLMig_FieldOf(after, 2, "text")),
        "the row the interrupted pass never reached must be converted now")
    AssertEqual(1, KLMigration.converted,
        "exactly the one unconverted row may be touched — the other must be skipped")
    KL_Enc_SetEnabled(false)
}

Test("KL_Mig: a half-converted ledger converges without double-wrapping", _KLMig_ConvergesFromAHalfConvertedLedger)

_KLMig_SyncRunsOnlyOnDisagreement() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["some text"])
    KL_Enc_SetEnabled(true)

    AssertTrue(KL_Mig_SyncToPosture(), "a ledger that disagrees with the posture must be converted")
    _KLMig_Drain()
    AssertFalse(KL_Mig_SyncToPosture(),
        "rewriting the whole ledger at every launch to change nothing is the cost this marker avoids")

    KL_Enc_SetEnabled(false)
    AssertTrue(KL_Mig_SyncToPosture(), "turning the setting off must schedule the reverse pass")
    _KLMig_Drain()
    AssertEqual("some text", _KLMig_FieldOf(FileRead(Keylogger.data_sql_path, "UTF-8"), 1, "text"))
}

Test("KL_Mig: the posture sync converts once and then stays quiet", _KLMig_SyncRunsOnlyOnDisagreement)




; ==============================================================================
; ==============================================================================
; ======= 6/ Failure Loses Nothing =============================================
; ==============================================================================
; ==============================================================================

_KLMig_RefusesToStartWithoutAKey() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["still secret"])
    before := FileRead(Keylogger.data_sql_path, "UTF-8")

    ; An empty machine id makes the key underivable.
    KL_Enc_SetMachineIdOverride("")
    KL_Enc_SetEnabled(true)
    AssertFalse(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false),
        "a pass that cannot encrypt must not start rewriting the ledger")
    AssertEqual(before, FileRead(Keylogger.data_sql_path, "UTF-8"),
        "data.sql must be byte-identical when the pass refuses to run")
    AssertFalse(FileExist(Keylogger.data_sql_path . KL_MIG_STAGING_SUFFIX),
        "no staging file may be left behind")

    KL_Enc_SetEnabled(false)
    KL_Enc_SetMachineIdOverride(_KLMigMachineId)
}

Test("KL_Mig: no key means no rewrite at all", _KLMig_RefusesToStartWithoutAKey)

_KLMig_AbortsWithoutTouchingTheLedger() {
    _KLMig_Reset()
    texts := ["recoverable one", "recoverable two"]
    _KLMig_WriteLedger(texts)
    KL_Enc_SetEnabled(true)
    KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
    _KLMig_Drain()
    encrypted := FileRead(Keylogger.data_sql_path, "UTF-8")

    ; The dangerous direction: KL_Enc_Decrypt returns "" when it has no key, and
    ; writing that would erase the rows for good.
    KL_Enc_SetMachineIdOverride("")
    KL_Enc_SetEnabled(false)
    KL_Mig_Start(KL_MIG_MODE_DECRYPT, false)
    _KLMig_Drain()

    AssertEqual(encrypted, FileRead(Keylogger.data_sql_path, "UTF-8"),
        "an undecryptable ledger must be left exactly as it was, never emptied")
    AssertFalse(FileExist(Keylogger.data_sql_path . KL_MIG_STAGING_SUFFIX),
        "the abandoned staging file must be cleaned up")
    AssertFalse(KL_Mig_IsActive(), "a failed pass must stop rather than keep slicing")

    KL_Enc_SetMachineIdOverride(_KLMigMachineId)
    AssertEqual("recoverable one",
        KL_Enc_Decrypt(_KLMig_FieldOf(FileRead(Keylogger.data_sql_path, "UTF-8"), 1, "text")),
        "and the rows must still be recoverable once the key is back")
}

Test("KL_Mig: a failure mid-pass leaves data.sql untouched", _KLMig_AbortsWithoutTouchingTheLedger)

_KLMig_HoldsOffTheIngestWhileRewriting() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["held"])
    KL_Enc_SetEnabled(true)
    try {
        KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)
        ; An append landing between the pass's last read and its single publishing
        ; move would be overwritten and lost, so the ingest tick must see this flag.
        AssertTrue(KL_Mig_IsActive(), "the ingest guard must be raised for the whole pass")
        _KLMig_Drain()
        AssertFalse(KL_Mig_IsActive(), "and lowered once the ledger has been published")

        ; Force the exact old data-loss window: handles have closed (active=false),
        ; but the staged ledger has not yet been moved because suspend interrupted
        ; the commit continuation. Ingest must remain fenced by commitPending.
        AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false))
        KLMigration.paused := true
        _KL_Mig_Finish()
        AssertFalse(KLMigration.active,
            "the finish protocol must release scan ownership before publication")
        AssertTrue(KL_Mig_IsActive(),
            "commitPending must keep ingest fenced until the staged ledger is published")
        ingest := _DriverFuncBody("KL_IngestOnce")
        AssertContains(ingest, "KL_Mig_IsActive",
            "the real ingest entry point must consume the full scan-or-commit predicate")
    } finally {
        KL_Mig_Cancel()
        KL_Enc_SetEnabled(false)
    }
}

Test("KL_Mig: the ingest guard is raised for the duration of the pass", _KLMig_HoldsOffTheIngestWhileRewriting)





; =============================================================
; =============================================================
; ======= 8/ A tick landing mid-slice must not re-enter =======
; =============================================================
; =============================================================

; A slice does blocking file I/O, and AHK PUMPS MESSAGES during it — so the
; one-shot KL_Mig_Tick a pass schedules can dispatch while a slice is already
; running. The inner slice can reach the end of the pass, call _KL_Mig_Release
; (which sets writeFh back to "") and return into the outer one, whose very next
; line is writeFh.Write(...).
;
; That surfaced twice as an intermittent
;   This value of type "String" has no method named "Write"
; in this file, and passed on every re-run — the shape a re-entrancy bug always
; takes. This drives the re-entry deterministically instead of waiting for the
; scheduler to do it.
_KLMig_ReentrantSliceIsRefused() {
    _KLMig_Reset()
    _KLMig_WriteLedger(["alpha", "beta", "gamma"])
    KL_Enc_SetEnabled(true)
    try {
        KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false)

        ; Stand where a dispatched tick stands: a pass is active and a slice is
        ; notionally in flight.
        KLMigration.inSlice := true
        AssertTrue(KL_Mig_Slice(),
            "a slice entered while another is in flight must YIELD and report the pass is still alive, not run a second slice over the same handles")
        AssertTrue(KL_Mig_IsActive(),
            "and it must not have ended the pass")
        AssertTrue(IsObject(KLMigration.writeFh),
            "nor released the write handle the outer slice is about to use — releasing it is what turned the next Write into a call on a String")

        ; With the guard down the pass completes normally, so the refusal above
        ; is a yield and not a permanent stall.
        KLMigration.inSlice := false
        _KLMig_Drain()
        AssertFalse(KL_Mig_IsActive(), "the pass must still finish once the re-entrant window closes")
        AssertEqual("alpha", KL_Enc_Decrypt(_KLMig_FieldOf(FileRead(Keylogger.data_sql_path, "UTF-8"), 1, "text")),
            "and it must have converted the ledger exactly as an uninterrupted pass would")
    } finally {
        KLMigration.inSlice := false
        KL_Enc_SetEnabled(false)
    }
}

Test("KL_Mig: a tick landing mid-slice yields instead of re-entering", _KLMig_ReentrantSliceIsRefused)




; ============================================================================
; ============================================================================
; ======= 9/ Suspend, durable completion, and new-ledger posture =============
; ============================================================================
; ============================================================================

_KLMig_SuspendTickDoesNoIoAndResumeContinuesOnce() {
    global _KLMigTimers
    oldTimer := KLMigration.timer_fn
    _KLMig_Reset()
    _KLMig_WriteLedger(["alpha", "beta", "gamma"])
    KL_Enc_SetEnabled(true)
    KLMigration.timer_fn := _KLMig_RecordTimer
    _KLMigTimers := []
    try {
        AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false),
            "the lifecycle fixture must own an active resumable pass")
        AssertTrue(KL_Mig_OnSuspend(),
            "suspend must claim and disarm an active migration")
        _KLMigTimers := []
        readPos := KLMigration.readFh.Pos
        writePos := KLMigration.writeFh.Pos
        scanned := KLMigration.scanned
        converted := KLMigration.converted

        KL_Mig_Tick()
        AssertEqual(readPos, KLMigration.readFh.Pos,
            "a suspended tick must perform zero source-ledger reads")
        AssertEqual(writePos, KLMigration.writeFh.Pos,
            "a suspended tick must perform zero staging-ledger writes")
        AssertEqual(scanned, KLMigration.scanned,
            "a suspended tick must not consume a statement")
        AssertEqual(converted, KLMigration.converted,
            "a suspended tick must not run crypto or publish conversion progress")

        AssertTrue(KL_Mig_OnResume(),
            "resume must schedule the retained cursor exactly once")
        AssertEqual(1, _KLMigTimers.Length,
            "one resume transition must arm one continuation, not a timer fan-out")
        AssertEqual(-KL_MIG_SLICE_INTERVAL_MS, _KLMigTimers[1]["period"],
            "the resumed continuation must use the named slice interval")
        AssertFalse(KL_Mig_OnResume(),
            "a duplicate resume callback must not arm a second continuation")
        AssertEqual(1, _KLMigTimers.Length,
            "duplicate resume must leave the one scheduled continuation unchanged")

        _KLMigTimers[1]["callback"].Call()
        AssertFalse(KL_Mig_IsActive(),
            "the scheduled continuation must finish the retained pass")
        after := FileRead(Keylogger.data_sql_path, "UTF-8")
        AssertEqual("alpha", KL_Enc_Decrypt(_KLMig_FieldOf(after, 1, "text")),
            "resume must continue from the same migration and publish its result")
    } finally {
        KL_Mig_Cancel()
        KLMigration.timer_fn := oldTimer
        KL_Enc_SetEnabled(false)
    }
}

Test("KL_Mig lifecycle: suspended ticks do zero I/O and resume one continuation",
    _KLMig_SuspendTickDoesNoIoAndResumeContinuesOnce)

_KLMig_MarkerFailureRetainsCheapRetryAndNoSuccess() {
    global _KLMigTimers, _KLMigSuccesses
    oldTimer := KLMigration.timer_fn
    oldCommit := KLMigration.marker_commit_fn
    oldSuccess := KLMigration.success_fn
    _KLMig_Reset()
    _KLMig_WriteLedger(["durable secret"])
    KL_Enc_SetEnabled(true)
    KLMigration.timer_fn := _KLMig_RecordTimer
    KLMigration.marker_commit_fn := _KLMig_FailMarkerCommit
    KLMigration.success_fn := _KLMig_RecordSuccess
    _KLMigTimers := []
    _KLMigSuccesses := []
    try {
        AssertTrue(KL_Mig_Start(KL_MIG_MODE_ENCRYPT, false),
            "the marker-failure fixture must start a real ledger conversion")
        _KLMig_Drain()
        scanned := KLMigration.scanned
        AssertFalse(KL_Mig_IsActive(),
            "the safely published ledger no longer needs to block ingest")
        AssertEqual("on", KLMigration.pendingMarker,
            "failed marker commit must retain the ledger's known posture for retry")
        AssertEqual(0, _KLMigSuccesses.Length,
            "migration SUCCESS is forbidden until the marker commit is durable")
        AssertEqual("", KL_Mig_ReadMarker(),
            "a failed marker seam must not leave a false completion artifact")
        AssertTrue(_KLMigTimers.Length >= 1,
            "marker failure must retain an explicit retry callback")

        KLMigration.marker_commit_fn := 0
        AssertTrue(KL_Mig_RetryMarker(),
            "a later writable marker commit must finish without rescanning data.sql")
        AssertEqual("on", KL_Mig_ReadMarker(),
            "the retry must durably publish the posture")
        AssertEqual("", KLMigration.pendingMarker,
            "successful marker retry must retire its pending state")
        AssertEqual(scanned, KLMigration.scanned,
            "marker-only recovery must be O(1), never a second ledger proof scan")
        AssertEqual(1, _KLMigSuccesses.Length,
            "exactly one SUCCESS may close the original migration START")
        AssertEqual(scanned, _KLMigSuccesses[1]["scanned"],
            "the delayed SUCCESS must retain the original completion counters")
    } finally {
        KL_Mig_Cancel()
        KLMigration.timer_fn := oldTimer
        KLMigration.marker_commit_fn := oldCommit
        KLMigration.success_fn := oldSuccess
        KL_Enc_SetEnabled(false)
    }
}

Test("KL_Mig lifecycle: marker failure withholds SUCCESS and retains O(1) retry",
    _KLMig_MarkerFailureRetainsCheapRetryAndNoSuccess)

_KLMig_NewLedgerPublishesUniformPostureWithoutScan() {
    _KLMig_Reset()
    FileAppend("-- brand-new uniform ledger`n", Keylogger.data_sql_path, "UTF-8")
    KLMigration.scanned := 777
    AssertTrue(KL_Mig_RecordNewLedgerPosture(),
        "new-ledger bootstrap must commit posture metadata after the header")
    AssertEqual("off", KL_Mig_ReadMarker(),
        "a new uniform ledger must record the cipher posture already in force")
    AssertFalse(KL_Mig_SyncToPosture(),
        "matching creation metadata must take the O(1) no-scan path")
    AssertEqual(777, KLMigration.scanned,
        "new-ledger posture sync must not open or consume the ledger")
    AssertFalse(KL_Mig_IsActive(),
        "the O(1) path must not create a background migration job")
    bootstrap := _DriverFuncBody("KL_BootstrapDataSql")
    AssertContains(bootstrap, "KL_Mig_RecordNewLedgerPosture",
        "the real data.sql creation path must publish the tested O(1) posture fact")
}

Test("KL_Mig lifecycle: a new uniform ledger records posture and skips proof scan",
    _KLMig_NewLedgerPublishesUniformPostureWithoutScan)

_KLMig_DriverLifecycleOwnsSuspendAndResume() {
    enter := _DriverFuncBody("Ergopti_OnSuspendEnter")
    resume := _DriverFuncBody("Ergopti_OnSuspendResume")
    boot := _DriverFuncBody("KL_Init")
    AssertContains(enter, "KL_Mig_OnSuspend",
        "the native Suspend reactor must disarm migration I/O explicitly")
    AssertContains(resume, "KL_Mig_OnResume",
        "the resume reactor must replay the retained migration owner")
    AssertContains(boot, "KL_Mig_RequestPostureSync",
        "boot posture work must be lifecycle-owned before its delayed timer is armed")
}

Test("KL_Mig lifecycle: driver suspend/resume owns every migration timer",
    _KLMig_DriverLifecycleOwnsSuspendAndResume)
