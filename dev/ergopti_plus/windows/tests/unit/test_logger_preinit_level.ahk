; tests/unit/test_logger_preinit_level.ahk

; ==============================================================================
; MODULE: Logger Pre-init Level Tests
; DESCRIPTION:
; Regression guard for logger-preinit-level-drop.
;
; The per-level fast-path flags are cached, and LoggerDebug / LoggerTrace /
; LoggerDone return at that cached flag BEFORE reaching _LoggerEmit — so they
; never reach the unconditional "queue it, the log path is not resolved yet"
; push that was built specifically to keep pre-init messages alive. Reading
; _LoggerEmit alone therefore says the problem cannot exist; the drop happens one
; level up, in an optimisation added later and never reconciled with the queueing
; guarantee.
;
; The consequence was measurable in production: with log_level = "DEBUG" in the
; config, the TRACE/DONE pair emitted by I18nInit appeared ZERO times across 15
; days of daily logs, while the structurally identical pair emitted a few source
; lines later — but after LoggerInit — appeared on every session. The whole boot
; window (the #Include graph's top-level code, the onboarding wizard, the config
; parse, I18nInit) was invisible at DEBUG granularity.
;
; The fix is two-sided and both sides are pinned here. The pre-init defaults fail
; OPEN, because a queued line can still be dropped later whereas a never-emitted
; one cannot be recovered; and LoggerInit then applies the configured level to
; the queue retroactively, so the symmetric failure — log_level = "ERROR" being
; handed a boot's worth of DEBUG/INFO noise — does not appear in its place.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ The pre-init default fails open =======
; ==================================================
; ==================================================

_LPIL_PreInitDefaultIsPermissive() {
	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "global\s+_LOGGER_DEBUG_ENABLED\s*:=\s*True") > 0,
		"the pre-init DEBUG flag must default to True: it gates LoggerDebug/LoggerTrace/LoggerDone before _LoggerEmit is reached, so a restrictive default DISCARDS every boot-phase line instead of queueing it, and a line that was never emitted cannot be recovered once the configured level is known (logger-preinit-level-drop)")
	Assert(RegExMatch(Src, "global\s+_LOGGER_DEBUG_ENABLED\s*:=\s*False") == 0,
		"no declaration may reinstate a restrictive pre-init DEBUG default")
}
Test("logger: the pre-init level flags fail open (logger-preinit-level-drop)", _LPIL_PreInitDefaultIsPermissive)





; ===============================================
; ===============================================
; ======= 2/ LoggerInit narrows the queue =======
; ===============================================
; ===============================================

; Fail-open is only honest if the configured level is applied afterwards, and
; only if it is applied BEFORE the queue is drained to disk.
_LPIL_InitFiltersBeforeDraining() {
	Body := _DriverFuncBody("LoggerInit")
	Assert(Body != "", "LoggerInit() must exist in the driver source")

	RefreshPos := InStr(Body, "_LoggerRefreshFastFlags()")
	FilterPos := InStr(Body, "_LoggerDropPreInitBelowLevel()")
	DrainPos := InStr(Body, "_LoggerFlush(false)")

	Assert(RefreshPos > 0, "prerequisite: LoggerInit still resolves the configured level via _LoggerRefreshFastFlags()")
	Assert(DrainPos > 0, "prerequisite: LoggerInit still drains the pre-init queue to disk via _LoggerFlush(false)")
	Assert(FilterPos > 0,
		"LoggerInit must apply the configured level to the pre-init queue: the permissive boot defaults would otherwise hand a user running at log_level = ERROR a full boot of DEBUG and INFO lines (logger-preinit-level-drop)")
	Assert(FilterPos > RefreshPos,
		"the pre-init queue can only be filtered AFTER the configured level has been resolved")
	Assert(FilterPos < DrainPos,
		"the pre-init queue must be filtered BEFORE it is drained to disk, otherwise the sub-threshold lines are already written")
}
Test("logger: LoggerInit applies the configured level to the pre-init queue before draining it (logger-preinit-level-drop)", _LPIL_InitFiltersBeforeDraining)





; =====================================================
; =====================================================
; ======= 3/ The filter keeps exactly the right =======
; =====================================================
; =====================================================

_LPIL_FilterKeepsAtOrAboveConfiguredLevel() {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, LOGGER_MIN_LEVEL
	SavePending := _LOGGER_PENDING
	SaveErrors := _LOGGER_PENDING_ERRORS
	SaveLevel := LOGGER_MIN_LEVEL
	try {
		Boot := [
			"",
			"===== 2026-07-29 12:00:00:000 - ErgoptiPlus session opened =====",
			"2026-07-29 12:00:00:001 [DEBUG] [registry] Adapter registered.",
			"2026-07-29 12:00:00:002 [TRACE] [i18n] Initialising i18n" . Chr(0x2026),
			"2026-07-29 12:00:00:003 [INFO] [boot] Configuration loaded.",
			"2026-07-29 12:00:00:004 [WARNING] [boot] Unknown key ignored.",
			"2026-07-29 12:00:00:005 [ERROR] [boot] Adapter failed to load."
		]

		; At DEBUG, nothing may be discarded - this is exactly the case that was
		; broken in production, where the configured level was DEBUG and the
		; boot-phase TRACE/DONE pairs never reached the log at all.
		_LOGGER_PENDING := Boot.Clone()
		_LOGGER_PENDING_ERRORS := []
		LOGGER_MIN_LEVEL := "DEBUG"
		_LoggerRefreshFastFlags()
		_LoggerDropPreInitBelowLevel()
		Assert(_LOGGER_PENDING.Length == Boot.Length,
			"at log_level = DEBUG every pre-init line must survive (kept " . _LOGGER_PENDING.Length . " of " . Boot.Length . ") (logger-preinit-level-drop)")

		; At ERROR, the permissive boot defaults must not leak: everything below
		; the configured level goes, and the structural lines stay.
		_LOGGER_PENDING := Boot.Clone()
		_LOGGER_PENDING_ERRORS := []
		LOGGER_MIN_LEVEL := "ERROR"
		_LoggerRefreshFastFlags()
		_LoggerDropPreInitBelowLevel()
		Assert(_LOGGER_PENDING.Length == 3,
			"at log_level = ERROR only the ERROR line and the two structural lines (blank separator + session banner) may survive, got " . _LOGGER_PENDING.Length)
		Kept := ""
		for _, Line in _LOGGER_PENDING
			Kept .= Line . "`n"
		Assert(InStr(Kept, "[ERROR]") > 0, "the ERROR line must survive a log_level = ERROR filter")
		Assert(InStr(Kept, "session opened") > 0,
			"the session banner carries no level and must never be filtered out - it is what makes a log readable")
		Assert(InStr(Kept, "[DEBUG]") == 0 and InStr(Kept, "[TRACE]") == 0,
			"boot-phase DEBUG/TRACE lines must not reach the log of a user who configured log_level = ERROR")
		Assert(InStr(Kept, "[INFO]") == 0 and InStr(Kept, "[WARNING]") == 0,
			"boot-phase INFO/WARNING lines must not reach the log of a user who configured log_level = ERROR")
	} finally {
		_LOGGER_PENDING := SavePending
		_LOGGER_PENDING_ERRORS := SaveErrors
		LOGGER_MIN_LEVEL := SaveLevel
		_LoggerRefreshFastFlags()
	}
}
Test("logger: the pre-init queue filter keeps exactly the lines at or above the configured level (logger-preinit-level-drop)", _LPIL_FilterKeepsAtOrAboveConfiguredLevel)
