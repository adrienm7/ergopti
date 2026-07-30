; tests/meta/test_secure_field_uia_probe_guards.ahk

; ==============================================================================
; MODULE: Secure-field UIA Probe Bounding Meta Test
; DESCRIPTION:
; UIA.GetFocusedElement is a cross-process COM round-trip, and every one of the
; driver's probe sites makes it from the single message thread that also
; dispatches hotkey subroutines and InputHook OnChar. Windows' own defaults are
; the only ceiling — 2000 ms TransactionTimeout, 20000 ms ConnectionTimeout —
; and 2000 ms plus overhead is exactly the driver's worst measured stall
; ("[HotPath] Slow Tooltip.ResolvePos: 2560.32 ms", 2026-07-16).
;
; The tooltip site was hardened with three guards; _UIA_SelectionPollTick got
; two; adapters/secure_field_detector.ahk's SFD_ProbeFocusedUia got none — its
; only guard was `if A_IsSuspended`. Nothing caught that, because adapters/
; carries no HotPath instrumentation at all: a stall there produces no
; `Slow ...` line, by construction.
;
; ROOT CAUSE ENCODED: an unbounded, un-gated cross-process wait reachable from
; the typing path. The probe-site set is DERIVED FROM THE SOURCE rather than
; listed, so a new call site joins the guarantee automatically instead of
; quietly reintroducing the stall. Deriving it immediately turned up a FOURTH
; site the shipped enumeration never named — the keylogger's
; KL_DetectPasswordFor — which is recorded as an explicit exemption below
; because it belongs to another module, not because it is acceptable.
;
; SCOPE: source introspection via the move-resilient driver-source helpers. The
; probe itself only runs from a SetTimer callback against a live foreground app,
; so it is unreachable under the headless harness.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Deriving the probe sites =======
; ===========================================
; ===========================================

; Name of the top-level function whose body encloses byte offset Pos: the last
; column-0 "Name(params) {" line at or before it. Src must already have its
; full-line comments stripped, so prose can never be mistaken for a definition.
_SFUG_EnclosingFunction(Src, Pos) {
	Name := ""
	for Line in StrSplit(SubStr(Src, 1, Pos), "`n", "`r")
		if RegExMatch(Line, "^([A-Za-z_]\w*)\([^\r\n]*\)\s*\{\s*$", &m)
			Name := m[1]
	return Name
}

; Every function that reads the focused UIA element, derived from the driver
; source. Listing them by hand is what let the adapter site drift: the shipped
; enumeration named it and then applied only the weakest assertion to it.
_SFUG_ProbeSites() {
	Src   := _DriverSourceNoComments()
	Sites := Map()
	Needle := "UIA.GetFocusedElement"
	Pos := 1
	while (Pos := InStr(Src, Needle, , Pos)) {
		Name := _SFUG_EnclosingFunction(Src, Pos)
		Pos += StrLen(Needle)
		if (Name != "")
			Sites[Name] := true
	}
	return Sites
}





; =================================================
; =================================================
; ======= 2/ Every probe site is idle-gated =======
; =================================================
; =================================================

; Probe sites that are knowingly un-gated. Listed rather than silently skipped:
; a named exemption keeps a FIFTH site from appearing unnoticed, and an entry
; that no longer matches a real function fails here instead of suppressing
; nothing. Never add one to make a change pass.
_SFUG_IdleGateExemptions() {
	return Map(
		; modules/keylogger/keylogger_password.ahk. The same missing guard, on the
		; keylogger's own verdict cache rather than on this adapter — a separate
		; owner and a separate audit item. Recorded here so it stays visible.
		"KL_DetectPasswordFor", true
	)
}

; The gate must precede the call: a check placed after the COM round-trip would
; satisfy a naive substring search while fixing nothing. A render or prediction
; debounce is NOT a substitute — a debounce coalesces work, it never establishes
; that a typing burst has ended.
_SFUG_EveryProbeSiteIsIdleGated() {
	Exemptions := _SFUG_IdleGateExemptions()
	Checked  := 0
	Exempted := 0
	for Name in _SFUG_ProbeSites() {
		Body := _DriverFuncBody(Name)
		if (Body == "" or InStr(Body, "UIA.GetFocusedElement") == 0)
			continue
		if Exemptions.Has(Name) {
			Exempted += 1
			continue
		}
		Checked += 1
		IdlePos := InStr(Body, "A_TimeIdlePhysical")
		UiaPos  := InStr(Body, "UIA.GetFocusedElement")
		Assert(IdlePos > 0 and IdlePos < UiaPos,
			Name . " must gate its UIA round-trip on A_TimeIdlePhysical BEFORE making it — the call runs on the thread that dispatches keystrokes, and a key arriving 1 ms after it starts queues behind an unbounded cross-process wait")
	}
	Assert(Checked >= 3,
		"the derived probe-site set must still reach every gated UIA.GetFocusedElement caller (found " . Checked . ") — a shrinking set would mean this guard had quietly stopped covering the class")
	Assert(Exempted = Exemptions.Count,
		"every exemption must still name a real, still-unguarded probe site (" . Exempted . " of " . Exemptions.Count . " matched) — a stale entry suppresses nothing and hides that its successor was never triaged")
}





; =========================================================
; =========================================================
; ======= 3/ The adapter site is bounded and cached =======
; =========================================================
; =========================================================

; The clamp and the per-process no-answer cache are the two guards the adapter
; was missing outright. Kept as a site-specific assertion because the sibling
; sites express the same two ideas through their own helpers, and pinning one
; spelling across all of them would be a false guarantee.
_SFUG_AdapterProbeIsClampedAndCached() {
	Body := _DriverFuncBody("SFD_ProbeFocusedUia")
	Assert(Body != "", "SFD_ProbeFocusedUia() must exist")

	UiaPos     := InStr(Body, "UIA.GetFocusedElement")
	ClampPos   := InStr(Body, "ClampUiaTimeouts")
	HostilePos := InStr(Body, "UiaProcessIsHostile")
	Assert(UiaPos > 0, "prerequisite: the adapter still probes the focused UIA element")
	Assert(ClampPos > 0 and ClampPos < UiaPos,
		"SFD_ProbeFocusedUia must clamp UIA's own transaction/connection timeouts BEFORE the round-trip — the clamp was reachable only from the tooltip's stage-2 branch, and this probe usually touches UIA first because it fires right after a typing burst, so the singleton still carried Windows' 2000 ms default")
	Assert(HostilePos > 0 and HostilePos < UiaPos,
		"SFD_ProbeFocusedUia must consult a per-process no-answer cache before probing — the field verdict expires about once a second, so a UIA-hostile app otherwise re-pays a full timeout at that rate, forever")
	Assert(InStr(Body, "MarkUiaHostile") > 0,
		"a failed probe must actually populate the no-answer cache, or consulting it is decoration")
}

; A deferred or skipped probe must leave the cache untouched. Committing a
; verdict from a path that never asked UIA anything would turn "we did not look"
; into a recorded answer, which is the opposite of the fail-closed policy the
; module header states.
_SFUG_SkippedProbeCommitsNothing() {
	Body := _DriverFuncBody("SFD_ProbeFocusedUia")
	Assert(Body != "", "SFD_ProbeFocusedUia() must exist")

	UiaPos    := InStr(Body, "UIA.GetFocusedElement")
	CommitPos := InStr(Body, "SFD_CommitFieldVerdict(")
	Assert(CommitPos > 0, "prerequisite: the probe still commits its verdict")
	Assert(CommitPos > UiaPos,
		"the only verdict commit must sit AFTER the probe — a commit reachable from a deferral path would record an answer the probe never obtained")
	Assert(InStr(Body, "SFD_CommitFieldVerdict(", , CommitPos + 1) = 0,
		"SFD_ProbeFocusedUia must have exactly one commit site, so every early return is guaranteed to leave the previous verdict to expire and fail closed")
}


Test("meta secure-field: every UIA probe site idle-gates its cross-process round-trip",
	_SFUG_EveryProbeSiteIsIdleGated)
Test("meta secure-field: the adapter's UIA probe is timeout-clamped and hostile-cached",
	_SFUG_AdapterProbeIsClampedAndCached)
Test("meta secure-field: a skipped or deferred UIA probe commits no verdict",
	_SFUG_SkippedProbeCommitsNothing)
