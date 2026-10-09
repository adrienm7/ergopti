; modules/keylogger/keylogger_constants.ahk

; ==============================================================================
; MODULE: Keylogger Runtime Constants
; DESCRIPTION: Shared limits for the resident journal and its ingestion tests.
; ==============================================================================

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
