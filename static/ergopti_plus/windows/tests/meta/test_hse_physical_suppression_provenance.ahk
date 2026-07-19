; tests/meta/test_hse_physical_suppression_provenance.ahk
; MODULE: HSE Physical Suppression Provenance Meta Test
#Requires AutoHotkey v2.0

_HPSP_PhysicalInputBypassesSyntheticSuppress() {
    Engine := _DriverFuncBody("HSE_FeedChar")
    Backspace := _DriverFuncBody("HSE_FeedBackspace")
    Hook := _DriverFuncBody("_OnPrefixChar")
    Assert(InStr(Engine, "IsPhysical := false") > 0, "HSE_FeedChar must carry explicit event provenance")
    Assert(InStr(Engine, "HSE_Suppressed and !IsPhysical") > 0, "synthetic suppression must not reject physical input")
    Assert(InStr(Hook, "HSE_FeedChar(Char, true)") > 0, "InputHook must mark observed input physical")
    Assert(InStr(Backspace, "IsPhysical := false") > 0 && InStr(Backspace, "HSE_Suppressed and !IsPhysical") > 0,
        "HSE_FeedBackspace must preserve physical backspaces during synthetic suppression")
    Assert(InStr(Hook, "HSE_FeedBackspace(true)") > 0, "InputHook keydown must mark Backspace physical")
}
Test("HSE: physical input bypasses synthetic suppression by provenance", _HPSP_PhysicalInputBypassesSyntheticSuppress)
