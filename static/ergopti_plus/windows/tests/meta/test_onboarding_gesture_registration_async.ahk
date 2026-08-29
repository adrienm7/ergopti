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
    Reserve := _DriverFuncBody("_Onboarding_ReserveGestureAuto")
    Assert(InStr(Start, "Run(") > 0 && InStr(Start, "&Pid") > 0
			&& InStr(Start, "_Onboarding_ReserveGestureAuto(") > 0
			&& InStr(Reserve, "TimerFn.Call(PollFn, -100)") > 0
			&& InStr(Reserve, "SetTimer(PollFn, -100)") > 0,
		"registration must launch asynchronously, retain its PID, and arm a completion poll")
	Assert(InStr(Start, "result") > 0 && InStr(Start, "DriverPid") > 0,
		"each worker must own a fresh result file (DriverPid + epoch), so an old successful status cannot be reused")
	StartReceiptPos := InStr(Start, "FileExist(_OnboardingGestureJob")
	StartPidPos := InStr(Start, "ProcessExist(_OnboardingGestureJob")
	Assert(StartReceiptPos > 0 && StartPidPos > StartReceiptPos,
		"a second launch must consume the old receipt before consulting its recyclable PID")
	Assert(InStr(Poll, "ProcessExist") > 0 && InStr(Poll, "A_IsSuspended") > 0 && InStr(Poll, "_Onboarding_ReadGestureAutoResult") > 0,
		"completion must wait across Suspend and trust only the worker-authored result, never a racy PID exit-code lookup")
	ReceiptPos := InStr(Poll, "FileExist(_OnboardingGestureJob")
	PidPos := InStr(Poll, "ProcessExist(_OnboardingGestureJob")
	Assert(ReceiptPos > 0 && PidPos > ReceiptPos,
		"the atomically published receipt must win before a potentially recycled launch PID (AHK-084)")
    Assert(InStr(Poll, "_SR_GetExitCode") = 0,
        "a vanished process handle must fail closed rather than being reported as success")
	Assert(InStr(Builder, "$ErgoptiExitCode = 1") > 0 && InStr(Builder, "WriteAllText($ResultStage") > 0
		&& InStr(Builder, "[System.IO.File]::Move($ResultStage, $ResultPath)") > 0
		&& InStr(Builder, "exit $ErgoptiExitCode") > 0,
		"the elevated worker must fail closed and atomically publish its own final result before exit")
    Assert(InStr(Web, "RunWait") = 0 && InStr(Web, "_Onboarding_StartGestureAuto") > 0,
        "WebView onboarding must use the same asynchronous PID-owned registration path")
    Assert(InStr(Web, "GestureAutoDone.Bind(SessionEpoch)") > 0,
        "the WebView callback must retain the controller session that started the worker")
    Done := _DriverFuncBody("_OnbWeb_GestureAutoDone")
    Assert(InStr(Done, "SessionEpoch != _OnbWeb_SessionEpoch") > 0 && InStr(Done, "A_IsSuspended") > 0,
        "a stale or suspended WebView completion must not publish into the active wizard")
}

Test("onboarding: native gesture registration is asynchronous and receipt-owned (AHK-084)", _OGRA_NativeRegistrationIsAsync)

global _OGRA_ReserveTimerCalls := 0
global _OGRA_ExpectedCandidate := 0

_OGRA_ObserveReservationTimer(Callback, DelayMs) {
	global _OnboardingGestureJob, _OGRA_ReserveTimerCalls, _OGRA_ExpectedCandidate
	_OGRA_ReserveTimerCalls += 1
	Assert(A_IsCritical,
		"onboarding poller admission and reservation must be non-interruptible")
	AssertFalse(_OnboardingGestureJob == _OGRA_ExpectedCandidate,
		"onboarding must acquire its completion poller before publishing the candidate")
}

_OGRA_ElevatedLaunchIsReservedBeforeRun() {
	global _OnboardingGestureJob, _OGRA_ReserveTimerCalls, _OGRA_ExpectedCandidate
	SavedJob := _OnboardingGestureJob
	try {
		_OnboardingGestureJob := Map("epoch", 0, "pid", 0, "script", "", "result", "", "done", 0,
			"starting", false)
		_OGRA_ReserveTimerCalls := 0
		Candidate := Map("epoch", 88002, "pid", 0, "script", "worker.ps1",
			"result", "worker.result", "done", 0, "starting", true)
		_OGRA_ExpectedCandidate := Candidate
		AssertTrue(_Onboarding_ReserveGestureAuto(Candidate, _OGRA_ObserveReservationTimer),
			"the first onboarding worker must reserve one exact epoch")
		AssertFalse(_Onboarding_ReserveGestureAuto(Candidate.Clone(), _OGRA_ObserveReservationTimer),
			"a re-entrant onboarding launch must be rejected during UAC")
		AssertEqual(1, _OGRA_ReserveTimerCalls,
			"a rejected onboarding duplicate must not acquire another poller")
		Body := _DriverFuncBody("_Onboarding_StartGestureAuto")
		Assert(InStr(Body, "_Onboarding_ReserveGestureAuto(") > 0
				&& InStr(Body, "_Onboarding_ReserveGestureAuto(") < InStr(Body, "Run("),
			"onboarding must reserve the worker before crossing the elevated Run seam")
	} finally {
		_OnboardingGestureJob := SavedJob
		_OGRA_ExpectedCandidate := 0
	}
}
Test("onboarding: elevated worker admission is serialized (touchpad-worker-admission)",
	_OGRA_ElevatedLaunchIsReservedBeforeRun)
