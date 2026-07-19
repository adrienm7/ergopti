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





; =====================================================
; =====================================================
; ======= 2/ Onboarding commit assertions =============
; =====================================================
; =====================================================

_ONA_CommitDoesNotUseAppState() {
	Seg := _DriverFuncBody("_Onboarding_Commit")
	Assert(Seg != "", "_Onboarding_Commit declaration must exist in the driver source")
	; Any AppState[...] index-assign in this function throws UnsetError in production
	; because the Map was removed from lib/app_state.ahk
	Assert(InStr(Seg, "AppState[") = 0,
		"_Onboarding_Commit must NOT use AppState[...] — AppState is not defined in production and throws UnsetError")
}
Test("onboarding: _Onboarding_Commit does not access AppState (UnsetError crash on first-run wizard)", _ONA_CommitDoesNotUseAppState)

_ONA_CommitUsesStrictCanonGlobal() {
	Seg := _DriverFuncBody("_Onboarding_Commit")
	Assert(Seg != "", "_Onboarding_Commit declaration must exist in the driver source")
	; Must use the correct plain global instead of the removed Map entry
	Assert(InStr(Seg, "_TOML_STRICT_CANON_IN_PROGRESS") > 0,
		"_Onboarding_Commit must use _TOML_STRICT_CANON_IN_PROGRESS global to block strict canonicalisation")
}
Test("onboarding: _Onboarding_Commit uses _TOML_STRICT_CANON_IN_PROGRESS global (not AppState Map)", _ONA_CommitUsesStrictCanonGlobal)

_ONA_CommitPublishesOnlyAfterPersistence() {
        Seg := _DriverFuncBody("_Onboarding_Commit")
        PathsWriter := _DriverFuncBody("_WritePathsToml")
        NativeFinish := _DriverFuncBody("_Step5_Finish")
        WebFinish := _DriverFuncBody("_OnbWeb_Finish")
        Assert(InStr(Seg, "TOML_BatchWrite(CandidateConfig, updates)") > 0 && InStr(Seg, "PathRedirectRequired && !_WritePathsToml(CandidateDir)") > 0,
                "onboarding must persist candidate config and paths redirect before it publishes globals")
        Assert(InStr(Seg, "_ConfigDir := CandidateDir") > InStr(Seg, "TOML_BatchWrite(CandidateConfig, updates)"),
                "onboarding must not publish _ConfigDir before the candidate config write succeeds")
        Assert(InStr(Seg, "finally") > 0 && InStr(Seg, "_TOML_STRICT_CANON_IN_PROGRESS := PreviousStrictCanon") > 0,
                "the strict-canonicalization guard must be restored on every commit outcome")
        Assert(InStr(PathsWriter, "FileMove(TmpPath, _PathsFile, true)") > 0 && InStr(PathsWriter, "return false") > 0,
                "paths.toml must be atomically replaced and report write failure")
        Assert(InStr(NativeFinish, "if _Onboarding_Commit()") > 0 && InStr(NativeFinish, "Reload") > 0,
                "native onboarding must reload only after a successful commit")
        Assert(InStr(WebFinish, "if _Onboarding_Commit()") > 0 && InStr(WebFinish, "_OnbWeb_Reset()") > 0,
                "WebView onboarding must retain its retry UI until commit success")
}
Test("onboarding: commit persists transactionally before publishing or reloading", _ONA_CommitPublishesOnlyAfterPersistence)





; ============================================================
; ============================================================
; ======= 3/ TOML strict canonicalisation assertions =========
; ============================================================
; ============================================================

_ONA_StrictCanonDoesNotUseAppState() {
	Seg := _DriverFuncBody("TOML_RunStrictCanonicalization")
	Assert(Seg != "", "TOML_RunStrictCanonicalization declaration must exist in lib/toml/toml_helpers.ahk")
	; AppState.Has(...) would throw UnsetError in production
	Assert(InStr(Seg, "AppState.Has") = 0,
		"TOML_RunStrictCanonicalization must NOT call AppState.Has — AppState is not defined in production")
	; AppState[...] index-access would throw UnsetError in production
	Assert(InStr(Seg, "AppState[") = 0,
		"TOML_RunStrictCanonicalization must NOT use AppState[...] — AppState is not defined in production")
}
Test("toml_helpers: TOML_RunStrictCanonicalization does not access AppState (UnsetError in production)", _ONA_StrictCanonDoesNotUseAppState)
