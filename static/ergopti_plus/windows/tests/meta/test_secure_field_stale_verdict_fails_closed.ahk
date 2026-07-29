; tests/meta/test_secure_field_stale_verdict_fails_closed.ahk

; ==============================================================================
; MODULE: Secure-field Expired-verdict Fail-closed Guard
; DESCRIPTION:
; SFD_IsSecureField caches one verdict keyed by the focused window handle. On a
; key match it used to return that verdict unconditionally — including long
; after SFD_FIELD_CACHE_TTL_MS had elapsed, and while the refreshing UIA probe
; was still in flight.
;
; That key does not identify what the verdict describes. Chromium and Electron
; host every field of a page behind one Chrome_RenderWidgetHostHWND — the very
; control class this detector exists to protect — so ControlGetFocus returns the
; same handle for a plain input and for the password box next to it. Type in the
; plain one, get {secure: false} cached; click into the password box and every
; character typed there was sent to the LLM as context for the rest of the
; window.
;
; ROOT CAUSE ENCODED: an expired verdict IS an unknown, and unknown must fail
; closed here exactly like an inconclusive native probe — the module header
; states the policy ("sending unknown focused-field content to an LLM is
; irreversible"). The shipped guard asserted that invariant on the
; first-classification branch only, so its sibling branch stayed uncovered.
;
; SCOPE: one source-structural guard (always meaningful) plus one behavioural
; guard that drives the real detector when the session has a focused control.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ The cached verdict needs freshness =======
; =====================================================
; =====================================================

_SFSV_CachedVerdictIsGuardedByFreshness() {
	Body := _DriverFuncBody("SFD_IsSecureField")
	Assert(Body != "", "SFD_IsSecureField() must exist")

	CachedReturn := InStr(Body, "return SFD_FIELD_CACHE[")
	Assert(CachedReturn > 0,
		"prerequisite: SFD_IsSecureField still short-circuits on a cached verdict — without that branch this guard has nothing to protect")
	Assert(InStr(Body, "return SFD_FIELD_CACHE[", , CachedReturn + 1) = 0,
		"the cached verdict must be returned from exactly one place, so one freshness test governs every way out of the cache-hit branch")

	FreshTest := InStr(Body, "< SFD_FIELD_CACHE_TTL_MS")
	Assert(FreshTest > 0 and FreshTest < CachedReturn,
		"the cached verdict may only be served under a FRESHNESS test (age < TTL). Gating on expiry and returning the value anyway is what let a password box inherit the 'not secure' answer of a sibling field sharing its HWND")

	; The expired half of the branch must do both things: refresh, and deny until
	; the refresh lands. Refreshing alone would still authorise the prediction it
	; was meant to withhold.
	Tail := SubStr(Body, CachedReturn)
	SchedulePos := InStr(Tail, "SFD_ScheduleUiaProbe(")
	DenyPos     := InStr(Tail, "return true")
	Assert(SchedulePos > 0,
		"an expired verdict must schedule the UIA probe that will replace it")
	Assert(DenyPos > SchedulePos,
		"an expired verdict must then fail closed — returning the stale value while the probe is in flight reopens the whole window the fix closes")
}





; ================================================
; ================================================
; ======= 2/ The detector behaves that way =======
; ================================================
; ================================================

; Drives the real function. The positive control runs FIRST and deliberately
; asserts the opposite outcome, so the guard below cannot be satisfied by a
; detector that has degenerated into `return true`.
_SFSV_ExpiredVerdictFailsClosedAtRuntime() {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS

	Hwnd := SFD_FocusedHwnd()
	if !Hwnd {
		; No focusable control in this session, so the cache branch is
		; unreachable. The no-focus branch is a real fail-closed guarantee of the
		; same function, and section 1 above covers the cache branch regardless.
		Assert(SFD_IsSecureField() == true,
			"with no resolvable focused control the detector must fail closed")
		return
	}

	SFD_FIELD_CACHE["pending_hwnd"] := 0
	SFD_FIELD_CACHE["secure"]       := false
	SFD_FIELD_CACHE["at"]           := A_TickCount
	SFD_FIELD_CACHE["hwnd"]         := Hwnd
	Assert(SFD_IsSecureField() == false,
		"a FRESH cached non-secure verdict must still authorise a prediction — a detector that always denies is not a fix, it is a broken feature")

	SFD_FIELD_CACHE["pending_hwnd"] := 0
	SFD_FIELD_CACHE["secure"]       := false
	SFD_FIELD_CACHE["at"]           := A_TickCount - (SFD_FIELD_CACHE_TTL_MS * 5)
	SFD_FIELD_CACHE["hwnd"]         := Hwnd
	Assert(SFD_IsSecureField() == true,
		"an EXPIRED cached verdict is an unknown and must fail closed exactly like an inconclusive native probe — serving the stale value lets a password field inherit the non-secure verdict of a sibling field on the same HWND")
}


Test("meta secure-field: a cached verdict is served only while it is fresh",
	_SFSV_CachedVerdictIsGuardedByFreshness)
Test("meta secure-field: an expired cached verdict fails closed at runtime",
	_SFSV_ExpiredVerdictFailsClosedAtRuntime)
