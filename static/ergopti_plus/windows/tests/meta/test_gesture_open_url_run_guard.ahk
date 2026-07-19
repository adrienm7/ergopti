; tests/meta/test_gesture_open_url_run_guard.ahk

; ============================================================================== 
; MODULE: Gesture Configured URL Launch Guard Regression Test
; DESCRIPTION:
; A valid configured URL can still fail at the Windows shell boundary.  The
; gesture callback must contain Run() failure rather than raising through the
; driver's global input error handler.
; ============================================================================== 

#Requires AutoHotkey v2.0

_GOURG_ConfiguredUrlLaunchIsGuarded() {
    Body := _DriverFuncBody("GestureOpenConfiguredURL")
    Assert(Body != "", "GestureOpenConfiguredURL must exist")
    ValidatePos := InStr(Body, "GestureValidateActionParameter")
    RunPos := InStr(Body, "Run(URL)")
    CatchPos := InStr(Body, "catch as Err")
    Assert(ValidatePos > 0 && RunPos > ValidatePos,
        "gesture URL launch must remain after parameter validation")
    Assert(CatchPos > RunPos,
        "gesture URL shell failure must be caught after Run(URL)")
    Assert(InStr(Body, "LoggerError") > CatchPos && InStr(Body, "TrayTip") > CatchPos,
        "failed gesture URL launch must be logged and reported non-modally")
}
Test("gestures: configured URL shell launch failures are contained", _GOURG_ConfiguredUrlLaunchIsGuarded)
