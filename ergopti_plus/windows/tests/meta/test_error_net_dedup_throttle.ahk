; tests/meta/test_error_net_dedup_throttle.ahk

; ==============================================================================
; MODULE: Error-Net Dedup Throttle Meta Test
; DESCRIPTION:
; Regression guard for "error-handler-no-dedup-throttle": ErgoptiGlobalErrorHandler
; had no rate limiting of its own. Any repeatedly-throwing callback OUTSIDE
; HookDispatcher.Dispatch's per-signature _err_cache throttle (a SetTimer
; callback, a hotkey a user holds/auto-repeats) re-ran the full WMI/
; healthcheck/git crash-report pipeline (SetTimer(_ErgoptiDeferredCrashReport...))
; on EVERY single occurrence, backing up the one thread that also serves every
; keystroke. The user-facing surface is the error window, whose own policy
; (_shared/modules/diagnostics/error_policy.json) deduplicates what it shows,
; so the handler raises no toast of its own.
;
; The fix mirrors HookDispatcher.Dispatch's own _err_cache pattern: a
; per-signature (message + location), TTL-based dedup cache that skips the
; expensive deferred report when the same fault fired again within
; ERROR_NET_DEDUP_TTL_MS — the cheap modifier release + LoggerError still run
; every time, so nothing is silently dropped from the logs.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================================
; ==========================================================
; ======= 1/ Dedup cache guards the expensive path =========
; ==========================================================
; ==========================================================

_ENDT_HandlerHasDedupCache() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler() must exist in infra/error_net.ahk")
	Assert(InStr(Body, "static") > 0 and InStr(Body, "Map()") > 0,
		"ErgoptiGlobalErrorHandler must declare a static per-signature dedup cache (Map()), mirroring HookDispatcher.Dispatch's _err_cache pattern (error-handler-no-dedup-throttle)")
}
Test("meta error-net: ErgoptiGlobalErrorHandler declares a static dedup cache (error-handler-no-dedup-throttle)", _ENDT_HandlerHasDedupCache)

_ENDT_DedupGuardsTheCrashReport() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler() must exist in infra/error_net.ahk")

	CacheCheckIdx := InStr(Body, "_geh_dedup_map.Has(")
	Assert(CacheCheckIdx > 0,
		"ErgoptiGlobalErrorHandler must check the dedup cache before doing the expensive work (error-handler-no-dedup-throttle)")

	SetTimerIdx := InStr(Body, "SetTimer(_ErgoptiDeferredCrashReport")
	Assert(SetTimerIdx > 0, "ErgoptiGlobalErrorHandler must schedule the deferred crash report")
	Assert(InStr(_StripFullLineComments(Body), "NotifierSend(") = 0,
		"ErgoptiGlobalErrorHandler must raise no toast of its own: the error window surfaces the logged ERROR "
		. "under its own deduplication, and a second surface would double every error (error-handler-no-dedup-throttle)")

	Assert(CacheCheckIdx < SetTimerIdx,
		"The dedup cache check must run BEFORE SetTimer(_ErgoptiDeferredCrashReport...) so a repeatedly-throwing "
		. "callback cannot re-run the ~100-500 ms WMI/healthcheck/git pipeline on every occurrence and back up the "
		. "keystroke thread (error-handler-no-dedup-throttle)")
}
Test("meta error-net: dedup cache check gates the deferred crash report (error-handler-no-dedup-throttle)", _ENDT_DedupGuardsTheCrashReport)

; An alt_gr tap-hold presses SC138, not RAlt, on a Kana-style layout. The crash
; net releases logically stuck modifiers after an uncaught error; a sweep that
; only names RAlt would leave that layout's AltGr hold stranded
; (kana-altgr-hold-2026-09-25).
_ENDT_StuckSweepKnowsTheLayoutAltGr() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler() must exist in infra/error_net.ahk")
	AltGrPos := InStr(Body, "StuckCandidates.Push(KS_AltGrKeyName())")
	SweepPos := InStr(Body, "for _, ModKey in StuckCandidates")
	Assert(AltGrPos > 0,
		"the stuck-modifier sweep must add the layout's AltGr key when it is not RAlt")
	Assert(SweepPos > AltGrPos,
		"the sweep must iterate the candidate list that includes the layout's AltGr key")
}
Test("meta error-net: the stuck-modifier sweep releases the layout's AltGr (kana-altgr-hold-2026-09-25)",
	_ENDT_StuckSweepKnowsTheLayoutAltGr)
