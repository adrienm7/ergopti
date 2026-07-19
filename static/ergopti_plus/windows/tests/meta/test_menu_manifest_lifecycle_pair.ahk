; tests/meta/test_menu_manifest_lifecycle_pair.ahk

; ============================================================================== 
; MODULE: Menu manifest lifecycle-pair regression test
; DESCRIPTION:
; Every path after the manifest loader's LoggerTrace must close the lifecycle.
; Otherwise an invalid manifest is indistinguishable from a callback that never
; completed, which hides failed menu construction in production diagnostics.
; ============================================================================== 

#Requires AutoHotkey v2.0

_MMLP_AllPostTraceFallbacksCloseLifecycle() {
    Body := _DriverFuncBody("MenuManifest_LoadHotstringGroups")
    TracePos := InStr(Body, 'LoggerTrace("MenuManifest"')

    Assert(TracePos > 0, "MenuManifest_LoadHotstringGroups must begin its traced lifecycle")
    for _, Reason in ["manifest is empty", "manifest root is not a JSON object", "hotstring_category_keys block not found", "hotstring_groups block not found"] {
        Pos := InStr(Body, Reason)
        DonePos := InStr(Body, "LoggerDone", , Pos)
        ReturnPos := InStr(Body, "return _MM_BuildResult", , Pos)
        Assert(Pos > TracePos && DonePos > Pos && DonePos < ReturnPos,
            "Manifest fallback '" . Reason . "' must close LoggerTrace with LoggerDone before returning")
    }
}

_MMLP_OnboardingAndLiveRebuildCloseTheirLifecycles() {
    Preload := _DriverFuncBody("_Onboarding_PreloadFromExistingConfig")
    Rebuild := _DriverFuncBody("RebuildHotstringsLive")

    Assert(InStr(Preload, "LoggerTrace") > 0 && InStr(Preload, "LoggerDone") > 0,
        "Onboarding config preload must close its traced lifecycle on fallback paths")
    Assert(InStr(Rebuild, "LoggerStart") > 0 && InStr(Rebuild, "catch as e") > 0
            && InStr(Rebuild, "LoggerError") > 0 && InStr(Rebuild, "throw e") > 0,
        "RebuildHotstringsLive must log and rethrow failures so its LoggerStart never has a silent unmatched exit")
}

Test("menu manifest: every traced fallback closes its logger lifecycle",
    _MMLP_AllPostTraceFallbacksCloseLifecycle)
Test("onboarding/menu: traced lifecycle failures are closed and propagated",
    _MMLP_OnboardingAndLiveRebuildCloseTheirLifecycles)
