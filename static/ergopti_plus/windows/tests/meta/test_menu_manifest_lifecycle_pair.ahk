; tests/meta/test_menu_manifest_lifecycle_pair.ahk

; ============================================================================== 
; MODULE: Menu manifest lifecycle-pair regression test
; DESCRIPTION:
; Every path after the manifest loader's LoggerTrace must close the lifecycle.
; Otherwise an invalid manifest is indistinguishable from a callback that never
; completed, which hides failed menu construction in production diagnostics.
; ============================================================================== 

#Requires AutoHotkey v2.0

; GUARANTEE, not spelling: every fallback return that happens AFTER the loader's
; LoggerTrace must close the lifecycle with a LoggerDone first.
;
; The previous version asserted the same guarantee by naming the four fallback
; REASON STRINGS that happened to exist at the time ("manifest is empty",
; "manifest root is not a JSON object", ...). Two of those branches belonged to
; the loader's own FileRead + JsonParse of menu_manifest.json, so the assertion
; effectively pinned a second, redundant decode of a 12.5 KB file in place — a
; mechanism — while what it meant to protect is the lifecycle pairing. The
; branch set is now DERIVED from the loader body, so the rule survives the move
; of those branches into the shared accessor and a newly added fallback inherits
; it automatically instead of silently escaping the check.
_MMLP_AllPostTraceFallbacksCloseLifecycle() {
    Body := _DriverFuncBody("MenuManifest_LoadHotstringGroups")
    Assert(Body != "", "MenuManifest_LoadHotstringGroups must exist in the driver source")
    TracePos := InStr(Body, 'LoggerTrace("MenuManifest"')
    Assert(TracePos > 0, "MenuManifest_LoadHotstringGroups must begin its traced lifecycle")

    Fallbacks := 0
    SegStart := TracePos
    Pos := TracePos
    while (ReturnPos := InStr(Body, "return _MM_BuildResult", , Pos)) {
        Fallbacks += 1
        DonePos := InStr(Body, "LoggerDone", , SegStart)
        Assert(DonePos > 0 && DonePos < ReturnPos,
            "fallback return #" . Fallbacks . " after the LoggerTrace must close it with a LoggerDone "
            . "before returning — an unclosed trace makes an invalid manifest indistinguishable from a "
            . "callback that never completed")
        SegStart := ReturnPos
        Pos := ReturnPos + 1
    }
    Assert(Fallbacks >= 3,
        "the fallback class must be derived from the loader body and hold at least three branches — "
        . "an empty class would make this test vacuous")
}

_MMLP_OnboardingAndLiveRebuildCloseTheirLifecycles() {
    Preload := _DriverFuncBody("_Onboarding_PreloadFromExistingConfig")
    Rebuild := _DriverFuncBody("_RebuildHotstringsLiveOnce")

    Assert(InStr(Preload, "LoggerTrace") > 0 && InStr(Preload, "LoggerDone") > 0,
        "Onboarding config preload must close its traced lifecycle on fallback paths")
    Assert(InStr(Rebuild, "LoggerStart") > 0 && InStr(Rebuild, "catch as e") > 0
            && InStr(Rebuild, "LoggerError") > 0 && InStr(Rebuild, "throw e") > 0,
        "the serialized live-rebuild pass must log and rethrow failures so its LoggerStart never has a silent unmatched exit")
}

Test("menu manifest: every traced fallback closes its logger lifecycle",
    _MMLP_AllPostTraceFallbacksCloseLifecycle)
Test("onboarding/menu: traced lifecycle failures are closed and propagated (menu-rebuild-lifecycle-pair)",
    _MMLP_OnboardingAndLiveRebuildCloseTheirLifecycles)
