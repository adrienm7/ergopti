; tests/meta/test_crash_report_not_suppressed.ahk

; ==============================================================================
; MODULE: Crash-Report Suppression Meta Test
; DESCRIPTION:
; The error net throttles by fault signature so a storm of identical crashes
; produces one report, not hundreds. The throttle entry was recorded BEFORE the
; report was attempted — it has to be, since the handler must decide whether to
; proceed before it can know the outcome — and nothing ever rolled it back.
;
; So one failed write suppressed every recurrence of that signature for the full
; TTL. A disk-full, read-only or disconnected config directory turned "throttle
; the duplicates" into "report nothing at all", and the only trace was a DEBUG
; throttle line plus a toast that looks like an ordinary error notification.
; That is the mechanism behind the field evidence of twelve uncaught errors
; producing zero crash reports.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE — a throttle recorded for a report that was never
;    written must be RELEASED — not "a crash report exists somewhere".
; 2. Pins the outcome contract that makes the release possible:
;    CrashReport_PromptUser must tell its caller whether anything was saved.
; 3. Pins that the report builder degrades per FIELD. Its input comes from
;    _HealthCheck_Collect, which substitutes an empty Map when a collector
;    throws, so an unguarded read there aborts the whole report — the exact
;    failure the healthcheck's own degradation was added to prevent.
;
; SCOPE: source introspection of lib/error_net.ahk and lib/crash_reporter.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ A failed report releases the throttle ==
; ==================================================
; ==================================================

_CRNS_PromptReportsItsOutcome() {
	Body := _DriverFuncBody("CrashReport_PromptUser")
	Assert(Body != "", "CrashReport_PromptUser() must exist")
	Assert(InStr(Body, "return true") > 0 and InStr(Body, "return false") > 0,
		"CrashReport_PromptUser must report whether a file was actually written — without that its caller cannot tell a saved report from a silently failed one, and the throttle it already recorded can never be rolled back")
}

_CRNS_ThrottleIsReleasedOnFailure() {
	Handler := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Handler != "", "ErgoptiGlobalErrorHandler() must exist")

	; The releaser must be handed to the deferred report. A static throttle map
	; cannot be reached from the timer callback any other way, and promoting it
	; to a global to work around that moves driver state for a diagnostic.
	Assert(InStr(Handler, "ReleaseDedup") > 0,
		"the handler must pass a releaser to the deferred crash report, so a report that fails to save can clear its own throttle entry")
	Assert(InStr(Handler, "_geh_dedup_map.Delete(") > 0,
		"the releaser must delete the signature from the throttle cache")

	Deferred := _DriverFuncBody("_ErgoptiDeferredCrashReport")
	Assert(Deferred != "", "_ErgoptiDeferredCrashReport() must exist")
	Assert(InStr(Deferred, "!CrashReport_PromptUser(") > 0,
		"the deferred report must branch on whether the report was saved")
	Assert(InStr(Deferred, "ReleaseDedup()") > 0,
		"the throttle must be released when the report was not written — otherwise a single failed save silences every recurrence of that fault for the whole TTL")

	; Both failure routes matter: a save that returns empty, and a build that
	; throws. The catch was already there; it must release too.
	CatchPos := InStr(Deferred, "catch as")
	Assert(CatchPos > 0, "the deferred report must keep its catch")
	Assert(InStr(SubStr(Deferred, CatchPos), "ReleaseDedup") > 0,
		"a crash-report build that THROWS must also release the throttle, not just one that returns empty")
}




; ==================================================
; ==================================================
; ======= 2/ The report degrades field by field ====
; ==================================================
; ==================================================

_CRNS_BuilderToleratesADegradedHealthcheck() {
	Body := _DriverFuncBody("CrashReport_Build")
	Assert(Body != "", "CrashReport_Build() must exist")

	; _HealthCheck_Collect substitutes an EMPTY Map when a collector throws, and
	; the healthcheck result always carries the "sys" key — so a .Has() test
	; alone is always true and the fallback probe below it was dead code.
	Assert(InStr(Body, 'HC["sys"].Count > 0') > 0,
		"the sys fallback must test the Map is non-EMPTY, not merely present — _HealthCheck_Collect degrades a failed collector to Map(), which .Has() cannot distinguish, leaving the fallback unreachable and every Sys read about to throw")

	; A partially-populated Sys must degrade one field, not abort the report.
	Assert(RegExMatch(Body, 'Sys\["(os_name|cpu_name|locale)"\]') == 0,
		"system fields must be read with Sys.Get(key, default) — a raw Map read throws on a missing key, which aborts CrashReport_Build inside the error net's catch: logged, never reported")
	Assert(InStr(Body, 'Sys.Get("os_name"') > 0,
		"prerequisite: the system fields are still read")
}


Test("meta crash-report: the prompt reports whether anything was saved",
	_CRNS_PromptReportsItsOutcome)
Test("meta crash-report: a failed report releases its throttle entry",
	_CRNS_ThrottleIsReleasedOnFailure)
Test("meta crash-report: the builder tolerates a degraded healthcheck",
	_CRNS_BuilderToleratesADegradedHealthcheck)
