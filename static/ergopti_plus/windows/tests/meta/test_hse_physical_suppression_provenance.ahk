; tests/meta/test_hse_physical_suppression_provenance.ahk
; MODULE: HSE Physical Suppression Provenance Meta Test
#Requires AutoHotkey v2.0

_HPSP_PhysicalInputBypassesSyntheticSuppress() {
    Engine := _DriverFuncBody("HSE_FeedChar")
    Backspace := _DriverFuncBody("HSE_FeedBackspace")
    Reset := _DriverFuncBody("HSE_FeedReset")
    CharHook := _DriverFuncBody("_OnPrefixChar")
    KeyDownHook := _DriverFuncBody("_OnPrefixKeyDown")
    Assert(InStr(Engine, "IsPhysical := false") > 0, "HSE_FeedChar must carry explicit event provenance")
    Assert(InStr(Engine, "HSE_Suppressed and !IsPhysical") > 0, "synthetic suppression must not reject physical input")
    Assert(InStr(CharHook, "HSE_FeedChar(Char, true)") > 0, "InputHook OnChar must mark observed input physical")
    Assert(InStr(Backspace, "IsPhysical := false") > 0 && InStr(Backspace, "HSE_Suppressed and !IsPhysical") > 0,
        "HSE_FeedBackspace must preserve physical backspaces during synthetic suppression")
    Assert(InStr(KeyDownHook, "HSE_FeedBackspace(true)") > 0, "InputHook keydown must mark Backspace physical")
    Assert(InStr(Reset, "IsPhysical := false") > 0 && InStr(Reset, "HSE_Suppressed and !IsPhysical") > 0,
        "HSE_FeedReset must preserve physical navigation resets during synthetic suppression")
    Assert(InStr(KeyDownHook, "HSE_FeedReset(true, true)") > 0, "InputHook navigation resets must carry physical provenance")
}
Test("HSE: physical input bypasses synthetic suppression by provenance", _HPSP_PhysicalInputBypassesSyntheticSuppress)
