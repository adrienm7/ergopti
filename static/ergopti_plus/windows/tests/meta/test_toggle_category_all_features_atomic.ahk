; static/ergopti_plus/windows/tests/meta/test_toggle_category_all_features_atomic.ahk

; ==============================================================================
; MODULE: ToggleCategoryAllFeatures Atomicity Meta Test
; DESCRIPTION:
; Static source guard for finding F39 (live-toggle-critical-window-too-narrow).
;
; ToggleCategoryAllFeatures's live-category branch used to mutate live Maps
; during snapshot/restore and ApplyMasterGatesToFeatures(). A keystroke landing
; in that multi-loop window could observe transiently inconsistent Features/
; TapHold state via a concurrent #HotIf/InputHook evaluation.
;
; The fix builds and persists detached candidates first, then publishes all
; live Map references inside one short Critical("On") span released in a
; finally block. No tree walk or I/O runs while the hook is held.
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
; STRUCTURAL guarantee (candidate construction before one atomic reference
; publish) is what we pin.
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

	RestorePos := InStr(Body, "_HSRestoreCategoryFrom(CandidateFeatures")
	SnapshotPos := InStr(Body, "_HSSnapshotCategoryTo(CandidateFeatures")
	Assert(RestorePos > 0, "ToggleCategoryAllFeatures must restore the category snapshot on ON")
	Assert(SnapshotPos > 0, "ToggleCategoryAllFeatures must snapshot the category on OFF")
	Assert(RestorePos < CritPos and SnapshotPos < CritPos,
		"snapshot/restore must build detached candidates before Critical; no live Map is exposed yet")

	GatesPos := InStr(Body, "ApplyMasterGatesToFeatures(CandidateFeatures, CandidateTapHold")
	Assert(GatesPos > 0, "ToggleCategoryAllFeatures must re-apply master gates before rebuilding")
	Assert(GatesPos < CritPos,
		"manifest I/O and master-gate application must finish on detached candidates before Critical")

	WritePos := InStr(Body, "ConfigCommitUpdates(ConfigurationFile")
	Assert(WritePos > GatesPos and WritePos < CritPos,
		"the detached candidate must persist successfully before the atomic publish window")
	PublishPos := InStr(Body, "Features := CandidateFeatures")
	Assert(PublishPos > CritPos,
		"Critical must begin before the first live candidate reference is published")

	RebuildPos := InStr(Body, "RebuildHotstringsLive()")
	Assert(RebuildPos > 0, "ToggleCategoryAllFeatures must rebuild the live hotstring engine")
	Assert(GatesPos < RebuildPos, "master gates must be re-applied before the engine rebuild")

	Assert(InStr(Body, "finally") > 0,
		"ToggleCategoryAllFeatures must release Critical in a finally block so an exception during publication cannot leak Critical")
	Assert(InStr(Body, "Critical(_TcafCrit)") > 0,
		"ToggleCategoryAllFeatures must restore the prior Critical state after the mutation window (no leaked Critical)")

	; F-01: the UPPER bound. Critical must be RELEASED before the rebuild.
	RelPos := InStr(Body, "Critical(_TcafCrit)")
	Assert(RelPos < RebuildPos,
		"ToggleCategoryAllFeatures must RELEASE Critical before RebuildHotstringsLive(): that call re-runs RegisterAllHotstrings (~1.3 s) and, via RebuildTrayMenu -> _HS_InvalidatePersonalCache, a full recursive personal-hotstrings + extensions rescan. Holding Critical across it starves the LL keyboard hook past LowLevelHooksTimeout and Windows silently drops physical keystrokes (F33 regression, reintroduced by this caller)")

	Assert(WritePos < CritPos,
		"the config write is unbounded file I/O and must sit before the Critical publish span")
}
Test("config_io: ToggleCategoryAllFeatures publishes detached candidates atomically (F39)", _TCAF_LiveToggleIsAtomic)




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
; number of call sites found, derived from driver source. Source is injectable
; so a fixture can prove the scanner accepts whitespace, multiline arguments,
; and a parameterized definition without accidentally enrolling the definition.
_TCAF_RebuildCallers(Source := unset) {
	Src := IsSet(Source) ? Source : _DriverSourceNoComments()
	Defs := _TCAF_TopLevelDefs(Src)
	Definition := _DriverFindFunctionDefinition(Src, "RebuildHotstringsLive")
	Assert(IsObject(Definition),
		"RebuildHotstringsLive must have a resolvable definition before its callers can be audited")
	Owners := Map()
	Sites := 0
	Pos := 1
	while RegExMatch(Src, "\bRebuildHotstringsLive\s*\(", &Call, Pos) {
		CallPos := Call.Pos
		Pos := Call.Pos + Call.Len
		; The same token starts the definition. Its balanced signature may contain
		; parameters and line breaks, so compare against the canonical definition
		; scanner instead of guessing from the next four characters.
		if (CallPos == Definition.Idx)
			continue
		Sites += 1
		Owner := _TCAF_OwnerOf(Defs, CallPos)
		Assert(Owner != "",
			"a RebuildHotstringsLive() call site could not be attributed to an enclosing function — the scan is broken and would certify the Critical bound without checking it")
		Owners[Owner] := true
	}
	return { owners: Owners, sites: Sites }
}

_TCAF_CallerScannerCoversCurrentCallSyntax() {
	Fixture := "RebuildHotstringsLive(Worker := 0) {`n}`n"
	Fixture .= "PlainCaller() {`n`tRebuildHotstringsLive()`n}`n"
	Fixture .= "InjectedCaller() {`n`tRebuildHotstringsLive (`n`t`tWorker)`n}`n"
	Scan := _TCAF_RebuildCallers(Fixture)
	AssertEqual(2, Scan.sites,
		"the caller scanner must enroll both zero-argument and multiline/injected calls while excluding the parameterized definition")
	Assert(Scan.owners.Has("PlainCaller") and Scan.owners.Has("InjectedCaller"),
		"every syntactic call variant must still be attributed to its enclosing top-level caller")
}
Test("config_io: RebuildHotstringsLive caller scan covers current call syntax (F-01)",
	_TCAF_CallerScannerCoversCurrentCallSyntax)

_TCAF_NoCallerHoldsCriticalAcrossRebuild() {
	Scan := _TCAF_RebuildCallers()

	; A scan that matches nothing must not be able to pass. Do not pin today's
	; caller count: removing a legitimate caller is not a regression. The fixture
	; above guards the parser, while this assertion proves production still has a
	; non-empty class to inspect.
	Assert(Scan.sites > 0 and Scan.owners.Count > 0,
		"the caller scan found no RebuildHotstringsLive call sites — it must fail closed rather than certify an empty class")

	for Fn, _ in Scan.owners {
		Body := _DriverFuncBody(Fn)
		; Hard assert, never a skip: a rename that makes the body unresolvable must
		; fail loudly rather than quietly stop checking this caller.
		Assert(Body != "",
			Fn . " calls RebuildHotstringsLive() but its body could not be resolved — the guard would silently stop checking it")

		RebuildPos := RegExMatch(Body, "\bRebuildHotstringsLive\s*\(")
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
