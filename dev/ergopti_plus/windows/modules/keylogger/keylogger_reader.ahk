; modules/keylogger/keylogger_reader.ahk

; ==============================================================================
; MODULE: Keylogger SQLite Reader (AHK) — orchestrator shim
; DESCRIPTION:
; Entry-point for the Windows SQLite reader subsystem. Declares the public API
; consumed by keylogger_prefetch.ahk and the metrics webview backends, which
; orchestrates the three sub-modules below:
;   keylogger_reader_db.ahk          — constants, schema loading, in-memory DB
;                                      construction, incremental update, and
;                                      aggregate rebuilding.
;   keylogger_reader_manifest.ahk    — projects agg_* tables into the legacy
;                                      manifest[date][app] Map shape.
;   keylogger_reader_ngrams.ahk      — projects ngram_* tables into the n-gram
;                                      Maps and today_idx JSON shapes.
;
; FEATURES & RATIONALE:
; 1. In-memory database: opening a `:memory:` SQLite handle and exec()-ing
;    schema + data.sql is fast (10-50 ms for a few hundred kB) and avoids
;    creating a stale db.sqlite file on disk that would diverge from the
;    canonical text source.
; 2. Cross-device aggregation: the dashboard JS expects a single global
;    stat per (date, app); the SQL projection sums across every
;    device_id row that survived the load.
; 3. Format-stable: the emitted manifest / today_idx shapes match
;    sqlite_reader.lua bit-for-bit so the JS can read either source
;    without a switch.
; 4. Fail-fast: a missing schema.sql, an invalid data.sql, or an absent
;    winsqlite3.dll all surface immediately as Logger.error and return
;    an empty manifest — the dashboard will show "no data" rather than
;    a half-projected blob.
; ==============================================================================

#Requires Autohotkey v2.0+

#Include keylogger_reader_db.ahk
#Include keylogger_reader_manifest.ahk
#Include keylogger_reader_ngrams.ahk
