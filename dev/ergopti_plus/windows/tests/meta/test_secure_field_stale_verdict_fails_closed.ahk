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
	Lookup := _DriverFuncBody("SFD_TryGetCachedVerdict")
	Assert(Lookup != "", "SFD_TryGetCachedVerdict() must exist")
	Assert(InStr(Lookup, "SFD_FIELD_CACHE_TTL_MS") > 0,
		"every cached verdict must expire at the configured TTL")
	Assert(InStr(Lookup, 'Secure := true') > 0,
		"a cache miss or expired verdict must leave the caller fail-closed")
	Assert(InStr(Lookup, 'focus_tracking_active') > 0
		and InStr(Lookup, 'verdict_generation') > 0
		and InStr(Lookup, 'element_id') > 0,
		"a negative cache hit must require the live invalidator, focus generation and UIA RuntimeId")

	Caller := _DriverFuncBody("SFD_IsSecureField")
	Assert(Caller != "" and InStr(Caller, "SFD_TryGetCachedVerdict(") > 0,
		"SFD_IsSecureField must route every cache hit through the focused-element lookup")
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

	SFD_FIELD_CACHE["secure"]       := false
	SFD_FIELD_CACHE["at"]           := A_TickCount
	SFD_FIELD_CACHE["hwnd"]         := 81
	SFD_FIELD_CACHE["focus_generation"] := 4
	SFD_FIELD_CACHE["verdict_generation"] := 4
	SFD_FIELD_CACHE["element_id"] := "field:plain"
	SFD_FIELD_CACHE["focus_tracking_active"] := true
	Secure := true
	Assert(SFD_TryGetCachedVerdict(81, 4, "field:plain", &Secure) and !Secure,
		"a fresh verdict for the exact focused element must still authorise prediction")

	SFD_FIELD_CACHE["secure"]       := false
	SFD_FIELD_CACHE["at"]           := A_TickCount - (SFD_FIELD_CACHE_TTL_MS * 5)
	Secure := false
	Assert(!SFD_TryGetCachedVerdict(81, 4, "field:plain", &Secure) and Secure,
		"an EXPIRED cached verdict is an unknown and must fail closed exactly like an inconclusive native probe — serving the stale value lets a password field inherit the non-secure verdict of a sibling field on the same HWND")
}


Test("meta secure-field: a cached verdict is served only while it is fresh",
	_SFSV_CachedVerdictIsGuardedByFreshness)
Test("meta secure-field: an expired cached verdict fails closed at runtime",
	_SFSV_ExpiredVerdictFailsClosedAtRuntime)





; =============================================================
; =============================================================
; ======= 3/ Cache identity follows the focused element =======
; =============================================================
; =============================================================

_SFSV_SiblingFieldsDoNotShareFreshNegativeVerdicts() {
	global SFD_FIELD_CACHE

	SFD_FIELD_CACHE["hwnd"] := 71
	SFD_FIELD_CACHE["secure"] := false
	SFD_FIELD_CACHE["at"] := A_TickCount
	SFD_FIELD_CACHE["focus_generation"] := 9
	SFD_FIELD_CACHE["verdict_generation"] := 9
	SFD_FIELD_CACHE["element_id"] := "field:plain"
	SFD_FIELD_CACHE["focus_tracking_active"] := true

	Secure := true
	Assert(SFD_TryGetCachedVerdict(71, 9, "field:plain", &Secure)
		and !Secure,
		"a fresh negative verdict may be reused for the exact focused element")
	Assert(!SFD_TryGetCachedVerdict(71, 10, "", &Secure) and Secure,
		"a sibling field sharing the same HWND must fail closed after focus invalidation")
	Assert(!SFD_TryGetCachedVerdict(71, 9, "field:password", &Secure) and Secure,
		"a different UIA RuntimeId must never inherit a fresh negative verdict")
}

Test("secure-field: fresh negative cache is focused-element scoped (AHK-051)",
	_SFSV_SiblingFieldsDoNotShareFreshNegativeVerdicts)
