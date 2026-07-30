; static/ergopti_plus/windows/tests/meta/test_toggle_category_all_features_atomic.ahk

; ==============================================================================
; MODULE: ToggleCategoryAllFeatures Atomicity Meta Test
; DESCRIPTION:
; Static source guard for finding F39 (live-toggle-critical-window-too-narrow).
;
; ToggleCategoryAllFeatures's live-category branch used to run the snapshot/
; restore step and ApplyMasterGatesToFeatures() completely unprotected, ahead
; of the Critical wrap that only started once RebuildHotstringsLive() was
; entered. A keystroke landing in that window (large category subtrees,
; multiple full-tree loops) could observe transiently inconsistent Features/
; TapHold state via a concurrent #HotIf/InputHook evaluation.
;
; The fix widens the Critical("On") span to start right before the first
; Features mutation (_HSRestoreCategory / _HSSnapshotCategory) and to cover
; the gate flip and ApplyMasterGatesToFeatures(), released in a finally block
; — mirroring the precedent set by HSE_DisableGroup's Critical wrap (see
; test_hse_disable_group_atomic.ahk).
;
; UPPER BOUND (F-01, audit 2026-07-20 second pass): the Critical span must
; STOP before TOML_Write + RebuildHotstringsLive(). F33 removed Critical from
; RebuildHotstringsLive precisely because that span does ~1.3 s of
; registration plus a recursive personal-hotstrings + extensions rescan, and
; holding Critical across it starves the LL keyboard hook past
; LowLevelHooksTimeout so Windows silently DROPS physical keystrokes. That
; guarantee is TRANSITIVE, so F33's own test — which only asserts Critical is
; absent from RebuildHotstringsLive's body — could not see this caller
; re-wrapping the call from the outside. Both bounds are pinned here.
;
; Meta-static rather than behavioral: the synchronous headless harness cannot
; reproduce the cooperative-threading preemption this guards against, so the
; STRUCTURAL guarantee (the whole mutation window sits inside one Critical
; region) is what we pin.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Atomicity assertion ====================
; ===================================================
; ===================================================

_TCAF_LiveToggleIsAtomic() {
	Body := _DriverFuncBody("ToggleCategoryAllFeatures")
	Assert(Body != "", "ToggleCategoryAllFeatures(Category, Value) declaration must exist in config_io.ahk")

	CritPos := InStr(Body, 'Critical("On")')
	Assert(CritPos > 0,
		"ToggleCategoryAllFeatures must enter Critical around the live-category mutation window so a concurrent #HotIf/InputHook evaluation never observes torn Features/TapHold state")

	RestorePos := InStr(Body, "_HSRestoreCategory(V2Cat)")
	SnapshotPos := InStr(Body, "_HSSnapshotCategory(V2Cat)")
	Assert(RestorePos > 0, "ToggleCategoryAllFeatures must restore the category snapshot on ON")
	Assert(SnapshotPos > 0, "ToggleCategoryAllFeatures must snapshot the category on OFF")
	Assert(CritPos < RestorePos and CritPos < SnapshotPos,
		"Critical must be entered BEFORE the first Features mutation (snapshot/restore), not just before the final rebuild")

	GatesPos := InStr(Body, "ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated")
	Assert(GatesPos > 0, "ToggleCategoryAllFeatures must re-apply master gates before rebuilding")
	Assert(CritPos < GatesPos,
		"Critical must cover the ApplyMasterGatesToFeatures() step, not just the final RebuildHotstringsLive() call")

	RebuildPos := InStr(Body, "RebuildHotstringsLive()")
	Assert(RebuildPos > 0, "ToggleCategoryAllFeatures must rebuild the live hotstring engine")
	Assert(GatesPos < RebuildPos, "master gates must be re-applied before the engine rebuild")

	Assert(InStr(Body, "finally") > 0,
		"ToggleCategoryAllFeatures must release Critical in a finally block so an exception mid-rebuild cannot leak Critical")
	Assert(InStr(Body, "Critical(_TcafCrit)") > 0,
		"ToggleCategoryAllFeatures must restore the prior Critical state after the mutation window (no leaked Critical)")

	; F-01: the UPPER bound. Critical must be RELEASED before the rebuild.
	RelPos := InStr(Body, "Critical(_TcafCrit)")
	Assert(RelPos < RebuildPos,
		"ToggleCategoryAllFeatures must RELEASE Critical before RebuildHotstringsLive(): that call re-runs RegisterAllHotstrings (~1.3 s) and, via RebuildTrayMenu -> _HS_InvalidatePersonalCache, a full recursive personal-hotstrings + extensions rescan. Holding Critical across it starves the LL keyboard hook past LowLevelHooksTimeout and Windows silently drops physical keystrokes (F33 regression, reintroduced by this caller)")

	WritePos := InStr(Body, "TOML_Write(Bool, ConfigurationFile")
	Assert(WritePos > 0, "ToggleCategoryAllFeatures must persist the category gate")
	Assert(RelPos < WritePos,
		"the TOML write is unbounded file I/O and must also sit OUTSIDE the Critical span")
}
Test("config_io: ToggleCategoryAllFeatures live-category branch is Critical-wrapped end to end (F39)", _TCAF_LiveToggleIsAtomic)




; ==========================================================
; ==========================================================
; ======= 2/ No caller holds Critical across the rebuild ====
; ==========================================================
; ==========================================================

; Root cause of F-01: F33 removed Critical from RebuildHotstringsLive, but the
; guarantee is TRANSITIVE — any caller that holds Critical across the call
; restores the freeze just as effectively. A test scoped to the callee's body
; cannot see that, so it has to be asserted at the call sites.
;
; This guard used to enumerate the callers BY NAME, and that list rotted exactly
; the way the bug it guards against does. It listed three names, one of which
; (ToggleAllHotstrings) never called RebuildHotstringsLive at all, while three
; real call sites added since — the two hotstring delay prompts and the config
; window's republish — were never added. It policed 2 of 5 sites and certified
; the other 3 without looking, and its `if (Body == "") continue` skip meant a
; simple rename silently downgraded an assertion to a no-op. Nothing in the TAP
; output distinguished "checked and clean" from "not checked".
;
; So the call-site set is now DERIVED from driver source: every non-definition
; `RebuildHotstringsLive()` occurrence is attributed to its enclosing top-level
; function, and every one of those functions is checked. A sibling added
; tomorrow enrols itself.


; Every top-level (column-0) function definition in Src, as {name, pos}, in
; source order. Control-flow keywords are excluded so a column-0 `if (…) {` in
; an auto-execute section cannot be mistaken for a function.
_TCAF_TopLevelDefs(Src) {
	static Keywords := Map("if", true, "while", true, "loop", true, "for", true,
		"switch", true, "catch", true, "else", true, "try", true, "return", true)
	Defs := []
	Pos := 1
	while (RegExMatch(Src, "m)^([A-Za-z_][A-Za-z0-9_]*)\([^\r\n]*\)\s*\{", &M, Pos)) {
		if !Keywords.Has(StrLower(M[1]))
			Defs.Push({ name: M[1], pos: M.Pos })
		Pos := M.Pos + M.Len
	}
	return Defs
}

; The name of the top-level function that encloses the given source position:
; the last definition that starts before it.
_TCAF_OwnerOf(Defs, CallPos) {
	Owner := ""
	for _, D in Defs {
		if (D.pos > CallPos)
			break
		Owner := D.name
	}
	return Owner
}

; Names of every top-level function that calls RebuildHotstringsLive(), plus the
; number of call sites found, derived from driver source.
_TCAF_RebuildCallers() {
	Needle := "RebuildHotstringsLive()"
	Src := _DriverSourceNoComments()
	Defs := _TCAF_TopLevelDefs(Src)
	Owners := Map()
	Sites := 0
	Pos := 1
	while (CallPos := InStr(Src, Needle, true, Pos)) {
		Pos := CallPos + 1
		; The definition line itself is `RebuildHotstringsLive() {` — skip it.
		if (SubStr(Trim(SubStr(Src, CallPos + StrLen(Needle), 4)), 1, 1) == "{")
			continue
		; Skip a longer identifier that merely ends with the same characters.
		if (CallPos > 1 and RegExMatch(SubStr(Src, CallPos - 1, 1), "[A-Za-z0-9_]"))
			continue
		Sites += 1
		Owner := _TCAF_OwnerOf(Defs, CallPos)
		Assert(Owner != "",
			"a RebuildHotstringsLive() call site could not be attributed to an enclosing function — the scan is broken and would certify the Critical bound without checking it")
		Owners[Owner] := true
	}
	return { owners: Owners, sites: Sites }
}

_TCAF_NoCallerHoldsCriticalAcrossRebuild() {
	Scan := _TCAF_RebuildCallers()

	; A scan that matches nothing must not be able to pass. Five call sites exist
	; today; the floor makes a derivation that silently stops matching fail loudly
	; instead of certifying an empty set.
	Assert(Scan.sites >= 5,
		"the caller scan must find every RebuildHotstringsLive() call site (found " . Scan.sites . ") — the hand-maintained name list this replaced policed 2 of 5 and degraded to a silent pass on rename, which is the same one-site blindness this file exists to close")

	for Fn, _ in Scan.owners {
		Body := _DriverFuncBody(Fn)
		; Hard assert, never a skip: a rename that makes the body unresolvable must
		; fail loudly rather than quietly stop checking this caller.
		Assert(Body != "",
			Fn . " calls RebuildHotstringsLive() but its body could not be resolved — the guard would silently stop checking it")

		RebuildPos := InStr(Body, "RebuildHotstringsLive()")
		Assert(RebuildPos > 0,
			Fn . " was attributed a RebuildHotstringsLive() call site but its resolved body does not contain one — the attribution is wrong and the check is meaningless")

		AcqPos := InStr(Body, 'Critical("On")')
		if (AcqPos == 0 or AcqPos > RebuildPos)
			continue
		RelPos := InStr(Body, "Critical(_")
		Assert(RelPos > 0 and RelPos < RebuildPos,
			Fn . " acquires Critical before RebuildHotstringsLive() and must release it first — that call re-runs RegisterAllHotstrings (~1.3 s) plus a recursive personal-hotstrings and extensions rescan, and holding Critical across it starves the LL keyboard hook past LowLevelHooksTimeout, so Windows silently drops physical keystrokes")
	}
}
Test("config_io: no caller holds Critical across RebuildHotstringsLive (F-01)", _TCAF_NoCallerHoldsCriticalAcrossRebuild)
