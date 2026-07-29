; tests/unit/test_prefetch_dbg_write_level_gated.ahk

; ==============================================================================
; MODULE: Prefetch Debug Log Gate (prefetch-dbg-write-unconditional)
; DESCRIPTION:
; KLPF_DbgWrite appended six lines per projection with no level gate. A worker
; projection is spawned on every ingest tick while a metrics dashboard is open
; (~4 300/day), and the file it writes -- <ConfigDir>\autohotkey\logs\
; prefetch_debug.log -- does not match _LoggerPurgeOldLogs' dated
; ErgoptiPlus_*.log pattern, so nothing rotates it and nothing ages it out. It
; grows for the lifetime of the install, paying an open+write+close NTFS/AV tax
; per line, and the bare try around the FileAppend hides any failure.
;
; The identical concern in the same pipeline was already fixed for its sibling
; KLR_PrefetchDebug, which early-returns on !LoggerIsDebugEnabled(). This is the
; untouched twin.
;
; ROOT CAUSE ENCODED: a diagnostic sink in this pipeline must produce no I/O at
; all below the DEBUG level. Asserted behaviourally (the file must not appear)
; rather than by grepping for the gate's spelling, and looped over both twins so
; the one that was already correct cannot regress either.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Level control helper =======
; =======================================
; =======================================

; Force the logger's cached fast-path flags to a given minimum level and return
; the previous one so the caller can restore it. Goes through the same refresh
; the driver uses, so the test cannot drift from the real gate.
_PDW_SetMinLevel(Level) {
	global LOGGER_MIN_LEVEL
	Previous := LOGGER_MIN_LEVEL
	LOGGER_MIN_LEVEL := Level
	_LoggerRefreshFastFlags()
	return Previous
}





; ===================================================
; ===================================================
; ======= 2/ The sinks are silent below DEBUG =======
; ===================================================
; ===================================================

_PDW_AssertSinkIsLevelGated(Name, Sink) {
	Path := A_Temp . "\ergopti_" . Name . "_probe_" . A_TickCount . ".log"
	try FileDelete(Path)
	Restore := _PDW_SetMinLevel("INFO")
	try {
		Sink(Path, "must-not-be-written")
		Assert(!FileExist(Path),
			Name . " must write nothing while the log level is above DEBUG: it emits six "
			. "lines per projection, a projection runs on every ingest tick while a "
			. "dashboard is open, and _LoggerPurgeOldLogs never matches the file it writes "
			. "-- so it grows unbounded and is never rotated or aged out")

		_PDW_SetMinLevel("DEBUG")
		Sink(Path, "must-be-written")
		Assert(FileExist(Path),
			Name . " must still write when DEBUG is enabled -- a gate that silenced the sink "
			. "outright would delete the diagnostics rather than bound them")
	} finally {
		_PDW_SetMinLevel(Restore)
		try FileDelete(Path)
	}
}

; Both diagnostic sinks of the prefetch/reader pipeline: KLPF_DbgWrite is the one
; that was unconditional, KLR_PrefetchDebug the sibling that was already gated and
; must stay that way.
_PDW_PrefetchSinksAreLevelGated() {
	_PDW_AssertSinkIsLevelGated("KLPF_DbgWrite", KLPF_DbgWrite)
	_PDW_AssertSinkIsLevelGated("KLR_PrefetchDebug", KLR_PrefetchDebug)
}

Test("prefetch: the worker diagnostic sinks write nothing below DEBUG (prefetch-dbg-write-unconditional)",
	_PDW_PrefetchSinksAreLevelGated)
