; modules/keylogger/keylogger_walker.ahk

; ==============================================================================
; MODULE: Keylogger Aggregation Walker (AHK) — orchestrator shim
; DESCRIPTION:
; Entry-point for the stateful walker subsystem. Includes the three sub-modules
; that together reproduce the Mac-side aggregator.lua byte-for-byte:
;   keylogger_walker_core.ahk    — constants, timing loader, KLW class, batch
;                                  initialiser, inner-loop helpers, and the
;                                  burst/session finalizers.
;   keylogger_walker_events.ahk  — the typing entry walker (hot inner loop) and
;                                  the non-typing event aggregators (app switch,
;                                  window switch, system events).
;   keylogger_walker_sql.ahk     — SQL escaping helpers, KLW_BuildBatchSql
;                                  (drains the batch into one SQL string), and
;                                  the context serialise/restore/rollover helpers.
;
; DESIGN:
; All functions and the KLW / KLWConst classes are global in AHK v2, so the
; three sub-files see each other's symbols without any explicit passing of state.
; The include order mirrors the dependency graph: core first (defines KLWConst,
; KLW, and all helper globals), events second (calls core helpers), sql last
; (calls KLW_ResetBatch from core and KLW_GetMap from core).
; ==============================================================================

#Requires Autohotkey v2.0+

#Include keylogger_walker_core.ahk
#Include keylogger_walker_events.ahk
#Include keylogger_walker_sql.ahk
