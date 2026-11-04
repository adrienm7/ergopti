; tests/meta/modules/llm/navigation/test_gpt_hotkey_run_guard.ahk

; ============================================================================== 
; MODULE: GPT Hotkey Run Guard Regression Test
; DESCRIPTION:
; Win+G launches a user-configured URL from the keyboard callback.  A malformed
; URL or denied shell association must be contained at that boundary; otherwise
; Run() escapes into the global error handler and degrades the keyboard path.
; ============================================================================== 

#Requires AutoHotkey v2.0

_GHG_ReadSource(RelPath) {
    SplitPath(A_ScriptDir, , &WindowsDir)
    return FileRead(WindowsDir . "\\" . StrReplace(RelPath, "/", "\\"))
}

_GHG_ConfiguredUrlLaunchIsGuarded() {
    Body := _DriverFuncBody("GestureOpenChatGpt")
    Source := _DriverDirConcat("modules/gestures")
    Assert(Body != "", "GestureOpenChatGpt must own the Win+G callback")
    Assert(InStr(Source, '"open_chatgpt", {') > 0,
        "open_chatgpt must dispatch through the guarded GestureOpenChatGpt callback")
    Assert(InStr(Body, "try") > 0 && InStr(Body, "catch as Err") > 0,
        "GestureOpenChatGpt must contain Run/config failures")
    Assert(InStr(Body, "Run(Link)") > 0,
        "GestureOpenChatGpt must launch the configured link only inside its guard")
    Assert(InStr(Body, "LoggerError") > 0 && InStr(Body, "TrayTip") > 0,
        "a failed Win+G launch must be logged and reported without a modal dialog")
    Assert(InStr(Body, "Type(Link)") > 0,
        "GestureOpenChatGpt must reject a non-string/empty config before Run")
}
Test("shortcuts: Win+G contains configured URL launch failures", _GHG_ConfiguredUrlLaunchIsGuarded)
