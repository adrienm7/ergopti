; tests/meta/test_personal_shortcuts_reload_handoff.ahk

; ==============================================================================
; MODULE: Personal shortcuts first-run reload hand-off regression test
; DESCRIPTION:
; AHK Reload launches the replacement but returns to the current auto-execute
; thread. The old process must exit before it reaches hook/layout registration,
; otherwise both instances can own keyboard input during first-run generation.
; ==============================================================================

#Requires AutoHotkey v2.0

_PSRH_EnsureHandoffExitsOldOwner() {
    EnsureBody := _DriverFuncBody("EnsurePersonalShortcutsFile")
    Assert(EnsureBody != "", "EnsurePersonalShortcutsFile() must exist")

    ReloadPos := InStr(EnsureBody, "Reload")
    ExitPos := InStr(EnsureBody, "ExitApp(0)", false, ReloadPos)
    Assert(ReloadPos > 0 && ExitPos > ReloadPos,
        "A generated personal-shortcuts reload must immediately ExitApp(0) so the old process cannot register input alongside its replacement")

}

Test("meta personal-shortcuts: reload hand-off exits old keyboard owner",
    _PSRH_EnsureHandoffExitsOldOwner)
