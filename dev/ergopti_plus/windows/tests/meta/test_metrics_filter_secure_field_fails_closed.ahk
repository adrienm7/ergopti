; tests/meta/test_metrics_filter_secure_field_fails_closed.ahk

; ==============================================================================
; MODULE: Secure-field Caller Direction (metrics-filter-secure-field-fails-open)
; DESCRIPTION:
; MF_ShouldFilter's secure-field layer seeded its verdict with the PERMISSIVE
; value -- is_pw := false -- and only the success path of the following bare try
; could make it restrictive. Any throw inside the detector chain therefore came
; out as "ordinary field" and the keystroke was persisted, indistinguishable
; from a detector that had run cleanly: the bare try had no catch and no warning,
; so a permanently degraded detector looked exactly like a healthy one.
;
; The driver's own convention for this very predicate is the opposite. The LLM
; caller is pinned by _DPFG_CallerFailureFailsClosed to set IsPw := true BEFORE
; `try IsPw := SFD_IsSecureField()`, and the sibling guard 40 lines down the same
; call chain -- KL_AppendLog's catch -- sets filtered := true and warns. The
; keylogger caller, which writes characters to disk rather than to a local model,
; did the reverse, and its bare inner try actively swallowed the error before
; that outer fail-closed backstop could see it.
;
; ROOT CAUSE ENCODED: a privacy verdict must be seeded restrictive before the
; call that can throw, at BOTH callers of the pair, and the degraded state must
; be visible in the log. Deliberately mirrors the LLM assertion so the two
; callers of the same guarantee cannot drift.
;
; Meta-static because the headless harness loads neither lib/metrics/
; metrics_filters.ahk nor modules/keylogger/keylogger_password.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ Both callers seed the verdict restrictive =======
; ============================================================
; ============================================================

; Looped over the CLASS of callers: one of the two was already right, and the
; failure mode was precisely that the other was written the other way round.
_MFSF_SecureFieldCallersFailClosed() {
	Callers := [
		["MF_ShouldFilter", "is_pw := true", "try {", "KL_IsFocusedFieldPassword()",
			"it persists characters to events_typing.text in data.sql, so it cannot be laxer "
			. "than the LLM caller its own test file already pins"],
		["LLM_Engine_FirePrediction", "IsPw := true", "try IsPw := SFD_IsSecureField()",
			"SFD_IsSecureField()",
			"a throwing adapter must not leak LLM context -- this is the caller the shipped "
			. "guard already covers, and it must stay covered"]
	]

	for _, Caller in Callers {
		Name       := Caller[1]
		DefaultLit := Caller[2]
		TryLit     := Caller[3]
		CallLit    := Caller[4]
		Why        := Caller[5]

		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist")

		CallPos := InStr(Body, CallLit)
		Assert(CallPos > 0,
			"prerequisite: " . Name . " must still call " . CallLit)

		DefaultPos := InStr(Body, DefaultLit)
		Assert(DefaultPos > 0 && DefaultPos < CallPos,
			Name . " must seed its secure-field verdict restrictive (" . DefaultLit . ") "
			. "BEFORE the detector call that can throw -- " . Why
			. " (metrics-filter-secure-field-fails-open)")

		TryPos := InStr(Body, TryLit)
		Assert(TryPos > 0 && TryPos > DefaultPos && TryPos <= CallPos,
			Name . " must keep the detector call inside a try that follows the restrictive "
			. "default, or a throw would propagate onto the keystroke path instead of "
			. "failing closed")
	}
}

Test("privacy: both secure-field callers seed their verdict closed before the try (metrics-filter-secure-field-fails-open)",
	_MFSF_SecureFieldCallersFailClosed)





; =================================================
; =================================================
; ======= 2/ A degraded detector is visible =======
; =================================================
; =================================================

; Fail-closed silently is still a bug: with no catch and no log line, "UIA is
; permanently unavailable on this machine" and "this one field is a password"
; produce byte-identical behaviour, so the metrics simply stop and nobody knows
; why (conventions 5.3).
_MFSF_DegradedDetectorIsLogged() {
	Body := _DriverFuncBody("MF_ShouldFilter")
	Assert(Body != "", "MF_ShouldFilter must exist")
	CallPos := InStr(Body, "KL_IsFocusedFieldPassword()")
	Assert(CallPos > 0, "prerequisite: the detector is still called")

	Tail := SubStr(Body, CallPos)
	Assert(InStr(Tail, "catch") > 0,
		"the secure-field try must have a catch -- a bare try swallows the error before "
		. "KL_AppendLog's own fail-closed catch can see it")
	Assert(InStr(Tail, "LoggerWarn") > 0,
		"and that catch must warn, so a permanently degraded detector stops looking exactly "
		. "like a healthy one that keeps meeting password fields")
}

Test("privacy: a throwing secure-field detector is logged, not just absorbed (metrics-filter-secure-field-fails-open)",
	_MFSF_DegradedDetectorIsLogged)
