; tests/meta/test_shell_runner_isolated_logger.ahk

; ============================================================================== 
; MODULE: ShellRunner Isolated Logger Regression Test
; DESCRIPTION:
; Validating adapters/shell_runner.ahk directly with #Warn previously treated
; LoggerError as an unassigned local because logger.ahk belongs to the outer
; driver include graph.  An adapter must remain parse-clean in isolation.
; ============================================================================== 

#Requires AutoHotkey v2.0

_SRIL_NoStaticLoggerDependency() {
    Helper := _DriverFuncBody("_SR_LogError")
    ExecBody := _DriverFuncBody("ShellRunner_Exec")
    StartBody := _DriverFuncBody("_SR_HandleStart")
    PollBody := _DriverFuncBody("_SR_Poll")
    Assert(Helper != "", "ShellRunner must define its isolated logging helper")
    Assert(InStr(Helper, 'Func("LoggerError")') > 0 && InStr(Helper, "OutputDebug") > 0,
        "_SR_LogError must dynamically resolve LoggerError and retain a standalone diagnostic fallback")
    Assert(InStr(ExecBody, "_SR_LogError(") > 0 && InStr(ExecBody, 'LoggerError("') = 0,
        "ShellRunner_Exec must not call LoggerError statically")
    Assert(InStr(StartBody, "_SR_LogError(") > 0 && InStr(StartBody, 'LoggerError("') = 0,
        "ShellRunner start failures must not call LoggerError statically")
    Assert(InStr(PollBody, "_SR_LogError(") > 0 && InStr(PollBody, 'LoggerError("') = 0,
        "ShellRunner completion failures must not call LoggerError statically")
}
Test("shell_runner: isolated validation has no static LoggerError dependency",
    _SRIL_NoStaticLoggerDependency)
