; tests/meta/test_onboarding_no_appstate.ahk

; ==============================================================================
; MODULE: Onboarding No-AppState Meta Test
; DESCRIPTION:
; Static source guard for the "_Onboarding_Commit crashes on AppState access"
; finding (onboarding-no-appstate).
;
; _Onboarding_Commit() in lib/onboarding.ahk previously set
; AppState["toml_strict_canon_in_progress"] as its first statement. AppState
; is never defined in production (the Map was deliberately removed from
; lib/app_state.ahk). This throws UnsetError immediately, aborting the entire
; first-run wizard commit: config is never written and the script never
; reloads.
;
; TOML_RunStrictCanonicalization() in lib/toml/toml_helpers.ahk also used
; AppState.Has("toml_strict_canon_in_progress") and AppState[...] for the same
; flag, suffering the same UnsetError in production.
;
; Fix: both functions now use the plain global _TOML_STRICT_CANON_IN_PROGRESS
; instead of the removed AppState Map entry.
;
; These are meta-static tests because the crash occurs at the very first
; statement of the commit path, before any injectable seam is reached.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================
; =============================================
; ======= 1/ Source scan helpers ==============
; =============================================
; =============================================

_ONA_ReadSource(RelPath) {
	Root := A_ScriptDir . "\.."
	return FileRead(Root . "\" . RelPath)
}

_ONA_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}





; =====================================================
; =====================================================
; ======= 2/ Onboarding commit assertions =============
; =====================================================
; =====================================================

_ONA_CommitDoesNotUseAppState() {
	Src := _ONA_ReadSource("lib\onboarding.ahk")
	Seg := _ONA_FuncBody(Src, "_Onboarding_Commit()")
	Assert(Seg != "", "_Onboarding_Commit declaration must exist in lib/onboarding.ahk")
	; Any AppState[...] index-assign in this function throws UnsetError in production
	; because the Map was removed from lib/app_state.ahk
	Assert(InStr(Seg, "AppState[") = 0,
		"_Onboarding_Commit must NOT use AppState[...] — AppState is not defined in production and throws UnsetError")
}
Test("onboarding: _Onboarding_Commit does not access AppState (UnsetError crash on first-run wizard)", _ONA_CommitDoesNotUseAppState)

_ONA_CommitUsesStrictCanonGlobal() {
	Src := _ONA_ReadSource("lib\onboarding.ahk")
	Seg := _ONA_FuncBody(Src, "_Onboarding_Commit() {")
	Assert(Seg != "", "_Onboarding_Commit declaration must exist in lib/onboarding.ahk")
	; Must use the correct plain global instead of the removed Map entry
	Assert(InStr(Seg, "_TOML_STRICT_CANON_IN_PROGRESS") > 0,
		"_Onboarding_Commit must use _TOML_STRICT_CANON_IN_PROGRESS global to block strict canonicalisation")
}
Test("onboarding: _Onboarding_Commit uses _TOML_STRICT_CANON_IN_PROGRESS global (not AppState Map)", _ONA_CommitUsesStrictCanonGlobal)





; ============================================================
; ============================================================
; ======= 3/ TOML strict canonicalisation assertions =========
; ============================================================
; ============================================================

_ONA_StrictCanonDoesNotUseAppState() {
	Src := _ONA_ReadSource("lib\toml\toml_helpers.ahk")
	Seg := _ONA_FuncBody(Src, "TOML_RunStrictCanonicalization(Path)")
	Assert(Seg != "", "TOML_RunStrictCanonicalization declaration must exist in lib/toml/toml_helpers.ahk")
	; AppState.Has(...) would throw UnsetError in production
	Assert(InStr(Seg, "AppState.Has") = 0,
		"TOML_RunStrictCanonicalization must NOT call AppState.Has — AppState is not defined in production")
	; AppState[...] index-access would throw UnsetError in production
	Assert(InStr(Seg, "AppState[") = 0,
		"TOML_RunStrictCanonicalization must NOT use AppState[...] — AppState is not defined in production")
}
Test("toml_helpers: TOML_RunStrictCanonicalization does not access AppState (UnsetError in production)", _ONA_StrictCanonDoesNotUseAppState)
