; tests/meta/test_error_net_dedup_throttle.ahk

; ==============================================================================
; MODULE: Error-Net Dedup Throttle Meta Test
; DESCRIPTION:
; Regression guard for "error-handler-no-dedup-throttle": ErgoptiGlobalErrorHandler
; had no rate limiting of its own. Any repeatedly-throwing callback OUTSIDE
; HookDispatcher.Dispatch's per-signature _err_cache throttle (a SetTimer
; callback, a hotkey a user holds/auto-repeats) re-ran the full WMI/
; healthcheck/git crash-report pipeline (SetTimer(_ErgoptiDeferredCrashReport...))
; and the NotifierSend toast on EVERY single occurrence, backing up the one
; thread that also serves every keystroke.
;
; The fix mirrors HookDispatcher.Dispatch's own _err_cache pattern: a
; per-signature (message + location), TTL-based dedup cache that skips the
; expensive deferred report + toast when the same fault fired again within
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
	Assert(Body != "", "ErgoptiGlobalErrorHandler() must exist in lib/error_net.ahk")
	Assert(InStr(Body, "static") > 0 and InStr(Body, "Map()") > 0,
		"ErgoptiGlobalErrorHandler must declare a static per-signature dedup cache (Map()), mirroring HookDispatcher.Dispatch's _err_cache pattern (error-handler-no-dedup-throttle)")
}
Test("meta error-net: ErgoptiGlobalErrorHandler declares a static dedup cache (error-handler-no-dedup-throttle)", _ENDT_HandlerHasDedupCache)

_ENDT_DedupGuardsSetTimerAndNotifier() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler() must exist in lib/error_net.ahk")

	CacheCheckIdx := InStr(Body, "_geh_dedup_map.Has(")
	Assert(CacheCheckIdx > 0,
		"ErgoptiGlobalErrorHandler must check the dedup cache before doing the expensive work (error-handler-no-dedup-throttle)")

	SetTimerIdx := InStr(Body, "SetTimer(_ErgoptiDeferredCrashReport")
	NotifierIdx := InStr(Body, "NotifierSend(")
	Assert(SetTimerIdx > 0, "ErgoptiGlobalErrorHandler must schedule the deferred crash report")
	Assert(NotifierIdx > 0, "ErgoptiGlobalErrorHandler must surface the error via NotifierSend")

	Assert(CacheCheckIdx < SetTimerIdx,
		"The dedup cache check must run BEFORE SetTimer(_ErgoptiDeferredCrashReport...) so a repeatedly-throwing "
		. "callback cannot re-run the ~100-500 ms WMI/healthcheck/git pipeline on every occurrence and back up the "
		. "keystroke thread (error-handler-no-dedup-throttle)")
	Assert(CacheCheckIdx < NotifierIdx,
		"The dedup cache check must run BEFORE NotifierSend(...) so a repeatedly-throwing callback cannot spam the "
		. "tray toast on every occurrence (error-handler-no-dedup-throttle)")
}
Test("meta error-net: dedup cache check gates both the deferred crash report and the toast (error-handler-no-dedup-throttle)", _ENDT_DedupGuardsSetTimerAndNotifier)
