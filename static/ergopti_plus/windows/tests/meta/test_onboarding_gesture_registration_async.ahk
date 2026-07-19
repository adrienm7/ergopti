; tests/meta/test_onboarding_gesture_registration_async.ahk
#Requires AutoHotkey v2.0

_OGRA_NativeRegistrationIsAsync() {
    Start := _DriverFuncBody("_Onboarding_StartGestureAuto")
    Poll := _DriverFuncBody("_Onboarding_PollGestureAuto")
    Builder := _DriverFuncBody("_Onboarding_BuildGesturePsScript")
    ClickBody := _DriverFuncBody("_Step5_AutoRegister")
    Web := _DriverFuncBody("_OnbWeb_RegisterGesturesAuto")
    Assert(Start != "" && Poll != "" && Builder != "" && ClickBody != "" && Web != "", "onboarding async registration helpers must exist")
    Assert(InStr(Start, "RunWait") = 0 && InStr(ClickBody, "RunWait") = 0,
        "native onboarding gesture registration must never block the AHK thread with RunWait")
    Assert(InStr(Start, "Run(") > 0 && InStr(Start, "&Pid") > 0 && InStr(Start, "SetTimer") > 0,
        "registration must launch asynchronously, retain its PID, and arm a completion poll")
    Assert(InStr(Start, "result") > 0 && InStr(Start, "A_Pid") > 0,
        "each worker must own a fresh result file, so an old successful status cannot be reused")
    Assert(InStr(Poll, "ProcessExist") > 0 && InStr(Poll, "A_IsSuspended") > 0 && InStr(Poll, "_Onboarding_ReadGestureAutoResult") > 0,
        "completion must wait across Suspend and trust only the worker-authored result, never a racy PID exit-code lookup")
    Assert(InStr(Poll, "_SR_GetExitCode") = 0,
        "a vanished process handle must fail closed rather than being reported as success")
    Assert(InStr(Builder, "$ErgoptiExitCode = 1") > 0 && InStr(Builder, "WriteAllText") > 0 && InStr(Builder, "exit $ErgoptiExitCode") > 0,
        "the elevated worker must fail closed and publish its own final result before exit")
    Assert(InStr(Web, "RunWait") = 0 && InStr(Web, "_Onboarding_StartGestureAuto") > 0,
        "WebView onboarding must use the same asynchronous PID-owned registration path")
    Assert(InStr(Web, "GestureAutoDone.Bind(SessionEpoch)") > 0,
        "the WebView callback must retain the controller session that started the worker")
    Done := _DriverFuncBody("_OnbWeb_GestureAutoDone")
    Assert(InStr(Done, "SessionEpoch != _OnbWeb_SessionEpoch") > 0 && InStr(Done, "A_IsSuspended") > 0,
        "a stale or suspended WebView completion must not publish into the active wizard")
}

Test("onboarding: native gesture registration is asynchronous and PID-owned", _OGRA_NativeRegistrationIsAsync)
