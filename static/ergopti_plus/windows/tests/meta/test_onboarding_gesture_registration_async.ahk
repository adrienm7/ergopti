; tests/meta/test_onboarding_gesture_registration_async.ahk
#Requires AutoHotkey v2.0

_OGRA_NativeRegistrationIsAsync() {
    Start := _DriverFuncBody("_Onboarding_StartGestureAuto")
    Poll := _DriverFuncBody("_Onboarding_PollGestureAuto")
    ClickBody := _DriverFuncBody("_Step5_AutoRegister")
    Web := _DriverFuncBody("_OnbWeb_RegisterGesturesAuto")
    Assert(Start != "" && Poll != "" && ClickBody != "" && Web != "", "onboarding async registration helpers must exist")
    Assert(InStr(Start, "RunWait") = 0 && InStr(ClickBody, "RunWait") = 0,
        "native onboarding gesture registration must never block the AHK thread with RunWait")
    Assert(InStr(Start, "Run(") > 0 && InStr(Start, "&Pid") > 0 && InStr(Start, "SetTimer") > 0,
        "registration must launch asynchronously, retain its PID, and arm a completion poll")
    Assert(InStr(Poll, "ProcessExist") > 0 && InStr(Poll, "_SR_GetExitCode") > 0,
        "completion must poll process exit and publish the real exit code")
    Assert(InStr(Web, "RunWait") = 0 && InStr(Web, "_Onboarding_StartGestureAuto") > 0,
        "WebView onboarding must use the same asynchronous PID-owned registration path")
}

Test("onboarding: native gesture registration is asynchronous and PID-owned", _OGRA_NativeRegistrationIsAsync)
