; tests/meta/test_kl_stop_shutdown_ingest_forced.ahk

; ==============================================================================
; MODULE: Shutdown Ingest Force Regression (kl-stop-ingest-defeated-by-idle-guard)
; DESCRIPTION:
; The kl-stop-flush-defeated-by-suspend fix taught KL_IngestOnce's A_IsSuspended
; guard to bypass on Keylogger._shutting_down, but the SIBLING early return one
; line below it -- the INGEST_IDLE_MS typing-idle defer -- was left untouched,
; and KL_Stop still called KL_IngestOnce() with no argument, so force defaulted
; to false. Quitting or reloading within 500 ms of a keystroke therefore
; returned ok:true / reason "typing" BEFORE the pending drain. _pending_entries
; is RAM-only (KL_AppendLog is its sole writer), so the entire closing batch --
; the final typing buffer, session_end, idle_end, the last roi_snapshot -- died
; with the process milliseconds later, leaving events_session with a
; session_start and no session_end. Reload is the driver's standard
; apply-settings path, so this fired routinely.
;
; ROOT CAUSE ENCODED: deferring only makes sense while a next tick still exists.
; Every early return in KL_IngestOnce that sits ahead of the pending drain must
; therefore be shutdown-aware, and the shutdown call site must force the pass.
;
; Meta-static because the headless harness does not load
; modules/keylogger/keylogger.ahk (it registers live hooks at load time).
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Source scan helper =======
; =====================================
; =====================================

; First source line of Body containing Needle. Comments are already stripped by
; _DriverFuncBody, so an explanatory line can never satisfy an assertion here.
_KSSI_LineContaining(Body, Needle) {
	for Line in StrSplit(Body, "`n", "`r")
		if InStr(Line, Needle)
			return Line
	return ""
}





; =================================================
; =================================================
; ======= 2/ Every pre-drain guard bypasses =======
; =================================================
; =================================================

; Looped over the CLASS of guards rather than the one that broke: both early
; returns that stand between the caller and the RAM queue discard the same batch,
; and only one of them had been taught about shutdown.
_KSSI_PreDrainGuardsAreShutdownAware() {
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(Body != "", "KL_IngestOnce must exist")

	Guards := Map(
		"A_IsSuspended",
			"the pause guard already bypasses on _shutting_down",
		"KeylogConst.INGEST_IDLE_MS",
			"the typing-idle defer must bypass on _shutting_down too -- at shutdown there is "
			. "no next tick to defer to, so it discards the batch instead of postponing it, "
			. "and _pending_entries exists only in RAM"
	)
	for Needle, Why in Guards {
		Line := _KSSI_LineContaining(Body, Needle)
		Assert(Line != "",
			"prerequisite: KL_IngestOnce must still guard on " . Needle)
		Assert(InStr(Line, "_shutting_down") > 0,
			"the '" . Needle . "' early return in KL_IngestOnce must carry a _shutting_down "
			. "bypass -- " . Why)
	}
}

Test("keylogger: every pre-drain guard in KL_IngestOnce bypasses on shutdown (kl-stop-ingest-defeated-by-idle-guard)",
	_KSSI_PreDrainGuardsAreShutdownAware)





; ===================================================
; ===================================================
; ======= 3/ The shutdown call site forces it =======
; ===================================================
; ===================================================

_KSSI_ShutdownIngestIsForcedAndDrainsOut() {
	Body := _DriverFuncBody("KL_Stop")
	Assert(Body != "", "KL_Stop must exist")

	Assert(RegExMatch(Body, "KL_IngestOnce\(\s*true") > 0,
		"KL_Stop must call KL_IngestOnce(true): with force=false the INGEST_IDLE_MS guard "
		. "returns before the _pending_entries drain, and that queue is RAM-only, so quitting "
		. "or reloading within 500 ms of a keystroke discarded the whole closing batch "
		. "including session_end and idle_end")
	Assert(RegExMatch(Body, "KL_IngestOnce\(\s*\)") = 0,
		"no unforced KL_IngestOnce() may remain in KL_Stop -- that is exactly the call that "
		. "was silently deferred at exit")

	Assert(InStr(Body, "SHUTDOWN_INGEST_MAX_PASSES") > 0,
		"KL_Stop must walk the ingest to EOF under a bounded pass count: each pass drains at "
		. "most INGEST_BATCH_LINES and the RAM queue is only flushed once the reader reaches "
		. "EOF, so a single forced pass still loses the closing batch whenever a backlog "
		. "exists -- and an unbounded loop would stall a Reload")
}

Test("keylogger: KL_Stop forces the shutdown ingest and drains it out (kl-stop-ingest-defeated-by-idle-guard)",
	_KSSI_ShutdownIngestIsForcedAndDrainsOut)
