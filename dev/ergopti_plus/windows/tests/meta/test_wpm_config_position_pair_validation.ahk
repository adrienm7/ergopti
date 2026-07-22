; tests/meta/test_wpm_config_position_pair_validation.ahk

; ==============================================================================
; MODULE: WPM position pair validation guard
; DESCRIPTION:
; WPMWidget_LoadConfig used to validate only CFG_X then call Integer(raw_y)
; unconditionally. A missing or malformed Y in a user-edited configuration
; raised during boot after keyboard subsystems had already registered. The
; position is one value: both coordinates must validate before either is used.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPCPPV_RequiresBothCoordinateValues() {
    Body := _DriverFuncBody("WPMWidget_LoadConfig")
    Assert(Body != "", "WPMWidget_LoadConfig must exist in ui/wpm/wpm_config.ahk")

    GuardPos := InStr(Body, "IsInteger(raw_x)")
    YGuardPos := InStr(Body, "IsInteger(raw_y)")
    ConvertPos := InStr(Body, "Integer(raw_y)")
    Assert(GuardPos > 0 && YGuardPos > GuardPos,
        "WPMWidget_LoadConfig must validate raw_y as well as raw_x before accepting a saved position")
    Assert(ConvertPos > YGuardPos,
        "WPMWidget_LoadConfig must validate raw_y before Integer(raw_y) can execute")
    Assert(InStr(Body, 'raw_y != "_"') > 0 && InStr(Body, 'raw_y != ""') > 0,
        "WPMWidget_LoadConfig must reject missing position Y values instead of converting them during boot")
}

Test("wpm config: saved position requires valid X and Y before conversion", _WPCPPV_RequiresBothCoordinateValues)
